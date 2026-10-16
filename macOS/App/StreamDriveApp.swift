import SwiftUI
import AppKit
import Combine
import FSKit
import os
import StreamDriveCore
import CFinderSidebar

@main
struct StreamDriveApp: App {
    @StateObject private var model = MenuModel()
    @NSApplicationDelegateAdaptor(AppTermination.self) private var termination
    @Environment(\.openWindow) private var openWindow
    init() {
        // Before MenuModel exists: a copy opened from the disk image moves to Applications and relaunches.
        let location = AppInstaller.prepareAtLaunch()
        LoginItemModel.applyLaunchDefault(location: location, service: SystemLoginItemService())
    }
    var body: some Scene {
        Window("ParaAir", id: "connections") {
            // Paper behind the title bar too, so the window reads as one surface.
            DriveHomeView(model: model).containerBackground(Glide.paper, for: .window)
        }.defaultSize(width: 620, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ParaAir") {
                    // The standard panel, with the release stage beside the version: "0.1.0 alpha 2 (148)".
                    let version = AppVersionText.current
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationVersion: version.title]
                    if let build = version.build { options[.version] = build }
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(after: .appInfo) {
                if model.updater.isAvailable { CheckForUpdatesButton(updater: model.updater) }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit ParaAir") { model.quit() }.keyboardShortcut("q")
            }
        }
        Window("ParaAir Storage Settings", id: "storage-settings") {
            ConnectionsView(stateRoot: model.stateRoot, reconnectRequest: $model.pendingReconnectID,
                            cloudAccount: model.cloudAccount,
                            onSaved: { model.offerDrive($0) },
                            onCloudDriveReady: { model.adoptStateRoot($0) })
                .id(model.stateRoot)
                .containerBackground(Glide.paper, for: .window)
        }.defaultSize(width: 680, height: 730)
        MenuBarExtra {
            MenuBarPanel(input: model.homeInputs(), details: model.homeDetails(),
                         connectAutomatically: $model.mountOnLaunch,
                         actions: model.homeActions(openWindow: openWindow), loginItem: model.loginItem)
                .onAppear { model.reload() }
        } label: {
            Image(nsImage: BrandMenuIcon.image).renderingMode(.template)
                .accessibilityLabel("ParaAir")
        }.menuBarExtraStyle(.window)
    }
}

/// Unified-log categories for auto-mount diagnosis (spec 7, E1). Capture with
/// `log show --last 30m --info --predicate 'subsystem BEGINSWITH "dev.streamdrive"'`.
/// Folder paths and record ids are hashed; outcomes and gates are public.
enum AppLog {
    static let lifecycle = Logger(subsystem: "dev.streamdrive.app", category: "lifecycle")
    static let renewal = Logger(subsystem: "dev.streamdrive.app", category: "renewal")
    static let setup = Logger(subsystem: "dev.streamdrive.app", category: "setup")
    static let mount = Logger(subsystem: "dev.streamdrive.app", category: "mount")
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var profiles: [DriveProfile] = []
    @Published var error: String?
    @Published var stateRoot: URL
    private var mounted: Set<String> = []
    private var renewalTask: Task<Void, Never>?
    /// One long-lived pair of renewal actors per known state folder.
    private var renewals: [String: (connections: ConnectionRenewal, cloud: CloudAccountRenewal)] = [:]
    @Published var creatingDrive = false
    @Published var renewalError: String?
    @Published private(set) var credentialCheckFinished = false
    @Published private var connectionErrors: [String: String] = [:]
    @Published private var connectionOutcomes: [String: RenewalOutcome] = [:]
    @Published private var cloudOutcomes: [String: RenewalOutcome] = [:]
    /// The selected folder's ParaAir Cloud account, shared with Storage Settings.
    @Published private(set) var cloudAccount: CloudAccountModel
    let activity = DriveActivityMonitor()
    let loginItem = LoginItemModel(service: SystemLoginItemService())
    @Published private(set) var uploadActivity: UploadActivity?
    private var observations = Set<AnyCancellable>()
    private var cloudObservation: AnyCancellable?
    /// Quick extension re-checks spent on the current pending continuation.
    private var stalePendingChecks = 0
    /// Modules with this extension's bundle identifier in the last FSKit listing; -1 when it failed.
    private var matchingModuleCount = 0
    private static let extensionBundleID = ParaAirBundle.filesystemIdentifier()
    private static let knownRootsKey = "knownStateRoots"
    private static let loginMountsKey = "loginMountStateRoots"
    private static let cloudTransientNotice = "ParaAir Cloud couldn’t be reached to renew sign-in. ParaAir keeps trying."
    private static let mountPendingNotice = "macOS is still opening the drive. ParaAir will finish setup when it replies; another mount is paused to avoid duplicates."
    /// One folder's last renewal results, as its automatic mount reads them.
    private struct FolderRenewal {
        var errors: [String: String] = [:]
        var outcomes: [String: RenewalOutcome] = [:]
        var cloud: [String: RenewalOutcome] = [:]
    }
    /// Folders besides the selected one whose drive mounts at login (spec D5).
    private var loginMounts = LoginMountFolders()
    /// Kept folders whose login mount hasn't started yet; queued once per launch.
    private var pendingLoginMounts: [URL] = []
    private var loginMountsQueued = false
    /// The last results of every other known folder, renewed in its own task.
    private var otherRenewals: [String: FolderRenewal] = [:]
    private var otherRenewalTask: Task<Void, Never>?
    /// Drives of other folders that didn't connect at login, by folder path.
    @Published private var otherDriveIssues: [String: String] = [:]
    /// A cloud drive's folder that became ready during a mount or drive creation.
    private var pendingAdoption: URL?
    @Published private(set) var adoptionNotice: String?
    @Published var mounting = false
    @Published var mountMessage: String?
    @Published var sidebarMessage: String?
    /// Presentation requests shared by the home window, menu bar panel and Storage Settings.
    @Published var appearanceOpen = false
    @Published var pendingReconnectID: String?
    /// A verified saved connection that has no drive yet (read from public connection records only).
    @Published private(set) var readyConnection: StorageConnection?
    @Published private(set) var extensionState: FinderExtensionState = .unchecked
    @Published private(set) var checkingExtension = false
    private lazy var finderSetup = FinderSetupCoordinator(
        bundleIdentifier: Self.extensionBundleID,
        expectedPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/StreamDriveFS.appex")
            .resolvingSymlinksInPath().path
    ) { [weak self] in
        self?.matchingModuleCount = -1
        let modules = try await FSClient.shared.installedExtensions.map {
            FinderExtensionModule(bundleIdentifier: $0.bundleIdentifier,
                                  path: $0.url.resolvingSymlinksInPath().path, isEnabled: $0.isEnabled)
        }
        self?.matchingModuleCount = modules.filter { $0.bundleIdentifier == Self.extensionBundleID }.count
        return modules
    }
    @Published var mountOnLaunch: Bool = UserDefaults.standard.object(forKey: "mountOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mountOnLaunch, forKey: "mountOnLaunch") }
    }
    private var sidebarAttempts = Set<String>()
    private var nativeMount: NativeMountOperation?

