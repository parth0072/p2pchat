import Foundation
import WebRTC
import os

private let rtcLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meshchat.app", category: "webrtc")

/// Public STUN servers only tell a device what its own public address looks
/// like so two peers on different networks can reach each other directly.
/// They never see message content and store nothing. (A TURN relay would
/// additionally be needed for the few NATs that block direct connections —
/// deliberately not included: this app has no server of its own, and the
/// local mesh remains the fallback when a direct internet path can't form.)
private let rtcStunServers = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
    "stun:stun.cloudflare.com:3478"
]

// MARK: - Signaling payload

/// Everything one side needs to hand the other so a WebRTC connection can
/// form without any signaling server: the SDP (which, because ICE gathering
/// is allowed to finish before this is created, already contains every
/// connection candidate) plus enough identity to know who it's from.
struct LinkSignal: Codable {
    enum Kind: String, Codable {
        case offer
        case answer
    }

    var v: Int = 1
    var kind: Kind
    /// Pairs an offer with its answer.
    var cid: String
    var fromID: String
    var fromName: String
    /// Sender's base64 Curve25519 public key (same key used for E2E chat
    /// encryption), so messages over the new link can be encrypted at once.
    var publicKey: String
    var sdp: String
}

/// Compact text form of a LinkSignal for QR codes / the clipboard: JSON,
/// zlib-compressed, base64, behind a short prefix so pasted garbage is
/// rejected immediately.
enum LinkSignalCodec {
    static let prefix = "mc1:"

    static func encode(_ signal: LinkSignal) -> String? {
        guard let json = try? JSONEncoder().encode(signal) else { return nil }
        let packed = (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
        return prefix + packed.base64EncodedString()
    }

    /// Tolerant of how codes actually get pasted: line breaks inserted by a
    /// messenger, stray spaces, or the code embedded in a longer sentence.
    static func decode(_ text: String) -> LinkSignal? {
        let candidates = candidateStrings(from: text)
        for candidate in candidates {
            if let signal = decodeExact(candidate) { return signal }
        }
        return nil
    }

    private static func candidateStrings(from text: String) -> [String] {
        var results: [String] = []
        // 1) The whole paste with all whitespace removed (handles wrapped lines).
        let compact = text.filter { !$0.isWhitespace }
        if let range = compact.range(of: prefix) {
            results.append(String(compact[range.lowerBound...]))
        }
        // 2) Just the whitespace-delimited token containing the prefix
        //    (handles a code followed by other words).
        for token in text.split(whereSeparator: { $0.isWhitespace }) where token.contains(prefix) {
            if let range = token.range(of: prefix) {
                results.append(String(token[range.lowerBound...]))
            }
        }
        return results
    }

    private static func decodeExact(_ candidate: String) -> LinkSignal? {
        guard candidate.hasPrefix(prefix) else { return nil }
        let body = String(candidate.dropFirst(prefix.count))
        guard let packed = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        let json = (try? (packed as NSData).decompressed(using: .zlib) as Data) ?? packed
        return try? JSONDecoder().decode(LinkSignal.self, from: json)
    }
}

/// Optional TURN relay, supplied by the user. Needed when two devices are on
/// networks that block direct peer-to-peer traffic (very common on mobile
/// data); the relay only forwards traffic that is already encrypted and
/// stores nothing. Kept in the Keychain because it holds a credential.
struct RelaySettings: Codable, Equatable {
    var url = ""
    var username = ""
    var credential = ""
}

enum RelayStore {
    private static let service = "app-chat.relay"
    private static let account = "turn"

    static func load() -> RelaySettings? {
        guard let data = KeychainStore.load(service: service, account: account),
              let settings = try? JSONDecoder().decode(RelaySettings.self, from: data),
              !settings.url.isEmpty else { return nil }
        return settings
    }

    static func save(_ settings: RelaySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        KeychainStore.save(data, service: service, account: account)
    }
}

struct LinkRemote: Hashable {
    let id: String
    let name: String
    let publicKey: String
}

// MARK: - One peer connection

/// A single WebRTC peer connection carrying one reliable, ordered data
/// channel — no audio/video. Delegate callbacks arrive on WebRTC's own
/// threads, so everything touching app state hops to the main actor.
final class MeshRTCLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    let connectionID: String
    private(set) var pc: RTCPeerConnection!
    private(set) var channel: RTCDataChannel?
    var remote: LinkRemote?
    weak var owner: WebRTCManager?

