import Foundation
import MultipeerConnectivity
import Combine
import UserNotifications
import os
#if canImport(UIKit)
import UIKit
#endif

/// Wraps MCSession + advertiser + browser into a mesh-topology manager.
/// Every peer advertises and browses simultaneously, and every peer floods
/// envelopes on toward peers it isn't directly connected to (see
/// floodForward) — there's no single designated relay device, so a message
/// can hop across several intermediate devices to reach one that's out of
/// direct range.
@MainActor
final class MeshManager: NSObject, ObservableObject {

    static let serviceType = "app-chat" // <=15 chars, lowercase, hyphens only

    // MARK: Published state

    @Published private(set) var discoveredPeers: [String: DiscoveredPeer] = [:]
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var activeTransfers: [UUID: FileTransfer] = [:]
    @Published var pendingTrustRequest: DiscoveredPeer?
    @Published private(set) var localNetworkAuthorized: Bool = true
    @Published var currentGroup: ChatGroup
    @Published private(set) var typingPeerIDs: Set<String> = []

    /// Rolling log of discovery/connect/trust/route events for the Debug
    /// view — lets you see *why* a device isn't connecting or where a
    /// message is actually routing instead of guessing. Capped and pruned
    /// FIFO so a long session doesn't grow this unbounded.
    @Published private(set) var debugLog: [DebugLogEntry] = []
    private let debugLogCap = 300

    /// Reconstructed mesh topology, gossiped by every peer: topologyEdges[id]
    /// = the set of peer IDs that peer is directly
    /// connected to. Merges what I know locally with what everyone else has
    /// reported about themselves, so the Discovery graph can show the whole
    /// mesh even for peers I've never been in direct range of.
    @Published private(set) var topologyEdges: [String: Set<String>] = [:]
    @Published private(set) var topologyNames: [String: String] = [:]

    /// Last time each ID showed up in topology gossip (as a sender or as
    /// someone a sender listed as a direct connection). Drives pruning of
    /// stale relay-only placeholder peers — see syncRelayReachablePeers.
    private var topologyLastSeen: [String: Date] = [:]
    private let relayPeerStaleAfter: TimeInterval = 20

    /// Set from ChatApp via scenePhase so incoming-message notifications are
    /// skipped while the chat is actually on screen, and fire once it isn't.
    @Published var isAppActive: Bool = true

    /// Stand-in for a system notification while the app is foregrounded
    /// (where those are suppressed). The view layer animates this in/out.
    @Published var inAppBanner: InAppBanner?

    /// Set by ChatView's onAppear/onDisappear. The banner is redundant (and
    /// visually annoying) when the user is already looking at the chat that
    /// just received the message, so it's skipped in that case.
    @Published var isChatViewVisible: Bool = false

    // MARK: Identity

    private(set) var localPeerID: MCPeerID
    private(set) var localDisplayName: String

    // MARK: MC plumbing

    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    private var trustStore: TrustStore
    private let onMessagesChanged: ([ChatMessage]) -> Void
    private var messageStore: MessageStore?

    private var reconnectTimer: Timer?
    private var expiryTimer: Timer?
    private var topologyTimer: Timer?
    private let knownInvitees = NSMutableSet() // avoid duplicate invites in-flight
    private var notificationAuthRequested = false

    /// Envelope IDs already relayed, so a flooded envelope that loops back
    /// around the mesh (any cycle in the connection graph) gets dropped
    /// instead of being forwarded again and again. Capped and pruned FIFO —
    /// this only needs to remember recent traffic, not forever.
    private var seenEnvelopeIDs: Set<UUID> = []
    private var seenEnvelopeOrder: [UUID] = []
    private let seenEnvelopeCap = 500

    /// Returns true the first time this envelope ID is seen; false (and
    /// records nothing new) on repeats.
    private func markSeenIfNew(_ id: UUID) -> Bool {
        guard !seenEnvelopeIDs.contains(id) else { return false }
        seenEnvelopeIDs.insert(id)
        seenEnvelopeOrder.append(id)
        if seenEnvelopeOrder.count > seenEnvelopeCap {
            let oldest = seenEnvelopeOrder.removeFirst()
            seenEnvelopeIDs.remove(oldest)
        }
        return true
    }

    /// Real structured logging (os.Logger / the unified logging system)
    /// instead of bare print(): every entry gets a subsystem + a category
    /// matching DebugLogEntry.Category, so in Console.app (or Xcode's
    /// console) you can filter to just "route" or just "error", the level
    /// (debug/info/error) drives the icon/color Console.app shows, and the
    /// log survives after the process exits — none of which a plain print()
    /// statement gives you. `\(message, privacy: .public)` is required or
    /// the unified logging system redacts dynamic content as "<private>" by
    /// default, which would make copied logs useless.
    private static let logSubsystem = Bundle.main.bundleIdentifier ?? "com.meshchat.app"

    private static let loggers: [DebugLogEntry.Category: Logger] = [
        .discovery: Logger(subsystem: logSubsystem, category: "discovery"),
        .connect: Logger(subsystem: logSubsystem, category: "connect"),
        .route: Logger(subsystem: logSubsystem, category: "route"),
        .trust: Logger(subsystem: logSubsystem, category: "trust"),
        .error: Logger(subsystem: logSubsystem, category: "error")
    ]

