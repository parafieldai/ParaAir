import Foundation

/// Bundle identifiers. Signed builds (releases and update tests) are dev.streamdrive.app with
/// .filesystem and .cli beneath it. Unsigned development builds are dev.streamdrive.app.dev, so a
/// development copy on a Mac that also runs ParaAir can never be taken for the installed app by
/// LaunchServices or FSKit. Apple DTS recommends exactly this split: stale registrations of
/// same-ID copies are what left FSKit unable to enable the installed module on 2026-10-15.
public enum ParaAirBundle {
    public static let releaseApp = "dev.streamdrive.app"
    public static let developmentApp = "dev.streamdrive.app.dev"

    /// The file system extension that belongs to an app identifier (the running app's by default).
    public static func filesystemIdentifier(forApp app: String? = Bundle.main.bundleIdentifier) -> String {
        (app.flatMap { [releaseApp, developmentApp].contains($0) ? $0 : nil } ?? releaseApp) + ".filesystem"
    }

    /// Mounted-volume type names: release builds register "streamdrive", development builds "streamdrive-dev".
    public static let volumeTypes: Set<String> = ["streamdrive", "streamdrive-dev", "paraair"]

    public static var isFilesystemExtension: Bool {
        [releaseApp + ".filesystem", developmentApp + ".filesystem"].contains(Bundle.main.bundleIdentifier ?? "")
    }

    public static var isApp: Bool { [releaseApp, developmentApp].contains(Bundle.main.bundleIdentifier ?? "") }
}
