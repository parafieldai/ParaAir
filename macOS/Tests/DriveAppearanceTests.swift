import AppKit
import CFinderSidebar
import StreamDriveCore

@main
struct DriveAppearanceTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("appearance-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DriveProfile(name: "ParaAir", backend: .local, localRoot: "/fixture")
        let appearance = DriveAppearance(stateRoot: root)
        let png = try DriveAppearance.defaultPNG()
        precondition(NSImage(data: png) != nil)
        precondition(png.count < 1_048_576)
        let family = try DriveAppearance.iconFamily(png: png)
        precondition(ParaAirFinderIconDataIsSupported(family as CFData), "macOS must accept the generated icon family")
        try appearance.saveIcon(png, profile: profile)
        let saved = try appearance.customPNG(profile)
        precondition(saved == png)
        try appearance.resetIcon(profile)
        let reset = try appearance.customPNG(profile)
        precondition(reset == nil)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        do {
            _ = try DriveAppearance.importPNG(from: invalid)
            preconditionFailure("Invalid image was accepted")
        } catch let error as DriveError { precondition(error.code == EINVAL) }
        let exported = root.appendingPathComponent("default.png")
        try png.write(to: exported)
        let imported = try DriveAppearance.importPNG(from: exported)
        precondition(NSImage(data: imported)?.size == NSSize(width: 256, height: 256))
        precondition(!ParaAirHasNativeMountEntitlement(), "Unsigned test must not silently enable privileged native mounting")
        print("Drive appearance passed: default icon, macOS IconRef, custom import/persistence/reset and invalid image")
    }
}