    private let lock = NSLock()
    private var gatherWaiter: CheckedContinuation<Void, Never>?

    init?(connectionID: String, factory: RTCPeerConnectionFactory, iceServers: [RTCIceServer], owner: WebRTCManager) {
        self.connectionID = connectionID
        self.owner = owner
        super.init()

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        // Gather once and let it finish before the offer/answer is shared,
        // so the SDP is complete and no candidate trickling (which would
        // need a live signaling channel) is ever required.
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return nil
        }
        pc = connection
    }

    // MARK: Negotiation

    func makeChannel() -> Bool {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "chat", configuration: config) else { return false }
        dc.delegate = self
        channel = dc
        return true
    }

    func createOffer() async -> RTCSessionDescription? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return await withCheckedContinuation { (cont: CheckedContinuation<RTCSessionDescription?, Never>) in
            pc.offer(for: constraints) { sdp, _ in
                cont.resume(returning: sdp)
            }
        }
    }

    func createAnswer() async -> RTCSessionDescription? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return await withCheckedContinuation { (cont: CheckedContinuation<RTCSessionDescription?, Never>) in
            pc.answer(for: constraints) { sdp, _ in
                cont.resume(returning: sdp)
            }
        }
    }

    func setLocal(_ sdp: RTCSessionDescription) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pc.setLocalDescription(sdp) { error in
                cont.resume(returning: error == nil)
            }
        }
    }

    func setRemote(_ sdp: RTCSessionDescription) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pc.setRemoteDescription(sdp) { error in
                cont.resume(returning: error == nil)
            }
        }
    }

    /// Waits for ICE gathering to finish (or the timeout, whichever comes
    /// first) so `pc.localDescription` carries every candidate.
    func waitForGathering(timeout: TimeInterval) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            gatherWaiter = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resumeGatherWaiter()
            }
        }
    }

    private func resumeGatherWaiter() {
        lock.lock()
        let waiter = gatherWaiter
        gatherWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    // MARK: Data

    var isChannelOpen: Bool {
        channel?.readyState == .open
    }

    func send(_ data: Data) -> Bool {
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func close() {
        channel?.close()
        pc?.close()
    }

    private func reportProgress(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.linkProgress(text)
        }
    }

    private func reportDown() {
        Task { @MainActor [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.linkClosed(self)
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .checking:
            reportProgress("Checking network routes between the two devices…")
        case .connected, .completed:
            reportProgress("Network route found — opening the chat channel…")
        case .failed:
            reportProgress("No direct route between these two networks (common on mobile data or strict Wi-Fi). Try both devices on the same Wi-Fi, or add a relay under Advanced.")
            reportDown()
        case .closed:
            reportDown()
        case .disconnected:
            // Often a momentary blip that heals itself — only give up if it
            // is still down after a grace period.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                let state = self.pc.iceConnectionState
                if state == .disconnected || state == .failed || state == .closed {
                    self.reportDown()
                }
            }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            resumeGatherWaiter()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // The answering side receives the offerer's channel here.
        dataChannel.delegate = self
        channel = dataChannel
        if dataChannel.readyState == .open {
            Task { @MainActor [weak self] in
                guard let self, let owner = self.owner else { return }
                owner.linkOpened(self)
            }
        }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor [weak self] in
            guard let self, let owner = self.owner else { return }
            if state == .open {
                owner.linkOpened(self)
            } else if state == .closed {
                owner.linkClosed(self)
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.received(data, on: self)
        }
    }
}

// MARK: - Manager

/// Owns every WebRTC link. Knows nothing about chat — it creates offers and
/// answers, reports when a link opens or closes, and moves opaque bytes.
/// MeshManager decides when to use it (internet available) and falls back to
/// the local mesh otherwise.
@MainActor
final class WebRTCManager {
    private lazy var factory = RTCPeerConnectionFactory()

    /// Links still negotiating, by connection ID.
    private var pending: [String: MeshRTCLink] = [:]
    /// Established links, by the remote peer's stable ID.
    private var open: [String: MeshRTCLink] = [:]

    /// (remote, isUp)
    var onLinkChange: (@MainActor (LinkRemote, Bool) -> Void)?
    var onData: (@MainActor (Data, LinkRemote) -> Void)?
    /// Human-readable connection progress ("Checking network routes…").
    var onProgress: (@MainActor (String) -> Void)?

    /// Optional user-supplied TURN relay (see RelaySettings).
    var relay: RelaySettings? = RelayStore.load()

    private var iceServers: [RTCIceServer] {
        var servers = [RTCIceServer(urlStrings: rtcStunServers)]
        if let relay, !relay.url.isEmpty {
            servers.append(RTCIceServer(urlStrings: [relay.url], username: relay.username, credential: relay.credential))
        }
        return servers
    }

    // MARK: Negotiation

    func makeOffer(myID: String, myName: String, myKey: String) async -> LinkSignal? {
        let cid = UUID().uuidString
        guard let link = MeshRTCLink(connectionID: cid, factory: factory, iceServers: iceServers, owner: self), link.makeChannel() else {
            return nil
        }
        pending[cid] = link
        guard let offer = await link.createOffer(), await link.setLocal(offer) else {
            discard(cid)
            return nil
        }
        await link.waitForGathering(timeout: 6)
        guard let sdp = link.pc.localDescription?.sdp else {
            discard(cid)
            return nil
        }
        scheduleExpiry(cid)
        return LinkSignal(kind: .offer, cid: cid, fromID: myID, fromName: myName, publicKey: myKey, sdp: sdp)
    }

    func makeAnswer(to offer: LinkSignal, myID: String, myName: String, myKey: String) async -> LinkSignal? {
        guard offer.kind == .offer else { return nil }
        let cid = offer.cid
        discard(cid)
        guard let link = MeshRTCLink(connectionID: cid, factory: factory, iceServers: iceServers, owner: self) else { return nil }
        link.remote = LinkRemote(id: offer.fromID, name: offer.fromName, publicKey: offer.publicKey)
        pending[cid] = link

        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        guard await link.setRemote(remoteDescription),
              let answer = await link.createAnswer(),
              await link.setLocal(answer) else {
            discard(cid)
            return nil
        }
        await link.waitForGathering(timeout: 6)
        guard let sdp = link.pc.localDescription?.sdp else {
            discard(cid)
            return nil
        }
        scheduleExpiry(cid)
        return LinkSignal(kind: .answer, cid: cid, fromID: myID, fromName: myName, publicKey: myKey, sdp: sdp)
    }

    /// Applies the other side's answer to an offer I made earlier.
    func complete(with answer: LinkSignal) async -> Bool {
        guard answer.kind == .answer, let link = pending[answer.cid] else { return false }
        link.remote = LinkRemote(id: answer.fromID, name: answer.fromName, publicKey: answer.publicKey)
        return await link.setRemote(RTCSessionDescription(type: .answer, sdp: answer.sdp))
    }

    private func discard(_ cid: String) {
        pending.removeValue(forKey: cid)?.close()
    }

    /// An invite nobody answered shouldn't hold a peer connection open
    /// forever.
    private func scheduleExpiry(_ cid: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard let self, let link = self.pending[cid] else { return }
            self.pending[cid] = nil
            link.close()
        }
    }

    // MARK: Link events (called by MeshRTCLink)

    fileprivate func linkOpened(_ link: MeshRTCLink) {
        guard let remote = link.remote else { return }
        pending[link.connectionID] = nil
        if let old = open[remote.id], old !== link {
            open[remote.id] = link
            old.close()
        } else {
            open[remote.id] = link
        }
        rtcLogger.info("Link up: \(remote.name, privacy: .public)")
        onLinkChange?(remote, true)
    }

    fileprivate func linkProgress(_ text: String) {
        onProgress?(text)
    }

    fileprivate func linkClosed(_ link: MeshRTCLink) {
        pending[link.connectionID] = nil
        guard let remote = link.remote, open[remote.id] === link else { return }
        open[remote.id] = nil
        link.close()
        rtcLogger.info("Link down: \(remote.name, privacy: .public)")
        onLinkChange?(remote, false)
    }

    fileprivate func received(_ data: Data, on link: MeshRTCLink) {
        guard let remote = link.remote, open[remote.id] === link else { return }
        onData?(data, remote)
    }

    // MARK: Use

    func isOpen(_ peerID: String) -> Bool {
        open[peerID]?.isChannelOpen ?? false
    }

    func send(_ data: Data, to peerID: String) -> Bool {
        open[peerID]?.send(data) ?? false
    }

    func close(peer peerID: String) {
        open[peerID]?.close()
    }

    func closeAll() {
        for link in Array(open.values) { link.close() }
        for link in Array(pending.values) { link.close() }
        pending.removeAll()
    }
}
