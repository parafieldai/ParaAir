import Foundation
import AppKit
import Darwin
import StreamDriveCore
#if canImport(FSKit)
import FSKit
#endif

/// Exit codes, and the JSON `code` beside them, that another app can act on (contract/paraair-cli-v1). 1 is any other
/// failure, 2 a usage error, 3 uploads left after `uploads --retry`.
struct CLIOutcome: Equatable {
    var code: String
    var exitCode: Int32

    static let failed = CLIOutcome(code: "failed", exitCode: 1)
    static let usage = CLIOutcome(code: "usage", exitCode: 2)
    static let appNotInstalled = CLIOutcome(code: "app_not_installed", exitCode: 10)
    static let notSignedIn = CLIOutcome(code: "not_signed_in", exitCode: 11)
    static let forbidden = CLIOutcome(code: "forbidden", exitCode: 12)
    static let extensionDisabled = CLIOutcome(code: "extension_disabled", exitCode: 13)
    static let driveNotFound = CLIOutcome(code: "drive_not_found", exitCode: 14)
    /// A mounted path that isn't inside a mounted ParaAir drive, or whose drive has no profile in a known state folder.
    static let notMounted = CLIOutcome(code: "not_mounted", exitCode: 15)
    /// The file changed since the version the caller expected (restore-version --expected-version).
    static let versionConflict = CLIOutcome(code: "version_conflict", exitCode: 16)
    /// No such file, version or conflict copy.
    static let notFound = CLIOutcome(code: "not_found", exitCode: 17)

    static func of(_ error: Error) -> CLIOutcome {
        if error is CLIUsageError { return .usage }
        if let error = error as? CLIOutcomeError { return error.outcome }
        switch ParaAirCloudOutcome.of(error) {
        case .notSignedIn?: return .notSignedIn
        case .forbidden?: return .forbidden
        case .driveNotFound?: return .driveNotFound
        case nil: return .failed
        }
    }
}

struct CLIOutcomeError: Error, LocalizedError {
    var outcome: CLIOutcome
    var message: String
    var errorDescription: String? { message }
}

/// What the setup commands ask of macOS. Tests replace it, so they never open the app or read its settings.
struct CLISystem {
    /// `version` is CFBundleShortVersionString ("0.1.0" for every 0.1.0 alpha); `build` is CFBundleVersion, the number
    /// that grows with each release (alpha.3 is 21), which is what to compare.
    struct AppInfo: Equatable { var bundleID: String?; var version: String?; var build: String? = nil }

