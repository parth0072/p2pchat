import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ProfileView: View {
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var mesh: MeshManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OnboardingFlag.key) private var onboardingDone = true
    @AppStorage(AppAppearance.key) private var appearanceRaw = AppAppearance.light.rawValue

    @State private var name: String
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var pendingAvatarData: Data?
    @State private var removedAvatar = false
    @State private var showingPrivacy = false

    init(profileStore: ProfileStore, mesh: MeshManager) {
        self.profileStore = profileStore
        self.mesh = mesh
        _name = State(initialValue: profileStore.profile.displayName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(
            title: "Your profile",
            trailing: SheetHeader.Trailing(title: "Save", isEnabled: !trimmedName.isEmpty, action: save),
            onLeading: { dismiss() }
        ) {
            ScrollView {
                VStack(spacing: 18) {
                    avatarView
                        .padding(.top, 8)

                    photoButtons

                    VStack(alignment: .leading, spacing: 6) {
                        SectionCaption("Name")
                        TextField("Your name", text: $name)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .brandField()
                        Text("Your name is shown to nearby people. Your photo stays on this device only — it isn't sent over the mesh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SectionCaption("Appearance")
                        Picker("Appearance", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Button {
                        showingPrivacy = true
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemName: "lock.shield")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Privacy & security")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("What's stored, and your controls")
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

                    TextLinkButton(title: "Show intro again", tint: .secondary) {
                        onboardingDone = false
                        dismiss()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            PrivacyView(mesh: mesh, profileStore: profileStore)
        }
        .onChange(of: photoPickerItem) {
            guard let item = photoPickerItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    pendingAvatarData = data
                    removedAvatar = false
                }
                photoPickerItem = nil
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first, let data = try? Data(contentsOf: url) else { return }
            pendingAvatarData = data
            removedAvatar = false
        }
    }

    private var photoButtons: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                photoButtonLabel("Choose photo", systemImage: "camera")
            }
            .buttonStyle(.plain)
            #else
            Button {
                showingFileImporter = true
            } label: {
                photoButtonLabel("Choose photo", systemImage: "camera")
            }
            .buttonStyle(.plain)
            #endif

            if hasAvatar {
                Button {
                    pendingAvatarData = nil
                    removedAvatar = true
                } label: {
                    photoButtonLabel("Remove photo", systemImage: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func photoButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .brandCard(cornerRadius: 14)
    }

    private var hasAvatar: Bool {
        if removedAvatar { return false }
        return pendingAvatarData != nil || profileStore.profile.avatarFileName != nil
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let data = pendingAvatarData, let image = platformImage(from: data) {
                image.resizable().scaledToFill()
            } else if !removedAvatar, let url = profileStore.avatarURL, let image = platformImage(at: url) {
                image.resizable().scaledToFill()
            } else {
                AvatarView(name: trimmedName.isEmpty ? "?" : trimmedName, size: 96)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
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

    private func save() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }

        if let data = pendingAvatarData {
            profileStore.updateAvatar(data: data)
        } else if removedAvatar {
            profileStore.clearAvatar()
        }

        // Always persist, even if the name is unchanged from the prefilled
        // default — otherwise tapping Save without editing anything never
        // writes to storage, and the app asks for a profile again on every
        // launch (isFirstRun never flips to false).
        let nameChanged = trimmed != profileStore.profile.displayName
        profileStore.updateName(trimmed)
        if nameChanged {
            mesh.updateIdentity(displayName: trimmed)
        }

        dismiss()
    }
}
