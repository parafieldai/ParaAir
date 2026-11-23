import Foundation
import StreamDriveCore
import Darwin

struct CLIExecution {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

final class CLIApplication {
    private let environment: [String: String]
    private let dependencies: EngineOpenDependencies
    private let system: CLISystem
    init(environment: [String: String] = ProcessInfo.processInfo.environment, dependencies: EngineOpenDependencies = .live,
         system: CLISystem = .live) {
        self.environment = environment; self.dependencies = dependencies; self.system = system
    }
    func run(_ arguments: [String]) -> CLIExecution {
        do { return try execute(CLIParser.parse(arguments)) }
        catch {
            let outcome = CLIOutcome.of(error)
            let message = error.localizedDescription
            if arguments.contains("--json") {
                let result = Failure(error: message, exitCode: outcome.exitCode, code: outcome.code)
                return CLIExecution(stdout: (try? json(result)) ?? "{\"error\":\"Operation failed\"}\n", stderr: "", exitCode: outcome.exitCode)
            }
            return CLIExecution(stdout: "", stderr: "paraair: \(message)\n", exitCode: outcome.exitCode)
        }
    }

    private func execute(_ invocation: CLIInvocation) throws -> CLIExecution {
        let stateRoot = ProfileStore.resolveRoot(explicit: invocation.stateDirectory, environment: environment)
        let store = ProfileStore(root: stateRoot)
        switch invocation.command {
        case .help(let topic):
            return success(CLIHelp.text(topic))
        case .connections:
            let records = try ConnectionStore(root: stateRoot).list()
            let text = records.map { "\($0.id)\t\($0.provider.title)\t\($0.state.rawValue)\t\($0.name)" }.joined(separator: "\n")
            return try render(records, invocation: invocation, text: text.isEmpty ? "No saved connections. Open ParaAir Connections.\n" : text + "\n")
        case .cloudAccounts:
            let accounts = CloudAccountStore(root: stateRoot).list().accounts
            let text = accounts.map { "\($0.id)\tParaAir Cloud\t\($0.state.rawValue)\t\(displayName($0.email))" }.joined(separator: "\n")
            return try render(accounts, invocation: invocation, text: text.isEmpty ? "No ParaAir Cloud accounts. Sign in from the ParaAir app.\n" : text + "\n")
        case .cloudDrives(let accountID):
            let found = try signedInAccount(accountID, roots: knownRoots(explicit: invocation.stateDirectory))
            let drives = try accountAPI(root: found.root, accountID: accountID).drives().map {
                CloudDriveItem(id: $0.id, workspaceId: $0.workspaceId, name: $0.name, role: $0.role, writable: $0.writable)
            }
            let text = drives.map { "\($0.id)\t\($0.workspaceId)\t\($0.role)\t\(displayName($0.name))" }.joined(separator: "\n")
            return try render(drives, invocation: invocation, text: text.isEmpty ? "This account has no ParaAir Cloud drives.\n" : text + "\n")
        case .cloudSignIn(let wait):
            let app = try installedApp()
            if let account = signedInAccounts(knownRoots(explicit: invocation.stateDirectory)).first {
                return try render(account, invocation: invocation, text: "Signed in as \(displayName(account.email)).\n")
            }
            try system.openURL(app.path, CLISystem.signInURL)
            guard let wait else {
                return try render(SignInStarted(opened: true), invocation: invocation, text: "Opened ParaAir to sign in. Finish in the browser it opens.\n")
            }
            for _ in 0..<wait {
                system.sleep(1)
                if let account = signedInAccounts(knownRoots(explicit: invocation.stateDirectory)).first {
                    return try render(account, invocation: invocation, text: "Signed in as \(displayName(account.email)).\n")
                }
            }
            throw CLIOutcomeError(outcome: .notSignedIn, message: "Sign-in didn’t finish within \(wait) seconds")
        case .setupStatus:
            let value = setupStatus(explicit: invocation.stateDirectory)
            return try render(value, invocation: invocation, text: setupStatusText(value))
        case .trash(let name):
            let profile = try cloudProfile(name, store: store)
            let api = try cloudAPI(profile, root: stateRoot)
            var items: [ParaAirCloudTrashPage.Item] = [], cursor: String?, pages = 0
            repeat {
                let page = try api.trash(driveID: profile.cloudDriveID!, cursor: cursor, limit: 1000)
                items += page.items; cursor = page.nextCursor; pages += 1
            } while cursor != nil && pages < 1000
            let text = items.isEmpty ? "Trash is empty.\n" : items.map { "\($0.nodeId)\t\($0.size)\t\(displayName($0.path))" }.joined(separator: "\n") + "\n"
            return try render(items, invocation: invocation, text: text)
        case .restore(let name, let nodeID, let to):
            let profile = try cloudProfile(name, store: store)
            let destination = try to.map { try canonicalPath($0) }
            let entry = try cloudAPI(profile, root: stateRoot).restore(driveID: profile.cloudDriveID!, nodeID: nodeID, to: destination, idempotencyKey: UUID())
            return try render(entry, invocation: invocation, text: "Restored \(displayName(entry.path)).\n")
        case .storedDrives(let connection, let library):
            let drives = try ConnectedDrive.storedDrives(connectionID: connection, stateRoot: stateRoot,
                                                        libraryURL: NativeLibraryLocation.resolve(configured: library.map(absolutePath), stateRoot: stateRoot))
            let text = drives.map { drive in
                let owner = drive.owner.map { "last used on \(displayName($0.name)) \(ISO8601DateFormatter().string(from: $0.at))" } ?? "no owner recorded"
                return "\(drive.volume)\t\(displayName(drive.owner?.drive ?? "-"))\t\(owner)\t\(drive.latestBackup)"
            }.joined(separator: "\n")
            return try render(drives, invocation: invocation, text: text.isEmpty ? "No backed-up drives in this bucket.\n" : text + "\n")
        case .recover(let name, let connection, let volume, let backup, let takeOver, let library):
            let recovered = try ConnectedDrive.recover(name: name, volume: volume, connectionID: connection, stateRoot: stateRoot,
                                                       libraryURL: NativeLibraryLocation.resolve(configured: library.map(absolutePath), stateRoot: stateRoot),
                                                       backupKey: backup, takeOver: takeOver)
            let response = ProfileReference(profile: recovered.profile.name, backend: recovered.profile.backend.rawValue,
                                            mountPoint: recovered.profile.mountPoint, mounted: false)
            return try render(response, invocation: invocation,
                              text: "Recovered '\(recovered.profile.name)' from \(recovered.backupKey). Open ParaAir to connect it in Finder.\n")
        case .connect(let arguments) where arguments.values["cloud-account"] != nil:
            let values = arguments.values
            guard values["cloud-drive"] != nil || values["cloud-drive-name"] != nil else {
                throw CLIUsageError(message: "--cloud-account requires --cloud-drive or --cloud-drive-name")
            }
            for flag in ["metadata-url", "library", "credential-id", "fixture-root", "connection"] where values[flag] != nil {
                throw CLIUsageError(message: "--\(flag) cannot be combined with --cloud-account")
            }
            if let size = values["block-size"], Int(size) != CloudDriveSetup.blockSize {
                throw CLIUsageError(message: "ParaAir Cloud drives use --block-size 4194304")
            }
            let drive: String
            if let wanted = values["cloud-drive-name"] {
                let accountID = values["cloud-account"]!
                _ = try signedInAccount(accountID, roots: [stateRoot])
                let name = wanted.precomposedStringWithCanonicalMapping
                let matches = try accountAPI(root: stateRoot, accountID: accountID).drives().filter { $0.name.precomposedStringWithCanonicalMapping == name }
                guard matches.count == 1 else {
                    throw CLIOutcomeError(outcome: .driveNotFound, message: matches.isEmpty
                        ? "This account has no ParaAir Cloud drive named \(displayName(wanted))"
                        : "More than one drive is named \(displayName(wanted)); use --cloud-drive with its id (see cloud-drives)")
                }
                drive = matches[0].id
            } else {
                drive = values["cloud-drive"]!
            }
            if arguments.overwrite, let previous = try? store.load(arguments.profile), mounted(previous) {
                throw DriveError(EBUSY, "Unmount the profile before replacing its configuration")
            }
            var profile = try CloudDriveSetup.attach(driveID: drive, finderName: arguments.profile, name: arguments.profile,
                                                     accountID: values["cloud-account"]!, stateRoot: stateRoot,
                                                     replace: arguments.overwrite, dependencies: dependencies)
            if values["cache-mib"] != nil || values["min-free-mib"] != nil || values["journal-mib"] != nil || values["mount-point"] != nil {
                profile.cacheLimitBytes = try bytes(values["cache-mib"], default: profile.cacheLimitBytes)
                profile.minFreeBytes = try bytes(values["min-free-mib"], default: profile.minFreeBytes)
                profile.maxJournalBytes = try bytes(values["journal-mib"], default: profile.maxJournalBytes)
                profile.mountPoint = values["mount-point"].map(absolutePath) ?? profile.mountPoint
                try store.save(profile, overwrite: true)
            }
            let response = ProfileReference(profile: profile.name, backend: profile.backend.rawValue, mountPoint: profile.mountPoint, mounted: false)
            return try render(response, invocation: invocation, text: "Saved ParaAir Cloud profile '\(profile.name)'. Run ls to browse it, then mount to open it in Finder.\n")
        case .connect(let arguments):
            let values = arguments.values
            let fixture = values["fixture-root"].map(absolutePath)
            if let fixture {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fixture, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw CLIUsageError(message: "--fixture-root must identify an existing local fixture directory")
                }
                try rejectStateInsideFixture(fixture, stateRoot: stateRoot)
                guard values["metadata-url"] == nil, values["credential-id"] == nil, values["connection"] == nil else {
                    throw CLIUsageError(message: "--fixture-root cannot be combined with remote metadata or credentials")
                }
            }
            if let connectionID = values["connection"] {
                let connection = try ConnectionStore(root: stateRoot).load(connectionID)
                guard connection.state == .storageReady else { throw DriveError(ENOTCONN, "Finish setup in ParaAir Connections") }
                _ = try connection.nativeBucketURL()
            }
            var profile = DriveProfile(
                name: arguments.profile, backend: fixture == nil ? .juicefs : .local,
                metadataURL: values["metadata-url"], localRoot: fixture,
                libraryPath: values["library"].map(absolutePath), mountPoint: values["mount-point"].map(absolutePath),
                cacheLimitBytes: try bytes(values["cache-mib"], default: 1_073_741_824),
                minFreeBytes: try bytes(values["min-free-mib"], default: 5_368_709_120),
                blockSize: values["block-size"].flatMap(Int.init) ?? 1_048_576,
                maxJournalBytes: try bytes(values["journal-mib"], default: 4_294_967_296),
                credentialID: values["credential-id"], connectionID: values["connection"]
            )
            let previous = arguments.overwrite ? try? store.load(arguments.profile) : nil
            if let previous, mounted(previous) {
                throw DriveError(EBUSY, "Unmount the profile before replacing its configuration")
            }
            // Cached blocks are keyed by block size; a replacement keeps the stored one unless asked.
            if values["block-size"] == nil {
                profile.blockSize = previous?.blockSize ?? (values["connection"] != nil ? ConnectedDrive.blockSize : profile.blockSize)
            }
            try store.save(profile, overwrite: arguments.overwrite)
            let response = ProfileReference(profile: profile.name, backend: profile.backend.rawValue, mountPoint: profile.mountPoint, mounted: false)
            return try render(response, invocation: invocation, text: "Saved profile '\(profile.name)' (\(profile.backend.rawValue)). Run ls to verify storage, then mount to open it in Finder.\n")
        case .list(let name, let path):
            let profile = try store.load(name)
            let entries = try open(profile, root: stateRoot).list(canonicalPath(path))
            let text = entries.map { "\($0.kind == .directory ? "d" : "f")\t\($0.size)\t\(displayName($0.name))" }.joined(separator: "\n")
            return try render(entries, invocation: invocation, text: text.isEmpty ? "" : text + "\n")
        case .status(let name):
            let profiles = try selectedProfiles(name, store: store)
            let values = try profiles.map { try status($0, root: stateRoot) }
            if name != nil, let first = values.first { return try render(first, invocation: invocation, text: statusText(first)) }
            return try render(values, invocation: invocation, text: values.isEmpty ? "No profiles configured. Run paraair connect.\n" : values.map(statusText).joined(separator: "\n"))
        case .cache(let name, let trim, let limit):
            var profile = try store.load(name)
            if let limit {
                guard !mounted(profile) else { throw DriveError(EBUSY, "Unmount before changing the cache limit; remount to apply the new limit") }
                profile.cacheLimitBytes = Int64(limit) * 1_048_576
                try store.save(profile, overwrite: true)
            }
            let engine = try open(profile, root: stateRoot)
            let evicted = trim ? try engine.evictCache() : 0
            let value = CacheResult(profile: name, evictedBytes: evicted, drive: try engine.status())
            return try render(value, invocation: invocation, text: "Evictable cache: \(humanBytes(value.drive.cacheBytes)) / \(humanBytes(value.drive.cacheLimitBytes)); pins: \(humanBytes(value.drive.pinnedBytes)); pending writes: \(humanBytes(value.drive.pendingWriteBytes)); evicted: \(humanBytes(evicted)).\n")
        case .pin(let name, let path), .unpin(let name, let path):
            let profile = try store.load(name), engine = try open(profile, root: stateRoot)
            let canonical = try canonicalPath(path)
            let pinning: Bool
            if case .pin = invocation.command { pinning = true; try engine.pin(canonical) }
            else { pinning = false; try engine.unpin(canonical) }
            let value = PinResult(profile: name, path: canonical, pinned: pinning, drive: try engine.status())
            return try render(value, invocation: invocation, text: "\(pinning ? "Pinned for offline reads" : "Unpinned") \(displayName(canonical)). Pins and pending writes are accounted separately from the evictable cache.\n")
        case .uploads(let name, let retry):
            let profile = try store.load(name), engine = try open(profile, root: stateRoot)
            let records = retry ? try engine.flushUploads() : try engine.uploads()
            let text = records.isEmpty ? "No pending uploads.\n" : records.map { "\($0.state)\t\($0.pendingBytes)\t\(displayName($0.path))\($0.lastError.map { "\t" + $0 } ?? "")" }.joined(separator: "\n") + "\n"
            var response = try render(records, invocation: invocation, text: text)
            if retry, !records.isEmpty { response.exitCode = 3 }
            return response
        case .conflicts(let name):
            let profile = try store.load(name), records = try open(profile, root: stateRoot).changesNeedingDecision()
            let text = records.map { record in
                let reason = record.state == "conflict" ? "changed-elsewhere" : "refused"
                return "\(reason)\t\(record.logicalSize)\t\(record.modifiedNanoseconds.map(isoDate) ?? "-")\t\(displayName(record.path))"
            }.joined(separator: "\n")
            return try render(records, invocation: invocation, text: text.isEmpty ? "No changes wait for a decision.\n" : text + "\n")
        case .resolve(let name, let path, let choice):
            let profile = try store.load(name), engine = try open(profile, root: stateRoot)
            let canonical = try canonicalPath(path)
            var result = ResolveResult(profile: name, path: canonical, resolution: "keep-theirs")
            let message: String
            switch choice {
            case .keepMine(let copy):
                let entry = try engine.keepMine(canonical, as: copy)
                // Upload now when storage answers; otherwise it waits like any new file.
                let uploaded = (try? engine.fsync(entry.path)) != nil
                result.resolution = "keep-mine"; result.copyPath = entry.path; result.uploaded = uploaded
                message = "Saved your copy as \(displayName(entry.path))" + (uploaded ? " and uploaded it" : "; it uploads with the next pass") + ".\n"
            case .keepTheirs:
                try engine.keepTheirs(canonical)
                message = "Discarded this Mac's copy of \(displayName(canonical)).\n"
            case .export(let file, let replace):
                let destination = URL(fileURLWithPath: absolutePath(file))
                try engine.exportChange(canonical, to: destination, replacing: replace)
                result.resolution = "export"; result.exportedTo = destination.path
                message = "Exported this Mac's copy to \(displayName(destination.path)) and removed it from the drive.\n"
            }
            return try render(result, invocation: invocation, text: message)
        case .mount(let name, let override, let wait):
            var profile = try store.load(name)
            guard !mounted(profile) else { throw DriveError(EBUSY, "This profile is already mounted; unmount it before choosing another mount point") }
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
                throw DriveError(ENOTSUP, "This Finder filesystem extension requires macOS 26 or later")
            }
            // Without a mount point, or under /Volumes (which only macOS can create folders in), the app mounts the drive
            // through FSKit at /Volumes/<profile>, as its own Connect button does. The app's own mount helper (this CLI,
            // run with PARAAIR_MOUNT_ROUTE=direct where FSKit's native mount isn't available) never asks the app back.
            let wanted = override.map(absolutePath) ?? profile.mountPoint
            if environment["PARAAIR_MOUNT_ROUTE"] != "direct", wanted == nil || wanted!.hasPrefix("/Volumes/") {
                return try mountThroughApp(profile, stateRoot: stateRoot, requested: wanted, waitSeconds: wait ?? 90, invocation: invocation)
            }
            guard let requested = wanted else { throw CLIUsageError(message: "Set --mount-point when connecting or mounting this profile") }
            let point = try prepareMountPoint(requested, stateRoot: stateRoot, profile: profile)
            let output = try SystemCommands.run(executable: "/sbin/mount", arguments: MountController.mountArguments(profile: name, stateRoot: stateRoot.path, mountPoint: point))
            guard output.exitCode == 0 else {
                throw DriveError(EIO, "macOS could not mount the profile (exit \(output.exitCode)). Install and enable the signed ParaAir filesystem extension, then run doctor.")
            }
            guard MountController.mountedVolumes().contains(where: { $0.mountPoint == point && $0.isStreamDrive }) else {
                throw DriveError(EIO, "macOS returned success, but the ParaAir mount could not be confirmed. Inspect the volume before retrying.")
            }
            profile.mountPoint = point
            try store.save(profile, overwrite: true)
            return try render(ProfileReference(profile: name, backend: profile.backend.rawValue, mountPoint: point, mounted: true), invocation: invocation, text: "Mounted '\(name)' at \(point).\n")
        case .unmount(let name):
            let profile = try store.load(name)
            let point = try mountedPoint(profile)
            try VolumeUnmount.unmount(point)
            guard !MountController.mountedVolumes().contains(where: { $0.mountPoint == point && $0.isStreamDrive }) else {
                throw DriveError(EBUSY, "The ParaAir volume is still mounted")
            }
            return try render(ProfileReference(profile: name, backend: profile.backend.rawValue, mountPoint: point, mounted: false), invocation: invocation, text: "Unmounted '\(name)'.\n")
        case .reveal(let name, let path):
            let profile = try store.load(name), point = try mountedPoint(profile), canonical = try canonicalPath(path)
            let target = canonical == "/" ? point : URL(fileURLWithPath: point).appendingPathComponent(String(canonical.dropFirst())).path
            let arguments = canonical == "/" ? [target] : ["-R", target]
            let output = try SystemCommands.run(executable: "/usr/bin/open", arguments: arguments)
            guard output.exitCode == 0 else { throw DriveError(EIO, "Finder could not reveal this path") }
            return try render(RevealResult(profile: name, path: canonical, localPath: target), invocation: invocation, text: "Opened in Finder: \(displayName(target)).\n")
        case .doctor(let name):
            return try doctor(name, store: store, invocation: invocation)
        }
    }

    private func open(_ profile: DriveProfile, root: URL) throws -> Engine { try Engine.open(profile: profile, stateRoot: root, dependencies: dependencies) }

    // MARK: Setup for other apps (setup-status, cloud-sign-in, cloud-drives, mount through the app)

    /// The installed ParaAir app, or exit 10.
    private func installedApp() throws -> (path: String, bundleID: String?) {
        let path = absolutePath(Self.applicationPath(environment: environment))
        guard let info = system.appInfo(path) else {
            throw CLIOutcomeError(outcome: .appNotInstalled, message: "ParaAir isn’t installed. Install it in Applications first")
        }
        return (path, info.bundleID)
    }

    /// State folders to look in: --state-dir alone when given (or STREAMDRIVE_HOME), otherwise the default folder plus
    /// every folder the installed app remembers (a ParaAir Cloud sign-in may have made one of its own).
    private func knownRoots(explicit: String?) -> [URL] {
        let base = ProfileStore.resolveRoot(explicit: explicit, environment: environment).standardizedFileURL
        guard explicit?.isEmpty != false, (environment["STREAMDRIVE_HOME"] ?? "").isEmpty else { return [base] }
        var roots = [base]
        let appPath = absolutePath(Self.applicationPath(environment: environment))
        let bundleID = system.appInfo(appPath)?.bundleID ?? ParaAirBundle.releaseApp
        for path in system.appStateFolders(bundleID) {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if !roots.contains(url), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { roots.append(url) }
        }
        return roots
    }

    private func accountItems(_ roots: [URL]) -> [SetupStatus.Account] {
        roots.flatMap { root -> [SetupStatus.Account] in
            let profiles = (try? ProfileStore(root: root).list()) ?? []
            return CloudAccountStore(root: root).list().accounts.map { account in
                let workspaces = profiles.filter { $0.cloudAccountID == account.id }.compactMap(\.cloudWorkspaceID)
                return SetupStatus.Account(id: account.id, email: account.email, issuer: account.issuer, state: account.state.rawValue,
                                           stateDirectory: root.path, workspaceIds: Array(Set(workspaces)).sorted())
            }
        }
    }
    private func signedInAccounts(_ roots: [URL]) -> [SetupStatus.Account] { accountItems(roots).filter { $0.state == CloudAccountState.signedIn.rawValue } }

    /// A signed-in account and its folder, or exit 11.
    private func signedInAccount(_ id: String, roots: [URL]) throws -> (root: URL, account: CloudAccount) {
        for root in roots {
            guard let account = try? CloudAccountStore(root: root).load(id) else { continue }
            guard account.state == .signedIn else {
                throw CLIOutcomeError(outcome: .notSignedIn, message: "Sign in to ParaAir Cloud again in the ParaAir app")
            }
            return (root, account)
        }
        throw CLIOutcomeError(outcome: .notSignedIn, message: "That ParaAir Cloud account isn’t signed in on this Mac (see setup-status)")
    }

    private func accountAPI(root: URL, accountID: String) throws -> ParaAirCloudAPI {
        let session = try ParaAirCloudSession.shared(root: root.standardizedFileURL.resolvingSymlinksInPath(), accountID: accountID,
                                                     vault: dependencies.cloudVault, configuration: dependencies.cloudConfiguration,
                                                     policy: dependencies.cloudPolicy, options: dependencies.cloudSessionOptions)
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }

    private func setupStatus(explicit: String?) -> SetupStatus {
        let appPath = absolutePath(Self.applicationPath(environment: environment))
        let info = system.appInfo(appPath)
        let app = SetupStatus.App(installed: info != nil, path: info == nil ? nil : appPath,
                                  running: info?.bundleID.map(system.isRunning) ?? false, version: info?.version, build: info?.build)
        let state = info == nil ? "notDiscovered" : system.extensionState(appPath, info?.bundleID)
        let roots = knownRoots(explicit: explicit)
        let profiles = roots.flatMap { root -> [SetupStatus.Profile] in
            ((try? ProfileStore(root: root).list()) ?? []).map { profile in
                let isMounted = mounted(profile)
                // Connectivity lives in the mounted drive's own process; a status read from here can't see it, so it is
                // not part of `healthy` (and not reported).
                let drive = try? open(profile, root: root).status()
                let healthy = isMounted && drive != nil && drive?.failingUploads == nil && drive?.ownedElsewhere == nil
                return SetupStatus.Profile(profile: profile.name, stateDirectory: root.path, backend: profile.backend.rawValue,
                                           cloudAccountId: profile.cloudAccountID, cloudDriveId: profile.cloudDriveID,
                                           workspaceId: profile.cloudWorkspaceID, mountPoint: profile.mountPoint, mounted: isMounted,
                                           healthy: healthy)
            }
        }
        return SetupStatus(app: app, extension: .init(state: state), accounts: accountItems(roots), profiles: profiles)
    }

    private func setupStatusText(_ value: SetupStatus) -> String {
        var lines = ["App: " + (value.app.installed ? "installed\(value.app.version.map { " " + $0 } ?? "")\(value.app.running ? ", running" : ", not running")" : "not installed"),
                     "File System Extension: \(value.extension.state)"]
        lines += value.accounts.map { "Account: \(displayName($0.email)) (\($0.state)) \($0.id)" }
        lines += value.profiles.map { "Drive: \($0.profile) \($0.mounted ? "mounted at " + displayName($0.mountPoint ?? "") : "not mounted")\($0.healthy ? ", healthy" : "")" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Asks the app to mount `profile` through FSKit (paraair://drive/mount), then waits for /Volumes/<Finder name>.
    private func mountThroughApp(_ profile: DriveProfile, stateRoot: URL, requested: String?, waitSeconds: Int,
                                 invocation: CLIInvocation) throws -> CLIExecution {
        let point = "/Volumes/" + profile.finderName
        if let requested, requested != point {
            throw CLIUsageError(message: "ParaAir mounts this drive at \(point); pass that or no --mount-point")
        }
        let app = try installedApp()
        let state = system.extensionState(app.path, app.bundleID)
        guard state != "disabled", state != "notDiscovered" else {
            throw CLIOutcomeError(outcome: .extensionDisabled,
                                  message: "Turn on ParaAir in System Settings → General → Login Items & Extensions → File System Extensions")
        }
        guard !system.mountedVolumes().contains(where: { $0.mountPoint == point }) else {
            throw DriveError(EBUSY, "Another volume is already mounted at \(point)")
        }
        try system.openURL(app.path, CLISystem.mountURL(profile: profile.name, stateDirectory: stateRoot.standardizedFileURL.path))
        // Done when a ParaAir volume is at the point and the app has saved that point to this drive's profile, which it
        // does only after checking the mounted volume serves this state folder. A volume that merely has the same name
        // (another folder's drive) never counts.
        let store = ProfileStore(root: stateRoot)
        let isUp = {
            guard (try? store.load(profile.name))?.mountPoint == point else { return false }
            return self.system.mountedVolumes().contains { $0.mountPoint == point && $0.isStreamDrive }
        }
        for _ in 0..<waitSeconds {
            if isUp() { break }
            system.sleep(1)
        }
        guard isUp() else {
            if system.extensionState(app.path, app.bundleID) == "disabled" {
                throw CLIOutcomeError(outcome: .extensionDisabled, message: "Turn on ParaAir in System Settings → General → Login Items & Extensions → File System Extensions")
            }
            throw DriveError(ETIMEDOUT, "ParaAir didn’t finish mounting '\(profile.name)' within \(waitSeconds) seconds. Open ParaAir to see why")
        }
        return try render(ProfileReference(profile: profile.name, backend: profile.backend.rawValue, mountPoint: point, mounted: true),
                          invocation: invocation, text: "Mounted '\(profile.name)' at \(point).\n")
    }
    private func cloudProfile(_ name: String, store: ProfileStore) throws -> DriveProfile {
        let profile = try store.load(name)
        guard profile.backend == .paraairCloud else { throw CLIUsageError(message: "trash and restore apply only to ParaAir Cloud profiles") }
        return profile
    }
    private func cloudAPI(_ profile: DriveProfile, root: URL) throws -> ParaAirCloudAPI {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try CloudAccountStore(root: root).load(profile.cloudAccountID!).issuer == profile.cloudIssuer else {
            throw DriveError(EXDEV, "This drive belongs to another ParaAir Cloud service")
        }
        let session = try ParaAirCloudSession.shared(root: root, accountID: profile.cloudAccountID!, vault: dependencies.cloudVault,
                                                     configuration: dependencies.cloudConfiguration, policy: dependencies.cloudPolicy,
                                                     options: dependencies.cloudSessionOptions)
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }
    private func selectedProfiles(_ name: String?, store: ProfileStore) throws -> [DriveProfile] { try name.map { [try store.load($0)] } ?? store.list() }
    private func mounted(_ profile: DriveProfile) -> Bool {
        guard let point = profile.mountPoint else { return false }
        return MountController.mountedVolumes().contains { $0.mountPoint == point && $0.isStreamDrive }
    }
    private func mountedPoint(_ profile: DriveProfile) throws -> String {
        guard let point = profile.mountPoint, mounted(profile) else { throw DriveError(ENODEV, "This profile is not mounted as a ParaAir volume") }
        return point
    }
    private func status(_ profile: DriveProfile, root: URL) throws -> ProfileStatus {
        ProfileStatus(profile: profile.name, backend: profile.backend.rawValue, mountPoint: profile.mountPoint,
                      mounted: mounted(profile), connectionState: "notProbed", drive: try open(profile, root: root).status())
    }
    private func statusText(_ value: ProfileStatus) -> String {
        "\(value.profile) (\(value.backend); \(value.mounted ? "mounted" : "unmounted"))\n" +
        "Cache: \(humanBytes(value.drive.cacheBytes)) / \(humanBytes(value.drive.cacheLimitBytes)); pins: \(humanBytes(value.drive.pinnedBytes)); pending writes: \(humanBytes(value.drive.pendingWriteBytes)).\n" +
        "App state: \(humanBytes(value.drive.stateBytes)); total local allocation: \(humanBytes(value.drive.totalAllocatedBytes)); available: \(humanBytes(value.drive.availableBytes)).\n" +
        "Uploads: \(value.drive.pendingUploads); conflicts: \(value.drive.conflictedUploads). Network connectivity was not probed.\n" +
        failingText(value.drive.failingUploads, cloud: value.backend == DriveBackendKind.paraairCloud.rawValue) +
        indexBackupText(value.drive.indexBackup) +
        (value.drive.ownedElsewhere.map { "Now used on \(displayName($0.ownerName ?? "another Mac")); read-only on this Mac.\n" } ?? "")
    }
    private func failingText(_ value: UploadFailureSummary?, cloud: Bool) -> String {
        guard let value else { return "" }
        let files = value.count == 1 ? "1 file" : "\(value.count) files"
        return "Couldn’t upload \(files): \(UploadFailureReason.text(value.errno, cloud: cloud)). "
            + "Oldest change: \(isoDate(value.oldestChangeNanoseconds)). ParaAir keeps retrying.\n"
    }
    private func isoDate(_ nanoseconds: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000))
    }
    /// Drives whose index lives on this Mac back it up into their own storage.
    private func indexBackupText(_ value: IndexBackupStatus?) -> String {
        guard let value else { return "" }
        let last = value.lastBackupNanoseconds.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000_000))
        } ?? "never"
        var text = "Index backup: \(last)"
        if value.pendingSinceNanoseconds != nil { text += "; newer changes pending" }
        if let error = value.lastError { text += "; last attempt failed: \(error)" }
        return text + ".\n"
    }

    private func prepareMountPoint(_ requested: String, stateRoot: URL, profile: DriveProfile) throws -> String {
        let point = absolutePath(requested), root = stateRoot.resolvingSymlinksInPath().path
        guard !pathsOverlap(point, root) else { throw DriveError(EINVAL, "Mount point and application state directory must not overlap") }
        if let fixture = profile.localRoot, pathsOverlap(point, fixture) { throw DriveError(EINVAL, "Mount point and fixture root must not overlap") }
        guard !MountController.mountedVolumes().contains(where: { $0.mountPoint == point }) else { throw DriveError(EBUSY, "The requested mount point already contains a mounted volume") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: point, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, try FileManager.default.contentsOfDirectory(atPath: point).isEmpty else {
                throw DriveError(ENOTEMPTY, "Mount point must be an empty directory so no existing files are hidden")
            }
        } else {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: point), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return point
    }

    private func doctor(_ name: String?, store: ProfileStore, invocation: CLIInvocation) throws -> CLIExecution {
        let appPath = absolutePath(Self.applicationPath(environment: environment))
        let extensionPath = appPath + "/Contents/Extensions/StreamDriveFS.appex"
        let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        var checks = [
            DoctorCheck(name: "macOS", state: supported ? "pass" : "fail", detail: "\(ProcessInfo.processInfo.operatingSystemVersionString); this Finder extension requires macOS 26+"),
            DoctorCheck(name: "filesystemExtension", state: FileManager.default.fileExists(atPath: extensionPath) ? "pass" : "fail", detail: "Expected signed filesystem extension in \(appPath)"),
            DoctorCheck(name: "extensionActivation", state: "unknown", detail: "Enable ParaAir in macOS File System Extensions settings. Activation is not inferred from bundle presence.")
        ]
        if FileManager.default.fileExists(atPath: appPath) {
            let signature = try? SystemCommands.run(executable: "/usr/bin/codesign", arguments: ["-d", "--verbose=2", appPath], timeout: 10)
            let details = (signature?.stdout ?? "") + (signature?.stderr ?? "")
            let signed = signature?.exitCode == 0 && details.contains("TeamIdentifier=") && !details.contains("TeamIdentifier=not set") && !details.contains("Signature=adhoc")
            checks.append(DoctorCheck(name: "distributionSignature", state: signed ? "pass" : "fail", detail: signed ? "A signing team is present; mounting still requires extension activation" : "Distribution signing is not verified. Ad-hoc builds require local extension approval."))
        }
        let profiles = try selectedProfiles(name, store: store)
        for profile in profiles {
            if profile.backend == .paraairCloud {
                checks.append(DoctorCheck(name: "profile:\(profile.name)", state: "pass",
                                          detail: "ParaAir Cloud drive \(profile.cloudDriveID ?? "") at \(profile.cloudIssuer ?? ""); service and Keychain access were not probed"))
                continue
            }
            let local = profile.backend == .local
            let exists = local ? profile.localRoot.map { FileManager.default.fileExists(atPath: $0) } ?? false : profile.libraryPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            checks.append(DoctorCheck(name: "profile:\(profile.name)", state: local && !exists ? "fail" : "pass", detail: local ? "Explicit local fixture; \(exists ? "root exists" : "root is missing")" : "Existing JuiceFS metadata reference; remote access and Keychain access were not probed"))
            if !local {
                checks.append(DoctorCheck(name: "library:\(profile.name)", state: exists ? "pass" : "unknown", detail: exists ? "Configured native library exists" : "Provide --library for the CLI or bundle libstreamdrive.dylib with the signed extension"))
            }
        }
        let value = DoctorResult(stateDirectory: store.root.path, profiles: profiles.map(\.name), checks: checks)
        let text = checks.map { "\($0.state)\t\($0.name)\t\($0.detail)" }.joined(separator: "\n") + "\n"
        var result = try render(value, invocation: invocation, text: text)
        if checks.contains(where: { $0.state == "fail" }) { result.exitCode = 1 }
        return result
    }

    /// Prefer the renamed app without losing existing installs or development overrides.
    static func applicationPath(environment: [String: String],
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        if let override = [environment["PARAAIR_APP_PATH"], environment["STREAMDRIVE_APP_PATH"]]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) { return override }
        let candidates = ["/Applications/ParaAir.app", homeDirectory.appendingPathComponent("Applications/ParaAir.app").path,
                          "/Applications/StreamDrive.app", homeDirectory.appendingPathComponent("Applications/StreamDrive.app").path]
        return candidates.first(where: fileExists) ?? candidates[0]
    }

    private func rejectStateInsideFixture(_ fixture: String, stateRoot: URL) throws {
        let root = stateRoot.resolvingSymlinksInPath().path
        guard root != fixture, !root.hasPrefix(fixture + "/") else {
            throw CLIUsageError(message: "Fixture root cannot contain the application's state directory")
        }
    }
    private func pathsOverlap(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    private func absolutePath(_ value: String) -> String { URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
    private func bytes(_ value: String?, default fallback: Int64) throws -> Int64 {
        guard let value else { return fallback }
        guard let integer = Int64(value), integer >= 0, integer <= Int64.max / 1_048_576 else { throw CLIUsageError(message: "MiB limits must be nonnegative bounded integers") }
        return integer * 1_048_576
    }
    private func humanBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private func displayName(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") }
    private func render<T: Encodable>(_ value: T, invocation: CLIInvocation, text: String) throws -> CLIExecution { success(invocation.json ? try json(value) : text) }
    private func success(_ text: String) -> CLIExecution { CLIExecution(stdout: text, stderr: "", exitCode: 0) }
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}

private struct Failure: Encodable { var error: String; var exitCode: Int32; var code: String }
private struct SignInStarted: Encodable { var opened: Bool }
private struct CloudDriveItem: Encodable { var id: String; var workspaceId: String; var name: String; var role: String; var writable: Bool }

/// `setup-status --json`: everything another app needs to walk a person through ParaAir setup. Read locally, no network.
struct SetupStatus: Encodable {
    struct App: Encodable { var installed: Bool; var path: String?; var running: Bool; var version: String?; var build: String? }
    struct Extension: Encodable { var state: String }
    struct Account: Encodable { var id: String; var email: String; var issuer: String; var state: String; var stateDirectory: String; var workspaceIds: [String] }
    struct Profile: Encodable {
        var profile: String; var stateDirectory: String; var backend: String
        var cloudAccountId: String?; var cloudDriveId: String?; var workspaceId: String?
        var mountPoint: String?; var mounted: Bool; var healthy: Bool
    }
    var app: App
    var `extension`: Extension
    var accounts: [Account]
    var profiles: [Profile]
}
private struct ProfileReference: Encodable { var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool }
private struct ProfileStatus: Encodable { var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool; var connectionState: String; var drive: DriveStatus }
private struct CacheResult: Encodable { var profile: String; var evictedBytes: Int64; var drive: DriveStatus }
private struct PinResult: Encodable { var profile: String; var path: String; var pinned: Bool; var drive: DriveStatus }
private struct RevealResult: Encodable { var profile: String; var path: String; var localPath: String }
private struct ResolveResult: Encodable {
    var profile: String; var path: String; var resolution: String
    var copyPath: String?; var uploaded: Bool?; var exportedTo: String?
}
private struct DoctorCheck: Encodable { var name: String; var state: String; var detail: String }
private struct DoctorResult: Encodable { var stateDirectory: String; var profiles: [String]; var checks: [DoctorCheck] }
