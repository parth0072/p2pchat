import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Buttons

/// Full-width capsule buttons from the Signal design: a filled indigo primary
/// and a white secondary with a hairline border.
struct BrandButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, destructive
    }

    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, kind: kind)
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BrandButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .primary
        case .destructive: return Brand.error
        }
    }

    private var fill: Color {
        kind == .primary ? Brand.accent : Brand.surface
    }

    var body: some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(kind == .primary ? 0 : 0.08), lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Quiet text-only button ("Back", "Not now", "Show my invite again").
struct TextLinkButton: View {
    let title: String
    var tint: Color = Brand.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet scaffolding

/// Round close / back button on the left and a centred title, as used by every
/// sheet in the design.
struct SheetHeader: View {
    enum Leading {
        case close, back, none
    }

    /// Text button on the right ("Save").
    struct Trailing {
        let title: String
        var isEnabled: Bool = true
        let action: () -> Void
    }

    let title: String
    let leading: Leading
    let trailing: Trailing?
    let action: () -> Void

    init(_ title: String, leading: Leading = .close, trailing: Trailing? = nil, action: @escaping () -> Void) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
            HStack {
                if leading != .none {
                    Button(action: action) {
                        Image(systemName: leading == .close ? "xmark" : "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(Brand.surface, in: Circle())
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(leading == .close ? "Close" : "Back")
                }
                Spacer()
                if let trailing {
                    Button(action: trailing.action) {
                        Text(trailing.title)
                            .font(.headline)
                            .foregroundStyle(Brand.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!trailing.isEnabled)
                    .opacity(trailing.isEnabled ? 1 : 0.4)
                }
            }
        }
        .frame(height: 38)
    }
}

/// Lavender background + header + content. On the Mac the sheet gets a fixed,
/// phone-like size so the layouts from the design hold.
struct SheetScaffold<Content: View>: View {
    let title: String
    let leading: SheetHeader.Leading
    let trailing: SheetHeader.Trailing?
    let onLeading: () -> Void
    let content: Content

    init(
        title: String,
        leading: SheetHeader.Leading = .close,
        trailing: SheetHeader.Trailing? = nil,
        onLeading: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
        self.onLeading = onLeading
        self.content = content()
    }

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 0) {
                SheetHeader(title, leading: leading, trailing: trailing, action: onLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                content
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 640)
        #endif
    }
}

// MARK: - Cards, banners, badges

extension View {
    /// White rounded card with a soft shadow.
    func brandCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    /// Rounded text-field box used on the Relay, Profile and Groups screens.
    func brandField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Small caption above a group of cards ("Encryption", "What's stored").
struct SectionCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Icon in a tinted rounded square.
struct IconBadge: View {
    let systemName: String
    var tint: Color = Brand.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Inline message: info (indigo), success (green) or error (red).
struct InfoBanner: View {
    enum Kind {
        case info, success, error, warning
    }

    let kind: Kind
    let title: String
    var message: String? = nil

    private var tint: Color {
        switch kind {
        case .info: return Brand.accent
        case .success: return Brand.connected
        case .error: return Brand.error
        case .warning: return Brand.warning
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// "Step 1 of 3" progress segments.
struct StepBar: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Brand.accent : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(total)")
    }
}

/// Dotted-arrow diagram: [You show] ┈> [Your friend scans].
struct HandoffDiagram: View {
    let leftIcon: String
    let leftLabel: String
    let rightIcon: String
    let rightLabel: String

    var body: some View {
        HStack(spacing: 14) {
            node(icon: leftIcon, label: leftLabel)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.accent)
            node(icon: rightIcon, label: rightLabel)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .brandCard(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(leftLabel), then \(rightLabel)")
    }

    private func node(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Brand.accent)
                .frame(width: 38, height: 50)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.accent, lineWidth: 1.5))
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - QR code + clipboard

/// A scannable QR image for `text`, or a hint when it's too long to encode.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            image
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Text("Too long for a QR code — use Copy or Share.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    static func image(for text: String) -> Image? {
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

enum Clipboard {
    static func text() -> String {
        #if canImport(UIKit)
        return UIPasteboard.general.string ?? ""
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return ""
        #endif
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// White box showing a QR code, centred.
struct QRCard: View {
    let code: String
    var size: CGFloat = 200

    var body: some View {
        QRCodeView(text: code)
            .frame(width: size, height: size)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .frame(maxWidth: .infinity)
    }
}

/// Truncated code text with Copy and Share buttons (for sending through any
/// messenger instead of scanning).
struct CodeActions: View {
    let code: String

    private var preview: String {
        guard code.count > 30 else { return code }
        return "\(code.prefix(18))…\(code.suffix(8))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(preview)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 10) {
                Button {
                    Clipboard.copy(code)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .brandCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)

                ShareLink(item: code) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .brandCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
