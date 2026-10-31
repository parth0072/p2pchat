import SwiftUI

/// Guided, server-free way to chat over the internet. One person creates an
/// invite (a QR code / text), the other scans or pastes it and shows a reply
/// back, and scanning that reply completes a direct WebRTC connection:
/// "two codes, two scans, one direct link". Devices that have already met on
/// the nearby mesh don't need this — they link automatically.
struct InternetLinkView: View {
    @ObservedObject var mesh: MeshManager
    /// Called with the freshly linked person when "Open chat" is tapped.
    var onOpenChat: ((DiscoveredPeer) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    enum Screen: Equatable {
        case start
        case inviteShow
        case inviteScanReply
        case connecting(peerID: String, name: String)
        case connected(peerID: String)
        case joinEnter
        case joinShowReply(peerID: String, name: String)
        case noRoute
        case expired(isReply: Bool)
        case relay
    }

    @State private var screen: Screen = .start
    @State private var relayReturn: Screen = .start

    @State private var invite: String?
    @State private var isPreparing = false
    @State private var replyCode: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingScanner = false
    @State private var showManualPaste = false
    @State private var manualText = ""

    /// How long to wait for a link to open before saying there's no direct
    /// route between the two networks.
    private static let connectTimeout: UInt64 = 40

    var body: some View {
        SheetScaffold(
            title: headerTitle,
            leading: headerLeading,
            onLeading: headerAction
        ) {
            screenContent
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { code in
                showingScanner = false
                handle(code: code)
            }
        }
        .onChange(of: mesh.internetLinkedPeerIDs) { oldValue, newValue in
            guard let newID = newValue.subtracting(oldValue).first, isInLinkFlow else { return }
            go(.connected(peerID: newID))
        }
        .onChange(of: mesh.internetLinkProgress) {
            // The inviter started working on my reply — the link is forming.
            if case .joinShowReply(let id, let name) = screen, mesh.internetLinkProgress != nil {
                go(.connecting(peerID: id, name: name))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: screen)
    }

    // MARK: Header

    private var headerTitle: String {
        switch screen {
        case .start: return "Internet chat"
        case .inviteShow, .inviteScanReply: return "Invite someone"
        case .connecting, .noRoute: return "Connecting"
        case .connected: return "Connected"
        case .joinEnter, .joinShowReply, .expired: return "I have an invite"
        case .relay: return "Relay server"
        }
    }

    private var headerLeading: SheetHeader.Leading {
        switch screen {
        case .start, .inviteShow, .joinShowReply, .expired: return .close
        case .inviteScanReply, .joinEnter, .noRoute, .relay: return .back
        case .connecting, .connected: return .none
        }
    }

    private func headerAction() {
        switch screen {
        case .start, .inviteShow, .joinShowReply, .expired:
            dismiss()
        case .inviteScanReply:
            go(.inviteShow)
        case .joinEnter, .noRoute:
            go(.start)
        case .relay:
            go(relayReturn)
        case .connecting, .connected:
            break
        }
    }

    /// True while a manual invite/join flow is on screen (as opposed to the
    /// start page, an error, or the relay settings), so a new link moves the
    /// flow to its success screen.
    private var isInLinkFlow: Bool {
        switch screen {
        case .inviteShow, .inviteScanReply, .connecting, .joinEnter, .joinShowReply: return true
        default: return false
        }
    }

    private func go(_ next: Screen) {
        errorMessage = nil
        screen = next
        if case .connecting(let id, _) = next {
            armTimeout(for: id)
        }
    }

    /// A manual link can silently fail to form (one network blocks
    /// peer-to-peer traffic, or the other person never finished) — say so
    /// instead of leaving a spinner running forever.
    private func armTimeout(for peerID: String) {
        Task {
            try? await Task.sleep(nanoseconds: Self.connectTimeout * 1_000_000_000)
            if case .connecting(let current, _) = screen,
               current == peerID,
               !mesh.internetLinkedPeerIDs.contains(peerID) {
                go(.noRoute)
            }
        }
    }

    // MARK: Screens

    @ViewBuilder
    private var screenContent: some View {
        switch screen {
        case .start: startScreen
        case .inviteShow: inviteShowScreen
        case .inviteScanReply: inviteScanReplyScreen
        case .connecting(_, let name): connectingScreen(name: name)
        case .connected(let id): connectedScreen(peerID: id)
        case .joinEnter: joinEnterScreen
        case .joinShowReply(_, let name): joinShowReplyScreen(name: name)
        case .noRoute: noRouteScreen
        case .expired(let isReply): expiredScreen(isReply: isReply)
        case .relay:
            RelayServerView(mesh: mesh) { go(relayReturn) }
        }
    }

    private func layout<Main: View, Footer: View>(
        @ViewBuilder content: () -> Main,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            VStack(spacing: 6) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .heavy))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Start

    private var linkedPeers: [DiscoveredPeer] {
        mesh.discoveredPeers.values
            .filter { $0.viaInternet }
            .sorted { $0.mcPeerID.displayName < $1.mcPeerID.displayName }
    }

    private var statusChip: some View {
        let on = mesh.internetChatEnabled && mesh.internetAvailable
        let text: String
        if !mesh.internetChatEnabled {
            text = "Internet chat is off"
        } else if mesh.internetAvailable {
            text = "Internet connection available"
        } else {
            text = "No internet connection"
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(on ? Brand.connected : Brand.offline)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var startScreen: some View {
        layout {
            statusChip
            title("Chat over the internet")
            bodyText("Your devices connect directly, with no server in the middle. You and a friend swap two short codes, one each way.")

            if !mesh.internetChatEnabled {
                InfoBanner(
                    kind: .warning,
                    title: "Internet chat is turned off",
                    message: "Turn it on in Privacy & security to link with people over the internet."
                )
            }

            VStack(spacing: 10) {
                actionCard(
                    icon: "qrcode",
                    title: "Invite someone",
                    detail: "Show a code first, then scan their reply"
                ) {
                    beginInvite()
                }
                actionCard(
                    icon: "qrcode.viewfinder",
                    title: "I have an invite",
                    detail: "Scan or paste a code you received"
                ) {
                    go(.joinEnter)
                }
            }
            .disabled(!mesh.internetChatEnabled)
            .opacity(mesh.internetChatEnabled ? 1 : 0.5)

            if !linkedPeers.isEmpty {
                SectionCaption("Connected over the internet")
                VStack(spacing: 0) {
                    ForEach(linkedPeers) { peer in
                        HStack(spacing: 12) {
                            AvatarView(name: peer.mcPeerID.displayName, size: 40, ring: .internet, status: .connected)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.mcPeerID.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text("Connected · end-to-end encrypted")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(Brand.connected)
                        }
                        .padding(12)
                    }
                }
                .brandCard()
            }

            Button {
                relayReturn = .start
                go(.relay)
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "server.rack", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Relay server (optional)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Only needed if a direct route can't be found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .brandCard()
            }
            .buttonStyle(.plain)
        } footer: {
            EmptyView()
        }
    }

    private func actionCard(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemName: icon, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .brandCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Invite path

    private func beginInvite() {
        invite = nil
        isPreparing = true
        go(.inviteShow)
        Task {
            let code = await mesh.createInternetInvite()
            invite = code
            isPreparing = false
            if code == nil {
                errorMessage = "Couldn't create an invite. Try again."
            }
        }
    }

    private var inviteShowScreen: some View {
        layout {
            StepBar(step: 1, total: 3)
            Text("Step 1 of 3 · Show your invite")
                .font(.caption)
                .foregroundStyle(.secondary)
            title("Show this to your friend")
            HandoffDiagram(leftIcon: "qrcode", leftLabel: "You show", rightIcon: "qrcode.viewfinder", rightLabel: "Your friend scans")

            if let errorMessage {
                InfoBanner(kind: .error, title: errorMessage)
            }

            if isPreparing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing your invite… this takes a few seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let invite {
                QRCard(code: invite, size: 190)
                CodeActions(code: invite)
                Label("Valid for 10 minutes · works once", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Try again") { beginInvite() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
            }
        } footer: {
            Button {
                go(.inviteScanReply)
            } label: {
                Label("Next: scan their reply", systemImage: "arrow.right")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(invite == nil)
        }
    }

    private var inviteScanReplyScreen: some View {
        layout {
            StepBar(step: 2, total: 3)
            Text("Step 2 of 3 · Scan their reply")
                .font(.caption)
                .foregroundStyle(.secondary)
            title("Now scan their reply")
            bodyText("Your friend's device now shows a reply code. Scan it, or paste it, to finish.")
            HandoffDiagram(leftIcon: "qrcode", leftLabel: "Your friend shows", rightIcon: "qrcode.viewfinder", rightLabel: "You scan")
            waitingChip("Waiting for their reply…")
            workingAndError
            manualPasteBox
        } footer: {
            Button {
                showingScanner = true
            } label: {
                Label("Scan reply code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(isWorking)

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste reply code", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(BrandButtonStyle(kind: .secondary))
            .disabled(isWorking)

            TextLinkButton(title: "Show my invite again") { go(.inviteShow) }
        }
    }

    // MARK: Join path

    private var joinEnterScreen: some View {
        layout {
            title("Scan or paste the invite")
            bodyText("Your friend shows a code on their device. Scan it, or paste the text they sent you.")
            HandoffDiagram(leftIcon: "qrcode", leftLabel: "Your friend shows", rightIcon: "qrcode.viewfinder", rightLabel: "You scan")
            workingAndError
            manualPasteBox
        } footer: {
            Button {
                showingScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(isWorking)

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste code", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(BrandButtonStyle(kind: .secondary))
            .disabled(isWorking)
        }
    }

    private func joinShowReplyScreen(name: String) -> some View {
        layout {
            title("Show this reply to \(name)")
            bodyText("\(name) scans it, or pastes it, to finish. You'll connect automatically.")
            if let replyCode {
                QRCard(code: replyCode, size: 190)
                CodeActions(code: replyCode)
            }
            waitingChip("Waiting for \(name) to scan…")
        } footer: {
            TextLinkButton(title: "Cancel", tint: .secondary) {
                replyCode = nil
                go(.start)
            }
        }
    }

    // MARK: Shared pieces for scan / paste

    private func waitingChip(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Brand.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var workingAndError: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the code…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let errorMessage {
            InfoBanner(kind: .error, title: errorMessage)
        }
    }

    private var manualPasteBox: some View {
        let trimmed = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognized = LinkSignalCodec.decode(manualText)
        return Group {
            if showManualPaste {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Paste a MeshChat code", text: $manualText, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .brandField()

                    if !trimmed.isEmpty {
                        if let recognized {
                            Label(
                                recognized.kind == .offer
                                    ? "Invite from \(recognized.fromName)"
                                    : "Reply from \(recognized.fromName)",
                                systemImage: "checkmark.seal.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(Brand.connected)
                        } else {
                            Label("Not a valid MeshChat code (yet)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Brand.warning)
                        }
                    }

                    Button("Connect") {
                        handle(code: manualText)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(recognized == nil || isWorking)
                }
            }
        }
    }

    private func pasteFromClipboard() {
        let text = Clipboard.text()
        if LinkSignalCodec.decode(text) != nil {
            manualText = text
            handle(code: text)
        } else {
            showManualPaste = true
            errorMessage = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "The clipboard is empty. Copy the code first, or paste it below."
                : "That isn't a MeshChat code. Paste a different one below."
        }
    }

    /// Handles a code from the scanner or the paste box: an invite gets
    /// answered (a reply code to show back), a reply completes an invite I
    /// made earlier.
    private func handle(code text: String) {
        errorMessage = nil
        isWorking = true
        let wasReply = screen == .inviteScanReply
        Task {
            let result = await mesh.processInternetCode(text)
            isWorking = false
            switch result {
            case .reply(let code, let peerID, let name):
                replyCode = code
                manualText = ""
                showManualPaste = false
                go(.joinShowReply(peerID: peerID, name: name))
            case .linked(let peerID, let name):
                manualText = ""
                showManualPaste = false
                go(.connecting(peerID: peerID, name: name))
            case .expired:
                go(.expired(isReply: wasReply))
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    // MARK: Connecting / connected

    private func connectingScreen(name: String) -> some View {
        layout {
            StepBar(step: 3, total: 3)
            Text("Step 3 of 3 · Connect")
                .font(.caption)
                .foregroundStyle(.secondary)
            title("Connecting to \(name)")
            bodyText("This usually takes a few seconds.")

            VStack(alignment: .leading, spacing: 0) {
                checkRow("Reply received", state: .done)
                Divider().padding(.leading, 44)
                checkRow("Codes match", state: .done)
                Divider().padding(.leading, 44)
                checkRow("Finding a direct route", state: .active)
                Divider().padding(.leading, 44)
                checkRow("Securing the connection", state: .pending)
            }
            .brandCard()

            if let progress = mesh.internetLinkProgress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            TextLinkButton(title: "Cancel", tint: .secondary) { go(.start) }
        }
    }

    private enum CheckState {
        case done, active, pending
    }

    private func checkRow(_ text: String, state: CheckState) -> some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.connected)
                case .active:
                    ProgressView().controlSize(.small)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            Text(text)
                .font(.subheadline.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func connectedScreen(peerID: String) -> some View {
        let peer = mesh.discoveredPeers[peerID]
        let name = peer?.mcPeerID.displayName ?? mesh.internetRemoteName(for: peerID)
        return layout {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Brand.connected.opacity(0.14)).frame(width: 96, height: 96)
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Brand.connected)
                }
                Text("Connected to \(name)")
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)
                Text("Encrypted, direct. Messages go straight between your devices, with nothing in the middle.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            if let peer, let onOpenChat {
                Button("Open chat") {
                    onOpenChat(peer)
                }
                .buttonStyle(BrandButtonStyle())
                Button("Done") { dismiss() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(BrandButtonStyle())
            }
        }
    }

    // MARK: Errors

    private var noRouteScreen: some View {
        layout {
            InfoBanner(kind: .error, title: "Couldn't connect", message: "No direct route between these two networks…")

            HStack(spacing: 14) {
                networkCard("Your network")
                ZStack {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.tertiary)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Brand.error)
                        .background(Circle().fill(Brand.surface))
                }
                networkCard("Their network")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            title("No direct route between your networks")
            bodyText("This is common on mobile data and some office or school Wi-Fi. A relay server can pass your encrypted data along. It can't read it.")
        } footer: {
            Button {
                relayReturn = .start
                go(.relay)
            } label: {
                Label("Add a relay server", systemImage: "server.rack")
            }
            .buttonStyle(BrandButtonStyle())

            Button("Try again") { go(.start) }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
        }
    }

    private func networkCard(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi")
                .font(.system(size: 18, weight: .medium))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .frame(width: 112, height: 78)
        .brandCard(cornerRadius: 16)
    }

    private func expiredScreen(isReply: Bool) -> some View {
        layout {
            Spacer(minLength: 40)
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Brand.surface).frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                    Image(systemName: "clock")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Brand.warning)
                }
                Text(isReply ? "This reply doesn't match an open invite" : "This invite has expired")
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)
                Text(isReply
                     ? "Invites work for 10 minutes, and only once. Create a new invite and try again."
                     : "Invites work for 10 minutes, and only once. Ask your friend to create a new one.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            if isReply {
                Button {
                    beginInvite()
                } label: {
                    Label("Create a new invite", systemImage: "qrcode")
                }
                .buttonStyle(BrandButtonStyle())
            } else {
                Button {
                    go(.joinEnter)
                    showingScanner = true
                } label: {
                    Label("Scan another code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(BrandButtonStyle())
            }
            TextLinkButton(title: "Back") { go(.start) }
        }
    }
}

// MARK: - Relay server

/// Optional TURN relay settings, used by both the Internet chat flow and the
/// Privacy & security screen. The host supplies the header.
struct RelayServerView: View {
    @ObservedObject var mesh: MeshManager
    let onDone: () -> Void

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Optional. A relay helps when two devices can't find a direct route. It passes encrypted data and can't read your messages.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    InfoBanner(
                        kind: .info,
                        title: "Relay servers only see encrypted data",
                        message: "Your chats stay end-to-end encrypted, even through a relay."
                    )

                    field("Server address") {
                        TextField("turn:relay.example.org:3478", text: $url)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .brandField()
                    }
                    field("Username") {
                        TextField("Optional", text: $username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .brandField()
                    }
                    field("Password") {
                        SecureField("Optional", text: $password)
                            .brandField()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            VStack(spacing: 6) {
                Button("Save") {
                    mesh.saveRelay(RelaySettings(url: url, username: username, credential: password))
                    onDone()
                }
                .buttonStyle(BrandButtonStyle())

                TextLinkButton(title: "Use direct connections only", tint: .secondary) {
                    mesh.saveRelay(RelaySettings())
                    url = ""
                    username = ""
                    password = ""
                    onDone()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .onAppear {
            let relay = mesh.relaySettings
            url = relay.url
            username = relay.username
            password = relay.credential
        }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
