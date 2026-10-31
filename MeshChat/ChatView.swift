import SwiftUI
import MultipeerConnectivity
import PhotosUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ChatView: View {
    @ObservedObject var mesh: MeshManager
    let peer: DiscoveredPeer
    let store: MessageStore

    @State private var draft = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var showingAttachmentPanel = false
    @State private var showingStickerPicker = false
    @State private var previewMessage: ChatMessage?
    @State private var largeFileWarning: (url: URL, name: String, size: Int)?
    @FocusState private var isComposerFocused: Bool

    /// This peer's own 1:1 thread — messages I sent *to* this peer plus
    /// messages I received *from* this peer, kept separate from every other
    /// connected device's conversation instead of one merged group feed.
    private var conversationMessages: [ChatMessage] {
        let myID = DiscoveredPeer.stableID(for: mesh.localPeerID)
        return mesh.messages
            .filter { $0.conversationPartnerID(myID: myID) == peer.id }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ExpiryChip()
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 6)
                        ForEach(conversationMessages) { message in
                            MessageBubble(
                                message: message,
                                isMine: message.senderID == DiscoveredPeer.stableID(for: mesh.localPeerID),
                                onTap: { previewMessage = message }
                            )
                            .id(message.id)
                        }
                        if mesh.typingPeerIDs.contains(peer.id) {
                            TypingIndicatorRow(name: peer.mcPeerID.displayName)
                        }
                    }
                    .padding()
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onAppear {
                    // Jump straight to the latest message when the chat
                    // opens — no animation, so it doesn't visibly scroll
                    // through the whole history first.
                    if let last = conversationMessages.last {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversationMessages.count) {
                    if let last = conversationMessages.last {
                        withAnimation { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: isComposerFocused) {
                    // Keep the newest message in view as the keyboard rises,
                    // synced to roughly the keyboard's own animation timing
                    // instead of jumping after the fact.
                    guard isComposerFocused, let last = conversationMessages.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            transferBar

            composer
        }
        .navigationTitle(peer.mcPeerID.displayName)
        #if os(macOS)
        .navigationSubtitle(routeSubtitle)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                chatHeader
            }
        }
        #endif
        .brandBackground()
        .onAppear { mesh.isChatViewVisible = true }
        .onDisappear { mesh.isChatViewVisible = false }
        .sheet(item: $previewMessage) { message in
            AttachmentPreview(message: message)
        }
        .alert("Large file", isPresented: .constant(largeFileWarning != nil), presenting: largeFileWarning) { info in
            Button("Send Anyway") {
                sendFile(url: info.url, name: info.name)
                largeFileWarning = nil
            }
            Button("Cancel", role: .cancel) { largeFileWarning = nil }
        } message: { info in
            let seconds = MeshManager.estimatedTransferSeconds(fileSizeBytes: info.size)
            Text("\(info.name) is \(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)). Estimated transfer time: \(Int(seconds))s over Wi-Fi/Bluetooth.")
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            handlePickedFile(url: url)
        }
        .onChange(of: photoPickerItem) {
            guard let item = photoPickerItem else { return }
            showingAttachmentPanel = false
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let name = "photo-\(UUID().uuidString.prefix(8)).jpg"
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try? data.write(to: tmp)
                    handlePickedFile(url: tmp)
                }
                photoPickerItem = nil
            }
        }
        .popover(isPresented: $showingAttachmentPanel, arrowEdge: .bottom) {
            AttachmentPanel(
                photoPickerItem: $photoPickerItem,
                onDocument: {
                    showingAttachmentPanel = false
                    showingFileImporter = true
                },
                onSticker: {
                    showingAttachmentPanel = false
                    showingStickerPicker = true
                }
            )
            .presentationCompactAdaptation(.sheet)
            #if os(iOS)
            .presentationDetents([.height(220)])
            #endif
        }
        .sheet(isPresented: $showingStickerPicker) {
            StickerPickerView { emoji in
                mesh.sendSticker(emoji, to: peer)
            }
            .presentationDetents([.medium, .large])
        }
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        #endif
    }

    private var transferBar: some View {
        let inProgress = mesh.activeTransfers.values.filter { $0.status == .inProgress }
        return Group {
            if !inProgress.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(inProgress), id: \.id) { transfer in
                        HStack {
                            Text(transfer.fileName)
                                .font(.caption)
                                .lineLimit(1)
                            ProgressView(value: transfer.fractionCompleted)
                            Text("\(Int(transfer.fractionCompleted * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                mesh.cancelTransfer(transfer.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .cardStyle()
                .padding(.horizontal)
                .padding(.top, 4)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            routeIndicator
            if livePeer.internetOnly {
                Text("\(peer.mcPeerID.displayName) is connected over the internet — text and stickers work, but files/photos need a nearby (Wi-Fi/Bluetooth) connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            } else if peer.isRelayed {
                Text("\(peer.mcPeerID.displayName) is reachable via relay — text works, but files/photos need a direct connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            composerRow
        }
    }

    /// Live route summary for this peer, recomputed from the gossiped mesh
    /// topology (see MeshManager.hopDistance) every time it changes — a
    /// direct 1-hop link vs. a message that has to cross other devices to
    /// get here are very different in practice (latency, and file transfers
    /// only work when it's direct), so this stays visible right above the
    /// composer instead of being buried in the Discovery graph.
    private var routeIndicator: some View {
        routePill
    }

    /// One centred pill — how this chat is routed, and that it's end-to-end
    /// encrypted. Messages are sealed to the recipient on every route, so
    /// even relay hops on a multi-hop path only ever pass along the sealed
    /// envelope; the lock is a real guarantee, not decoration.
    private var routePill: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: routeIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(routeIsDirect ? Brand.accent : Brand.warning)
                Text(routeShortLabel)
                    .font(.caption.weight(.semibold))
            }
            Text("•")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text("End-to-end encrypted")
                    .font(.caption)
            }
            .foregroundStyle(Brand.encrypted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Brand.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .frame(maxWidth: .infinity)
    }

    private var routeIcon: String {
        if routeIsInternet { return "globe" }
        return routeIsDirect ? "circle" : "arrow.triangle.branch"
    }

    /// Short route name for the pill: "Direct · Nearby", "Relayed · 3 hops", …
    private var routeShortLabel: String {
        if routeIsInternet { return "Internet · Peer-to-peer" }
        switch routeHopCount {
        case nil:
            return peer.state == .connecting ? "Connecting…" : "Route unknown"
        case 0, 1:
            return "Direct · Nearby"
        case let hop?:
            return "Relayed · \(hop) hops"
        }
    }

    /// Window subtitle under the person's name.
    private var routeSubtitle: String {
        if routeIsInternet { return "Internet · Direct" }
        switch routeHopCount {
        case nil:
            return peer.state == .connecting ? "Connecting…" : "Route unknown"
        case 0, 1:
            return "Nearby · Direct"
        case let hop?:
            return "Relayed · \(hop) hops"
        }
    }

    #if os(iOS)
    /// Centred header: avatar, name and how you're connected.
    private var chatHeader: some View {
        HStack(spacing: 8) {
            AvatarView(name: peer.mcPeerID.displayName, size: 34, ring: headerRing)
            VStack(alignment: .leading, spacing: 0) {
                Text(peer.mcPeerID.displayName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(Brand.color(for: livePeer.state))
                        .frame(width: 6, height: 6)
                    Text(routeSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(Brand.surface, in: Capsule())
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private var headerRing: AvatarRing {
        if routeIsInternet { return .internet }
        switch routeHopCount {
        case nil: return livePeer.state == .connecting ? .connecting : .none
        case 0, 1: return .direct
        case let hop?: return .relayed(hops: hop)
        }
    }
    #endif

    /// The peer's current state (ChatView is handed a snapshot when the chat
    /// opens, which doesn't reflect later link changes).
    private var livePeer: DiscoveredPeer {
        mesh.discoveredPeers[peer.id] ?? peer
    }

    /// Messages to this peer are going out over their WebRTC link.
    private var routeIsInternet: Bool {
        mesh.internetUsable && mesh.internetLinkedPeerIDs.contains(peer.id)
    }

    private var routeHopCount: Int? {
        mesh.hopDistance(to: peer.id)
    }

    private var routeIsDirect: Bool {
        routeIsInternet || (routeHopCount ?? .max) <= 1
    }

    private var composerRow: some View {
        HStack(spacing: 8) {
            Button {
                showingAttachmentPanel = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: composerIconSize))
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: composerTapTarget, height: composerTapTarget)
            .contentShape(Rectangle())
            .disabled(peer.isRelayed || livePeer.internetOnly)
            .opacity(peer.isRelayed || livePeer.internetOnly ? 0.4 : 1)
            .buttonStyle(.plain)
            .foregroundStyle(Brand.accent)
            .accessibilityLabel("Attach")

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isComposerFocused)
                .onChange(of: draft) {
                    mesh.sendTypingIndicator(isTyping: !draft.isEmpty, to: peer)
                }
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: composerIconSize))
            }
            .frame(width: composerTapTarget, height: composerTapTarget)
            .contentShape(Rectangle())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.plain)
            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? Color.secondary.opacity(0.4)
                             : Brand.accent)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// iOS gets touch-appropriate sizing (Apple HIG wants >=44pt tap
    /// targets); macOS keeps the smaller pointer-friendly size that fit
    /// the sidebar layout.
    private var composerIconSize: CGFloat {
        #if os(iOS)
        30
        #else
        20
        #endif
    }

    private var composerTapTarget: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mesh.sendText(trimmed, to: peer)
        draft = ""
        mesh.sendTypingIndicator(isTyping: false, to: peer)
    }

    private func handlePickedFile(url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            sendFile(url: url, name: url.lastPathComponent)
            return
        }
        if size > MeshManager.largeFileThresholdBytes {
            largeFileWarning = (url, url.lastPathComponent, size)
        } else {
            sendFile(url: url, name: url.lastPathComponent)
        }
    }

    private func sendFile(url: URL, name: String) {
        // Files need a real MultipeerConnectivity session — not available
        // for relay-only or internet-only peers (also guards the macOS
        // drag-and-drop path, which bypasses the disabled attach button).
        guard !peer.isRelayed, !livePeer.internetOnly else { return }
        mesh.sendResource(at: url, named: name, toPeer: peer.mcPeerID)
    }

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    handlePickedFile(url: url)
                }
            }
        }
        return true
    }
    #endif
}

