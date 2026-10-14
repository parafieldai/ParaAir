import AppKit
import os
import StreamDriveCore

extension AppLog {
    static let install = Logger(subsystem: "dev.streamdrive.app", category: "install")
}

/// Moves a copy opened from the disk image or from a quarantined download into
/// Applications, then opens that copy and quits. Runs once, first thing at launch,
/// before any renewal, extension check or window. An older copy that is open at the
/// destination is replaced only after the person agrees, and is asked to quit, never forced.
/// Every other location stays put: developer builds run from .build and never move themselves.
@MainActor
enum AppInstaller {
    private static var prepared: InstallLocation?

    /// The running copy's location, after any move. Returns only when this copy keeps running.
    static func prepareAtLaunch() -> InstallLocation {
        if let prepared { return prepared }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        let location = InstallLocation.classify(bundlePath: bundle.path, homeDirectory: home, volumeIsReadOnly: readOnly ?? false)
        prepared = location
        let readOnlyText = readOnly.map { "\($0)" } ?? "unknown"
        AppLog.install.notice("launch location=\(location.rawValue, privacy: .public) bundle=\(bundle.path, privacy: .private(mask: .hash)) volumeReadOnly=\(readOnlyText, privacy: .public)")
        guard location.shouldMove else { return location }

        let destination = URL(fileURLWithPath: InstallDestination.path(
            systemApplicationsWritable: FileManager.default.isWritableFile(atPath: "/Applications"), homeDirectory: home))
        let installed = installedCopy(at: destination)
        let running = BundleVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
        let action = InstallAction.plan(location: location, installed: installed, running: running)
        let installedText = installed.map {
            "\($0.version.build ?? "none")/\($0.version.marketing ?? "none") running=\($0.running) sameIdentifier=\($0.sameIdentifier)"
        } ?? "none"
        let runningText = "\(running.build ?? "none")/\(running.marketing ?? "none")"
        AppLog.install.notice("move decision=\(String(describing: action), privacy: .public) destination=\(destination.path, privacy: .private(mask: .hash)) installed=\(installedText, privacy: .public) self=\(runningText, privacy: .public)")

        var fallback = ManualMove.couldNotMove
        switch action {
        case .stay:
            return location
        case .openInstalled:
            if open(destination, newInstance: !(installed?.running ?? false)) { quit() }
        case .install(let replacing):
            fallback = installAndRelaunch(bundle, at: destination, replacing: replacing)
        case .askToReplaceRunning:
            let old = installed?.version ?? BundleVersion(build: nil, marketing: nil)
            // Asked here, before anything else starts, so the old copy is never kept without asking.
            guard confirmReplacingRunning(InstallPrompt.replaceRunning(installed: old, running: running)) else {
                AppLog.install.notice("update declined; this copy keeps running from location=\(location.rawValue, privacy: .public)")
                return location
            }
            if quitRunningCopies(at: destination) {
                fallback = installAndRelaunch(bundle, at: destination, replacing: true)
            } else {
                fallback = .stillOpen(old.label(distinctFrom: running))
            }
        case .askToMoveManually:
            break
        }
        // Still running from the download or disk image: explain the manual move once the app is up.
        let reason = fallback
        Task { @MainActor in askToMoveManually(reason, location: location, bundle: bundle, destination: destination) }
        return location
    }

    /// Copies, opens the copy and quits. Returns only when something failed, with the reason.
    /// Replacing a copy ejects ParaAir's drives first: their file system extension runs from it.
    private static func installAndRelaunch(_ bundle: URL, at destination: URL, replacing: Bool) -> ManualMove {
        if replacing {
            let busy = ParaAirVolumes.eject(ParaAirVolumes.mountedPaths()).filter { !$0.ejected }.map(\.name)
            AppLog.install.notice("ejected drives before replacing busy=\(busy.count)")
            if !busy.isEmpty { return .drivesInUse(busy) }
        }
        do {
            try install(bundle, at: destination, replacing: replacing)
            if open(destination, newInstance: true) { quit() }
        } catch {
            let failure = error as NSError
            AppLog.install.error("move failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        }
        return .couldNotMove
    }

    private static func runningCopies(at destination: URL) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL.path == destination.path
        }
    }

