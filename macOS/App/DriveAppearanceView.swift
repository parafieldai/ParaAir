import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StreamDriveCore

@MainActor
struct DriveAppearanceView: View {
    let profile: DriveProfile
    let stateRoot: URL
    let saved: (DriveProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var driveName: String
    @State private var customIcon: Data?
    @State private var iconChanged = false
    @State private var error: String?

    init(profile: DriveProfile, stateRoot: URL, saved: @escaping (DriveProfile) -> Void) {
        self.profile = profile; self.stateRoot = stateRoot; self.saved = saved
        _driveName = State(initialValue: profile.finderName)
        _customIcon = State(initialValue: try? DriveAppearance(stateRoot: stateRoot).customPNG(profile))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Drive appearance").font(.title2.bold())
            HStack(spacing: 22) {
                Image(nsImage: preview).resizable().scaledToFit().frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Finder name", text: $driveName).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Choose image…") { chooseImage() }
                        Button("Use default icon") { customIcon = nil; iconChanged = true }
                            .disabled(customIcon == nil)
                    }
                }
            }
            Text("The name updates in Finder’s sidebar. The volume name updates on the next mount. Your chosen icon appears in ParaAir; Finder may keep its system sidebar icon.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 460)
    }
    private var preview: NSImage {
        if let customIcon, let image = NSImage(data: customIcon) { return image }
        return NSImage(data: (try? DriveAppearance.defaultPNG()) ?? Data()) ?? NSImage(size: NSSize(width: 256, height: 256))
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a drive icon"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { customIcon = try DriveAppearance.importPNG(from: url); iconChanged = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            let value = driveName.trimmingCharacters(in: .whitespacesAndNewlines)
            try DriveProfile.validateFinderName(value)
            let store = ProfileStore(root: stateRoot)
            var updated = try store.load(profile.name)
            guard updated.targetsSameStorage(as: profile) else {
                throw DriveError(ESTALE, "The drive connection changed. Reopen Drive appearance to continue.")
            }
            let appearance = DriveAppearance(stateRoot: stateRoot)
            if iconChanged {
                if let customIcon { try appearance.saveIcon(customIcon, profile: updated) }
                else { try appearance.resetIcon(updated) }
            }
            updated.displayName = value == updated.name ? nil : value
            try store.save(updated, overwrite: true)
            saved(updated); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
