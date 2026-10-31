import SwiftUI

/// UserDefaults key for "the welcome tour has been completed". Shared with
/// the Profile screen, which can clear it to replay the tour.
enum OnboardingFlag {
    static let key = "app-chat.onboardingDone"
}

/// First-launch flow: three short beats (nearby vs internet, no account,
/// messages disappear), a permissions explainer, then a name. Shown once;
/// replayable from the Profile screen.
///
/// Nothing here starts networking — discovery (and the system permission
/// prompts it triggers) begins when the main screen appears afterwards.
struct OnboardingView: View {
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var mesh: MeshManager
    let onFinish: () -> Void

    @State private var step = 0
    @State private var name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let beatCount = 3
    private let lastStep = 4

    init(profileStore: ProfileStore, mesh: MeshManager, onFinish: @escaping () -> Void) {
        self.profileStore = profileStore
        self.mesh = mesh
        self.onFinish = onFinish
        _name = State(initialValue: profileStore.profile.displayName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 0) {
                topBar
                ZStack {
                    page
                        .id(step)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if step < beatCount {
                    PageDots(count: beatCount, current: step)
                        .padding(.bottom, 18)
                }
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 520, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(width: 520, height: 680)
        #endif
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            if step < beatCount {
                Button("Skip") { go(to: beatCount) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.accent.opacity(primaryEnabled ? 1 : 0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.defaultAction)

            if step == beatCount {
                Button("Not now") { go(to: lastStep) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var primaryTitle: String {
        step == lastStep ? "Start chatting" : "Continue"
    }

    private var primaryEnabled: Bool {
        step == lastStep ? !trimmedName.isEmpty : true
    }

    private func primaryAction() {
        if step == lastStep {
            finish()
        } else {
            go(to: step + 1)
        }
    }

    private func go(to newStep: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            step = min(newStep, lastStep)
        }
    }

    private func finish() {
        let capped = String(trimmedName.prefix(60))
        if !capped.isEmpty {
            let changed = capped != profileStore.profile.displayName
            // Persisting also clears the "first run" flag, so the profile
            // sheet doesn't appear again on top of the main screen.
            profileStore.updateName(capped)
            if changed {
                mesh.updateIdentity(displayName: capped)
            }
        }
        profileStore.markFirstRunShown()
        onFinish()
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0:
            beat(
                title: "Nearby first. Internet when you need it.",
                message: "MeshChat links devices directly over Wi-Fi and Bluetooth, even with no signal. Anywhere else, connect over the internet."
            ) {
                VStack(spacing: 16) {
                    NetworkIllustration().frame(height: 190)
                    RingLegend()
                }
            }
        case 1:
            beat(
                title: "No account. No server.",
                message: "There's nothing to sign up for. Messages go straight from device to device, end-to-end encrypted, with no company in the middle."
            ) {
                NoAccountIllustration()
            }
        case 2:
            beat(
                title: "Messages disappear after 24 hours",
                message: "Chats live only on your device, encrypted. After a day they're deleted automatically. There's no copy anywhere else."
            ) {
                ExpiryIllustration()
            }
        case 3:
            permissionsPage
        default:
            namePage
        }
    }

    private func beat<Art: View>(title: String, message: String, @ViewBuilder art: () -> Art) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            art()
            Spacer(minLength: 24)
            Text(title)
                .font(.system(size: 28, weight: .heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Spacer(minLength: 16)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 8)
            Text("Allow what MeshChat needs")
                .font(.system(size: 28, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("Nearby chat needs Local Network and Bluetooth. You can change these any time in \(settingsName).")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 22)

            VStack(spacing: 0) {
                PermissionRow(icon: "wifi", title: "Local Network", detail: "Find people on the same Wi-Fi", isRequired: true)
                Divider().padding(.leading, 60)
                PermissionRow(icon: "antenna.radiowaves.left.and.right", title: "Bluetooth", detail: "Reach devices with no Wi-Fi at all", isRequired: true)
                Divider().padding(.leading, 60)
                PermissionRow(icon: "bell", title: "Notifications", detail: "Tell you when a message arrives", isRequired: false)
                Divider().padding(.leading, 60)
                PermissionRow(icon: "camera", title: "Camera", detail: "Only to scan invite codes", isRequired: false)
            }
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

            Text("Your system will ask for these as MeshChat starts looking for people nearby.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            Spacer(minLength: 16)
        }
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 8)
            Text("What should people call you?")
                .font(.system(size: 28, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("Your name is shown to people nearby. It isn't stored on any server, because there isn't one.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 22)

            TextField("Your name", text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .onChange(of: name) {
                    if name.count > 60 { name = String(name.prefix(60)) }
                }
                .onSubmit {
                    if !trimmedName.isEmpty { finish() }
                }

            Text("You can change this later in your profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer(minLength: 16)
        }
    }

    private var settingsName: String {
        #if os(macOS)
        return "System Settings"
        #else
        return "Settings"
        #endif
    }
}

// MARK: - Components

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Brand.accent : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let isRequired: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 34, height: 34)
                .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(isRequired ? "Needed" : "Optional")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isRequired ? Brand.accent : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isRequired ? Brand.accent.opacity(0.14) : Color.secondary.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Nearby / Relayed / Internet key under the first illustration.
private struct RingLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            item("Nearby", dash: [])
            item("Relayed", dash: [2.5, 3])
            item("Internet", dash: [1, 3])
        }
        .font(.caption.weight(.medium))
    }

    private func item(_ title: String, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dash))
                .frame(width: 14, height: 14)
            Text(title)
        }
    }
}

// MARK: - Illustrations

/// You in the middle of range halos, one friend nearby with a further friend
/// relayed through them, and an internet-only friend on a dotted link.
private struct NetworkIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let me = CGPoint(x: w * 0.26, y: h * 0.5)
            let near = CGPoint(x: w * 0.58, y: h * 0.26)
            let relayed = CGPoint(x: w * 0.86, y: h * 0.2)
            let hop = CGPoint(x: w * 0.54, y: h * 0.80)
            let web = CGPoint(x: w * 0.9, y: h * 0.66)

            ZStack {
                ForEach([92.0, 150.0, 208.0], id: \.self) { diameter in
                    Circle()
                        .stroke(Brand.accent.opacity(0.14), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                        .position(me)
                }

                link(from: me, to: near, dash: [])
                link(from: near, to: relayed, dash: [1, 5])
                link(from: me, to: hop, dash: [])
                link(from: hop, to: web, dash: [1, 5])

                Circle().fill(Brand.accent.opacity(0.18)).frame(width: 46, height: 46).position(me)
                node(at: me, size: 18)
                node(at: near, size: 14)
                node(at: relayed, size: 14)
                node(at: hop, size: 14)
                Circle()
                    .strokeBorder(Brand.accent, lineWidth: 2)
                    .background(Circle().fill(Brand.surface))
                    .frame(width: 18, height: 18)
                    .position(web)
            }
        }
        .accessibilityHidden(true)
    }

