import AppKit
import SwiftUI
import Combine
import Sparkle
import StreamDriveCore

/// Sparkle updates (feed and EdDSA key in Info.plist). The file system extension serving every
/// mounted drive runs from the app bundle an update replaces, so drives are ejected first
/// (UpdateGate). That covers both ways an update installs:
/// - Install and Relaunch: Sparkle asks to postpone the relaunch; ParaAir ejects, then lets it go.
/// - Install on quit: Sparkle installs when ParaAir terminates, so MenuModel.quit ejects first.
/// Development builds (no ParaAirReleaseTag) never start the updater.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    /// A scheduled check found an update while ParaAir wasn't in front: "ParaAir 0.1.0 alpha 3".
    /// Shown as a row in the menu bar panel and home window (gentle reminders) instead of an
    /// alert that would open behind other apps, since ParaAir has no Dock icon.
    @Published private(set) var pendingUpdateTitle: String?
    /// A downloaded update installs when ParaAir quits.
    private(set) var hasPendingInstall = false
    private var controller: SPUStandardUpdaterController?
    private let ejectDrives: (@escaping (UpdateGate.Outcome) -> Void) -> Void

    static var isReleaseBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "ParaAirReleaseTag") is String }

    init(ejectDrives: @escaping (@escaping (UpdateGate.Outcome) -> Void) -> Void) {
        self.ejectDrives = ejectDrives
        super.init()
        guard Self.isReleaseBuild else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the alert itself only when it would be in front anyway (just after launch, or
    /// after the Mac was idle); otherwise ParaAir shows the reminder row.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let title = update.title ?? "ParaAir \(update.displayVersionString)"
        MainActor.assumeIsolated { if !handleShowingUpdate { pendingUpdateTitle = title } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateTitle = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingUpdateTitle = nil }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingInstall = true }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { hasPendingInstall = true }
        return false
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            hasPendingInstall = true
            ejectThenInstall(installHandler)
        }
        return true
    }

    /// Ejects every drive, then installs. A busy drive keeps the update waiting: Try Again ejects
    /// again; Later leaves it to install when ParaAir quits (which ejects first too).
    private func ejectThenInstall(_ install: @escaping () -> Void) {
        ejectDrives { [weak self] outcome in
            switch outcome {
            case .install:
                install()
            case .blocked(let drives):
                let alert = NSAlert()
                alert.messageText = UpdateGate.blockedTitle(drives)
                alert.informativeText = UpdateGate.blockedMessage(drives)
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { self?.ejectThenInstall(install) }
            }
        }
    }
}

/// The app menu's "Check for Updates…", enabled while Sparkle can start a check.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Routes NSApplication's termination question to MenuModel.shouldTerminate.
final class AppTermination: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: MenuModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.model?.shouldTerminate() ?? .terminateNow }
    }
}

/// Every ParaAir drive mounted on this Mac, from any state folder. The file system extension
/// serving them runs from the installed app, so they are ejected before that app is replaced,
/// by an in-app update (UpdateGate) or by a newer copy opened from the disk image.
enum ParaAirVolumes {
    static func mountedPaths() -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard let mounts else { return [] }
        var paths: [String] = []
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            guard ParaAirBundle.volumeTypes.contains(type) else { continue }
            paths.append(withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            })
        }
        return paths.sorted()
    }

    /// Ejects each drive without forcing open files closed; reports each drive's name and result.
    nonisolated static func eject(_ paths: [String]) -> [(name: String, ejected: Bool)] {
        paths.map { path in
            let name = FileManager.default.displayName(atPath: path)
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path, isDirectory: true))
                return (name, true)
            } catch {
                AppLog.mount.error("eject before replacing the app failed: \(error.localizedDescription, privacy: .public)")
                return (name, false)
            }
        }
    }
}