    private static func installedCopy(at destination: URL) -> InstalledCopy? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        let info = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let identifier = Bundle.main.bundleIdentifier
        return InstalledCopy(version: BundleVersion(infoDictionary: info),
                             sameIdentifier: identifier != nil && info["CFBundleIdentifier"] as? String == identifier,
                             running: !runningCopies(at: destination).isEmpty)
    }

    /// "ParaAir 0.1.0 is open. Quit it and install 0.2.0?" with Install as the default.
    private static func confirmReplacingRunning(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate()
        let install = alert.runModal() == .alertFirstButtonReturn
        AppLog.install.notice("replace running copy answer=\(install ? "install" : "not-now", privacy: .public)")
        return install
    }

    /// Asks the open copy to quit, the way Quit does, and waits up to 10 seconds. It is
    /// never forced: a copy that stays open keeps its drive and its unsaved state.
    private static func quitRunningCopies(at destination: URL) -> Bool {
        let copies = runningCopies(at: destination)
        let pids = copies.map(\.processIdentifier)
        for copy in copies {
            let asked = copy.terminate()
            AppLog.install.notice("asked running copy to quit sent=\(asked)")
        }
        // NSRunningApplication updates on the main run loop, which hasn't started yet; ask the kernel.
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if pids.allSatisfy({ kill($0, 0) != 0 && errno == ESRCH }) {
                AppLog.install.notice("running copy quit")
                return true
            }
            usleep(100_000)
        } while Date() < deadline
        AppLog.install.error("running copy still open after 10 seconds; not forcing it")
        return false
    }

    /// Copies next to the destination first, so a failed copy never costs the installed one.
    private static func install(_ bundle: URL, at destination: URL, replacing: Bool) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? files.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(InstallDestination.bundleName)
        // FileManager keeps the bundle's files, signature and extended attributes.
        try files.copyItem(at: bundle, to: copy)
        let cleared = clearQuarantine(copy)
        AppLog.install.notice("copied quarantineCleared=\(cleared)")
        if replacing {
            try files.trashItem(at: destination, resultingItemURL: nil)
            AppLog.install.notice("older copy moved to Trash")
        }
        try files.moveItem(at: copy, to: destination)
        AppLog.install.notice("installed at destination=\(destination.path, privacy: .private(mask: .hash))")
    }

    /// The person approved this download when they first opened it; the copy keeps
    /// that approval rather than asking again.
    private static func clearQuarantine(_ root: URL) -> Int {
        var paths = [root.path]
        if let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let item as URL in items { paths.append(item.path) }
        }
        var cleared = 0
        for path in paths where removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 { cleared += 1 }
        return cleared
    }

    /// Opens the installed copy and waits for macOS to confirm it started.
    private static func open(_ app: URL, newInstance: Bool) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        configuration.activates = true
        let done = DispatchSemaphore(value: 0)
        let result = OpenResult()
        // AppKit calls the handler on a concurrent queue, so waiting here can't block it.
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            result.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            AppLog.install.error("open installed copy timed out")
            return false
        }
        if let error = result.error as NSError? {
            AppLog.install.error("open installed copy failed domain=\(error.domain, privacy: .public) code=\(error.code)")
            return false
        }
        AppLog.install.notice("opened installed copy newInstance=\(newInstance); quitting this copy")
        return true
    }

    private final class OpenResult: @unchecked Sendable { var error: Error? }

    /// Nothing has started yet (no renewal, mount or window), so leaving now is clean.
    private static func quit() -> Never { exit(0) }

    /// Why this copy is still running from the download or disk image.
    private enum ManualMove {
        case couldNotMove
        /// The older copy didn't quit when asked; carries its version when known.
        case stillOpen(String?)
        /// A ParaAir drive has open files, so it couldn't be ejected before replacing.
        case drivesInUse([String])

        var title: String {
            switch self {
            case .couldNotMove: return "Move ParaAir to Applications"
            case .stillOpen: return "Quit ParaAir to finish installing"
            case .drivesInUse(let drives): return UpdateGate.blockedTitle(drives)
            }
        }
        var detail: String {
            switch self {
            case .couldNotMove:
                return "ParaAir couldn’t move itself. Drag ParaAir into your Applications folder, then open it from there. Until then it runs from where it is now."
            case .stillOpen(let version):
                return "ParaAir\(version.map { " " + $0 } ?? "") didn’t quit. Click the ParaAir menu bar icon, choose Quit ParaAir, then open this copy again. Until then this copy runs from where it is now."
            case .drivesInUse(let drives):
                return "ParaAir ejects its drives before replacing the copy in Applications, and \(drives.count == 1 ? "“\(drives[0])”" : "\(drives.count) drives") has files open. "
                    + "Close them, then open this copy again. Nothing has changed, and files waiting to upload stay on this Mac."
            }
        }
    }

    private static func askToMoveManually(_ reason: ManualMove, location: InstallLocation, bundle: URL, destination: URL) {
        let alert = NSAlert()
        alert.messageText = reason.title
        alert.informativeText = reason.detail
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let original = originalCopy(location: location, bundle: bundle) {
            NSWorkspace.shared.activateFileViewerSelecting([original])
        } else {
            NSWorkspace.shared.open(destination.deletingLastPathComponent())
        }
    }

    /// The copy the person opened. macOS hides a translocated copy's real path, so look
    /// where it usually is: a mounted disk image, then Downloads.
    private static func originalCopy(location: InstallLocation, bundle: URL) -> URL? {
        guard location == .translocated else { return bundle }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsReadOnlyKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        let candidates = volumes.filter { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true }
            .map { $0.appendingPathComponent(InstallDestination.bundleName) }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/" + InstallDestination.bundleName)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
