import SwiftUI

/// "Privacy & security": what protects your chats, what's stored on this
/// device, and the switches that decide how MeshChat connects. Opened from the
/// Profile screen.
struct PrivacyView: View {
    @ObservedObject var mesh: MeshManager
    @ObservedObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OnboardingFlag.key) private var onboardingDone = true

    @State private var showingRelay = false
    @State private var confirmForget = false

    private var relaySummary: String {
        let url = mesh.relaySettings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return "Not set" }
        return url.count > 18 ? String(url.prefix(18)) + "…" : url
    }

    var body: some View {
        SheetScaffold(
            title: showingRelay ? "Relay server" : "Privacy & security",
            leading: showingRelay ? .back : .close,
            onLeading: {
                if showingRelay {
                    showingRelay = false
                } else {
                    dismiss()
                }
            }
        ) {
            if showingRelay {
                RelayServerView(mesh: mesh) { showingRelay = false }
            } else {
                mainContent
            }
        }
        .alert("Forget everything?", isPresented: $confirmForget) {
            Button("Forget Everything", role: .destructive, action: forgetEverything)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all chats, trusted devices and your profile from this device. It can't be undone.")
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionCaption("Encryption")
                card {
                    PrivacyRow(
                        icon: "lock",
                        title: "End-to-end encrypted",
                        detail: "Every message, on every route"
                    )
                    divider
                    PrivacyRow(
                        icon: "shield",
                        title: "No account, no server",
                        detail: "Nothing in the middle can read, store or shut it down"
                    )
                }

                SectionCaption("What's stored")
                    .padding(.top, 8)
                card {
                    PrivacyRow(
                        icon: "clock",
                        title: "Chat history",
                        detail: "Only on this device, encrypted. Deleted after 24 hours"
                    )
                    divider
                    PrivacyRow(
                        icon: "person",
                        title: "Your name",
                        detail: "Shown to people you connect with"
                    )
                    divider
                    PrivacyRow(
                        icon: "photo",
                        title: "Your photo",
                        detail: "Stays on this device. Never sent"
                    )
                }

                SectionCaption("Your controls")
                    .padding(.top, 8)
                card {
                    PrivacyRow(
                        icon: "globe",
                        title: "Internet chat",
                        detail: "Allow connections over the internet"
                    ) {
                        Toggle("Internet chat", isOn: $mesh.internetChatEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider
                    PrivacyRow(
                        icon: "ellipsis",
                        title: "Relay for others",
                        detail: "Pass messages between nearby people"
                    ) {
                        Toggle("Relay for others", isOn: $mesh.relayForOthers)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    divider
                    Button {
                        showingRelay = true
                    } label: {
                        PrivacyRow(
                            icon: "server.rack",
                            title: "Relay server",
                            detail: "For when a direct route can't be found"
                        ) {
                            HStack(spacing: 4) {
                                Text(relaySummary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    divider
                    PrivacyRow(
                        icon: "cpu",
                        title: "Memory-only mode",
                        detail: "Keep nothing on this device, even for 24 hours"
                    ) {
                        comingSoon
                    }
                    divider
                    PrivacyRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Nostr relays",
                        detail: "Reach people without sharing a network"
                    ) {
                        comingSoon
                    }
                }

                SectionCaption("Danger zone")
                    .padding(.top, 8)
                Button {
                    confirmForget = true
                } label: {
                    Label("Forget everything", systemImage: "trash")
                }
                .buttonStyle(BrandButtonStyle(kind: .destructive))

                Text("Deletes all chats, trusted devices and your profile from this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var comingSoon: some View {
        Text("Coming soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14), in: Capsule())
    }

    private var divider: some View {
        Divider().padding(.leading, 58)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .brandCard()
    }

    private func forgetEverything() {
        mesh.forgetEverything()
        profileStore.reset()
        mesh.updateIdentity(displayName: profileStore.profile.displayName)
        // Back to the welcome flow, as on a fresh install.
        onboardingDone = false
    }
}

/// One line in a Privacy card: icon, title, one-line detail, optional control
/// on the right.
private struct PrivacyRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let trailing: Trailing

    init(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

extension PrivacyRow where Trailing == EmptyView {
    fileprivate init(icon: String, title: String, detail: String) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}
