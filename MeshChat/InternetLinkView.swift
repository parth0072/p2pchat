import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manual, server-free way to chat over the internet: one person creates an
/// invite (shown as a QR code and as text), the other pastes it and gets a
/// reply code to send back, and pasting that reply completes a direct
/// WebRTC connection between the two devices. Devices that have already met
/// on the nearby mesh don't need this — they link automatically.
struct InternetLinkView: View {
    @ObservedObject var mesh: MeshManager
    @Environment(\.dismiss) private var dismiss

    @State private var myInvite: String?
    @State private var pasted = ""
    @State private var reply: String?
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isWorking = false
    @State private var showingScanner = false
    @State private var relayURL = ""
    @State private var relayUser = ""
    @State private var relayPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        mesh.internetAvailable ? "Internet connection available" : "No internet connection",
                        systemImage: mesh.internetAvailable ? "globe" : "wifi.slash"
                    )
                    .foregroundStyle(mesh.internetAvailable ? Color.green : Color.secondary)
                    Text("Chat directly with someone over the internet — no server, nothing stored. Messages go straight from device to device and stay end-to-end encrypted. When there's no internet, chats fall back to the nearby Wi-Fi/Bluetooth mesh automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Result/progress lives at the TOP of the form: with an invite
                // QR and a reply QR on screen the bottom of this sheet is
                // easily scrolled out of view, which made a tap on Connect
                // look like it did nothing.
                if isWorking || status != nil {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            if isWorking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(statusIsError ? Color.red : Color.blue)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(status ?? "")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let progress = mesh.internetLinkProgress {
                                    Text(progress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if let progress = mesh.internetLinkProgress {
                    Section {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("1 · Invite someone") {
                    if let myInvite {
                        CodeBlock(title: "Your invite", code: myInvite)
                    }
                    Button(myInvite == nil ? "Create invite" : "Create a new invite") {
                        createInvite()
                    }
                    .disabled(isWorking)
                }

                Section("2 · Scan or paste a code you received") {
                    TextField("Paste an invite or reply code", text: $pasted, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    if !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let recognized = LinkSignalCodec.decode(pasted) {
                            Label(
                                recognized.kind == .offer
                                    ? "Invite from \(recognized.fromName) — press Connect"
                                    : "Reply from \(recognized.fromName) — press Connect",
                                systemImage: "checkmark.seal.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(Color.green)
                        } else {
                            Label("Not a valid MeshChat code (yet)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                        }
                    }
                    // Each button gets an explicit style so it is tapped on
                    // its own — in a Form row, buttons left on the default
                    // style all fire together when any part of the row is
                    // tapped.
                    HStack(spacing: 12) {
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            pasted = Self.clipboardText()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        connect(with: pasted)
                    } label: {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let reply {
                        CodeBlock(title: "Show this reply to the person who invited you", code: reply)
                    }
                }

                Section {
                    DisclosureGroup("Advanced: relay server (optional)") {
                        Text("If two networks can't connect directly (common on mobile data), a TURN relay can carry the connection. It only forwards traffic that is already encrypted and stores nothing. Only one of the two devices needs it set.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("turn:your-server:3478", text: $relayURL)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        TextField("Username", text: $relayUser)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        SecureField("Password", text: $relayPassword)
                        Button("Save relay") {
                            mesh.saveRelay(RelaySettings(url: relayURL, username: relayUser, credential: relayPassword))
                            statusIsError = false
                            status = relayURL.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "Relay cleared."
                                : "Relay saved. It applies to new invites and replies."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !linkedPeers.isEmpty {
                    Section("Connected over the internet") {
                        ForEach(linkedPeers) { peer in
                            Label(peer.mcPeerID.displayName, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                        }
                    }
                }

            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Internet Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            let relay = mesh.relaySettings
            relayURL = relay.url
            relayUser = relay.username
            relayPassword = relay.credential
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { code in
                pasted = code
                connect(with: code)
            }
        }
        .onChange(of: mesh.internetLinkedPeerIDs) { oldValue, newValue in
            guard let newID = newValue.subtracting(oldValue).first else { return }
            let name = mesh.discoveredPeers[newID]?.mcPeerID.displayName ?? newID
            reply = nil
            pasted = ""
            isWorking = false
            statusIsError = false
            status = "Connected to \(name) ✓ — open the chat from the peer list."
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    private var linkedPeers: [DiscoveredPeer] {
        mesh.discoveredPeers.values
            .filter { $0.viaInternet }
            .sorted { $0.mcPeerID.displayName < $1.mcPeerID.displayName }
    }

    /// A manual link can silently fail to form (the other person never
    /// entered the reply, or one network blocks peer-to-peer traffic) —
    /// say so instead of leaving the sheet looking like it's still working.
    private func watchForLink(peerID: String, name: String) {
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !mesh.internetLinkedPeerIDs.contains(peerID) {
                statusIsError = true
                status = "Still not connected to \(name). Check that both steps were completed on both devices and that both are online. Some networks block direct peer-to-peer connections."
            }
        }
    }

    private func createInvite() {
        isWorking = true
        statusIsError = false
        status = "Preparing invite… (up to ~6 seconds)"
        Task {
            let code = await mesh.createInternetInvite()
            myInvite = code
            statusIsError = code == nil
            status = code == nil
                ? "Couldn't create an invite. Try again."
                : "Share this with the other person, then paste the reply they send back in step 2."
            isWorking = false
        }
    }

    private func connect(with text: String) {
        isWorking = true
        statusIsError = false
        status = "Connecting… (up to ~6 seconds)"
        Task {
            switch await mesh.processInternetCode(text) {
            case .reply(let code, let peerID, let name):
                reply = code
                pasted = ""
                status = "Now show the reply below to \(name): they tap Scan QR (or Paste) and then Connect on their device. You'll connect automatically."
                watchForLink(peerID: peerID, name: name)
            case .linked(let peerID, let name):
                reply = nil
                pasted = ""
                status = "Connecting to \(name)… this takes a few seconds."
                watchForLink(peerID: peerID, name: name)
            case .failure(let message):
                statusIsError = true
                status = message
            }
            isWorking = false
        }
    }

    static func clipboardText() -> String {
        #if canImport(UIKit)
        return UIPasteboard.general.string ?? ""
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return ""
        #endif
    }
}

/// A code shown both as a scannable QR image (when it fits) and as text that
/// can be copied or shared through any messenger.
private struct CodeBlock: View {
    let title: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            if let image = Self.qrImage(for: code) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Too long for a QR code — use Copy or Share.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(.caption2.monospaced())
                .lineLimit(3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Copy") { Self.copy(code) }
                ShareLink(item: code) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private static func qrImage(for text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