    private func link(from a: CGPoint, to b: CGPoint, dash: [CGFloat]) -> some View {
        Path { path in
            path.move(to: a)
            path.addLine(to: b)
        }
        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
    }

    private func node(at point: CGPoint, size: CGFloat) -> some View {
        Circle().fill(Brand.accent).frame(width: size, height: size).position(point)
    }
}

/// Email, phone number and password crossed out; "just pick a name" ticked.
private struct NoAccountIllustration: View {
    var body: some View {
        VStack(spacing: 10) {
            crossed("Email address", icon: "envelope")
            crossed("Phone number", icon: "phone")
            crossed("Password", icon: "key")
            Label("Just pick a name", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.connected)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No email, phone number or password. Just pick a name.")
    }

    private func crossed(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).strikethrough()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 220)
        .background(Brand.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// A 24h ring and a short chat that fades out.
private struct ExpiryIllustration: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Brand.accent.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Brand.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("24h")
                    .font(.system(size: 26, weight: .bold))
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .trailing, spacing: 8) {
                bubble("Are you near the east gate?", mine: false, opacity: 1)
                bubble("Yes, walking over now.", mine: true, opacity: 1)
                bubble("See you in a minute", mine: false, opacity: 0.35)
            }
            .frame(width: 250)
        }
        .accessibilityHidden(true)
    }

    private func bubble(_ text: String, mine: Bool, opacity: Double) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(mine ? Brand.accent : Brand.surface, in: Capsule())
            .opacity(opacity)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}