    private func log(_ category: DebugLogEntry.Category, _ message: String) {
        debugLog.append(DebugLogEntry(timestamp: Date(), category: category, message: message))
        if debugLog.count > debugLogCap {
            debugLog.removeFirst(debugLog.count - debugLogCap)
        }

        let logger = Self.loggers[category] ?? Logger(subsystem: Self.logSubsystem, category: "mesh")
        switch category {
        case .error:
            logger.error("\(message, privacy: .public)")
        case .connect, .trust:
            logger.info("\(message, privacy: .public)")
        case .discovery, .route:
            logger.debug("\(message, privacy: .public)")
        }
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    /// Best-effort human-readable name for a stable peer ID, for log
    /// messages — falls back to whatever's known (topology gossip, a
    /// discovered peer, or just the raw ID) rather than requiring a real
    /// MCPeerID to be on hand.
    private func displayName(for id: String) -> String {
        if id == DiscoveredPeer.stableID(for: localPeerID) { return "me" }
        return topologyNames[id] ?? discoveredPeers[id]?.mcPeerID.displayName ?? id
    }

    /// Messages older than this vanish from history, in memory and on disk.
    static let messageLifetime: TimeInterval = 24 * 60 * 60

    /// Correlates didStartReceivingResourceWithName with the later
    /// didFinishReceivingResourceWithName callback (MCSession gives no
    /// shared token between them besides peer+resource name), so the
    /// transfer bar can be marked complete/failed instead of sitting at
    /// "100%, still in progress" forever.
    private var receivingTransferIDs: [String: UUID] = [:]

    private func receivingTransferKey(peerID: MCPeerID, resourceName: String) -> String {
        "\(DiscoveredPeer.stableID(for: peerID))|\(resourceName)"
    }

    init(
        displayName: String,
        group: ChatGroup,
        trustStore: TrustStore = TrustStore(),
        onMessagesChanged: @escaping ([ChatMessage]) -> Void = { _ in }
    ) {
        let peerID = MCPeerID(displayName: displayName)
        self.localPeerID = peerID
        self.localDisplayName = displayName
        self.currentGroup = group
        self.trustStore = trustStore
        self.onMessagesChanged = onMessagesChanged

        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)

        let discoveryInfo: [String: String] = [
            DiscoveryKey.groupName: group.name,
            DiscoveryKey.displayName: displayName
        ]

        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: discoveryInfo,
            serviceType: Self.serviceType
        )
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startReconnectTimer()
        startExpiryTimer()
        startTopologyTimer()
        requestNotificationAuthorizationIfNeeded()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
    }

    private func startTopologyTimer() {
        topologyTimer?.invalidate()
        broadcastTopology()
        topologyTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastTopology()
            }
        }
    }

    private func startReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rejoinDroppedPeers()
            }
        }
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        purgeExpiredMessages()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeExpiredMessages()
            }
        }
    }

    /// Drops any message older than messageLifetime from memory and from
    /// disk. Runs on a timer plus once at startup, so history someone left
    /// sitting overnight is gone by the time they reopen the app, not just
    /// the next time a new message happens to trigger a save.
    private func purgeExpiredMessages() {
        let cutoff = Date().addingTimeInterval(-Self.messageLifetime)
        let before = messages.count
        messages.removeAll { $0.timestamp < cutoff }
        if messages.count != before {
            onMessagesChanged(messages)
        }
        messageStore?.purgeMessages(olderThan: Self.messageLifetime)
    }

    /// Peers that dropped to .notConnected but are still discovered nearby
    /// get re-invited. Chat history is keyed by stable peerID so reconnects
    /// never duplicate it. Gated by shouldInitiateAutoConnect so both sides
    /// of an already-mutually-trusted pair don't invite each other at once,
    /// and by reconnectBackoff so a peer that keeps failing to connect (bad
    /// radio conditions, genuinely out of range) gets retried less
    /// aggressively over time instead of being hammered every 8s forever —
    /// which mostly just adds more collision risk without ever actually
    /// helping it reconnect sooner.
    private func rejoinDroppedPeers() {
        let now = Date()
        for (id, peer) in discoveredPeers where peer.state == .notConnected {
            guard trustStore.isTrusted(id), shouldInitiateAutoConnect(to: peer.mcPeerID) else { continue }
            if let nextAllowed = nextReconnectAttempt[id], nextAllowed > now { continue }
            invite(peer.mcPeerID)
        }
    }

    /// Consecutive failed-to-connect attempts per peer, and the earliest
    /// time the next one is allowed. Reset the moment a peer actually
    /// reaches .connected (see session(_:peer:didChange:)).
    private var reconnectAttempts: [String: Int] = [:]
    private var nextReconnectAttempt: [String: Date] = [:]

    private func recordFailedReconnect(for id: String) {
        let attempt = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempt
        // 8s, 16s, 32s, 64s, capped at 2 minutes.
        let delay = min(8.0 * pow(2.0, Double(attempt - 1)), 120.0)
        nextReconnectAttempt[id] = Date().addingTimeInterval(delay)
        log(.connect, "\(displayName(for: id)): backing off, next retry in \(Int(delay))s (attempt \(attempt))")
    }

    private func resetReconnectBackoff(for id: String) {
        reconnectAttempts[id] = nil
        nextReconnectAttempt[id] = nil
    }

    /// When both sides already trust each other, both would otherwise try to
    /// invite one another the instant they rediscover each other — a known
    /// MultipeerConnectivity race where the session connects and then
    /// immediately drops because two simultaneous invitations collide.
    /// Deterministically let only the "lower" stable ID initiate; the other
    /// side just waits to receive (and auto-accept) the invitation.
    private func shouldInitiateAutoConnect(to mcPeerID: MCPeerID) -> Bool {
        DiscoveredPeer.stableID(for: localPeerID) < DiscoveredPeer.stableID(for: mcPeerID)
    }

    // MARK: Trust

    /// Marks a peer trusted without inviting. Used when we're accepting an
    /// *inbound* invitation — the invitationHandler passed to the advertiser
    /// delegate already joins the session, so also calling invite() here
    /// would fire a redundant outbound invite at the same peer and race with
    /// the connection that's already being established.
    private func markTrusted(_ peer: DiscoveredPeer) {
        trustStore.trust(peerID: peer.id, displayName: peer.mcPeerID.displayName)
        if pendingTrustRequest?.id == peer.id {
            pendingTrustRequest = nil
        }
        discoveredPeers[peer.id]?.isTrusted = true
    }

    /// User-initiated connect (tapping "Connect" on a discovered peer):
    /// marks trusted and actively sends the invite, since at this point
    /// nothing else is going to.
    func trust(_ peer: DiscoveredPeer) {
        markTrusted(peer)
        if discoveredPeers[peer.id]?.state == .notConnected {
            discoveredPeers[peer.id]?.state = .connecting
        }
        log(.trust, "Trusting \(peer.mcPeerID.displayName) and connecting")

        if shouldInitiateAutoConnect(to: peer.mcPeerID) {
            invite(peer.mcPeerID)
        } else {
            // If both people tap Connect on each other at nearly the same
            // moment, whoever's invite lands second collides with the
            // first — the classic MultipeerConnectivity race where the
            // session connects and then immediately drops. Give the other
            // side's own invite a brief head start to land and auto-accept
            // first; if it doesn't show up in time, invite anyway so a
            // manual tap always eventually connects instead of silently
            // waiting forever.
            let peerID = peer.id
            let mcPeerID = peer.mcPeerID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.discoveredPeers[peerID]?.state != .connected else { return }
                self.invite(mcPeerID)
            }
        }
    }

    func decline(_ peer: DiscoveredPeer) {
        if pendingTrustRequest?.id == peer.id {
            pendingTrustRequest = nil
        }
    }

    // MARK: Invitations

    private func invite(_ mcPeerID: MCPeerID) {
        // Bonjour rediscovery pings keep firing browser(_:foundPeer:) for
        // peers we're already connected to, and that auto-invite path has no
        // connection-state check of its own — without this guard, an already
        // trusted+connected peer gets re-invited over and over for as long as
        // the session lasts, which re-runs the whole invite/accept handshake
        // (and can look like "asking to trust" repeatedly) instead of only
        // once per actual disconnect.
        guard !session.connectedPeers.contains(mcPeerID) else { return }
        guard !knownInvitees.contains(mcPeerID) else { return }
        knownInvitees.add(mcPeerID)
        log(.connect, "Inviting \(mcPeerID.displayName)")
        browser.invitePeer(mcPeerID, to: session, withContext: nil, timeout: 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self else { return }
            self.knownInvitees.remove(mcPeerID)
            let id = DiscoveredPeer.stableID(for: mcPeerID)
            if self.discoveredPeers[id]?.state == .connecting {
                self.discoveredPeers[id]?.state = .notConnected
                self.recordFailedReconnect(for: id)
                self.log(.error, "Invite to \(mcPeerID.displayName) timed out with no response")
            }
        }
    }

    // MARK: Sending text

    /// Every send below is a direct 1:1 message to a specific peer, not a
    /// broadcast — each connected device gets its own separate conversation
    /// thread (see ChatMessage.conversationPartnerID / ChatView's filtering)
    /// instead of one merged feed shared by everyone in the group.
    func sendText(_ text: String, to peer: DiscoveredPeer) {
        let message = ChatMessage(
            senderID: DiscoveredPeer.stableID(for: localPeerID),
            senderName: localDisplayName,
            type: .text,
            content: text,
            groupID: currentGroup.name,
            recipientPeerID: peer.id
        )
        appendLocal(message)
        sendChatMessage(message, to: peer, deliveryMode: .reliable)
    }

    /// Stickers are just an emoji glyph sent as its own message type so the
    /// UI can render it large and without a bubble background, Telegram-style.
    func sendSticker(_ emoji: String, to peer: DiscoveredPeer) {
        let message = ChatMessage(
            senderID: DiscoveredPeer.stableID(for: localPeerID),
            senderName: localDisplayName,
            type: .sticker,
            content: emoji,
            groupID: currentGroup.name,
            recipientPeerID: peer.id
        )
        appendLocal(message)
        sendChatMessage(message, to: peer, deliveryMode: .reliable)
    }

    func sendTypingIndicator(isTyping: Bool, to peer: DiscoveredPeer) {
        let message = ChatMessage(
            senderID: DiscoveredPeer.stableID(for: localPeerID),
            senderName: localDisplayName,
            type: .typing,
            content: isTyping ? "1" : "0",
            groupID: currentGroup.name,
            recipientPeerID: peer.id
        )
        sendChatMessage(message, to: peer, deliveryMode: .unreliable)
    }

    private func sendChatMessage(_ message: ChatMessage, to peer: DiscoveredPeer, deliveryMode: MCSessionSendDataMode) {
        guard let payload = try? JSONEncoder().encode(message) else { return }
        let envelope = MeshEnvelope(
            id: UUID(),
            kind: .chatMessage,
            originPeerID: message.senderID,
            targetPeerID: peer.id,
            hopCount: 0,
            payload: payload
        )
        // Typing indicators fire on every keystroke — logging those would
        // drown out everything else in the Debug view, so only real
        // messages/stickers/files get a route entry.
        if message.type != .typing {
            log(.route, routeDescription(sending: "message", to: peer.mcPeerID))
        }
        sendDirect(envelope, to: peer.mcPeerID, deliveryMode: deliveryMode)
    }

    /// Describes, for the Debug log, what sendDirect is about to try: a
    /// direct send if the peer is actually in session.connectedPeers, a
    /// flood if not (someone else will have to relay it the rest of the
    /// way), or the "stuck" case where there's nobody to even flood to yet.
    private func routeDescription(sending what: String, to mcPeerID: MCPeerID) -> String {
        let name = mcPeerID.displayName
        if session.connectedPeers.contains(mcPeerID) {
            return "Sending \(what) to \(name): direct connection"
        } else if !session.connectedPeers.isEmpty {
            return "Sending \(what) to \(name): no direct link, flooding via \(session.connectedPeers.count) connected peer(s)"
        } else {
            return "Sending \(what) to \(name): no connected peers at all — nothing to send it through yet"
        }
    }

    /// Sends straight to the peer if directly connected; otherwise floods to
    /// whoever we *are* connected to (targetPeerID stays set on the
    /// envelope), and every peer that receives it keeps forwarding it one
    /// hop closer via floodForward until it reaches the actual target — this
    /// is what lets a message reach a peer several hops away through
    /// intermediate devices, not just peers directly in range.
    private func sendDirect(_ envelope: MeshEnvelope, to mcPeerID: MCPeerID, deliveryMode: MCSessionSendDataMode) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        if session.connectedPeers.contains(mcPeerID) {
            try? session.send(data, toPeers: [mcPeerID], with: deliveryMode)
        } else if !session.connectedPeers.isEmpty {
            try? session.send(data, toPeers: session.connectedPeers, with: deliveryMode)
        }
    }

    private func appendLocal(_ message: ChatMessage) {
        messages.append(message)
        messageStore?.save(message)
        onMessagesChanged(messages)
    }

    /// Loads prior history for the current group from SwiftData and retains
    /// the store so future messages (sent or received) get persisted too.
    /// Existing in-memory messages for other groups are kept; duplicates by
    /// id are skipped so reconnects/relaunches never double up history.
    func loadPersistedHistory(from store: MessageStore) {
        messageStore = store
        store.purgeMessages(olderThan: Self.messageLifetime)
        store.saveGroup(currentGroup)
        let persisted = store.messages(groupID: currentGroup.name)
        let existingIDs = Set(messages.map(\.id))
        for message in persisted where !existingIDs.contains(message.id) {
            messages.append(message)
        }
        messages.sort { $0.timestamp < $1.timestamp }
    }

    private func sendEnvelope(_ envelope: MeshEnvelope, deliveryMode: MCSessionSendDataMode) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let connected = session.connectedPeers
        guard !connected.isEmpty else { return }
        do {
            try session.send(data, toPeers: connected, with: deliveryMode)
        } catch {
            log(.error, "Topology/control send failed: \(error.localizedDescription)")
        }
    }

    // MARK: Sending resources (files/video/images)

    @discardableResult
    func sendResource(at url: URL, named name: String, toPeer mcPeerID: MCPeerID) -> Progress? {
        let transferID = UUID()
        let transfer = FileTransfer(
            id: transferID,
            peerID: DiscoveredPeer.stableID(for: mcPeerID),
            fileName: name,
            direction: .sending,
            fractionCompleted: 0,
            status: .inProgress,
            estimatedSecondsRemaining: nil
        )
        activeTransfers[transferID] = transfer

        let progress = session.sendResource(at: url, withName: name, toPeer: mcPeerID) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.activeTransfers[transferID]?.status = .failed
                    self.scheduleTransferCleanup(transferID: transferID)
                    self.log(.error, "File send to \(mcPeerID.displayName) failed: \(error.localizedDescription)")
                } else {
                    self.activeTransfers[transferID]?.status = .completed
                    self.activeTransfers[transferID]?.fractionCompleted = 1
                    self.scheduleTransferCleanup(transferID: transferID)
                    let ext = (name as NSString).pathExtension.lowercased()
                    let type: MessageType = ["mov", "mp4", "m4v"].contains(ext) ? .video : .file
                    let message = ChatMessage(
                        senderID: DiscoveredPeer.stableID(for: self.localPeerID),
                        senderName: self.localDisplayName,
                        type: type,
                        content: name,
                        groupID: self.currentGroup.name,
                        recipientPeerID: DiscoveredPeer.stableID(for: mcPeerID),
                        fileName: name,
                        fileSize: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
                        localURL: url
                    )
                    self.appendLocal(message)
                }
            }
        }

        if let progress {
            observeProgress(progress, transferID: transferID)
        }
        return progress
    }

    private var progressObservers: [UUID: NSKeyValueObservation] = [:]

    /// Drops a finished/failed transfer out of activeTransfers (and its KVO
    /// observer) shortly after it settles, so the dictionary doesn't grow
    /// unbounded over a long session. The UI already hides non-.inProgress
    /// entries immediately; this is just memory hygiene.
    private func scheduleTransferCleanup(transferID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.activeTransfers.removeValue(forKey: transferID)
            self?.progressObservers.removeValue(forKey: transferID)
        }
    }

    private func observeProgress(_ progress: Progress, transferID: UUID) {
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
            Task { @MainActor [weak self] in
                self?.activeTransfers[transferID]?.fractionCompleted = prog.fractionCompleted
            }
        }
        progressObservers[transferID] = observation
    }

    /// Warn/queue guardrail for large files, called from UI before initiating a send.
    static func estimatedTransferSeconds(fileSizeBytes: Int, assumedThroughputMBps: Double = 3.0) -> Double {
        let mb = Double(fileSizeBytes) / (1024 * 1024)
        return mb / assumedThroughputMBps
    }

    static let largeFileThresholdBytes = 100 * 1024 * 1024

    // MARK: Group / relay switching

    func switchGroup(to group: ChatGroup) {
        stop()
        currentGroup = group
        discoveredPeers.removeAll()
        topologyEdges.removeAll()
        topologyNames.removeAll()
        topologyLastSeen.removeAll()
        reconnectAttempts.removeAll()
        nextReconnectAttempt.removeAll()

        rebuildNetworkStack()
        start()

        if let messageStore {
            loadPersistedHistory(from: messageStore)
        }
    }

    // MARK: Identity updates

    /// Changes the display name shown to peers. MCPeerID is immutable once
    /// created, so this tears down and recreates the whole session/advertiser
    /// /browser under a new peer identity — any currently connected peers
    /// will drop and need to reconnect (they'll see the new name).
    func updateIdentity(displayName: String) {
        let trimmed = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty, trimmed != localDisplayName else { return }

        stop()
        localDisplayName = trimmed
        localPeerID = MCPeerID(displayName: trimmed)
        discoveredPeers.removeAll()
        topologyEdges.removeAll()
        topologyNames.removeAll()
        topologyLastSeen.removeAll()
        reconnectAttempts.removeAll()
        nextReconnectAttempt.removeAll()

        rebuildNetworkStack()
        start()
    }

    /// Rebuilds session/advertiser/browser from the current localPeerID and
    /// currentGroup. Shared by switchGroup and updateIdentity so both stay
    /// in sync with the same discoveryInfo-construction logic.
    private func rebuildNetworkStack() {
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let discoveryInfo: [String: String] = [
            DiscoveryKey.groupName: currentGroup.name,
            DiscoveryKey.displayName: localDisplayName
        ]
        advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: discoveryInfo, serviceType: Self.serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        browser.delegate = self
    }

    // MARK: Local notifications

    private func requestNotificationAuthorizationIfNeeded() {
        // Without a delegate, UNUserNotificationCenter never presents a
        // notification's banner/sound while the app itself is frontmost —
        // it just silently calls willPresent(_:) and stops, on both iOS and
        // macOS. That's normally invisible on iOS (a banner is enough), but
        // on macOS people expect a real system notification even with the
        // app window open and focused (Messages/Slack/etc. all do this).
        UNUserNotificationCenter.current().delegate = self

        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            // This completion handler isn't guaranteed to run on the main
            // actor, and log()/MeshManager's state is — hop back over
            // before touching either.
            Task { @MainActor in
                if let error {
                    self?.log(.error, "Notification authorization error: \(error.localizedDescription)")
                } else if !granted {
                    self?.log(.error, "Notification authorization denied by user")
                }
            }
        }
    }

    /// Surfaces a message that just arrived from a peer. Skipped for the
    /// app's own outgoing messages, typing indicators, and whenever the
    /// exact chat that received it is already on screen (the message is
    /// already visible live there).
    ///
    /// - iOS: an in-app banner while foregrounded, a real system
    ///   notification while backgrounded — matches iOS convention, where
    ///   foreground alerts are usually suppressed in favor of in-app UI.
    /// - macOS: always a real system notification, even while the app
    ///   window is open and frontmost, since that's the normal Mac
    ///   convention for chat apps — plus the in-app banner as a same-window
    ///   cue when a different conversation is open.
    private func postLocalNotification(for message: ChatMessage) {
        guard message.senderID != DiscoveredPeer.stableID(for: localPeerID) else { return }
        guard message.type != .typing else { return }

        // isChatViewVisible only means anything while the app is actually
        // active — it doesn't reset on background, so it must never gate
        // the "app is backgrounded" branches below (that was a real bug:
        // it would silently drop a legitimate background notification for
        // whichever chat happened to be on screen before backgrounding).
        if isAppActive, isChatViewVisible {
            return
        }

        #if os(macOS)
        postSystemNotification(for: message)
        if isAppActive {
            showInAppBanner(for: message)
        }
        #else
        if isAppActive {
            showInAppBanner(for: message)
        } else {
            postSystemNotification(for: message)
        }
        #endif
    }

    private func postSystemNotification(for message: ChatMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.senderName
        content.subtitle = currentGroup.name
        content.body = notificationBody(for: message)
        content.sound = .default

        let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.log(.error, "Failed to post system notification: \(error.localizedDescription)")
            }
        }
    }

    /// Shows the in-app banner and auto-dismisses it a few seconds later,
    /// unless a newer banner has already replaced it by then.
    private func showInAppBanner(for message: ChatMessage) {
        let banner = InAppBanner(
            id: message.id,
            senderName: message.senderName,
            groupName: currentGroup.name,
            preview: notificationBody(for: message)
        )
        inAppBanner = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.inAppBanner?.id == banner.id else { return }
            self.inAppBanner = nil
        }
    }

    func dismissInAppBanner() {
        inAppBanner = nil
    }

    private func notificationBody(for message: ChatMessage) -> String {
        switch message.type {
        case .text: return message.content
        case .image: return "📷 Photo"
        case .video: return "🎬 Video"
        case .file: return "📎 \(message.fileName ?? "File")"
        case .sticker: return "\(message.content) Sticker"
        case .typing: return ""
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension MeshManager: UNUserNotificationCenterDelegate {
    /// Called whenever a notification would otherwise arrive while this app
    /// is the frontmost app. Returning .banner/.sound/.badge here is what
    /// actually makes postSystemNotification's macOS "always notify" promise
    /// true — without this, the system swallows it silently instead.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

// MARK: - MCSessionDelegate

extension MeshManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            var peer = discoveredPeers[id] ?? DiscoveredPeer(
                id: id,
                mcPeerID: peerID,
                groupName: nil,
                state: .notConnected,
                isTrusted: trustStore.isTrusted(id),
                isRelayed: false,
                lastSeen: Date()
            )
            // A real MCSession state change is unambiguous proof of a
            // direct connection — upgrade a relay-only placeholder (fake
            // MCPeerID, never actually in session.connectedPeers) to the
            // real one instead of leaving it stuck pointing at a
            // placeholder that invites/sends can't actually use directly.
            peer.mcPeerID = peerID
            peer.isRelayed = false
            peer.state = PeerConnectionState(from: state)
            peer.lastSeen = Date()
            discoveredPeers[id] = peer

            if state == .connected {
                // A real connection landed — clear any accumulated backoff
                // so a future drop starts retrying at the normal 8s pace
                // again instead of staying artificially slow.
                resetReconnectBackoff(for: id)
            }

            log(.connect, "\(peerID.displayName) → \(Self.describe(state))")

            // Any connect/disconnect changes my own edges in the mesh graph
            // — announce it right away instead of waiting for the next
            // periodic tick so the Discovery graph feels responsive.
            broadcastTopology()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else { return }
            // Drop anything we've already relayed/handled once before —
            // required for floodForward to terminate instead of looping
            // envelopes around any cycle in the mesh forever.
            guard markSeenIfNew(envelope.id) else { return }
            handle(envelope, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        Task { @MainActor in
            let transferID = UUID()
            let transfer = FileTransfer(
                id: transferID,
                peerID: DiscoveredPeer.stableID(for: peerID),
                fileName: resourceName,
                direction: .receiving,
                fractionCompleted: 0,
                status: .inProgress,
                estimatedSecondsRemaining: nil
            )
            activeTransfers[transferID] = transfer
            receivingTransferIDs[receivingTransferKey(peerID: peerID, resourceName: resourceName)] = transferID
            observeProgress(progress, transferID: transferID)
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        Task { @MainActor in
            let key = receivingTransferKey(peerID: peerID, resourceName: resourceName)
            let transferID = receivingTransferIDs.removeValue(forKey: key)

            guard let localURL, error == nil else {
                log(.error, "File receive from \(peerID.displayName) failed: \(error?.localizedDescription ?? "unknown")")
                if let transferID {
                    activeTransfers[transferID]?.status = .failed
                    scheduleTransferCleanup(transferID: transferID)
                }
                return
            }
            do {
                let destination = try Self.receivedFileDestination(named: resourceName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: localURL, to: destination)

                let ext = (resourceName as NSString).pathExtension.lowercased()
                let type: MessageType = ["mov", "mp4", "m4v"].contains(ext) ? .video :
                    (["png", "jpg", "jpeg", "heic", "gif"].contains(ext) ? .image : .file)

                let message = ChatMessage(
                    senderID: DiscoveredPeer.stableID(for: peerID),
                    senderName: peerID.displayName,
                    type: type,
                    content: resourceName,
                    groupID: currentGroup.name,
                    fileName: resourceName,
                    fileSize: (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil,
                    localURL: destination
                )
                if let transferID {
                    activeTransfers[transferID]?.status = .completed
                    activeTransfers[transferID]?.fractionCompleted = 1
                    scheduleTransferCleanup(transferID: transferID)
                }
                appendLocal(message)
                postLocalNotification(for: message)
            } catch {
                log(.error, "Failed to store received file from \(peerID.displayName): \(error.localizedDescription)")
                if let transferID {
                    activeTransfers[transferID]?.status = .failed
                    scheduleTransferCleanup(transferID: transferID)
                }
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used; all transport goes through send(_:toPeers:with:) and sendResource.
    }

    private static func describe(_ state: MCSessionState) -> String {
        switch state {
        case .notConnected: return "not connected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        @unknown default: return "unknown state"
        }
    }

    static func receivedFileDestination(named name: String) throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let receivedDir = docs.appendingPathComponent("Received", isDirectory: true)
        if !FileManager.default.fileExists(atPath: receivedDir.path) {
            try FileManager.default.createDirectory(at: receivedDir, withIntermediateDirectories: true)
        }
        return receivedDir.appendingPathComponent(name)
    }

    // MARK: Envelope handling / relay forwarding

    private func handle(_ envelope: MeshEnvelope, from peerID: MCPeerID) {
        switch envelope.kind {
        case .chatMessage:
            guard let message = try? JSONDecoder().decode(ChatMessage.self, from: envelope.payload) else { return }
            let myID = DiscoveredPeer.stableID(for: localPeerID)
            // targetPeerID is nil only for old/legacy envelopes; every
            // message sent by the current code has it set to the intended
            // recipient, so any relaying peer can tell "mine to keep" apart
            // from "someone else's, just pass it on" instead of
            // showing/relaying everything to everyone.
            let isForMe = envelope.targetPeerID == nil || envelope.targetPeerID == myID

            if message.type == .typing {
                if isForMe {
                    if message.content == "1" {
                        typingPeerIDs.insert(message.senderID)
                    } else {
                        typingPeerIDs.remove(message.senderID)
                    }
                } else {
                    floodForward(envelope, excluding: peerID)
                }
                return
            }

            if isForMe, !messages.contains(where: { $0.id == message.id }) {
                appendLocal(message)
                postLocalNotification(for: message)
                let route = envelope.hopCount == 0 ? "direct" : "via relay, \(envelope.hopCount) hop(s)"
                log(.route, "Received from \(message.senderName): \(route)")
            }
            // Every peer helps relay now, not just a designated host — keep
            // forwarding envelopes addressed to someone else one hop closer
            // to them, so a message can cross several intermediate devices
            // to reach a peer that's out of direct range.
            if let targetID = envelope.targetPeerID, targetID != myID {
                floodForward(envelope, excluding: peerID)
            }
        case .control:
            guard let control = try? JSONDecoder().decode(ControlMessage.self, from: envelope.payload) else { return }
            handleControl(control, from: peerID)
            // Topology/roster gossip has no single target — it floods to
            // the whole mesh — so keep passing it along too.
            if envelope.targetPeerID == nil {
                floodForward(envelope, excluding: peerID)
            }
        }
    }

    /// Worst case, a message needs one hop per *other* device in a straight
    /// chain to cross the whole mesh (device 1 -> 2 -> 3 -> ... -> N is N-1
    /// hops). So instead of a fixed cap, size it to how many distinct peers
    /// we actually know about right now (directly connected, or reported by
    /// someone else's topology gossip) — that's always enough hops to reach
    /// anyone currently reachable at all, and it grows automatically as more
    /// devices join instead of silently capping reach in a bigger mesh or
    /// wasting relays flooding a tiny one. Floors at 3 so a freshly-launched
    /// app (topology map still empty) isn't stuck at 0-1 hops before its
    /// first gossip round lands.
    private var dynamicHopCap: Int {
        var knownIDs = Set(topologyNames.keys)
        knownIDs.formUnion(discoveredPeers.keys)
        knownIDs.insert(DiscoveredPeer.stableID(for: localPeerID))
        return max(3, knownIDs.count - 1)
    }

    /// Re-sends an envelope (with hopCount bumped) toward its intended
    /// recipient if directly connected to them, or as a best-effort flood to
    /// everyone else otherwise. Every peer does this now (not just a
    /// designated relay host), which is what makes multi-hop delivery work:
    /// each hop only needs to know its own direct connections, not the whole
    /// route — the envelope just keeps getting handed one hop closer until
    /// hopCount hits the cap. seenEnvelopeIDs (checked before handle() is
    /// even called) stops it from looping forever around any cycle.
    private func floodForward(_ envelope: MeshEnvelope, excluding sender: MCPeerID) {
        // Topology gossip re-floods every ~6s from every peer, hop after hop
        // — logging that would drown out the actual chat routing the Debug
        // view is meant to surface, so only .chatMessage envelopes get a
        // route entry.
        let shouldLog = envelope.kind == .chatMessage

        guard envelope.hopCount < dynamicHopCap else {
            if shouldLog {
                log(.error, "Dropped message toward \(displayName(for: envelope.targetPeerID ?? "mesh")): hop cap (\(dynamicHopCap)) reached")
            }
            return
        }
        let forwarded = MeshEnvelope(
            id: envelope.id,
            kind: envelope.kind,
            originPeerID: envelope.originPeerID,
            targetPeerID: envelope.targetPeerID,
            hopCount: envelope.hopCount + 1,
            payload: envelope.payload
        )
        guard let data = try? JSONEncoder().encode(forwarded) else { return }

        if let targetID = envelope.targetPeerID,
           let targetPeer = session.connectedPeers.first(where: { DiscoveredPeer.stableID(for: $0) == targetID }) {
            if shouldLog {
                log(.route, "Relaying to \(targetPeer.displayName): direct from here (hop \(forwarded.hopCount))")
            }
            try? session.send(data, toPeers: [targetPeer], with: .reliable)
            return
        }

        let others = session.connectedPeers.filter { $0 != sender }
        guard !others.isEmpty else { return }
        if shouldLog {
            log(.route, "Relaying toward \(displayName(for: envelope.targetPeerID ?? "mesh")): flooding to \(others.count) peer(s) (hop \(forwarded.hopCount))")
        }
        try? session.send(data, toPeers: others, with: .reliable)
    }

    /// BFS hop-distance from me to `peerID` over the gossiped topology graph
    /// (same adjacency data the Discovery view draws) — 0 is me, 1 is a
    /// direct connection, 2+ means the message has to cross that many
    /// intermediate devices. Returns nil if I've never heard of this peer at
    /// all yet (e.g. we're mid-discovery and no gossip has arrived).
    func hopDistance(to peerID: String) -> Int? {
        let myID = DiscoveredPeer.stableID(for: localPeerID)
        guard peerID != myID else { return 0 }

        var adjacency: [String: Set<String>] = topologyEdges
        for (a, neighbors) in topologyEdges {
            for b in neighbors {
                adjacency[b, default: []].insert(a)
            }
        }

        var visited: Set<String> = [myID]
        var queue: [(id: String, hop: Int)] = [(myID, 0)]
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            if current.id == peerID { return current.hop }
            for neighbor in adjacency[current.id] ?? [] where !visited.contains(neighbor) {
                visited.insert(neighbor)
                queue.append((neighbor, current.hop + 1))
            }
        }
        return nil
    }

    /// Announces my own direct connections to the whole mesh (flooded, see
    /// floodForward) so every device — even ones I've never been in direct
    /// range of — can merge everyone's reports into one adjacency map and
    /// draw the full Discovery graph, not just their own 1-hop neighborhood.
    private func broadcastTopology() {
        let myID = DiscoveredPeer.stableID(for: localPeerID)
        // Must come from session.connectedPeers (the actual MCSession
        // truth), not discoveredPeers — the latter also holds relay-only
        // placeholder entries (state == .connected but never really in
        // range), and reporting those as "directly connected to me" would
        // corrupt everyone's topology map with a phantom direct edge.
        let directPeers = session.connectedPeers.map {
            TopologyPeerInfo(id: DiscoveredPeer.stableID(for: $0), name: $0.displayName)
        }

        topologyEdges[myID] = Set(directPeers.map(\.id))
        topologyNames[myID] = localDisplayName
        topologyLastSeen[myID] = Date()
        syncRelayReachablePeers()

        guard !session.connectedPeers.isEmpty else { return }
        let control = ControlMessage(
            type: .topology,
            senderID: myID,
            senderName: localDisplayName,
            directPeers: directPeers
        )
        guard let payload = try? JSONEncoder().encode(control) else { return }
        let envelope = MeshEnvelope(id: UUID(), kind: .control, originPeerID: myID, targetPeerID: nil, hopCount: 0, payload: payload)
        sendEnvelope(envelope, deliveryMode: .reliable)
    }

    private func handleControl(_ control: ControlMessage, from _: MCPeerID) {
        switch control.type {
        case .topology:
            guard let directPeers = control.directPeers else { return }
            let now = Date()
            topologyNames[control.senderID] = control.senderName
            topologyEdges[control.senderID] = Set(directPeers.map(\.id))
            topologyLastSeen[control.senderID] = now
            for peerInfo in directPeers {
                if topologyNames[peerInfo.id] == nil {
                    topologyNames[peerInfo.id] = peerInfo.name
                }
                // Being listed in a fresh report is itself evidence they
                // were alive as of this gossip round, even though we have
                // no direct report *from* them ourselves.
                topologyLastSeen[peerInfo.id] = now
            }
            syncRelayReachablePeers()
        case .trustRequest, .trustAccepted:
            break
        }
    }

    /// Every peer we've heard about via topology gossip but have never
    /// discovered directly ourselves gets a placeholder entry here so it
    /// shows up in the peer list / Discovery graph as reachable — sendText
    /// etc. already flood-route to it correctly (see sendDirect) without
    /// needing a real MCPeerID. Placeholders get upgraded to the real
    /// MCPeerID automatically the moment we do discover/connect to them
    /// directly (see the browser/session delegate callbacks), and get
    /// dropped if nobody's reported them reachable in a while so a peer
    /// that's actually left the mesh doesn't linger forever as "Connected."
    private func syncRelayReachablePeers() {
        let myID = DiscoveredPeer.stableID(for: localPeerID)
        let now = Date()
        // session.connectedPeers is the only real source of truth for
        // "directly connected right now" — never let this function touch
        // one of those.
        let directlyConnectedIDs = Set(session.connectedPeers.map { DiscoveredPeer.stableID(for: $0) })

        for (id, name) in topologyNames where id != myID && !directlyConnectedIDs.contains(id) {
            if var existing = discoveredPeers[id] {
                // A peer actively mid-handshake (.connecting) is NOT yet in
                // session.connectedPeers — MCSession only adds it once the
                // link is actually up — so without this guard, any peer
                // also reachable via relay gossip (common in any mesh with
                // 3+ devices) would get its real, in-progress direct
                // connect attempt silently overwritten with "Connected (via
                // relay)" the moment gossip arrived, which is exactly what
                // made a genuinely-forming direct link look indistinguishable
                // from relay-only. Leave .connecting alone — it either
                // resolves to a true direct connection (session:didChange)
                // or times out to .notConnected on its own, at which point
                // this function is free to mark it relay-reachable.
                guard existing.state != .connecting else { continue }

                // Known some other way already (e.g. discovered nearby but
                // never actually connected, or a stalled/timed-out invite
                // left it at .notConnected) — topology gossip proves the
                // mesh can still reach them via relay, so reflect that in
                // the peer list instead of leaving it stuck on whatever
                // state it was in before the mesh found another path. This
                // was the bug behind a peer sitting at "Connecting…" forever
                // despite the Discovery graph and multi-hop delivery already
                // working for them.
                let wasAlreadyUpToDate = existing.isRelayed && existing.state == .connected
                existing.isRelayed = true
                existing.state = .connected
                existing.lastSeen = topologyLastSeen[id] ?? now
                discoveredPeers[id] = existing
                if !wasAlreadyUpToDate {
                    log(.connect, "\(existing.mcPeerID.displayName) → connected (via relay)")
                }
                continue
            }
            discoveredPeers[id] = DiscoveredPeer(
                id: id,
                mcPeerID: MCPeerID(displayName: name),
                groupName: currentGroup.name,
                state: .connected,
                isTrusted: trustStore.isTrusted(id),
                isRelayed: true,
                lastSeen: topologyLastSeen[id] ?? now
            )
        }

        for (id, peer) in discoveredPeers where peer.isRelayed {
            let lastSeen = topologyLastSeen[id] ?? peer.lastSeen
            if now.timeIntervalSince(lastSeen) > relayPeerStaleAfter {
                log(.discovery, "\(peer.mcPeerID.displayName) dropped from mesh (no gossip for \(Int(relayPeerStaleAfter))s)")
                discoveredPeers.removeValue(forKey: id)
                topologyNames.removeValue(forKey: id)
                topologyEdges.removeValue(forKey: id)
                topologyLastSeen.removeValue(forKey: id)
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            if trustStore.isTrusted(id) {
                log(.trust, "Auto-accepting invitation from \(peerID.displayName) (already trusted)")
                invitationHandler(true, session)
            } else {
                log(.trust, "Invitation from \(peerID.displayName) — awaiting trust decision")
                let peer = DiscoveredPeer(
                    id: id,
                    mcPeerID: peerID,
                    groupName: nil,
                    state: .connecting,
                    isTrusted: false,
                    isRelayed: false,
                    lastSeen: Date()
                )
                discoveredPeers[id] = peer
                pendingTrustRequest = peer
                // Hold the handler until the user responds via trust(_:)/decline(_:).
                pendingInvitationHandlers[id] = invitationHandler
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            log(.error, "Advertising failed to start: \(error.localizedDescription)")
            localNetworkAuthorized = false
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshManager: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            let groupName = info?[DiscoveryKey.groupName]
            guard groupName == nil || groupName == currentGroup.name else {
                log(.discovery, "Ignored \(peerID.displayName): different group (\(groupName ?? "-"))")
                return
            }

            let wasAlreadyKnown = discoveredPeers[id] != nil
            let wasRelayOnly = discoveredPeers[id]?.isRelayed ?? false
            var peer = discoveredPeers[id] ?? DiscoveredPeer(
                id: id,
                mcPeerID: peerID,
                groupName: groupName,
                state: .notConnected,
                isTrusted: trustStore.isTrusted(id),
                isRelayed: false,
                lastSeen: Date()
            )
            // Actually finding this peer nearby is unambiguous proof it's
            // directly reachable — upgrade a relay-only placeholder (fake
            // MCPeerID, and a "Connected" state that was never backed by a
            // real MCSession link) to the genuine one. Being *found* isn't
            // the same as being *connected* though, so drop back to
            // .notConnected and let the normal trust/invite flow below (or
            // a manual tap) establish the real session.
            if wasRelayOnly {
                peer.mcPeerID = peerID
                peer.isRelayed = false
                peer.state = .notConnected
            }
            peer.groupName = groupName
            peer.lastSeen = Date()
            peer.isTrusted = trustStore.isTrusted(id)
            discoveredPeers[id] = peer

            if !wasAlreadyKnown || wasRelayOnly {
                log(.discovery, "Found \(peerID.displayName) nearby\(peer.isTrusted ? " (trusted)" : "")")
            }

            if peer.isTrusted && shouldInitiateAutoConnect(to: peerID) {
                invite(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            discoveredPeers[id]?.state = .notConnected
            log(.discovery, "Lost \(peerID.displayName) (out of range)")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            log(.error, "Browsing failed to start: \(error.localizedDescription)")
            localNetworkAuthorized = false
        }
    }
}

// MARK: - Pending invitation storage (kept off the delegate extension to stay MainActor-isolated)

@MainActor
private var pendingInvitationHandlersStorage: [String: (Bool, MCSession?) -> Void] = [:]

extension MeshManager {
    fileprivate var pendingInvitationHandlers: [String: (Bool, MCSession?) -> Void] {
        get { pendingInvitationHandlersStorage }
        set { pendingInvitationHandlersStorage = newValue }
    }

    func resolvePendingTrust(accept: Bool, peer: DiscoveredPeer) {
        guard let handler = pendingInvitationHandlers[peer.id] else { return }
        handler(accept, accept ? session : nil)
        pendingInvitationHandlers[peer.id] = nil
        log(.trust, accept ? "Accepted \(peer.mcPeerID.displayName)" : "Declined \(peer.mcPeerID.displayName)")
        if accept {
            markTrusted(peer)
        } else {
            decline(peer)
        }
    }
}

// MARK: - Trust store

/// Persists trusted peer identities to UserDefaults, keyed by stable peerID
/// (derived from displayName). No login/auth — trust is device-local and
/// purely about auto-accepting future invitations.
final class TrustStore {
    private let key = "app-chat.trustedPeers"
    private var cache: [String: TrustedPeer]

    init() {
        cache = Self.load(key: "app-chat.trustedPeers")
    }

    func isTrusted(_ peerID: String) -> Bool {
        cache[peerID] != nil
    }

    func trust(peerID: String, displayName: String) {
        cache[peerID] = TrustedPeer(peerID: peerID, displayName: displayName, trustedAt: Date())
        persist()
    }

    func untrust(peerID: String) {
        cache[peerID] = nil
        persist()
    }

    var allTrusted: [TrustedPeer] {
        Array(cache.values)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load(key: String) -> [String: TrustedPeer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: TrustedPeer].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
