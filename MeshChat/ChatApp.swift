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
    @StateObject private var sheets = HomeSheets()
    @AppStorage(OnboardingFlag.key) private var onboardingDone = false
    @AppStorage(AppAppearance.key) private var appearanceRaw = AppAppearance.light.rawValue

    var body: some View {
        Group {
            if onboardingDone {
                mainContent
            } else {
                // Discovery (and the permission prompts it triggers) only
                // starts once the main screen appears, i.e. after this.
                OnboardingView(profileStore: profileStore, mesh: mesh) {
                    onboardingDone = true
                }
            }
        }
        .brandTint()
        .preferredColorScheme(AppAppearance.from(appearanceRaw).colorScheme)
        .onAppear(perform: loadKnownGroups)
        .onChange(of: onboardingDone) {
            // Finishing the welcome flow (including after "Forget
            // everything") starts from a clean selection and group list.
            guard onboardingDone else { return }
            selectedPeer = nil
            knownGroups = [ChatGroup(name: "General")]
            loadKnownGroups()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(macOS)
        // A plain two-pane layout rather than NavigationSplitView: the system
        // split view hosted the sidebar in a way that left it blank, and this
        // gives the sidebar and detail the exact Signal look.
        HStack(spacing: 0) {
            PeerListView(mesh: mesh, profileStore: profileStore, selectedPeer: $selectedPeer, sheets: sheets, knownGroups: $knownGroups)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Brand.sidebar.ignoresSafeArea())

            Divider()

            Group {
                if let selectedPeer {
                    ChatView(mesh: mesh, peer: selectedPeer, store: store)
                        .id(selectedPeer.id)
                } else {
                    NoPeerSelectedView(
                        mesh: mesh,
                        onInternet: { sheets.internet = true },
                        onGroups: { sheets.groups = true }
                    )
                    .brandBackground()
                    .navigationTitle(mesh.currentGroup.name)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar { homeToolbar }
        #else
        NavigationStack {
            PeerListView(mesh: mesh, profileStore: profileStore, selectedPeer: $selectedPeer, sheets: sheets, knownGroups: $knownGroups)
                .navigationDestination(item: $selectedPeer) { peer in
                    ChatView(mesh: mesh, peer: peer, store: store)
                }
        }
        #endif
    }

    #if os(macOS)
    /// The window's top-right action buttons — everything a new user needs to
    /// get connected, available from any screen.
    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                sheets.discovery = true
            } label: {
                Label("Network map", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .help("Network map")

            Button {
                sheets.groups = true
            } label: {
                Label("Groups", systemImage: "person.3")
            }
            .help("Groups")

            Button {
                sheets.internet = true
            } label: {
                Label("Internet chat", systemImage: "globe")
            }
            .help("Chat over the internet")

            Button {
                sheets.profile = true
            } label: {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .help("Profile, appearance and privacy")
        }
    }
    #endif

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
    let onInternet: () -> Void
    let onGroups: () -> Void

    private var connectedCount: Int {
        mesh.discoveredPeers.values.filter { $0.state == .connected }.count
    }

    private var icon: String {
        if mesh.discoveredPeers.isEmpty { return "dot.radiowaves.left.and.right" }
        return connectedCount == 0 ? "person.crop.circle.badge.questionmark" : "bubble.left.and.bubble.right"
    }

    private var title: String {
        if mesh.discoveredPeers.isEmpty { return "No one nearby yet" }
        return connectedCount == 0 ? "Pick someone to connect" : "Choose a conversation"
    }

    private var message: String {
        if mesh.discoveredPeers.isEmpty {
            return "Looking for devices in \"\(mesh.currentGroup.name)\". Make sure Wi-Fi or Bluetooth is on, or start an internet chat from the globe button."
        }
        if connectedCount == 0 {
            return "Devices are nearby but not connected yet. Select one in the sidebar and tap Connect."
        }
        return "Pick someone from the sidebar to start chatting. Everything is end-to-end encrypted."
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Brand.surface)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Brand.accent)
            }
            Text(title)
                .font(.system(size: 24, weight: .heavy))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if connectedCount == 0 {
                VStack(spacing: 10) {
                    Button(action: onInternet) {
                        Label("Chat over the internet", systemImage: "globe")
                    }
                    .buttonStyle(BrandButtonStyle())
                    Button(action: onGroups) {
                        Label("Join or create a group", systemImage: "person.3")
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                }
                .frame(maxWidth: 280)
                .padding(.top, 4)
            }
            Label("End-to-end encrypted", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.encrypted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Brand.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
        .padding(32)
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
                .background(Circle().fill(Brand.accent))

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
