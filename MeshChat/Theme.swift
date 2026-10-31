import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Brand palette

/// Colours and surfaces from the "Signal" design direction. Status colours are
/// semantic (connected / connecting / offline / warning / encrypted) so the same
/// meaning looks the same everywhere in the app.
enum Brand {
    /// Primary indigo, used for actions, your own bubbles and "direct" rings.
    static let accent = Color(red: 0.357, green: 0.294, blue: 0.839)
    static let connected = Color(red: 0.18, green: 0.62, blue: 0.36)
    static let connecting = Color(red: 0.85, green: 0.58, blue: 0.12)
    static let offline = Color(red: 0.55, green: 0.56, blue: 0.64)
    static let warning = Color(red: 0.78, green: 0.36, blue: 0.18)
    static let encrypted = Color(red: 0.14, green: 0.50, blue: 0.43)
    static let error = Color(red: 0.76, green: 0.22, blue: 0.26)

    /// Surface for cards, "their" bubbles and the composer — white in light
    /// mode, a raised indigo-tinted dark in dark mode.
    static let surface = adaptive(light: (1, 1, 1), dark: (0.14, 0.13, 0.22))

    /// Base colour behind every screen — near-white lavender, or a deep
    /// indigo-black.
    static let background = adaptive(light: (0.955, 0.955, 0.985), dark: (0.055, 0.05, 0.105))

    /// Mac sidebar panel — a touch deeper than the page behind the chat.
    static let sidebar = adaptive(light: (0.925, 0.925, 0.965), dark: (0.085, 0.078, 0.16))

    /// A colour that switches between a light and a dark RGB value with the
    /// appearance of whatever view it's drawn in.
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    static func color(for state: PeerConnectionState) -> Color {
        switch state {
        case .connected: return connected
        case .connecting: return connecting
        case .notConnected: return offline
        }
    }
}

// MARK: - Background

/// Soft lavender wash that fades out from the top-right corner (light mode) or
/// a deep indigo-black (dark mode).
struct BrandBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Brand.background
            RadialGradient(
                colors: [Brand.accent.opacity(scheme == .dark ? 0.30 : 0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 760
            )
            RadialGradient(
                colors: [Brand.accent.opacity(scheme == .dark ? 0.14 : 0.06), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Appearance

/// Light, dark, or follow the system. The app opens in light, matching the
/// primary Signal design; this is changed from the Profile screen.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    static let key = "app-chat.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    static func from(_ raw: String) -> AppAppearance {
        AppAppearance(rawValue: raw) ?? .light
    }
}

// MARK: - Avatar

/// How a person is reached, drawn as a ring around their avatar: a solid ring
/// for a direct nearby link, dashed for relayed or internet (with a hop-count
/// or globe badge), and a partial spinner-style ring while connecting.
enum AvatarRing: Equatable {
    case none
    case direct
    case relayed(hops: Int?)
    case internet
    case connecting
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 38
    var ring: AvatarRing = .none
    var status: PeerConnectionState? = nil

    private static let palettes: [[Color]] = [
        [Color(red: 0.80, green: 0.32, blue: 0.24), Color(red: 0.62, green: 0.20, blue: 0.18)],
        [Color(red: 0.29, green: 0.42, blue: 0.82), Color(red: 0.20, green: 0.26, blue: 0.62)],
        [Color(red: 0.52, green: 0.34, blue: 0.82), Color(red: 0.38, green: 0.22, blue: 0.64)],
        [Color(red: 0.16, green: 0.55, blue: 0.50), Color(red: 0.10, green: 0.38, blue: 0.38)],
        [Color(red: 0.62, green: 0.28, blue: 0.46), Color(red: 0.46, green: 0.18, blue: 0.34)],
        [Color(red: 0.34, green: 0.36, blue: 0.44), Color(red: 0.22, green: 0.24, blue: 0.32)]
    ]

    private var palette: [Color] {
        // Stable across launches (String.hashValue isn't), so a person keeps
        // the same colour every time.
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palettes[sum % Self.palettes.count]
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var ringInset: CGFloat {
        ring == .none ? 0 : size * 0.1
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(ringInset)
            Text(initials)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white)
            ringView
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) { statusDot }
        .overlay(alignment: .topTrailing) { badge }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var ringView: some View {
        switch ring {
        case .none:
            EmptyView()
        case .direct:
            Circle().strokeBorder(Brand.accent, lineWidth: 2)
        case .relayed, .internet:
            Circle().strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [2.5, 3]))
        case .connecting:
            ZStack {
                Circle().strokeBorder(Brand.connecting.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Brand.connecting, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if let status {
            Circle()
                .fill(Brand.color(for: status))
                .frame(width: size * 0.26, height: size * 0.26)
                .overlay(Circle().strokeBorder(Brand.surface, lineWidth: 1.5))
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch ring {
        case .relayed(let hops):
            if let hops, hops > 1 {
                badgeCircle { Text("\(hops)") }
            }
        case .internet:
            badgeCircle { Image(systemName: "globe") }
        default:
            EmptyView()
        }
    }

    private func badgeCircle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: size * 0.22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size * 0.38, height: size * 0.38)
            .background(Circle().fill(Color.black))
    }

    private var accessibilityText: String {
        switch ring {
        case .none: return name
        case .direct: return "\(name), nearby"
        case .relayed(let hops):
            if let hops { return "\(name), relayed, \(hops) hops" }
            return "\(name), relayed"
        case .internet: return "\(name), over the internet"
        case .connecting: return "\(name), connecting"
        }
    }
}

// MARK: - Route tag

/// Small "how is this person reached" label shown on the right of a peer row.
struct RouteTag: View {
    enum Kind {
        case nearby, relayed, internet
    }

    let kind: Kind

    private var title: String {
        switch kind {
        case .nearby: return "Nearby"
        case .relayed: return "Relayed"
        case .internet: return "Internet"
        }
    }

    private var icon: String {
        switch kind {
        case .nearby: return "dot.radiowaves.left.and.right"
        case .relayed: return "ellipsis"
        case .internet: return "globe"
        }
    }

    var body: some View {
        Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Chips and cards

/// "Messages disappear after 24 hours" — shown at the top of a conversation so
/// the expiry is never a surprise.
struct ExpiryChip: View {
    var body: some View {
        Label("Messages disappear after 24 hours", systemImage: "clock")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Brand.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Shared styling helpers

extension View {
    /// The lavender brand background behind a whole screen. The view is
    /// stretched to fill its container first, so short content (an empty
    /// state) gets the full-pane background instead of a small patch.
    func brandBackground() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandBackground())
    }

    /// Tints controls with the brand indigo.
    func brandTint() -> some View {
        self.tint(Brand.accent)
    }

    /// Wraps content in a raised rounded card (transfer bar, banners).
    func cardStyle() -> some View {
        self
            .padding(10)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    /// Signal-style chat bubble: indigo for mine, white for theirs.
    func chatBubbleStyle(isMine: Bool) -> some View {
        modifier(ChatBubbleStyle(isMine: isMine))
    }
}

private struct ChatBubbleStyle: ViewModifier {
    let isMine: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMine ? Brand.accent : Brand.surface)
            .foregroundStyle(isMine ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(isMine ? 0 : 0.06), radius: 3, y: 1)
    }
}
