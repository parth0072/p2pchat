import SwiftUI
import MultipeerConnectivity
#if canImport(AppKit)
import AppKit
#endif

/// Home screen: your group, who's around and how you're connected to each
/// person. On the Mac this is the sidebar; on iPhone/iPad it's the first
/// screen, with the same rows.
struct PeerListView: View {
    @ObservedObject var mesh: MeshManager
    @ObservedObject var profileStore: ProfileStore
    @Binding var selectedPeer: DiscoveredPeer?
    @State var showingGroupSwitcher = false
    @State var showingProfile = false
    @State var showingDiscovery = false
    @State var showingInternet = false
    @Binding var knownGroups: [ChatGroup]

    /// Connected people first, then connecting, then everyone else — each
    /// group alphabetical.
    private var sortedPeers: [DiscoveredPeer] {
        func rank(_ state: PeerConnectionState) -> Int {
            switch state {
            case .connected: return 0
            case .connecting: return 1
            case .notConnected: return 2
            }
        }
        return mesh.discoveredPeers.values.sorted {
            let a = rank($0.state), b = rank($1.state)
            if a != b { return a < b }
            return $0.mcPeerID.displayName < $1.mcPeerID.displayName
        }
    }

    private var connectedCount: Int {
        mesh.discoveredPeers.values.filter { $0.state == .connected }.count
    }

    private var otherCount: Int {
        max(0, mesh.discoveredPeers.count - connectedCount)
    }

    var body: some View {
        screen
            .navigationTitle(mesh.currentGroup.name)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            #if os(macOS)
            .toolbar {
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
                        showingInternet = true
                    } label: {
                        Label("Internet", systemImage: "globe")
                    }
                }
                ToolbarItem {
                    Button {
                        showingProfile = true
                    } label: {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingGroupSwitcher) {
                GroupSwitcherView(mesh: mesh, knownGroups: $knownGroups)
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView(profileStore: profileStore, mesh: mesh)
            }
            .sheet(isPresented: $showingDiscovery) {
                DiscoveryView(mesh: mesh)
            }
            .sheet(isPresented: $showingInternet) {
                InternetLinkView(mesh: mesh, onOpenChat: { peer in
                    showingInternet = false
                    selectedPeer = peer
                })
            }
            .sheet(item: $mesh.pendingTrustRequest) { peer in
                TrustPromptView(mesh: mesh, peer: peer)
            }
            .onChange(of: mesh.pendingTrustRequest) {
                // SwiftUI can only present one sheet at a time from this view,
                // and this view has several independent .sheet() triggers.
                // Without this, an inbound connection request arriving while any
                // other sheet is already up would silently fail to show its
                // trust prompt — the invitation handler never gets called, the
                // system times the invite out on its own, and the connection
                // just quietly dies with nothing on screen explaining why.
                guard mesh.pendingTrustRequest != nil else { return }
                showingGroupSwitcher = false
                showingProfile = false
                showingDiscovery = false
                showingInternet = false
            }
            .onAppear {
                mesh.start()
                if profileStore.isFirstRun {
                    showingProfile = true
                    profileStore.markFirstRunShown()
                }
            }
    }

    // MARK: Layout

