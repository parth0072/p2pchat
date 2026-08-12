import SwiftUI

@main
struct ChatApp: App {
    @StateObject private var mesh: MeshManager
    @StateObject private var profileStore = ProfileStore()
    @Environment(\.scenePhase) private var scenePhase
    private let store = MessageStore()

    init() {
        // ProfileStore isn't available yet at this point in init (StateObjects
        // aren't wired up until the view body runs), so identity is seeded
        // from the same UserDefaults keys it reads, then reconciled with
        // ProfileStore.profile.displayName once the view appears.
        let displayName = Self.seedDisplayName()
        // Reopen whichever group was active last time instead of always
        // dropping back to "General" — the group's chat history is already
        // preserved across launches (SwiftData), so the active group should
        // be too.
        let defaultGroup = ChatGroup(name: MeshManager.lastGroupName() ?? "General")
        let manager = MeshManager(displayName: displayName, group: defaultGroup)
        _mesh = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            RootView(mesh: mesh, profileStore: profileStore, store: store)
                .onAppear {
                    // Seed history for the default group from disk so a relaunch
                    // shows prior messages before any new envelopes arrive.
                    mesh.loadPersistedHistory(from: store)
                    if profileStore.profile.displayName != mesh.localDisplayName {
                        mesh.updateIdentity(displayName: profileStore.profile.displayName)
                    }
                }
                .overlay(alignment: .top) {
                    if let banner = mesh.inAppBanner {
                        InAppBannerView(banner: banner) {
                            mesh.dismissInAppBanner()
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .animation(.spring(duration: 0.35), value: mesh.inAppBanner)
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
        .onChange(of: scenePhase) {
            mesh.isAppActive = (scenePhase == .active)
        }
    }

    private static func seedDisplayName() -> String {
        if let data = UserDefaults.standard.data(forKey: "app-chat.profile"),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            return decoded.displayName
        }
        if let legacy = UserDefaults.standard.string(forKey: "app-chat.displayName"), !legacy.isEmpty {
            return legacy
        }
        #if os(iOS)
        let name = UIDevice.current.name
        #elseif os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = "Device"
        #endif
        // MCPeerID displayName must be <= 63 UTF-8 bytes.
        return String(name.prefix(60))
    }
}

#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @ObservedObject var mesh: MeshManager
    @ObservedObject var profileStore: ProfileStore
    let store: MessageStore
    @State private var selectedPeer: DiscoveredPeer?
    @State private var knownGroups: [ChatGroup] = [ChatGroup(name: "General")]

    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                PeerListView(mesh: mesh, profileStore: profileStore, selectedPeer: $selectedPeer, knownGroups: $knownGroups)
            } detail: {
                if let selectedPeer {
                    ChatView(mesh: mesh, peer: selectedPeer, store: store)
                } else {
                    NoPeerSelectedView(mesh: mesh)
                }
            }
            #else
            NavigationStack {
                PeerListView(mesh: mesh, profileStore: profileStore, selectedPeer: $selectedPeer, knownGroups: $knownGroups)
                    .navigationDestination(item: $selectedPeer) { peer in
                        ChatView(mesh: mesh, peer: peer, store: store)
                    }
            }
            #endif
        }
        .onAppear(perform: loadKnownGroups)
    }

    /// Restores every group the user has ever created (persisted via
    /// MessageStore.saveGroup/PersistedGroup) into the switcher list, plus
    /// whichever group is currently active — without this, knownGroups
    /// always reset to just "General" on every relaunch even though the
    /// chat history and the group itself were still on disk, making a
    /// custom group look like it had silently vanished.
    private func loadKnownGroups() {
        var merged = knownGroups
        for group in store.allGroups() where !merged.contains(where: { $0.name == group.name }) {
            merged.append(group)
        }
        if !merged.contains(where: { $0.name == mesh.currentGroup.name }) {
            merged.append(mesh.currentGroup)
        }
        knownGroups = merged.sorted { $0.name < $1.name }
    }
}

// MARK: - Empty detail-pane state (macOS)

/// Shown in the NavigationSplitView detail pane whenever nothing is
/// selected, instead of falling back to an ambiguous "chat with nobody in
/// particular" view. Distinguishes "haven't discovered anyone yet" from
/// "peers are right there, just pick one."
private struct NoPeerSelectedView: View {
    @ObservedObject var mesh: MeshManager

    private var connectedCount: Int {
        mesh.discoveredPeers.values.filter { $0.state == .connected }.count
    }

    var body: some View {
        if mesh.discoveredPeers.isEmpty {
            ContentUnavailableView(
                "No Peers Yet",
                systemImage: "person.2.slash",
                description: Text("Waiting for nearby devices on group \"\(mesh.currentGroup.name)\". Make sure Wi-Fi or Bluetooth is on.")
            )
        } else if connectedCount == 0 {
            ContentUnavailableView(
                "Check Nearby Peers",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Devices are nearby but not connected yet. Select one in the sidebar and tap Connect.")
            )
        } else {
            ContentUnavailableView(
                "Select a Peer",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a connected device from the sidebar to start chatting.")
            )
        }
    }
}

// MARK: - In-app notification banner

/// Stand-in for a system notification while the app is foregrounded (where
/// UNUserNotificationCenter banners are suppressed). Auto-dismisses itself
/// via MeshManager; tapping dismisses it early.
private struct InAppBannerView: View {
    let banner: InAppBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "message.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(banner.senderName)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(banner.groupName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(banner.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
