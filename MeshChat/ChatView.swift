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
    let peer: DiscoveredPeer?
    let store: MessageStore

    @State private var draft = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var showingAttachmentPanel = false
    @State private var showingStickerPicker = false
    @State private var previewMessage: ChatMessage?
    @State private var largeFileWarning: (url: URL, name: String, size: Int)?
    @FocusState private var isComposerFocused: Bool

    private var groupMessages: [ChatMessage] {
        mesh.messages
            .filter { $0.groupID == mesh.currentGroup.name }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupMessages) { message in
                            MessageBubble(
                                message: message,
                                isMine: message.senderID == DiscoveredPeer.stableID(for: mesh.localPeerID),
                                onTap: { previewMessage = message }
                            )
                            .id(message.id)
                        }
                        if !mesh.typingPeerIDs.isEmpty {
                            TypingIndicatorRow(count: mesh.typingPeerIDs.count)
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
                    if let last = groupMessages.last {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: groupMessages.count) {
                    if let last = groupMessages.last {
                        withAnimation { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: isComposerFocused) {
                    // Keep the newest message in view as the keyboard rises,
                    // synced to roughly the keyboard's own animation timing
                    // instead of jumping after the fact.
                    guard isComposerFocused, let last = groupMessages.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            transferBar

            composer
        }
        .navigationTitle(peer?.mcPeerID.displayName ?? mesh.currentGroup.name)
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
                mesh.sendSticker(emoji)
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
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
        }
    }

    private var composer: some View {
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

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isComposerFocused)
                .onChange(of: draft) {
                    mesh.sendTypingIndicator(isTyping: !draft.isEmpty)
                }
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: composerIconSize))
            }
            .frame(width: composerTapTarget, height: composerTapTarget)
            .contentShape(Rectangle())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        mesh.sendText(trimmed)
        draft = ""
        mesh.sendTypingIndicator(isTyping: false)
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
        guard let target = peer?.mcPeerID else { return }
        mesh.sendResource(at: url, named: name, toPeer: target)
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

    private var standardBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !isMine {
                    Text(message.senderName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                content
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.2))
            .foregroundStyle(isMine ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if !isMine { Spacer(minLength: 40) }
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
    let count: Int

    var body: some View {
        HStack {
            Text(count == 1 ? "Someone is typing…" : "\(count) people are typing…")
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
