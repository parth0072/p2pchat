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
    @State private var isWorking = false

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

                Section("1 · Invite someone") {
                    if let myInvite {
                        CodeBlock(title: "Your invite", code: myInvite)
                    }
                    Button(myInvite == nil ? "Create invite" : "Create a new invite") {
                        createInvite()
                    }
                    .disabled(isWorking)
                }

                Section("2 · Paste a code you received") {
                    TextField("Paste an invite or reply code", text: $pasted, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste from clipboard") { pasted = Self.clipboardText() }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Connect") { connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reply {
                        CodeBlock(title: "Send this reply back", code: reply)
                    }
                }

                if isWorking || status != nil {
                    Section {
                        HStack(spacing: 8) {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(status ?? "")
                                .font(.caption)
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
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    private func createInvite() {
        isWorking = true
        status = "Preparing invite…"
        Task {
            let code = await mesh.createInternetInvite()
            myInvite = code
            status = code == nil
                ? "Couldn't create an invite. Try again."
                : "Share this with the other person, then paste the reply they send back in step 2."
            isWorking = false
        }
    }

    private func connect() {
        let text = pasted
        isWorking = true
        status = "Working…"
        Task {
            switch await mesh.processInternetCode(text) {
            case .reply(let code):
                reply = code
                status = "Send this reply back to them. You'll be connected as soon as they paste it."
            case .linked(let name):
                reply = nil
                pasted = ""
                status = "Connecting to \(name)… this takes a few seconds."
            case .failure(let message):
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
