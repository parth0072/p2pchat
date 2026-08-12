import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SwiftData model

@Model
final class PersistedMessage {
    @Attribute(.unique) var id: UUID
    var senderID: String
    var senderName: String
    var timestamp: Date
    var typeRaw: String
    var content: String
    var groupID: String
    var recipientPeerID: String?
    var fileName: String?
    var fileSize: Int?
    var localURLString: String?

    init(from message: ChatMessage) {
        id = message.id
        senderID = message.senderID
        senderName = message.senderName
        timestamp = message.timestamp
        typeRaw = message.type.rawValue
        content = message.content
        groupID = message.groupID
        recipientPeerID = message.recipientPeerID
        fileName = message.fileName
        fileSize = message.fileSize
        localURLString = message.localURL?.absoluteString
    }

    var asChatMessage: ChatMessage {
        ChatMessage(
            id: id,
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            type: MessageType(rawValue: typeRaw) ?? .text,
            content: content,
            groupID: groupID,
            recipientPeerID: recipientPeerID,
            fileName: fileName,
            fileSize: fileSize,
            localURL: localURLString.flatMap(URL.init(string:))
        )
    }
}

@Model
final class PersistedGroup {
    @Attribute(.unique) var name: String

    init(from group: ChatGroup) {
        name = group.name
    }

    var asChatGroup: ChatGroup {
        ChatGroup(name: name)
    }
}

// MARK: - Store

@MainActor
final class MessageStore {
    let container: ModelContainer
    private let context: ModelContext

    init() {
        do {
            container = try ModelContainer(for: PersistedMessage.self, PersistedGroup.self)
        } catch {
            // Fall back to an in-memory store rather than crashing; chat still
            // works for the session, just without history across relaunch.
            container = (try? ModelContainer(
                for: PersistedMessage.self, PersistedGroup.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )) ?? MessageStore.emptyContainerOrFatal()
        }
        context = ModelContext(container)
    }

    private static func emptyContainerOrFatal() -> ModelContainer {
        guard let fallback = try? ModelContainer(
            for: PersistedMessage.self, PersistedGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) else {
            preconditionFailure("Unable to create even an in-memory ModelContainer")
        }
        return fallback
    }

    func save(_ message: ChatMessage) {
        let existing = messages(groupID: message.groupID).first { $0.id == message.id }
        guard existing == nil else { return }
        context.insert(PersistedMessage(from: message))
        trySave()
    }

    func messages(groupID: String) -> [ChatMessage] {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.groupID == groupID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.asChatMessage }
    }

    func saveGroup(_ group: ChatGroup) {
        let descriptor = FetchDescriptor<PersistedGroup>(predicate: #Predicate { $0.name == group.name })
        if (try? context.fetch(descriptor))?.first == nil {
            context.insert(PersistedGroup(from: group))
        }
        trySave()
    }

    func allGroups() -> [ChatGroup] {
        let descriptor = FetchDescriptor<PersistedGroup>(sortBy: [SortDescriptor(\.name)])
        return ((try? context.fetch(descriptor)) ?? []).map { $0.asChatGroup }
    }

    /// Deletes any stored message older than `olderThan` (a duration in
    /// seconds). Messages disappear from history after that window — this
    /// app doesn't keep chat logs indefinitely.
    @discardableResult
    func purgeMessages(olderThan maxAge: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: #Predicate { $0.timestamp < cutoff })
        guard let expired = try? context.fetch(descriptor), !expired.isEmpty else { return 0 }
        for message in expired {
            context.delete(message)
        }
        trySave()
        return expired.count
    }

    private func trySave() {
        do {
            try context.save()
        } catch {
            print("persistence save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Profile store

/// Local-only storage for "who am I" — display name + optional avatar photo.
/// Name is what gets embedded in every ChatMessage and advertised over the
/// mesh; the avatar stays device-local (never transferred to peers) to avoid
/// adding a binary-resource handshake to the connection flow.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile
    private(set) var isFirstRun: Bool

    private let defaultsKey = "app-chat.profile"
    private let avatarFileName = "avatar.jpg"

    init() {
        if let data = UserDefaults.standard.data(forKey: "app-chat.profile"),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = decoded
            isFirstRun = false
        } else if let legacyName = UserDefaults.standard.string(forKey: "app-chat.displayName"), !legacyName.isEmpty {
            // Carries over the name from before the profile screen existed,
            // so an already-running install doesn't silently rename itself
            // to the peers it's already trusted/connected to.
            profile = UserProfile(displayName: legacyName, avatarFileName: nil)
            isFirstRun = false
        } else {
            profile = UserProfile(displayName: Self.defaultDisplayName(), avatarFileName: nil)
            isFirstRun = true
        }
    }

    var avatarURL: URL? {
        guard profile.avatarFileName != nil, let dir = Self.profileDirectory() else { return nil }
        return dir.appendingPathComponent(avatarFileName)
    }

    func updateName(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty else { return }
        profile.displayName = trimmed
        persist()
    }

    func updateAvatar(data: Data) {
        guard let dir = Self.profileDirectory() else { return }
        let url = dir.appendingPathComponent(avatarFileName)
        do {
            try data.write(to: url, options: .atomic)
            profile.avatarFileName = avatarFileName
            persist()
        } catch {
            print("failed to save avatar: \(error.localizedDescription)")
        }
    }

    func clearAvatar() {
        if let dir = Self.profileDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(avatarFileName))
        }
        profile.avatarFileName = nil
        persist()
    }

    private func persist() {
        isFirstRun = false
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func defaultDisplayName() -> String {
        #if os(iOS)
        return String(UIDevice.current.name.prefix(60))
        #elseif os(macOS)
        return String((Host.current().localizedName ?? "Mac").prefix(60))
        #else
        return "Device"
        #endif
    }

    private static func profileDirectory() -> URL? {
        guard let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let dir = docs.appendingPathComponent("Profile", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
