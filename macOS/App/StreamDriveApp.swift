import SwiftUI
import AppKit
import FSKit
import StreamDriveCore
import CFinderSidebar

@main
struct StreamDriveApp: App {
    @StateObject private var model = MenuModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("ParaAir", id: "connections") {
            DriveHomeView(model: model)
        }.defaultSize(width: 620, height: 640)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit ParaAir") { model.quit() }.keyboardShortcut("q")
            }
        }
        Window("ParaAir Storage Settings", id: "storage-settings") {
            ConnectionsView(stateRoot: model.stateRoot, reconnectRequest: $model.pendingReconnectID) { model.offerDrive($0) }
                .id(model.stateRoot)
        }.defaultSize(width: 680, height: 730)
        MenuBarExtra {
            MenuBarPanel(input: model.homeInputs(), details: model.homeDetails(),
                         connectAutomatically: $model.mountOnLaunch,
                         actions: model.homeActions(openWindow: openWindow))
                .onAppear { model.reload() }
        } label: {
            Image(nsImage: BrandMenuIcon.image).renderingMode(.template)
                .accessibilityLabel("ParaAir")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var profiles: [DriveProfile] = []
    @Published var error: String?
    @Published var stateRoot: URL
    private var mounted: Set<String> = []
    private var renewalTask: Task<Void, Never>?
    private var renewal: ConnectionRenewal?
    @Published var creatingDrive = false
    @Published var renewalError: String?
    @Published private(set) var credentialCheckFinished = false
    @Published private var connectionErrors: [String: String] = [:]
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
        bundleIdentifier: "dev.streamdrive.app.filesystem",
        expectedPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/StreamDriveFS.appex")
            .resolvingSymlinksInPath().path
    ) {
        try await FSClient.shared.installedExtensions.map {
            FinderExtensionModule(bundleIdentifier: $0.bundleIdentifier,
                                  path: $0.url.resolvingSymlinksInPath().path, isEnabled: $0.isEnabled)
        }
    }
    @Published var mountOnLaunch: Bool = UserDefaults.standard.object(forKey: "mountOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mountOnLaunch, forKey: "mountOnLaunch") }
    }
    private var sidebarAttempts = Set<String>()
    private var nativeMount: NativeMountOperation?

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--state-dir"), index + 1 < args.count {
            stateRoot = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL
        } else if let value = ProcessInfo.processInfo.environment["STREAMDRIVE_HOME"] {
            stateRoot = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } else if let value = UserDefaults.standard.string(forKey: "selectedStateRoot") {
            stateRoot = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } else {
            stateRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/StreamDrive", isDirectory: true)
        }
        UserDefaults.standard.set(stateRoot.path, forKey: "selectedStateRoot")
        reload()
        startRenewal()
    }
    func startRenewal() {
        renewalTask?.cancel()
        credentialCheckFinished = false
        connectionErrors = [:]
        renewalError = nil
        let service = ConnectionRenewal(root: stateRoot)
        renewal = service
        renewalTask = Task { [weak self] in
            var initialRenewal = true
            while !Task.isCancelled {
                let report = await service.renewDueConnections()
                guard !Task.isCancelled else { break }
                self?.connectionErrors = report.errors
                self?.credentialCheckFinished = true
                self?.renewalError = report.errors.sorted { $0.key < $1.key }.first?.value
                self?.reload()
                if initialRenewal {
                    initialRenewal = false
                    if let self, self.mountOnLaunch, let profile = self.profiles.first, !self.isMounted(profile) {
                        self.finderSetup.requestContinuation(for: self.setupTarget(profile))
                    }
                    await self?.refreshExtensionStatus()
                    guard !Task.isCancelled else { break }
                }
                self?.resumePendingSetup()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
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
            defer { creatingDrive = false }
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
        readyConnection = profiles.isEmpty
            ? (try? ConnectionStore(root: stateRoot).list())?.first { $0.state == .storageReady } : nil
        mounted.removeAll()
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        if let mounts {
            for index in 0..<Int(count) {
                var entry = mounts[index]
                let type = withUnsafePointer(to: &entry.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                }
                guard type == "streamdrive" || type == "paraair" else { continue }
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                mounted.insert(path)
            }
        }
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
    func mount(_ profile: DriveProfile) {
        guard !mounting, !isMounted(profile) else { return }
        guard canMount(profile) else { return }
        finderSetup.cancelContinuation()
        if #available(macOS 27.0, *), ParaAirHasNativeMountEntitlement(),
           NativeMountOperation.enabledByConfiguration(Bundle.main.infoDictionary ?? [:]) {
            mountNative(profile)
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ParaAirCLI.app/Contents/MacOS/paraair")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            mountMessage = "This build is missing its mount helper."; return
        }
        let root = stateRoot
        mounting = true; mountMessage = nil
        Task {
            defer { mounting = false }
            do {
                let status = try await Task.detached {
                    try Self.runMountHelper(helper, stateRoot: root, profileName: profile.name)
                }.value
                guard root == stateRoot else { return }
                reload()
                if status != 0 || !isMounted(profile) {
                    mountMessage = "ParaAir couldn’t open the drive. Check that ParaAir is turned on in System Settings, or review the connection in Storage Settings. Your saved files are retained."
                }
            } catch { if root == stateRoot { mountMessage = error.localizedDescription } }
        }
    }
    @available(macOS 27.0, *)
    private func mountNative(_ profile: DriveProfile) {
        let root = stateRoot
        mounting = true; mountMessage = nil
        let operation = NativeMountOperation { [weak self] event in
            guard let self else { return }
            switch event {
            case .pending:
                self.mountMessage = "macOS is still opening the drive. ParaAir will finish setup when it replies; another mount is paused to avoid duplicates."
            case .finished(let result):
                defer { self.mounting = false; self.nativeMount = nil }
                do {
                    let url = try result.get()
                    try NativeMountOperation.verifyMountedResource(url, stateRoot: root)
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
                }
            }
        }
        nativeMount = operation
        do { try operation.start(stateRoot: root, profileName: profile.name) }
        catch { nativeMount = nil; mounting = false; mountMessage = error.localizedDescription }
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
    func refreshExtensionStatus() async {
        checkingExtension = true
        extensionState = await finderSetup.refresh()
        checkingExtension = finderSetup.isRefreshing
        resumePendingSetup()
    }
    func continueSetup(_ profile: DriveProfile) {
        guard !mounting else { return }
        if isMounted(profile) { reveal(profile); return }
        guard credentialCheckFinished, connectionIssue(profile) == nil else { return }
        finderSetup.requestContinuation(for: setupTarget(profile))
        Task { await refreshExtensionStatus() }
    }
    func resumeAfterSettings() {
        guard finderSetup.hasPendingContinuation else { return }
        Task { await refreshExtensionStatus() }
    }
    private func setupTarget(_ profile: DriveProfile) -> String {
        stateRoot.standardizedFileURL.path + "\0" + profile.name
    }
    private func resumePendingSetup() {
        guard let profile = profiles.first else { return }
        if finderSetup.takeContinuation(for: setupTarget(profile),
                                        storageReady: credentialCheckFinished && connectionIssue(profile) == nil,
                                        mounted: isMounted(profile), mounting: mounting) {
            mount(profile)
        }
    }
    func connectionIssue(_ profile: DriveProfile) -> String? {
        guard let id = profile.connectionID else { return nil }
        if let error = connectionErrors[id] ?? connectionErrors["connections"] { return error }
        guard let record = try? ConnectionStore(root: stateRoot).load(id), record.state == .storageReady else {
            return "Reconnect your saved storage connection in Storage settings."
        }
        return nil
    }
    func canMount(_ profile: DriveProfile) -> Bool {
        credentialCheckFinished && connectionIssue(profile) == nil && extensionState == .enabled && !checkingExtension
    }
    func connectionSummary(_ profile: DriveProfile) -> String {
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
            finderSetup.requestContinuation(for: setupTarget(profile))
        }
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            if !NSWorkspace.shared.open(url) {
                mountMessage = "Couldn’t open System Settings. Open General → Login Items & Extensions → File System Extensions, then return and choose Check again."
            }
        }
    }
    func quit() {
        if !mounted.isEmpty {
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
            stateRoot = selected
            UserDefaults.standard.set(selected.path, forKey: "selectedStateRoot")
            mountMessage = nil; sidebarMessage = nil
            startRenewal(); reload()
        }
    }
}