    /// The app's bundle id and version from its Info.plist; nil when no app is there.
    var appInfo: (_ appPath: String) -> AppInfo?
    var isRunning: (_ bundleID: String) -> Bool
    /// "enabled", "disabled", "notDiscovered" or "unknown" for the app's File System Extension.
    var extensionState: (_ appPath: String, _ bundleID: String?) -> String
    /// State folders the app remembers (its `selectedStateRoot` and `knownStateRoots` settings).
    var appStateFolders: (_ bundleID: String) -> [String]
    /// Other copies of the app LaunchServices has registered that still exist (OtherAppCopies.present).
    var otherAppCopies: (_ appPath: String, _ bundleID: String?) -> [String] = { _, _ in [] }
    /// Opens System Settings at the File System Extensions list (ExtensionSetupGuidance.location).
    var openExtensionSettings: () throws -> Void = {}
    var openURL: (_ appPath: String, _ url: URL) throws -> Void
    var mountedVolumes: () -> [MountedVolume]
    var sleep: (_ seconds: TimeInterval) -> Void
    /// The current time, for waits measured in elapsed seconds. Tests advance it with `sleep`.
    var now: () -> Date = { Date() }
    /// Creates and removes the refresh marker in a drive folder through the ParaAir volume mounted at the mount point
    /// (Housekeeping.touchRefreshMarker), so the drive's extension drops the kernel's caches for what changed there.
    /// False when nothing was written. Does nothing unless set, so tests never write into a real mount.
    var refreshFolder: (_ folder: String, _ mountPoint: String) -> Bool = { _, _ in false }
    /// The macOS major version. On 27 and later the app mounts with FSKit's own call at exactly /Volumes/<Finder name>;
    /// on 26 its /Volumes helper takes "<name> 2" … when another volume has the name.
    var macOSMajorVersion: () -> Int = { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    /// The parent process, so `changes --follow` can stop when whoever started it is gone (it was reparented).
    var parentProcess: () -> pid_t = { 1 }
    /// Whether standard output has no reader any more (a pipe whose read end was closed), so a follower stops without
    /// waiting for its next line to fail.
    var outputClosed: () -> Bool = { false }
    /// Makes a write to a pipe nobody reads fail with EPIPE instead of killing the process (SIGPIPE), so a follower
    /// whose reader closed exits 0.
    var ignoreBrokenPipe: () -> Void = {}

    /// Opens ParaAir's own sign-in (Storage Settings → ParaAir Cloud). The code is typed in the browser, never here.
    static let signInURL = URL(string: "paraair://cloud/sign-in")!
    /// Asks the app to mount a saved drive of one of its state folders, as its Connect button does.
    static func mountURL(profile: String, stateDirectory: String) -> URL {
        var components = URLComponents()
        components.scheme = "paraair"; components.host = "drive"; components.path = "/mount"
        components.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "folder", value: stateDirectory)]
        return components.url!
    }

    static let live = CLISystem(
        appInfo: { path in
            let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
            return AppInfo(bundleID: info["CFBundleIdentifier"] as? String, version: info["CFBundleShortVersionString"] as? String,
                           build: info["CFBundleVersion"] as? String)
        },
        isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
        extensionState: { liveExtensionState(appPath: $0, bundleID: $1) },
        appStateFolders: { bundleID in
            guard let defaults = UserDefaults(suiteName: bundleID) else { return [] }
            return [defaults.string(forKey: "selectedStateRoot")].compactMap { $0 } + (defaults.stringArray(forKey: "knownStateRoots") ?? [])
        },
        otherAppCopies: { appPath, bundleID in
            guard let bundleID else { return [] }
            let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
            return OtherAppCopies.sort(registered: registered, current: appPath, exists: { FileManager.default.fileExists(atPath: $0) }).present
        },
        openExtensionSettings: {
            // macOS 27: FSKit's own call. Then (and on macOS 26) the File System Extensions list's own link, which opens
            // it with ParaAir's switch in one click; Login Items & Extensions only if that link doesn't open.
            #if canImport(FSKit)
            if #available(macOS 27.0, *) {
                if FSClient.shared.openFileSystemExtensionsSettings() { return }
            }
            #endif
            var exitCode: Int32 = -1
            for link in ExtensionSetupGuidance.settingsLinks {
                exitCode = try SystemCommands.run(executable: "/usr/bin/open", arguments: [link]).exitCode
                if exitCode == 0 { return }
            }
            throw DriveError(EIO, "macOS couldn’t open System Settings (exit \(exitCode)). Open \(ExtensionSetupGuidance.location) yourself")
        },
        openURL: { appPath, url in
            let output = try SystemCommands.run(executable: "/usr/bin/open", arguments: ["-a", appPath, url.absoluteString])
            guard output.exitCode == 0 else { throw DriveError(EIO, "macOS couldn’t open ParaAir (exit \(output.exitCode))") }
        },
        mountedVolumes: { MountController.mountedVolumes() },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        refreshFolder: { folder, point in Housekeeping.isParaAirMount(point) && Housekeeping.touchRefreshMarker(in: folder, mountPoint: point) },
        parentProcess: { getppid() },
        outputClosed: { standardOutputReaderGone() },
        ignoreBrokenPipe: { _ = signal(SIGPIPE, SIG_IGN) })
}

private final class ModulesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FinderExtensionModule]?
    var value: [FinderExtensionModule]? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ modules: [FinderExtensionModule]?) { lock.lock(); stored = modules; lock.unlock() }
}

/// The app's FSKit module as FSKit lists it, with the app's own rule (FinderExtensionState.resolve): only this app's
/// copy counts. "unknown" when FSKit doesn't answer within 5 seconds.
private func liveExtensionState(appPath: String, bundleID: String?) -> String {
    guard let bundleID else { return "unknown" }
    #if canImport(FSKit)
    if #available(macOS 26.0, *) {
        let expected = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Extensions/StreamDriveFS.appex").resolvingSymlinksInPath().path
        let box = ModulesBox(), done = DispatchSemaphore(value: 0)
        Task.detached {
            let modules = try? await FSClient.shared.installedExtensions.map {
                FinderExtensionModule(bundleIdentifier: $0.bundleIdentifier, path: $0.url.resolvingSymlinksInPath().path, isEnabled: $0.isEnabled)
            }
            box.set(modules); done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, let modules = box.value else { return "unknown" }
        switch FinderExtensionState.resolve(modules, bundleIdentifier: ParaAirBundle.filesystemIdentifier(forApp: bundleID), expectedPath: expected) {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .notDiscovered: return "notDiscovered"
        default: return "unknown"
        }
    }
    #endif
    return "unknown"
}

/// Whether standard output is a pipe or socket whose reader has gone: kqueue reports EV_EOF on the write filter once
/// the read end is closed. A terminal or a file never reports it.
private func standardOutputReaderGone() -> Bool {
    let queue = kqueue()
    guard queue >= 0 else { return false }
    defer { close(queue) }
    var change = kevent(ident: UInt(STDOUT_FILENO), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: 0, data: 0, udata: nil)
    var event = kevent()
    var timeout = timespec(tv_sec: 0, tv_nsec: 0)
    guard kevent(queue, &change, 1, &event, 1, &timeout) == 1 else { return false }
    return event.flags & UInt16(EV_EOF) != 0
}
