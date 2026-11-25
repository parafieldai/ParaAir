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
        VStack(alignment: .leading, spacing: 22) {
            Text("Drive appearance").airDisplay(Air.Size.title).foregroundStyle(Air.ink)
            HStack(alignment: .center, spacing: 22) {
                Image(nsImage: preview).resizable().scaledToFit()
                    .frame(width: 72, height: 72)
                    .frame(width: 104, height: 104)
                    .background(AirSurface(radius: 22))
                    .id(customIcon)
                    .airTransition(.words)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Finder name", text: $driveName).airField()
                    HStack(spacing: Air.Space.sm) {
                        Button("Choose image…") { chooseImage() }
                        Button("Use default icon") { customIcon = nil; iconChanged = true }
                            .disabled(customIcon == nil)
                    }
                    .controlSize(.small)
                }
            }
            .airAnimation(AirMotion.settle, value: customIcon)
            Text("The name updates in Finder’s sidebar. The volume name updates on the next mount. Your chosen icon appears in ParaAir; Finder may keep its system sidebar icon.")
                .font(.callout).foregroundStyle(Air.quiet)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(Air.problem).textSelection(.enabled) }
            HStack(spacing: Air.Space.sm) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.airProminent)
            }
        }
        .padding(28).frame(width: 470)
        .airSurface()
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