    private var screen: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !mesh.localNetworkAuthorized {
                        LocalNetworkBanner()
                    }
                    peersContent
                }
                #if os(macOS)
                .padding(.horizontal, 8)
                #else
                .padding(.horizontal, 20)
                #endif
                .padding(.bottom, 12)
            }

            footer
        }
        #if os(iOS)
        .background(BrandBackground())
        #endif
    }

    @ViewBuilder
    private var header: some View {
        #if os(macOS)
        macHeader
        #else
        iosHeader
        #endif
    }

    // MARK: Rows

    @ViewBuilder
    private var peersContent: some View {
        if !mesh.localNetworkAuthorized && sortedPeers.isEmpty {
            NearbyPausedView {
                showingInternet = true
            }
        } else {
            #if os(macOS)
            Text("Nearby devices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            peerRows
            #else
            SectionCaption("Nearby devices")
            peerRows
                .brandCard(cornerRadius: 22)
            #endif
        }
    }

    @ViewBuilder
    private var peerRows: some View {
        if sortedPeers.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Searching for nearby people…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 2) {
                ForEach(sortedPeers) { peer in
                    PeerRowCard(
                        peer: peer,
                        hops: mesh.hopDistance(to: peer.id),
                        isSelected: selectedPeer?.id == peer.id,
                        onSelect: { selectedPeer = peer },
                        onConnect: { mesh.trust(peer) },
                        onForget: { mesh.forget(peer) }
                    )
                }
            }
            #if os(iOS)
            .padding(6)
            #endif
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Searching nearby")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Relay for others")
                .font(.caption.weight(.semibold))
            Toggle("Relay for others", isOn: $mesh.relayForOthers)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #if os(iOS)
        .brandCard(cornerRadius: 22)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        #endif
    }

    // MARK: Mac header

    #if os(macOS)
    private var macHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showingGroupSwitcher = true
            } label: {
                HStack(spacing: 6) {
                    Text(mesh.currentGroup.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch group")

            HStack(spacing: 6) {
                Circle()
                    .fill(connectedCount > 0 ? Brand.connected : Brand.offline)
                    .frame(width: 7, height: 7)
                Text(otherCount > 0 ? "\(connectedCount) connected · \(otherCount) more nearby" : "\(connectedCount) connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
    #endif

    // MARK: iPhone / iPad header

    #if os(iOS)
    private var iosHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    showingProfile = true
                } label: {
                    Image(systemName: "person")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Brand.surface, in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile")

                Spacer()

                HStack(spacing: 2) {
                    pillButton("point.3.connected.trianglepath.dotted", label: "Discovery") { showingDiscovery = true }
                    pillButton("person.3", label: "Groups") { showingGroupSwitcher = true }
                    pillButton("globe", label: "Internet") { showingInternet = true }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Brand.surface, in: Capsule())
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }

            Button {
                showingGroupSwitcher = true
            } label: {
                HStack(spacing: 8) {
                    Text(mesh.currentGroup.name)
                        .font(.system(size: 34, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            heroCard
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func pillButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var heroCard: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(connectedCount)")
                        .font(.system(size: 56, weight: .heavy))
                    Text("connected")
                        .font(.headline)
                }
                Text(otherCount > 0 ? "\(otherCount) more nearby" : "Nobody else nearby yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MiniNetworkSketch(connected: min(connectedCount, 3), others: min(otherCount, 3))
                .frame(width: 130, height: 84)
        }
        .padding(18)
        .brandCard(cornerRadius: 26)
        .accessibilityElement(children: .combine)
    }
    #endif
}

// MARK: - Peer row

/// One person: avatar with a route ring, name, status line, and either the
/// route tag or a Connect pill on the right. Shared by the Mac sidebar and
/// the iPhone/iPad list.
private struct PeerRowCard: View {
    let peer: DiscoveredPeer
    let hops: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onForget: () -> Void

    @State private var hovering = false

    /// How long since we last saw a not-connected device before the row says
    /// it's out of range instead of just "not connected".
    private static let outOfRangeAfter: TimeInterval = 90

    private var name: String { peer.mcPeerID.displayName }

    private var isOutOfRange: Bool {
        peer.state == .notConnected && Date().timeIntervalSince(peer.lastSeen) > Self.outOfRangeAfter
    }

    private var isRelayedRoute: Bool {
        peer.isRelayed || (hops ?? 1) > 1
    }

    private var ring: AvatarRing {
        switch peer.state {
        case .connecting:
            return .connecting
        case .notConnected:
            return .none
        case .connected:
            if peer.internetOnly { return .internet }
            if isRelayedRoute { return .relayed(hops: hops) }
            return .direct
        }
    }

    private var routeKind: RouteTag.Kind {
        if peer.internetOnly { return .internet }
        return isRelayedRoute ? .relayed : .nearby
    }

    private var statusText: String {
        switch peer.state {
        case .connected:
            if let hops, hops > 1 { return "Connected · \(hops) hops" }
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .notConnected:
            if isOutOfRange {
                let ago = peer.lastSeen.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
                return "Out of range · seen \(ago)"
            }
            return "Not connected"
        }
    }

    private var rowBackground: Color {
        if isSelected { return Brand.accent.opacity(0.14) }
        if hovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, size: 42, ring: ring, status: peer.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !peer.isTrusted {
                        Text("untrusted")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.warning)
                    }
                }
            }

            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(rowBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if peer.isTrusted {
                Button(role: .destructive, action: onForget) {
                    Label("Forget Device", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch peer.state {
        case .connected:
            RouteTag(kind: routeKind)
        case .connecting:
            EmptyView()
        case .notConnected:
            if isOutOfRange {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Not currently in range")
            } else {
                Button(action: onConnect) {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Hero sketch (iPhone / iPad)

/// A tiny abstract network: you in the middle, filled dots for people you're
/// connected to, hollow dots for people nearby but not connected.
private struct MiniNetworkSketch: View {
    let connected: Int
    let others: Int

    private let connectedSpots: [CGPoint] = [
        CGPoint(x: 0.62, y: 0.22), CGPoint(x: 0.92, y: 0.46), CGPoint(x: 0.66, y: 0.82)
    ]
    private let otherSpots: [CGPoint] = [
        CGPoint(x: 0.34, y: 0.9), CGPoint(x: 0.84, y: 0.14), CGPoint(x: 0.12, y: 0.18)
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let me = CGPoint(x: w * 0.3, y: h * 0.5)

            ZStack {
                ForEach(0..<connected, id: \.self) { index in
                    let spot = connectedSpots[index]
                    let point = CGPoint(x: w * spot.x, y: h * spot.y)
                    Path { path in
                        path.move(to: me)
                        path.addLine(to: point)
                    }
                    .stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: index == 0 ? [] : [1, 5]))
                    Circle()
                        .fill(Brand.accent)
                        .frame(width: 11, height: 11)
                        .position(point)
                }
                ForEach(0..<others, id: \.self) { index in
                    let spot = otherSpots[index]
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .position(CGPoint(x: w * spot.x, y: h * spot.y))
                }
                Circle().fill(Brand.accent.opacity(0.18)).frame(width: 34, height: 34).position(me)
                Circle().fill(Brand.accent).frame(width: 15, height: 15).position(me)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Local Network denied

/// Orange banner shown on top of the list while Local Network access is off.
private struct LocalNetworkBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoBanner(
                kind: .warning,
                title: "Local Network is off",
                message: "MeshChat can't find people nearby without it."
            )
            Button("Open Settings", action: openSettings)
                .buttonStyle(BrandButtonStyle())
        }
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

/// Empty state while nearby chat can't work: three steps to turn it back on,
/// and the internet as an alternative that doesn't need Local Network.
private struct NearbyPausedView: View {
    let onUseInternet: () -> Void

    private var settingsName: String {
        #if os(macOS)
        return "System Settings"
        #else
        return "Settings"
        #endif
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Brand.surface).frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Brand.warning)
            }
            Text("Nearby chat is paused")
                .font(.system(size: 22, weight: .heavy))

            VStack(spacing: 0) {
                step(1, "Open \(settingsName) and tap MeshChat")
                Divider().padding(.leading, 46)
                step(2, "Turn on Local Network")
                Divider().padding(.leading, 46)
                step(3, "Come back. It connects on its own")
            }
            .brandCard()

            Button(action: onUseInternet) {
                Label("Use internet chat instead", systemImage: "globe")
            }
            .buttonStyle(BrandButtonStyle(kind: .secondary))
        }
        .padding(.top, 8)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 24, height: 24)
                .background(Brand.accent.opacity(0.12), in: Circle())
            Text(text)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Trust prompt

private struct TrustPromptView: View {
    @ObservedObject var mesh: MeshManager
    let peer: DiscoveredPeer
    @State private var trustDevice = true

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 18) {
                ZStack(alignment: .topTrailing) {
                    AvatarView(name: peer.mcPeerID.displayName, size: 84, ring: .direct)
                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black))
                        .offset(x: 2, y: -2)
                }
                .padding(.top, 8)

                VStack(spacing: 6) {
                    Text("\(peer.mcPeerID.displayName) wants to connect")
                        .font(.system(size: 24, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A nearby device is asking to connect directly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack {
                    Text("Trust this device")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Trust this device", isOn: $trustDevice)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .brandCard(cornerRadius: 16)

                Text("Trusted devices auto-connect next time without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button("Decline") {
                        mesh.resolvePendingTrust(accept: false, peer: peer)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .destructive))

                    Button(trustDevice ? "Trust & Connect" : "Connect Once") {
                        mesh.resolvePendingTrust(accept: true, peer: peer, persistTrust: trustDevice)
                    }
                    .buttonStyle(BrandButtonStyle())
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 400)
        #else
        .presentationDetents([.height(460)])
        #endif
    }
}

// MARK: - Groups

private struct GroupSwitcherView: View {
    @ObservedObject var mesh: MeshManager
    @Binding var knownGroups: [ChatGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""

    private var trimmedNewName: String {
        newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(title: "Groups", onLeading: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only devices in the same group name can see each other.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SectionCaption("Switch group")
                    VStack(spacing: 0) {
                        ForEach(Array(knownGroups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Divider().padding(.leading, 58)
                            }
                            groupRow(group)
                        }
                    }
                    .brandCard()

                    SectionCaption("New group")
                        .padding(.top, 8)
                    TextField("Group name, for example Saturday Market", text: $newGroupName)
                        .brandField()
                    Text("Anyone who types exactly the same group name joins the group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Button("Create & Join", action: createGroup)
                        .buttonStyle(BrandButtonStyle())
                        .disabled(trimmedNewName.isEmpty)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    private func groupRow(_ group: ChatGroup) -> some View {
        let isCurrent = group.name == mesh.currentGroup.name
        return Button {
            mesh.switchGroup(to: group)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                IconBadge(systemName: "person.3")
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(isCurrent ? "Current group" : "Tap to switch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createGroup() {
        guard !trimmedNewName.isEmpty else { return }
        let group = ChatGroup(name: trimmedNewName)
        if !knownGroups.contains(where: { $0.name == group.name }) {
            knownGroups.append(group)
        }
        mesh.switchGroup(to: group)
        dismiss()
    }
}
