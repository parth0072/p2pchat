import Foundation
import MultipeerConnectivity
import Combine
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Wraps MCSession + advertiser + browser into a mesh-topology manager.
/// Every peer advertises and browses simultaneously. Optionally one peer per
/// group can act as a relay host, forwarding envelopes between peers that
/// aren't directly connected (used once a group exceeds full-mesh range).
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
    @Published var isRelayHost: Bool = false
    @Published private(set) var typingPeerIDs: Set<String> = []

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

    /// Peers we've been told about by a relay host but aren't directly
    /// connected to. Used to avoid re-browsing for them and to route sends
    /// through the host instead.
    private var relayReachablePeerIDs: Set<String> = []

    private var reconnectTimer: Timer?
    private var expiryTimer: Timer?
    private let knownInvitees = NSMutableSet() // avoid duplicate invites in-flight
    private var notificationAuthRequested = false

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

        var discoveryInfo: [String: String] = [
            DiscoveryKey.groupName: group.name,
            DiscoveryKey.displayName: displayName
        ]
        if group.isHostRelay {
            discoveryInfo[DiscoveryKey.relayMode] = "1"
        }

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
    /// of an already-mutually-trusted pair don't invite each other at once.
    private func rejoinDroppedPeers() {
        for (id, peer) in discoveredPeers where peer.state == .notConnected {
            guard trustStore.isTrusted(id), shouldInitiateAutoConnect(to: peer.mcPeerID) else { continue }
            invite(peer.mcPeerID)
        }
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
        invite(peer.mcPeerID)
    }

    func decline(_ peer: DiscoveredPeer) {
        if pendingTrustRequest?.id == peer.id {
            pendingTrustRequest = nil
        }
    }

    // MARK: Invitations

    private func invite(_ mcPeerID: MCPeerID) {
        guard !knownInvitees.contains(mcPeerID) else { return }
        knownInvitees.add(mcPeerID)
        browser.invitePeer(mcPeerID, to: session, withContext: nil, timeout: 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self else { return }
            self.knownInvitees.remove(mcPeerID)
            let id = DiscoveredPeer.stableID(for: mcPeerID)
            if self.discoveredPeers[id]?.state == .connecting {
                self.discoveredPeers[id]?.state = .notConnected
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
            kind: .chatMessage,
            originPeerID: message.senderID,
            targetPeerID: peer.id,
            hopCount: 0,
            payload: payload
        )
        sendDirect(envelope, to: peer.mcPeerID, deliveryMode: deliveryMode)
    }

    /// Sends straight to the peer if directly connected; otherwise falls
    /// back to a best-effort broadcast to whoever we *are* connected to
    /// (with targetPeerID already set on the envelope) so a relay host among
    /// them can pick it up and forward it on via relayForward.
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
            print("send failed: \(error.localizedDescription)")
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
                    print("resource send failed: \(error.localizedDescription)")
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
        isRelayHost = group.isHostRelay && group.hostPeerID == DiscoveredPeer.stableID(for: localPeerID)
        discoveredPeers.removeAll()
        relayReachablePeerIDs.removeAll()

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
        relayReachablePeerIDs.removeAll()

        rebuildNetworkStack()
        start()
    }

    /// Rebuilds session/advertiser/browser from the current localPeerID and
    /// currentGroup. Shared by switchGroup and updateIdentity so both stay
    /// in sync with the same discoveryInfo-construction logic.
    private func rebuildNetworkStack() {
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        var discoveryInfo: [String: String] = [
            DiscoveryKey.groupName: currentGroup.name,
            DiscoveryKey.displayName: localDisplayName
        ]
        if currentGroup.isHostRelay {
            discoveryInfo[DiscoveryKey.relayMode] = "1"
        }
        advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: discoveryInfo, serviceType: Self.serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        browser.delegate = self
    }

    // MARK: Local notifications

    private func requestNotificationAuthorizationIfNeeded() {
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                print("notification authorization denied")
            }
        }
    }

    /// Surfaces a message that just arrived from a peer: a system
    /// notification while backgrounded, or an in-app banner while
    /// foregrounded (system notifications are suppressed in that case, and
    /// silently doing nothing would mean missed messages on any screen other
    /// than the exact chat that received them) — unless the chat is already
    /// open, in which case the message is already visible live and a banner
    /// on top of it would just be redundant. Skipped for the app's own
    /// outgoing messages and typing indicators either way.
    private func postLocalNotification(for message: ChatMessage) {
        guard message.senderID != DiscoveredPeer.stableID(for: localPeerID) else { return }
        guard message.type != .typing else { return }

        if isAppActive {
            if !isChatViewVisible {
                showInAppBanner(for: message)
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = message.senderName
        content.subtitle = currentGroup.name
        content.body = notificationBody(for: message)
        content.sound = .default

        let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("failed to post notification: \(error.localizedDescription)")
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
            peer.state = PeerConnectionState(from: state)
            peer.lastSeen = Date()
            discoveredPeers[id] = peer

            if state == .connected, isRelayHost {
                broadcastRoster()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else { return }
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
                print("resource receive failed: \(error?.localizedDescription ?? "unknown")")
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
                print("failed to store received resource: \(error.localizedDescription)")
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
            // recipient, so a relay host can tell "mine to keep" apart from
            // "someone else's, just pass it on" instead of showing/relaying
            // everything to everyone.
            let isForMe = envelope.targetPeerID == nil || envelope.targetPeerID == myID

            if message.type == .typing {
                if isForMe {
                    if message.content == "1" {
                        typingPeerIDs.insert(message.senderID)
                    } else {
                        typingPeerIDs.remove(message.senderID)
                    }
                } else if isRelayHost {
                    relayForward(envelope, excluding: peerID)
                }
                return
            }

            if isForMe, !messages.contains(where: { $0.id == message.id }) {
                appendLocal(message)
                postLocalNotification(for: message)
            }
            // A relay host keeps forwarding envelopes addressed to someone
            // else it isn't the final destination for.
            if isRelayHost, let targetID = envelope.targetPeerID, targetID != myID {
                relayForward(envelope, excluding: peerID)
            }
        case .control:
            guard let control = try? JSONDecoder().decode(ControlMessage.self, from: envelope.payload) else { return }
            handleControl(control)
        }
    }

    /// Host-mode: re-sends an envelope (with hopCount bumped) toward its
    /// intended recipient if directly connected to them, or as a best-effort
    /// broadcast to everyone else otherwise, so devices that aren't directly
    /// linked to the original sender still receive messages addressed to them.
    private func relayForward(_ envelope: MeshEnvelope, excluding sender: MCPeerID) {
        guard envelope.hopCount < 3 else { return }
        let forwarded = MeshEnvelope(
            kind: envelope.kind,
            originPeerID: envelope.originPeerID,
            targetPeerID: envelope.targetPeerID,
            hopCount: envelope.hopCount + 1,
            payload: envelope.payload
        )
        guard let data = try? JSONEncoder().encode(forwarded) else { return }

        if let targetID = envelope.targetPeerID,
           let targetPeer = session.connectedPeers.first(where: { DiscoveredPeer.stableID(for: $0) == targetID }) {
            try? session.send(data, toPeers: [targetPeer], with: .reliable)
            return
        }

        let others = session.connectedPeers.filter { $0 != sender }
        guard !others.isEmpty else { return }
        try? session.send(data, toPeers: others, with: .reliable)
    }

    private func broadcastRoster() {
        let control = ControlMessage(
            type: .peerRoster,
            senderID: DiscoveredPeer.stableID(for: localPeerID),
            senderName: localDisplayName,
            knownPeerIDs: session.connectedPeers.map(DiscoveredPeer.stableID(for:))
        )
        guard let payload = try? JSONEncoder().encode(control) else { return }
        let envelope = MeshEnvelope(kind: .control, originPeerID: DiscoveredPeer.stableID(for: localPeerID), targetPeerID: nil, hopCount: 0, payload: payload)
        sendEnvelope(envelope, deliveryMode: .reliable)
    }

    private func handleControl(_ control: ControlMessage) {
        switch control.type {
        case .peerRoster:
            guard let ids = control.knownPeerIDs else { return }
            for id in ids where discoveredPeers[id] == nil {
                relayReachablePeerIDs.insert(id)
            }
        case .trustRequest, .trustAccepted:
            break
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            if trustStore.isTrusted(id) {
                invitationHandler(true, session)
            } else {
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
            print("advertising failed: \(error.localizedDescription)")
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
            guard groupName == nil || groupName == currentGroup.name else { return }

            var peer = discoveredPeers[id] ?? DiscoveredPeer(
                id: id,
                mcPeerID: peerID,
                groupName: groupName,
                state: .notConnected,
                isTrusted: trustStore.isTrusted(id),
                isRelayed: false,
                lastSeen: Date()
            )
            peer.groupName = groupName
            peer.lastSeen = Date()
            peer.isTrusted = trustStore.isTrusted(id)
            discoveredPeers[id] = peer

            if peer.isTrusted && shouldInitiateAutoConnect(to: peerID) {
                invite(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            let id = DiscoveredPeer.stableID(for: peerID)
            discoveredPeers[id]?.state = .notConnected
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            print("browsing failed: \(error.localizedDescription)")
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
