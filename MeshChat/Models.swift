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
    case peerRoster
    /// Periodic "here's who I'm directly connected to" gossip, floods through
    /// the whole mesh so every device can reconstruct the full topology graph.
    case topology
}

/// One edge reported by a .topology broadcast: "the sender is directly
/// connected to this peer." Carries the name too so a device that has never
/// been in direct radio range of a far peer can still show its name in the
/// Discovery graph.
struct TopologyPeerInfo: Codable, Hashable {
    let id: String
    let name: String
}

struct ControlMessage: Codable {
    let type: ControlMessageType
    let senderID: String
    let senderName: String
    /// Used by .peerRoster to let a host tell others who's reachable through it.
    let knownPeerIDs: [String]?
    /// Used by .topology: the sender's own current direct connections.
    var directPeers: [TopologyPeerInfo]? = nil
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
    let mcPeerID: MCPeerID
    var groupName: String?
    var state: PeerConnectionState
    var isTrusted: Bool
    /// True when this peer is reachable only via a relay host, not directly.
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

// MARK: - Group

struct ChatGroup: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    var isHostRelay: Bool
    var hostPeerID: String?
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
    static let relayMode = "relayMode"
}