    init() {
        let args = ProcessInfo.processInfo.arguments
        let root: URL
        if let index = args.firstIndex(of: "--state-dir"), index + 1 < args.count {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL
        } else if let value = ProcessInfo.processInfo.environment["STREAMDRIVE_HOME"] {
            root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } else if let value = UserDefaults.standard.string(forKey: "selectedStateRoot") {
            root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/StreamDrive", isDirectory: true)
        }
        stateRoot = root
        cloudAccount = CloudAccountModel(stateRoot: root)
        UserDefaults.standard.set(root.path, forKey: "selectedStateRoot")
        rememberStateRoot(root)
        loginMounts = LoginMountFolders(kept: UserDefaults.standard.stringArray(forKey: Self.loginMountsKey) ?? [])
        activity.$activity.sink { [weak self] value in
            self?.uploadActivity = value
            self?.cloudAccount.pendingUploads = value
        }.store(in: &observations)
        observeCloudAccount()
        reload()
        logLifecycle("launch")
        startRenewal()
        updater.$pendingUpdateTitle.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        AppTermination.model = self
    }

    /// Sparkle updates; it ejects every drive before an update replaces the app (UpdateGate).
    lazy var updater = AppUpdater { [weak self] done in
        guard let self else { return done(.install) }
        self.ejectAllDrives(done)
    }

