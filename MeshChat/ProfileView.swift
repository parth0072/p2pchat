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

    @State private var name: String
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var pendingAvatarData: Data?
    @State private var removedAvatar = false

    init(profileStore: ProfileStore, mesh: MeshManager) {
        self.profileStore = profileStore
        self.mesh = mesh
        _name = State(initialValue: profileStore.profile.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        avatarView
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Your name", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                }

                Section("Photo") {
                    #if os(iOS)
                    PhotosPicker("Choose Photo", selection: $photoPickerItem, matching: .images)
                    #else
                    Button("Choose Photo…") { showingFileImporter = true }
                    #endif
                    if hasAvatar {
                        Button("Remove Photo", role: .destructive) {
                            pendingAvatarData = nil
                            removedAvatar = true
                        }
                    }
                }

                Section {
                    Text("Your name is shown to nearby peers and attached to every message you send. Your photo stays on this device only — it isn't transferred over the mesh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Your Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let data = pendingAvatarData {
            profileStore.updateAvatar(data: data)
        } else if removedAvatar {
            profileStore.clearAvatar()
        }

        if trimmed != profileStore.profile.displayName {
            profileStore.updateName(trimmed)
            mesh.updateIdentity(displayName: trimmed)
        }

        dismiss()
    }
}
