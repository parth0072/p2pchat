import Foundation
import MultipeerConnectivity

// MARK: - Message

enum MessageType: String, Codable {
    case text
    case file
    case video
    case image
    case typing
    case sticker
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let senderID: String
    let senderName: String
    let timestamp: Date
    let type: MessageType
    let content: String
    let groupID: String

    /// The peer this message was addressed to, set only on messages *I*
    /// sent. Together with senderID this reconstructs "the other person in
    /// this thread" from either side: for my own messages that's
    /// recipientPeerID; for messages I received, it's just senderID. Lets
    /// ChatView show a separate 1:1 conversation per peer instead of one
    /// merged feed for everyone in the group.
    var recipientPeerID: String?

    var fileName: String?
    var fileSize: Int?
    var localURL: URL?

    init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        timestamp: Date = Date(),
        type: MessageType,
        content: String,
        groupID: String,
        recipientPeerID: String? = nil,
        fileName: String? = nil,
        fileSize: Int? = nil,
        localURL: URL? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.groupID = groupID
        self.recipientPeerID = recipientPeerID
        self.fileName = fileName
        self.fileSize = fileSize
        self.localURL = localURL
    }

    /// The stable ID of "the other participant" in this 1:1 thread, from my
    /// own perspective (myID = my own stable peer ID).
    func conversationPartnerID(myID: String) -> String? {
        senderID == myID ? recipientPeerID : senderID
    }
}

// MARK: - Envelope

/// Wire-format wrapper sent over MCSession. Keeps ChatMessage decoupled from
/// relay metadata (hop count, origin, target) needed for multi-hop relaying.
struct MeshEnvelope: Codable {
    enum Kind: String, Codable {
        case chatMessage
        case control
    }

    /// Unique per envelope (preserved unchanged across every hop it takes).
    /// Every peer that relays an envelope remembers IDs it's already seen and
    /// drops repeats — without this, a mesh with any cycle in it would flood
    /// the same envelope around forever instead of it dying out after a
    /// bounded number of hops.
    let id: UUID
    let kind: Kind
    let originPeerID: String
    /// nil means "flood to the whole mesh" (used for topology/roster gossip);
    /// otherwise a specific peer's displayName-derived stable ID that every
    /// relaying peer keeps forwarding toward until it arrives.
    let targetPeerID: String?
    let hopCount: Int
    let payload: Data
}

enum ControlMessageType: String, Codable {
    case trustRequest
    case trustAccepted
    /// Periodic "here's who I'm directly connected to" gossip, floods through
    /// the whole mesh so every device can reconstruct the full topology graph.
    case topology
}

/// One edge reported by a .topology broadcast: "the sender is directly
/// connected to this peer." Carries the name too so a device that has never
/// been in direct radio range of a far peer can still show its name in the
/// Discovery graph. Also carries that peer's public key (base64 raw
/// Curve25519 bytes) so end-to-end encryption keys propagate the same way
/// names do — a peer several hops away, never directly discovered, still
/// needs its key learned from *someone's* gossip before you can encrypt a
/// message to them (see MeshManager's peerPublicKeys cache).
struct TopologyPeerInfo: Codable, Hashable {
    let id: String
    let name: String
    var publicKey: String? = nil
}

struct ControlMessage: Codable {
    let type: ControlMessageType
    let senderID: String
    let senderName: String
    /// Used by .topology: the sender's own current direct connections.
    var directPeers: [TopologyPeerInfo]? = nil
    /// The sender's own base64 Curve25519 public key — carried on every
    /// .topology broadcast (which already floods to the whole mesh every
    /// ~6s) so a device's E2E key reaches every other device the same way
    /// its name and topology edges do, without a separate handshake message.
    var senderPublicKey: String? = nil
}

// MARK: - Peer

enum PeerConnectionState: String {
    case notConnected
    case connecting
    case connected

    init(from mcState: MCSessionState) {
        switch mcState {
        case .notConnected: self = .notConnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        @unknown default: self = .notConnected
        }
    }
}

/// Stable identity independent of MCPeerID instances, which are recreated
/// across launches. Derived from displayName; good enough for a trust-store
/// keyed by "device name" since there's no login/auth layer.
struct TrustedPeer: Codable, Identifiable, Hashable {
    var id: String { peerID }
    let peerID: String
    let displayName: String
    var trustedAt: Date
}

struct DiscoveredPeer: Identifiable, Hashable {
    let id: String
    /// Mutable so a relay-only placeholder entry (see
    /// MeshManager.syncRelayReachablePeers) can be upgraded to the real
    /// MCPeerID once we actually discover this peer directly ourselves —
    /// the placeholder's MCPeerID is a standalone object that was never
    /// part of any real MCSession handshake, so it can't be used to invite
    /// or directly send to them.
    var mcPeerID: MCPeerID
    var groupName: String?
    var state: PeerConnectionState
    var isTrusted: Bool
    /// True when this peer is known only through another peer's topology
    /// gossip — never discovered directly ourselves. Messages still reach
    /// them via flood relay; direct actions (invite, file transfer) can't.
    var isRelayed: Bool
    var lastSeen: Date

    static func stableID(for mcPeerID: MCPeerID) -> String {
        mcPeerID.displayName
    }
}

// MARK: - Profile

/// The local user's own display name + optional avatar. Persisted on-device
/// only (UserDefaults + a file in Documents/Profile) — there's no login, so
/// this is just "how you want to appear to peers," not an account.
struct UserProfile: Codable, Equatable {
    var displayName: String
    var avatarFileName: String?
}

// MARK: - In-app banner

/// A transient "toast" shown inside the app when a message arrives while
/// the app is foregrounded (system notifications are suppressed in that
/// case, so this is what stands in for them).
struct InAppBanner: Identifiable, Equatable {
    let id: UUID
    let senderName: String
    let groupName: String
    let preview: String
}

// MARK: - Debug log

/// A single event in MeshManager's in-memory debug log — discovery, connect
/// state changes, trust decisions, and message routing attempts. Purely for
/// the in-app Debug view (see DebugLogView); nothing here is persisted.
struct DebugLogEntry: Identifiable, Hashable {
    enum Category: String {
        case discovery
        case connect
        case route
        case trust
        case error
    }

    let id = UUID()
    let timestamp: Date
    let category: Category
    let message: String
}

// MARK: - Group

struct ChatGroup: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
}

// MARK: - Transfer progress (in-memory only, not persisted)

struct FileTransfer: Identifiable {
    enum Direction { case sending, receiving }
    enum Status { case inProgress, completed, failed, cancelled }

    let id: UUID
    let peerID: String
    let fileName: String
    let direction: Direction
    var fractionCompleted: Double
    var status: Status
    var estimatedSecondsRemaining: Double?
}

// MARK: - Discovery info keys

enum DiscoveryKey {
    static let groupName = "groupName"
    static let displayName = "displayName"
    /// Base64 raw Curve25519 public key, advertised in the same Bonjour TXT
    /// record as the group/display name so a peer's E2E encryption key is
    /// known the instant it's discovered — no separate handshake needed.
    static let publicKey = "publicKey"
}
