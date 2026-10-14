import AppKit
import SwiftUI
import Combine
import Sparkle

/// Sparkle updates (feed and EdDSA key in Info.plist). The file system extension serving every
/// mounted drive runs from the app bundle an update replaces, so drives are ejected first
/// (UpdateGate). That covers both ways an update installs:
/// - Install and Relaunch: Sparkle asks to postpone the relaunch; ParaAir ejects, then lets it go.
/// - Install on quit: Sparkle installs when ParaAir terminates, so MenuModel.quit ejects first.
/// Development builds (no ParaAirReleaseTag) never start the updater.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    /// A downloaded update installs when ParaAir quits.
    private(set) var hasPendingInstall = false
    private var controller: SPUStandardUpdaterController?
    private let ejectDrives: (@escaping (UpdateGate.Outcome) -> Void) -> Void

    static var isReleaseBuild: Bool { Bundle.main.object(forInfoDictionaryKey: "ParaAirReleaseTag") is String }

    init(ejectDrives: @escaping (@escaping (UpdateGate.Outcome) -> Void) -> Void) {
        self.ejectDrives = ejectDrives
        super.init()
        guard Self.isReleaseBuild else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
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