    /// Every way ParaAir quits passes here: Quit ParaAir, logging out, another app asking it to
    /// quit. A downloaded update installs as ParaAir quits, so its drives are ejected first and the
    /// update never replaces the app under a mounted drive's extension. A busy drive asks.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard updater.hasPendingInstall else { return .terminateNow }
        reload()
        guard !mounted.isEmpty else { return .terminateNow }
        ejectBeforeTerminating()
        return .terminateLater
    }

    private func ejectBeforeTerminating() {
        ejectAllDrives { outcome in
            switch outcome {
            case .install:
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            case .blocked(let drives):
                let alert = NSAlert()
                alert.messageText = UpdateGate.blockedTitle(drives)
                alert.informativeText = UpdateGate.blockedMessage(drives)
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Keep Running")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.ejectBeforeTerminating()
                } else {
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                }
            }
        }
    }

    /// Ejects every mounted ParaAir drive off the main thread, then reports which stayed busy.
    /// Ejecting keeps files waiting to upload on this Mac; they upload once a drive reconnects.
    func ejectAllDrives(_ completion: @escaping (UpdateGate.Outcome) -> Void) {
        reload()
        let paths = mounted.sorted()
        AppLog.mount.notice("eject for update drives=\(paths.count)")
        DispatchQueue.global(qos: .userInitiated).async {
            let results = ParaAirVolumes.eject(paths)
            DispatchQueue.main.async {
                self.reload()
                completion(UpdateGate.outcome(results))
            }
        }
    }

    // MARK: Known state folders

    /// Folders whose credentials ParaAir renews: every folder this app has used that
    /// still exists, plus the selected one (spec D5).
    func knownStateRoots() -> [URL] {
        let selected = stateRoot.standardizedFileURL
        var roots = [selected]
        for path in UserDefaults.standard.stringArray(forKey: Self.knownRootsKey) ?? [] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if url != selected, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
               !roots.contains(url) {
                roots.append(url)
            }
        }
        return roots
    }

    private func rememberStateRoot(_ url: URL) {
        let paths = knownStateRoots().map(\.path)
        let path = url.standardizedFileURL.path
        UserDefaults.standard.set(paths.contains(path) ? paths : paths + [path], forKey: Self.knownRootsKey)
    }

    private func saveLoginMounts() { UserDefaults.standard.set(loginMounts.kept, forKey: Self.loginMountsKey) }

    private static func hasDrive(_ root: URL) -> Bool { (try? ProfileStore(root: root).list())?.isEmpty == false }

    private func replaceCloudAccount() {
        cloudAccount = CloudAccountModel(stateRoot: stateRoot)
        cloudAccount.pendingUploads = uploadActivity
        observeCloudAccount()
    }

    private func observeCloudAccount() {
        cloudObservation = cloudAccount.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        cloudAccount.refreshPendingUploads = { [weak self] in await self?.activity.refreshNow() }
    }

    private func logLifecycle(_ event: String) {
        let bundledClientID = Bundle.main.object(forInfoDictionaryKey: "StreamDriveCloudflareClientID") != nil
        AppLog.lifecycle.notice("\(event, privacy: .public) folder=\(self.stateRoot.path, privacy: .private(mask: .hash)) profiles=\(self.profiles.count) mountOnLaunch=\(self.mountOnLaunch) bundledClientID=\(bundledClientID) nativeMountEntitlement=\(ParaAirHasNativeMountEntitlement()) knownFolders=\(self.knownStateRoots().count) keptLoginFolders=\(self.loginMounts.kept.count)")
    }

    // MARK: Renewal and automatic mounting

    /// Renews the selected folder, publishes its result, resumes a pending mount, then
    /// renews every other known folder in its own task (logged, and read by their login
    /// mounts). Extension checks run beside the loop, never inside it. While a mount waits
    /// on a stale extension state, it re-checks every 3 seconds for 10 tries, then every 30.
    func startRenewal() {
        renewalTask?.cancel()
        credentialCheckFinished = false
        connectionErrors = [:]; connectionOutcomes = [:]; cloudOutcomes = [:]
        renewalError = nil
        let root = stateRoot
        renewalTask = Task { [weak self] in
            var first = true
            var nextRenewal = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                var renewed = false
                if Date() >= nextRenewal {
                    renewed = await self.renewSelected(root)
                    guard !Task.isCancelled else { return }
                    nextRenewal = Date().addingTimeInterval(renewed ? 30 : 1)
                }
                if first, renewed {
                    first = false
                    if self.mountOnLaunch, let profile = self.profiles.first, !self.isMounted(profile) {
                        self.requestContinuation(profile, reason: "launch")
                    } else {
                        AppLog.setup.notice("continuation not requested at launch mountOnLaunch=\(self.mountOnLaunch) hasDrive=\(!self.profiles.isEmpty) mounted=\(self.profiles.first.map(self.isMounted) ?? false)")
                    }
                    self.queueLoginMounts()
                    self.refreshExtensionInBackground(trigger: "launch")
                } else if self.waitsForMount, self.extensionState != .enabled {
                    self.refreshExtensionInBackground(trigger: "pending-retry")
                } else {
                    self.resumeWaitingWork(trigger: renewed ? "renewal" : "timer")
                }
                guard !Task.isCancelled else { return }
                if renewed {
                    self.renewOtherRootsInBackground(excluding: root)
                    if self.profiles.first?.backend == .paraairCloud { self.cloudAccount.reloadSummary(maxAge: 300) }
                }
                var delay = max(1, nextRenewal.timeIntervalSinceNow)
                if self.waitsForMount, self.extensionState != .enabled, self.stalePendingChecks < 10 {
                    self.stalePendingChecks += 1
                    delay = min(delay, 3)
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func renewalServices(for root: URL) -> (connections: ConnectionRenewal, cloud: CloudAccountRenewal) {
        if let existing = renewals[root.path] { return existing }
        let live = EngineOpenDependencies.live
        let services = (ConnectionRenewal(root: root),
                        CloudAccountRenewal(root: root, vault: live.cloudVault, configuration: live.cloudConfiguration,
                                            policy: live.cloudPolicy))
        renewals[root.path] = services
        return services
    }

    /// Publishes the selected folder's outcomes. Returns false when another renewal of
    /// this folder was still running, so nothing new is known yet.
    private func renewSelected(_ root: URL) async -> Bool {
        let services = renewalServices(for: root)
        let started = Date()
        let report = await services.connections.renewDueConnections()
        let cloud = await services.cloud.renewDue()
        guard !Task.isCancelled, root == stateRoot else { return false }
        logRenewal(root: root, report: report, cloud: cloud, started: started, selected: true)
        guard !report.alreadyRunning else { return false }
        connectionErrors = report.errors
        connectionOutcomes = report.outcomes
        cloudOutcomes = cloud
        credentialCheckFinished = true
        renewalError = report.errors.sorted { $0.key < $1.key }.first?.value
            ?? (cloud.values.contains(.transientFailure) ? Self.cloudTransientNotice : nil)
        reload()
        return true
    }

    /// Renews the other known folders without holding up the selected folder's next pass,
    /// which slow or unreachable endpoints there could otherwise delay past its token's
    /// expiry. One such task runs at a time.
    private func renewOtherRootsInBackground(excluding selected: URL) {
        guard otherRenewalTask == nil else { return }
        otherRenewalTask = Task { [weak self] in
            await self?.renewOtherRoots(excluding: selected)
            self?.otherRenewalTask = nil
        }
    }

    private func renewOtherRoots(excluding selected: URL) async {
        for root in knownStateRoots() where root != selected {
            if Task.isCancelled { return }
            let services = renewalServices(for: root)
            let started = Date()
            let report = await services.connections.renewDueConnections()
            let cloud = await services.cloud.renewDue()
            logRenewal(root: root, report: report, cloud: cloud, started: started, selected: false)
            guard !report.alreadyRunning else { continue }
            otherRenewals[root.path] = FolderRenewal(errors: report.errors, outcomes: report.outcomes, cloud: cloud)
            resumeLoginMounts()
        }
        // Read again: the selected folder may have changed while this ran.
        let paths = Set(knownStateRoots().map(\.path))
        renewals = renewals.filter { paths.contains($0.key) }
        otherRenewals = otherRenewals.filter { paths.contains($0.key) }
    }

    /// A mount waits on the extension: the selected folder's continuation or a kept folder's login mount.
    private var waitsForMount: Bool { finderSetup.hasPendingContinuation || !pendingLoginMounts.isEmpty }

    /// Queues, once per launch, the drives of the folders kept for login besides the
    /// selected one (spec D5). The selected folder's drive uses the Finder setup continuation.
    private func queueLoginMounts() {
        guard !loginMountsQueued else { return }
        loginMountsQueued = true
        let targets = loginMounts.targets(selected: stateRoot.path) { Self.hasDrive(URL(fileURLWithPath: $0, isDirectory: true)) }
        saveLoginMounts()
        pendingLoginMounts = mountOnLaunch ? targets.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) } : []
        AppLog.setup.notice("login mounts queued other=\(self.pendingLoginMounts.count) mountOnLaunch=\(self.mountOnLaunch)")
        resumeLoginMounts()
    }

    /// Mounts the next queued drive of another folder once every gate is open. Its folder
    /// must have been renewed in this session; a blocking storage issue keeps it queued and
    /// is shown in the home window, since that folder has no window of its own.
    private func resumeLoginMounts() {
        for root in pendingLoginMounts where !mounting {
            // A folder chosen since launch mounts through the Finder setup continuation instead.
            guard root != stateRoot, let profile = (try? ProfileStore(root: root).list())?.first else {
                pendingLoginMounts.removeAll { $0 == root }; continue
            }
            let renewal = otherRenewals[root.path]
            let issue = renewal.flatMap { storageIssue(profile, root: root, renewal: $0) }
            let readiness = AutoMountReadiness(credentialCheckFinished: renewal != nil, storageBlocked: issue != nil,
                                               extensionState: extensionState, checkingExtension: checkingExtension,
                                               mounted: isMounted(profile), mounting: mounting)
            AppLog.setup.notice("login mount folder=\(root.path, privacy: .private(mask: .hash)) \(readiness.description, privacy: .public)")
            setOtherDriveIssue(issue == nil ? nil : Self.otherDriveNotice(profile, root: root), root: root)
            guard readiness.mounted || readiness.canStartMount else { continue }
            pendingLoginMounts.removeAll { $0 == root }
            if readiness.canStartMount { mount(profile, root: root, readiness: readiness) }
        }
    }

    private func setOtherDriveIssue(_ notice: String?, root: URL) {
        if otherDriveIssues[root.path] != notice { otherDriveIssues[root.path] = notice }
    }

    private static func otherDriveNotice(_ profile: DriveProfile, root: URL) -> String {
        "“\(profile.finderName)” didn’t connect at login. Choose its state folder, \(root.path), with Choose State Folder… to review it."
    }

    /// The first drive of another folder that didn't connect at login.
    var otherDriveNotice: String? { otherDriveIssues.sorted { $0.key < $1.key }.first?.value }

    /// Continues what waits for no mount or drive creation to be running: a folder switch,
    /// the selected drive's continuation and the login mounts of other folders.
    private func resumeWaitingWork(trigger: String) {
        guard !mounting, !creatingDrive else { return }
        if let root = pendingAdoption { adoptStateRoot(root) }
        resumePendingSetup(trigger: trigger)
        resumeLoginMounts()
    }

    private func logRenewal(root: URL, report: ConnectionRenewalReport, cloud: [String: RenewalOutcome], started: Date, selected: Bool) {
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.renewal.notice("pass folder=\(root.path, privacy: .private(mask: .hash)) selected=\(selected) durationMs=\(milliseconds) renewed=\(report.renewed.count) errors=\(report.errors.count) alreadyRunning=\(report.alreadyRunning) unreadable=\(report.unreadableRecords) cloudAccounts=\(cloud.count)")
        for (id, outcome) in report.outcomes.sorted(by: { $0.key < $1.key }) {
            AppLog.renewal.notice("record=\(id, privacy: .private(mask: .hash)) kind=connection outcome=\(outcome.rawValue, privacy: .public)")
        }
        for id in report.errors.keys.sorted() where report.outcomes[id] == nil {
            AppLog.renewal.notice("record=\(id, privacy: .private(mask: .hash)) kind=connection outcome=error-without-outcome")
        }
        for (id, outcome) in cloud.sorted(by: { $0.key < $1.key }) {
            AppLog.renewal.notice("record=\(id, privacy: .private(mask: .hash)) kind=cloud outcome=\(outcome.rawValue, privacy: .public)")
        }
    }

    private func requestContinuation(_ profile: DriveProfile, reason: String) {
        finderSetup.requestContinuation(for: setupTarget(profile))
        stalePendingChecks = 0
        AppLog.setup.notice("continuation requested reason=\(reason, privacy: .public)")
    }

    /// Switches to a folder whose drive just became ready (a ParaAir Cloud drive choice),
    /// restarts renewal there and continues Finder setup for its drive. The folder it
    /// leaves keeps mounting at login. During a mount or drive creation the switch waits
    /// for it to end; the new folder is renewed from the start.
    func adoptStateRoot(_ url: URL) {
        let root = url.standardizedFileURL
        // Saved at once, so the folder is renewed now and selected at the next launch even
        // if the switch below has to wait.
        rememberStateRoot(root)
        if root != stateRoot {
            loginMounts.adopt(root.path, leaving: stateRoot.path, previousHasDrive: Self.hasDrive(stateRoot))
            saveLoginMounts()
            UserDefaults.standard.set(root.path, forKey: "selectedStateRoot")
        }
        guard !creatingDrive, !mounting else {
            AppLog.lifecycle.notice("adopt-folder deferred creating=\(self.creatingDrive) mounting=\(self.mounting)")
            pendingAdoption = root
            adoptionNotice = "Your ParaAir Cloud drive is saved. ParaAir switches to it when the current drive finishes connecting."
            return
        }
        pendingAdoption = nil; adoptionNotice = nil
        finderSetup.cancelContinuation()
        if root != stateRoot {
            stateRoot = root
            mountMessage = nil; sidebarMessage = nil
            replaceCloudAccount()
        }
        reload()
        logLifecycle("adopt-folder")
        startRenewal()
        if let profile = profiles.first { continueSetup(profile) }
    }
    func offerDrive(_ connection: StorageConnection) {
        guard !creatingDrive, !mounting else { return }
        reload()
        startRenewal()
        guard profiles.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Create a drive using \(connection.name)?"
        let explanation = "Name the drive as you want it to appear in Finder. ParaAir keeps the drive’s files in a new folder inside the bucket; files already in the bucket won’t appear. The drive’s file index stays on this Mac, so keep this Mac backed up too. Storage and transfers may be charged by your provider."
        alert.informativeText = explanation
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = "ParaAir"; alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create Drive"); alert.addButton(withTitle: "Later")
        // Keep the dialog open until the name is valid, so the reason is shown where it was typed.
        var finderName = ""
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            finderName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try DriveProfile.validateFinderName(finderName)
                break
            } catch {
                alert.informativeText = error.localizedDescription + "\n\n" + explanation
            }
        }
        // The stored profile name is an identifier limited to letters, digits, dots,
        // underscores and hyphens; the typed name is kept as the Finder name.
        let name = DriveNaming.profileName(for: finderName)
        guard let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libstreamdrive.dylib") else {
            error = "This app is missing its native storage engine"; return
        }
        let root = stateRoot
        creatingDrive = true
        Task {
            defer { creatingDrive = false; resumeWaitingWork(trigger: "drive-created") }
            do {
                let profile = try await Task.detached {
                    let created = try ConnectedDrive.create(name: name, connectionID: connection.id, stateRoot: root, libraryURL: library)
                    guard finderName != created.name else { return created }
                    let store = ProfileStore(root: root)
                    var named = try store.load(created.name)
                    named.displayName = finderName
                    try store.save(named, overwrite: true)
                    return named
                }.value
                guard root == stateRoot else { return }
                reload()
                await refreshExtensionStatus()
                if canMount(profile) { mount(profile) }
            } catch { if root == stateRoot { self.error = error.localizedDescription } }
        }
    }
    /// Home-window shortcut after "Later": offer the drive for the saved, verified connection.
    func createDriveFromReadyConnection() {
        reload()
        guard let connection = readyConnection else { return }
        offerDrive(connection)
    }
    func reload() {
        do {
            profiles = try ProfileStore(root: stateRoot).list()
            error = nil
        } catch { self.error = error.localizedDescription; profiles = [] }
        // A waiting switch keeps the sign-in it is for on screen until it happens.
        if pendingAdoption == nil { cloudAccount.reload() }
        activity.watch(stateRoot: stateRoot, profile: profiles.first)
        readyConnection = profiles.isEmpty
            ? (try? ConnectionStore(root: stateRoot).list())?.first { $0.state == .storageReady } : nil
        mounted = Set(ParaAirVolumes.mountedPaths())
        for profile in profiles where isMounted(profile) {
            let identity = stateRoot.path + "\0" + profile.name
            if sidebarAttempts.insert(identity).inserted { addToSidebar(profile, automatically: true) }
        }
    }
    func isMounted(_ profile: DriveProfile) -> Bool {
        guard let mount = profile.mountPoint else { return false }
        return mounted.contains(mount)
    }
    func reveal(_ profile: DriveProfile) {
        guard let mount = profile.mountPoint, isMounted(profile) else { return }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: mount, isDirectory: true)) {
            mountMessage = "Finder couldn’t open the mounted drive at " + mount + "."
        }
    }
    func mount(_ profile: DriveProfile) { mount(profile, root: stateRoot, readiness: readiness(profile)) }

    /// Mounts the selected folder's drive or, at login, a kept folder's drive. Problems
    /// with a kept folder's drive go to `otherDriveIssues`, not to the selected drive's message.
    private func mount(_ profile: DriveProfile, root: URL, readiness: AutoMountReadiness) {
        guard !mounting, !isMounted(profile) else {
            AppLog.mount.notice("mount skipped gate=\(self.mounting ? "mounting" : "mounted", privacy: .public)")
            return
        }
        guard readiness.canStartMount else {
            AppLog.mount.notice("mount skipped \(readiness.description, privacy: .public)")
            return
        }
        let selected = root == stateRoot
        if selected { finderSetup.cancelContinuation() } else { setOtherDriveIssue(nil, root: root) }
        if #available(macOS 27.0, *), ParaAirHasNativeMountEntitlement(),
           NativeMountOperation.enabledByConfiguration(Bundle.main.infoDictionary ?? [:]) {
            AppLog.mount.notice("mount route=native selected=\(selected)")
            mountNative(profile, root: root)
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ParaAirCLI.app/Contents/MacOS/paraair")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            AppLog.mount.error("mount route=helper missing")
            mountMessage = "This build is missing its mount helper."; return
        }
        AppLog.mount.notice("mount route=helper selected=\(selected)")
        mounting = true
        if selected { mountMessage = nil }
        Task {
            defer { mounting = false; resumeWaitingWork(trigger: "mount-finished") }
            do {
                let status = try await Task.detached {
                    try Self.runMountHelper(helper, stateRoot: root, profileName: profile.name)
                }.value
                guard root == stateRoot else {
                    // The helper exits 0 only once the volume is in the mount table.
                    AppLog.mount.notice("helper finished status=\(status) selected=false")
                    if status != 0 { setOtherDriveIssue(Self.otherDriveNotice(profile, root: root), root: root) }
                    return
                }
                reload()
                AppLog.mount.notice("helper finished status=\(status) mounted=\(self.isMounted(profile))")
                if status != 0 || !isMounted(profile) {
                    mountMessage = "ParaAir couldn’t open the drive. Check that ParaAir is turned on in System Settings, or review the connection in Storage Settings. Your saved files are retained."
                }
            } catch {
                AppLog.mount.error("helper failed errno=\((error as? DriveError)?.code ?? -1)")
                if root == stateRoot { mountMessage = error.localizedDescription }
                else { setOtherDriveIssue(Self.otherDriveNotice(profile, root: root), root: root) }
            }
        }
    }
    @available(macOS 27.0, *)
    private func mountNative(_ profile: DriveProfile, root: URL) {
        mounting = true
        if root == stateRoot { mountMessage = nil }
        let operation = NativeMountOperation { [weak self] event in
            guard let self else { return }
            switch event {
            case .pending:
                self.mountMessage = Self.mountPendingNotice
            case .finished(let result):
                defer { self.mounting = false; self.nativeMount = nil; self.resumeWaitingWork(trigger: "mount-finished") }
                if root != self.stateRoot, self.mountMessage == Self.mountPendingNotice { self.mountMessage = nil }
                do {
                    let url = try result.get()
                    do {
                        try NativeMountOperation.verifyMountedResource(url, stateRoot: root)
                        AppLog.mount.notice("verify mounted resource ok")
                    } catch {
                        AppLog.mount.error("verify mounted resource failed errno=\((error as? DriveError)?.code ?? -1)")
                        throw error
                    }
                    let store = ProfileStore(root: root)
                    var saved = try store.load(profile.name)
                    guard saved == profile else {
                        throw DriveError(ESTALE, "The drive settings changed during mounting. The mounted volume is at " + url.path)
                    }
                    // Update only the mount location; retain the storage identity,
                    // pins and durable pending writes.
                    saved.mountPoint = url.path
                    try store.save(saved, overwrite: true)
                    guard root == self.stateRoot else { return }
                    self.reload()
                    guard self.isMounted(saved) else {
                        throw DriveError(EIO, "macOS returned a volume that is not present in the mount table")
                    }
                    self.mountMessage = nil
                } catch {
                    if root == self.stateRoot { self.mountMessage = error.localizedDescription }
                    else { self.setOtherDriveIssue(Self.otherDriveNotice(profile, root: root), root: root) }
                }
            }
        }
        nativeMount = operation
        do { try operation.start(stateRoot: root, profileName: profile.name) }
        catch {
            nativeMount = nil; mounting = false
            if root == stateRoot { mountMessage = error.localizedDescription }
            else { setOtherDriveIssue(Self.otherDriveNotice(profile, root: root), root: root) }
            // After this call returns, so a queued mount doesn't start inside the one that failed.
            Task { resumeWaitingWork(trigger: "mount-failed") }
        }
    }
    private nonisolated static func runMountHelper(_ helper: URL, stateRoot: URL, profileName: String) throws -> Int32 {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--state-dir", stateRoot.path, "mount", profileName]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 40) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            throw DriveError(ETIMEDOUT, "Opening the drive timed out. Check that ParaAir is turned on in System Settings, then try again.")
        }
        return process.terminationStatus
    }
    func addToSidebar(_ profile: DriveProfile, automatically: Bool) {
        switch FinderSidebar(stateRoot: stateRoot).registerMountedVolume(profile, automatically: automatically) {
        case .added, .alreadyPresent:
            sidebarMessage = "ParaAir is in Finder’s Favorites."
        case .automaticPreviouslyAttempted: break
        case .notMounted: sidebarMessage = "Mount the drive before adding it to Finder’s sidebar."
        case .manualRequired(let message): sidebarMessage = message
        }
    }
    func refreshExtensionStatus(trigger: String = "home-window") async {
        checkingExtension = true
        extensionState = await finderSetup.refresh()
        checkingExtension = finderSetup.isRefreshing
        AppLog.setup.notice("extension refresh trigger=\(trigger, privacy: .public) state=\(String(describing: self.extensionState), privacy: .public) matchingModules=\(self.matchingModuleCount)")
        resumePendingSetup(trigger: "extension-" + trigger)
        resumeLoginMounts()
    }
    /// Starts an extension check beside the renewal loop: a slow or unanswered FSKit
    /// listing must never hold up credential renewal. A check already running is joined
    /// by its own waiters, so none is added.
    private func refreshExtensionInBackground(trigger: String) {
        guard !finderSetup.isRefreshing else { return }
        Task { await refreshExtensionStatus(trigger: trigger) }
    }
    /// Asks to mount once every gate is open. While credentials are still being checked
    /// the request waits; a blocking storage issue is shown instead.
    func continueSetup(_ profile: DriveProfile) {
        guard !mounting else { AppLog.setup.notice("continuation not requested: mounting"); return }
        if isMounted(profile) { reveal(profile); return }
        if credentialCheckFinished, connectionIssue(profile) != nil {
            AppLog.setup.notice("continuation not requested: storage-blocked")
            return
        }
        requestContinuation(profile, reason: "continue-setup")
        Task { await refreshExtensionStatus(trigger: "continue-setup") }
    }
    func resumeAfterSettings() {
        guard finderSetup.hasPendingContinuation else { return }
        Task { await refreshExtensionStatus(trigger: "app-active") }
    }
    private func setupTarget(_ profile: DriveProfile) -> String {
        stateRoot.standardizedFileURL.path + "\0" + profile.name
    }
    private func resumePendingSetup(trigger: String) {
        guard let profile = profiles.first, finderSetup.hasPendingContinuation else { return }
        let readiness = readiness(profile)
        let take = finderSetup.takeContinuation(for: setupTarget(profile), readiness: readiness)
        AppLog.setup.notice("take trigger=\(trigger, privacy: .public) took=\(take) canStartMount=\(readiness.canStartMount) \(readiness.description, privacy: .public)")
        if take { mount(profile) }
    }
    /// The one readiness value both the take decision and `canMount` read.
    func readiness(_ profile: DriveProfile) -> AutoMountReadiness {
        AutoMountReadiness(credentialCheckFinished: credentialCheckFinished, storageBlocked: connectionIssue(profile) != nil,
                           extensionState: extensionState, checkingExtension: checkingExtension,
                           mounted: isMounted(profile), mounting: mounting)
    }
    /// Only issues that must stop an automatic mount. Transient and not-yet-due renewal
    /// problems keep working credentials and appear as `renewalError` notices instead.
    func connectionIssue(_ profile: DriveProfile) -> String? {
        storageIssue(profile, root: stateRoot,
                     renewal: FolderRenewal(errors: connectionErrors, outcomes: connectionOutcomes, cloud: cloudOutcomes))
    }
    /// The same check for a drive in any folder, from that folder's last renewal.
    private func storageIssue(_ profile: DriveProfile, root: URL, renewal: FolderRenewal) -> String? {
        if profile.backend == .paraairCloud { return cloudIssue(profile, root: root, outcomes: renewal.cloud) }
        guard let id = profile.connectionID else { return nil }
        if let error = renewal.errors["connections"] { return error }
        // Without a recorded outcome an error is treated as blocking, as before outcomes existed.
        if let error = renewal.errors[id], renewal.outcomes[id]?.blocksAutoMount ?? true { return error }
        guard renewal.outcomes[id]?.blocksAutoMount != true,
              let record = try? ConnectionStore(root: root).load(id), record.state == .storageReady else {
            return "Reconnect your saved storage connection in Storage settings."
        }
        return nil
    }
    private func cloudIssue(_ profile: DriveProfile, root: URL, outcomes: [String: RenewalOutcome]) -> String? {
        guard let id = profile.cloudAccountID, let account = try? CloudAccountStore(root: root).load(id),
              account.state == .signedIn else {
            return "Sign in to ParaAir Cloud in Storage Settings."
        }
        switch outcomes[id] {
        case .authorizationEnded?: return "Your ParaAir Cloud sign-in ended. Sign in again in Storage Settings."
        case let outcome? where outcome.blocksAutoMount:
            return "ParaAir Cloud sign-in couldn’t be renewed. Sign in again in Storage Settings."
        default: return nil
        }
    }
    func canMount(_ profile: DriveProfile) -> Bool { readiness(profile).canStartMount }
    func connectionSummary(_ profile: DriveProfile) -> String {
        if profile.backend == .paraairCloud {
            let account = profile.cloudAccountID.flatMap { try? CloudAccountStore(root: stateRoot).load($0) }
            return account.map { "ParaAir Cloud · " + $0.email } ?? "ParaAir Cloud"
        }
        guard let id = profile.connectionID, let record = try? ConnectionStore(root: stateRoot).load(id) else {
            return "Your saved storage connection"
        }
        // A connection keeps its provider title as its default name; show the bucket instead
        // of repeating the provider.
        let detail = record.name == record.provider.title ? record.bucket : record.name
        return [record.provider.title, detail].compactMap { $0 }.joined(separator: " · ")
    }
    func openExtensionSettings() {
        if let profile = profiles.first, !isMounted(profile) {
            requestContinuation(profile, reason: "extension-settings")
        }
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            if !NSWorkspace.shared.open(url) {
                mountMessage = "Couldn’t open System Settings. Open General → Login Items & Extensions → By Category → File System Extensions, "
                    + "switch on ParaAir, then return and choose Check again."
            }
        }
    }
    func quit() {
        // With an update waiting, quitting ejects the drives (shouldTerminate), so the
        // "drive stays mounted" question doesn't apply.
        if !mounted.isEmpty && !updater.hasPendingInstall {
            let alert = NSAlert()
            alert.messageText = "Quit ParaAir while a drive is mounted?"
            alert.informativeText = "The drive stays mounted, but cloud sign-in renewal stops. Eject the drive in Finder first, or keep ParaAir open for continued access."
            alert.addButton(withTitle: "Keep running")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        NSApplication.shared.terminate(nil)
    }
    func setCredential(_ profile: DriveProfile) {
        guard let identifier = profile.credentialID else { return }
        let alert = NSAlert()
        alert.messageText = "Metadata credential for " + profile.name
        alert.informativeText = "Enter the complete authenticated metadata URI. It is stored only in this Mac’s Keychain. The filesystem extension may require separate Keychain access authorization."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Authenticated metadata URI"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save in Keychain")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { field.stringValue = ""; return }
        defer { field.stringValue = "" }
        do {
            try KeychainSecretStore().storeMetadataURL(field.stringValue, identifier: identifier)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func selectRoot() {
        guard !creatingDrive, !mounting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the ParaAir state folder created by the CLI."
        panel.directoryURL = stateRoot
        if panel.runModal() == .OK, !creatingDrive, !mounting, let selected = panel.url {
            finderSetup.cancelContinuation()
            pendingAdoption = nil; adoptionNotice = nil
            loginMounts.choose(selected.standardizedFileURL.path, leaving: stateRoot.path, previousHasDrive: Self.hasDrive(stateRoot))
            saveLoginMounts()
            stateRoot = selected.standardizedFileURL
            setOtherDriveIssue(nil, root: stateRoot)
            UserDefaults.standard.set(stateRoot.path, forKey: "selectedStateRoot")
            mountMessage = nil; sidebarMessage = nil
            rememberStateRoot(stateRoot)
            replaceCloudAccount()
            startRenewal(); reload()
            logLifecycle("select-folder")
        }
    }
}