// MARK: - Attachment panel (Telegram-style attach menu)

private struct AttachmentPanel: View {
    @Binding var photoPickerItem: PhotosPickerItem?
    let onDocument: () -> Void
    let onSticker: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                AttachmentRow(icon: "photo.on.rectangle.angled", tint: .blue, title: "Photo or Video")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            Button(action: onDocument) {
                AttachmentRow(icon: "doc.fill", tint: .indigo, title: "Document")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            Button(action: onSticker) {
                AttachmentRow(icon: "face.smiling.fill", tint: .orange, title: "Sticker")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(minWidth: 260)
    }
}

private struct AttachmentRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint)
                Image(systemName: icon)
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 30, height: 30)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Sticker picker

private struct StickerPickerView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let stickers = [
        "😀", "😂", "😍", "😎", "🥳", "😢", "😡", "👍", "👎", "❤️",
        "🔥", "🎉", "👏", "🙏", "😴", "🤔", "😱", "🤯", "🥰", "😇",
        "🤗", "🙄", "😅", "🤩", "💯", "✨", "🎈", "🌟", "🍕", "☕️",
        "🐶", "🐱", "🚀", "⚡️", "🌈", "🎵", "💀", "👻", "🤝", "🫡"
    ]

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(stickers, id: \.self) { sticker in
                        Button {
                            onSelect(sticker)
                            dismiss()
                        } label: {
                            Text(sticker)
                                .font(.system(size: 40))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Stickers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let onTap: () -> Void

    var body: some View {
        if message.type == .sticker {
            stickerBubble
        } else {
            standardBubble
        }
    }

    /// Sender name above, the bubble itself, timestamp below.
    private var standardBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !isMine {
                    Text(message.senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                content
                    .chatBubbleStyle(isMine: isMine)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 60) }
        }
    }

    /// Stickers render like Telegram's: no bubble background, just a big
    /// glyph with the sender name/timestamp alongside it.
    private var stickerBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !isMine {
                    Text(message.senderName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .font(.system(size: 72))
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.type {
        case .text, .typing, .sticker:
            Text(message.content)
        case .image:
            thumbnail
                .onTapGesture(perform: onTap)
        case .video:
            ZStack {
                thumbnail
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
            .onTapGesture(perform: onTap)
        case .file:
            fileBubble
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let localURL = message.localURL, let image = platformImage(at: localURL) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 160, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.gray.opacity(0.3))
                .frame(width: 160, height: 120)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func platformImage(at url: URL) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }

    private var fileBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? message.content)
                    .font(.subheadline)
                    .lineLimit(1)
                if let size = message.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if message.localURL != nil {
                Button {
                    onTap()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .frame(minWidth: 180)
    }
}

private struct TypingIndicatorRow: View {
    let name: String

    var body: some View {
        HStack {
            Text("\(name) is typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct AttachmentPreview: View {
    let message: ChatMessage

    var body: some View {
        Group {
            if let url = message.localURL {
                switch message.type {
                case .video:
                    VideoPlayer(player: AVPlayer(url: url))
                case .image:
                    #if canImport(UIKit)
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage).resizable().scaledToFit()
                    }
                    #elseif canImport(AppKit)
                    if let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage).resizable().scaledToFit()
                    }
                    #endif
                default:
                    VStack(spacing: 12) {
                        Image(systemName: "doc.fill").font(.largeTitle)
                        Text(message.fileName ?? url.lastPathComponent)
                        #if os(macOS)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        #endif
                    }
                    .padding()
                }
            } else {
                Text("File not available")
            }
        }
        .padding()
    }
}
