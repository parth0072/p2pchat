import SwiftUI
import MultipeerConnectivity

struct PeerListView: View {
    @ObservedObject var mesh: MeshManager
    @ObservedObject var profileStore: ProfileStore
    @Binding var selectedPeer: DiscoveredPeer?
    @State var showingGroupSwitcher = false
    @State var showingProfile = false
    @State var showingDiscovery = false
    @State var showingDebug = false
    @State var knownGroups: [ChatGroup]

    private var sortedPeers: [DiscoveredPeer] {
        mesh.discoveredPeers.values.sorted { $0.mcPeerID.displayName < $1.mcPeerID.displayName }
    }

    var body: some View {
        List(selection: $selectedPeer) {
            Section {
                ConnectionSummaryRow(mesh: mesh)
            }

            if !mesh.localNetworkAuthorized {
                Section {
                    LocalNetworkDeniedRow()
                }
            }

            Section("Nearby Devices") {
                if sortedPeers.isEmpty {
                    Text("Searching for nearby peers…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedPeers) { peer in
                        PeerRow(peer: peer, onConnect: {
                            // Show the raw connect/route log live while the
                            // handshake is in flight, so a stuck or failed
                            // connect attempt is visible instead of a
                            // silent spinner with no explanation.
                            showingDebug = true
                            mesh.trust(peer)
                        })
                        .tag(peer)
                    }
                }
            }
        }
        .navigationTitle(mesh.currentGroup.name)
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    showingProfile = true
                } label: {
                    Label("Profile", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem {
                Button {
                    showingDiscovery = true
                } label: {
                    Label("Discovery", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            ToolbarItem {
                Button {
                    showingGroupSwitcher = true
                } label: {
                    Label("Groups", systemImage: "person.3")
                }
            }
            ToolbarItem {
                Button {
                    showingDebug = true
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            }
            #else
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingProfile = true
                } label: {
                    Label("Profile", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingDiscovery = true
                } label: {
                    Label("Discovery", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingGroupSwitcher = true
                } label: {
                    Label("Groups", systemImage: "person.3")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingDebug = true
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            }
            #endif
        }
        .sheet(isPresented: $showingGroupSwitcher) {
            GroupSwitcherView(mesh: mesh, knownGroups: $knownGroups)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView(profileStore: profileStore, mesh: mesh)
        }
        .sheet(isPresented: $showingDiscovery) {
            DiscoveryView(mesh: mesh)
        }
        .sheet(isPresented: $showingDebug) {
            DebugView(mesh: mesh)
        }
        .sheet(item: $mesh.pendingTrustRequest) { peer in
            TrustPromptView(mesh: mesh, peer: peer)
        }
        .onChange(of: mesh.pendingTrustRequest) {
            // SwiftUI can only present one sheet at a time from this view,
            // and this view has five independent .sheet() triggers. Without
            // this, an inbound connection request arriving while any other
            // sheet (most commonly Debug, which now auto-opens on every
            // Connect tap) is already up would silently fail to show its
            // trust prompt — the invitation handler never gets called, the
            // system times the invite out on its own, and the connection
            // just quietly dies with nothing on screen explaining why.
            guard mesh.pendingTrustRequest != nil else { return }
            showingGroupSwitcher = false
            showingProfile = false
            showingDiscovery = false
            showingDebug = false
        }
        .onAppear {
            mesh.start()
            if profileStore.isFirstRun {
                showingProfile = true
            }
        }
    }
}

private struct ConnectionSummaryRow: View {
    @ObservedObject var mesh: MeshManager

    private var connectedCount: Int {
        mesh.discoveredPeers.values.filter { $0.state == .connected }.count
    }

    var body: some View {
        HStack {
            Image(systemName: connectedCount > 0 ? "wifi" : "wifi.slash")
                .foregroundStyle(connectedCount > 0 ? Color.green : Color.secondary)
            Text("\(connectedCount) connected")
                .font(.subheadline)
            Spacer()
        }
    }
}

private struct LocalNetworkDeniedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Network access denied", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())
            Text("This app needs Local Network permission to discover nearby devices. Enable it in Settings > Privacy > Local Network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption)
            #endif
        }
        .padding(.vertical, 4)
    }
}

private struct PeerRow: View {
    let peer: DiscoveredPeer
    let onConnect: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(color(for: peer.state))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.mcPeerID.displayName)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(statusText(for: peer.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if peer.isRelayed {
                        Text("· via relay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !peer.isTrusted {
                        Text("· untrusted")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if peer.state == .notConnected {
                Button("Connect", action: onConnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if peer.state == .connecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for state: PeerConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .notConnected: return .gray
        }
    }

    private func statusText(for state: PeerConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .notConnected: return "Not connected"
        }
    }
}

private struct TrustPromptView: View {
    @ObservedObject var mesh: MeshManager
    let peer: DiscoveredPeer
    @State private var trustDevice = true

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("\(peer.mcPeerID.displayName) wants to connect")
                .font(.headline)
            Toggle("Trust this device", isOn: $trustDevice)
                .padding(.horizontal)
            Text("Trusted devices auto-connect next time without asking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Decline", role: .destructive) {
                    mesh.resolvePendingTrust(accept: false, peer: peer)
                }
                Button(trustDevice ? "Trust & Connect" : "Connect Once") {
                    if trustDevice {
                        mesh.resolvePendingTrust(accept: true, peer: peer)
                    } else {
                        mesh.resolvePendingTrust(accept: true, peer: peer)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 300)
    }
}

private struct GroupSwitcherView: View {
    @ObservedObject var mesh: MeshManager
    @Binding var knownGroups: [ChatGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Switch group") {
                    ForEach(knownGroups) { group in
                        Button {
                            mesh.switchGroup(to: group)
                            dismiss()
                        } label: {
                            Text(group.name)
                        }
                    }
                }
                Section("New group") {
                    TextField("Group name", text: $newGroupName)
                    Button("Create & Join") {
                        guard !newGroupName.isEmpty else { return }
                        let group = ChatGroup(name: newGroupName)
                        knownGroups.append(group)
                        mesh.switchGroup(to: group)
                        dismiss()
                    }
                    .disabled(newGroupName.isEmpty)
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
