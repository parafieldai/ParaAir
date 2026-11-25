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
    /// Standard output for commands that stream (cat-version's bytes, changes' lines) instead of returning their output.
    private let output: (Data) throws -> Void
    /// Tests stop `changes --follow` after this many polls; nil follows until the process ends.
    var maxFollowPolls: Int?
    /// Where "Cloud Drives" is (connect --new-state-folder, and the folders setup-status looks in); tests replace it.
    private let home: URL
    init(environment: [String: String] = ProcessInfo.processInfo.environment, dependencies: EngineOpenDependencies = .live,
         system: CLISystem = .live, output: @escaping (Data) throws -> Void = CLIApplication.writeStandardOutput,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment; self.dependencies = dependencies; self.system = system; self.output = output; self.home = home
    }

    /// Writes all of `data` to file descriptor 1, unbuffered, so each line of a followed feed reaches the reader at once.
    static func writeStandardOutput(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if count < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Couldn’t write to standard output") }
                written += count
            }
        }
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
        case .extensionSettings(let wait):
            let app = try installedApp()
            let enabled = ExtensionSettingsResult(state: "enabled", opened: false)
            if system.extensionState(app.path, app.bundleID) == "enabled" {
                return try render(enabled, invocation: invocation, text: "ParaAir’s File System Extension is on.\n")
            }
            try system.openExtensionSettings()
            guard let wait else {
                let state = system.extensionState(app.path, app.bundleID)
                return try render(ExtensionSettingsResult(state: state, opened: true), invocation: invocation,
                                  text: "Opened System Settings. \(ExtensionSetupGuidance.turnOn)\n")
            }
            // Elapsed seconds, not polls: a slow FSKit answer (up to 5 s each) must not stretch the wait.
            let deadline = system.now().addingTimeInterval(TimeInterval(wait))
            while system.now() < deadline {
                system.sleep(1)
                if system.extensionState(app.path, app.bundleID) == "enabled" {
                    return try render(ExtensionSettingsResult(state: "enabled", opened: true), invocation: invocation,
                                      text: "ParaAir’s File System Extension is on.\n")
                }
            }
            throw CLIOutcomeError(outcome: .extensionDisabled,
                                  message: "ParaAir wasn’t turned on within \(wait) seconds. \(ExtensionSetupGuidance.turnOn)")
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
            (try? open(profile, root: stateRoot))?.changedOutsideMount(entry.path, mountPoint: profile.mountPoint)
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
            let accountID = values["cloud-account"]!
            // With --new-state-folder the account may be signed in in any folder ParaAir knows; the drive gets its own.
            var accountRoot = stateRoot, targetRoot = stateRoot, sharing: CloudAccount?
            if arguments.newStateFolder {
                let found = try signedInAccount(accountID, roots: [stateRoot.standardizedFileURL] + knownRoots(explicit: nil))
                accountRoot = found.root; sharing = found.account
                for root in knownRoots(explicit: nil) + [stateRoot.standardizedFileURL] {
                    if let other = (try? ProfileStore(root: root).list())?.first(where: { $0.name == arguments.profile }) {
                        throw DriveError(EEXIST, "A drive named '\(other.name)' is already saved in \(root.path); it would mount at the same place. Choose another name")
                    }
                }
            }
            let drive: String
            if let wanted = values["cloud-drive-name"] {
                _ = try signedInAccount(accountID, roots: [accountRoot])
                let name = wanted.precomposedStringWithCanonicalMapping
                let matches = try accountAPI(root: accountRoot, accountID: accountID).drives().filter { $0.name.precomposedStringWithCanonicalMapping == name }
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
            if let sharing { targetRoot = try CloudDriveSetup.newStateRoot(sharing: sharing, vault: dependencies.cloudVault, home: home) }
            let targetStore = ProfileStore(root: targetRoot)
            var profile: DriveProfile
            do {
                profile = try CloudDriveSetup.attach(driveID: drive, finderName: arguments.profile, name: arguments.profile,
                                                     accountID: accountID, stateRoot: targetRoot,
                                                     replace: arguments.overwrite, dependencies: dependencies)
            } catch {
                // Only the folder this command just made goes; it holds nothing but the account record.
                if sharing != nil { try? FileManager.default.removeItem(at: targetRoot) }
                throw error
            }
            if values["cache-mib"] != nil || values["min-free-mib"] != nil || values["journal-mib"] != nil || values["mount-point"] != nil
                || arguments.conflictCopies {
                if arguments.conflictCopies { profile.conflictCopies = true }
                profile.cacheLimitBytes = try bytes(values["cache-mib"], default: profile.cacheLimitBytes)
                profile.minFreeBytes = try bytes(values["min-free-mib"], default: profile.minFreeBytes)
                profile.maxJournalBytes = try bytes(values["journal-mib"], default: profile.maxJournalBytes)
                profile.mountPoint = values["mount-point"].map(absolutePath) ?? profile.mountPoint
                try targetStore.save(profile, overwrite: true)
            }
            let response = ProfileReference(profile: profile.name, backend: profile.backend.rawValue, mountPoint: profile.mountPoint, mounted: false,
                                            stateDirectory: targetRoot.standardizedFileURL.path)
            return try render(response, invocation: invocation, text: "Saved ParaAir Cloud profile '\(profile.name)' in \(displayName(targetRoot.path)). "
                              + "Run ls to browse it, then mount to open it in Finder\(sharing == nil ? "" : " (pass --state-dir \(displayName(targetRoot.path)))").\n")
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
            if arguments.conflictCopies { profile.conflictCopies = true }
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
            // The file under the mounted drive changed without the drive's extension doing it.
            engine.changedOutsideMount(canonical, mountPoint: profile.mountPoint)
            return try render(result, invocation: invocation, text: message)
        case .settings(let name, let conflictCopies):
            var profile = try store.load(name)
            if let conflictCopies, conflictCopies != (profile.conflictCopies ?? false) {
                profile.conflictCopies = conflictCopies
                try store.save(profile, overwrite: true)
            }
            let isMounted = mounted(profile)
            let value = SettingsResult(profile: name, conflictCopies: profile.conflictCopies ?? false, mounted: isMounted,
                                       appliesAtNextMount: conflictCopies != nil && isMounted)
            return try render(value, invocation: invocation, text: "Conflict copies: \(value.conflictCopies ? "on" : "off")."
                              + (value.appliesAtNextMount ? " The mounted drive keeps its setting until it is mounted again." : "") + "\n")
        case .versions(let target, let before, let limit):
            let resolved = try resolve(target, invocation: invocation)
            let page = try collaboration {
                try cloudAPI(cloudOnly(resolved.profile), root: resolved.root)
                    .versions(driveID: resolved.profile.cloudDriveID!, path: resolved.path, before: before, limit: limit ?? 100)
            }
            var text = page.versions.map { version in
                "\(version.version)\t\(version.size)\t\(version.createdAt)\t\(displayName(version.author.email ?? version.author.name ?? "-"))\(version.current ? "\tcurrent" : "")"
            }.joined(separator: "\n")
            text = text.isEmpty ? "No versions kept.\n" : text + "\n"
            if let next = page.nextBefore { text += "More: --before \(next)\n" }
            return try render(page, invocation: invocation, text: text)
        case .catVersion(let target, let version):
            let resolved = try resolve(target, invocation: invocation)
            let profile = try cloudOnly(resolved.profile)
            try collaboration {
                // The version must be one of this file's: the newest version below version + 1 is that version or none.
                let number = Int64(version.dropFirst(3))!
                let page = try cloudAPI(profile, root: resolved.root).versions(driveID: profile.cloudDriveID!, path: resolved.path, before: number + 1, limit: 1)
                guard let found = page.versions.first, found.version == version else {
                    throw CLIOutcomeError(outcome: .notFound, message: "\(version) isn’t a kept version of \(displayName(resolved.path)) (see versions)")
                }
                let engine = try open(profile, root: resolved.root)
                var offset: Int64 = 0
                while offset < found.size {
                    let piece = try engine.readVersion(resolved.path, version: version, offset: offset, length: Int(min(found.size - offset, 8 << 20)))
                    guard !piece.isEmpty else { throw DriveError(EIO, "The version is shorter than its history says") }
                    try output(piece)
                    offset += Int64(piece.count)
                }
            }
            return CLIExecution(stdout: "", stderr: "", exitCode: 0)
        case .restoreVersion(let target, let version, let expected):
            let resolved = try resolve(target, invocation: invocation)
            let profile = try cloudOnly(resolved.profile)
            let entry = try collaboration {
                try cloudAPI(profile, root: resolved.root).restoreVersion(driveID: profile.cloudDriveID!, path: resolved.path, version: version,
                                                                         expectedVersion: expected, idempotencyKey: UUID())
            }
            // This Mac shows the restored contents at once, also through its mounted drive; other Macs learn of it
            // from the change feed.
            (try? open(profile, root: resolved.root))?.changedOutsideMount(resolved.path, mountPoint: profile.mountPoint)
            let value = RestoreVersionResult(path: entry.path, restoredVersion: version, version: entry.version, size: entry.size)
            return try render(value, invocation: invocation, text: "Restored \(version) of \(displayName(entry.path)) as \(entry.version).\n")
        case .conflictInfo(let target):
            let resolved = try resolve(target, invocation: invocation)
            let info = try collaboration { try open(resolved.profile, root: resolved.root).conflictCopyInfo(resolved.path) }
            guard let info else {
                throw CLIOutcomeError(outcome: .notFound, message: "\(displayName(resolved.path)) isn’t a known conflict copy")
            }
            return try render(info, invocation: invocation,
                              text: "Copy of \(displayName(info.original)): based on \(info.baseVersion ?? "a new file"), lost to \(info.theirsVersion ?? "an unknown version").\n")
        case .changes(let target, let follow, let since, let interval, let push):
            let resolved = try resolve(target, invocation: invocation)
            return try changes(resolved, follow: follow, since: since, interval: interval ?? 3, push: push, json: invocation.json)
        case .access(let action, let target):
            let resolved = try resolve(target, invocation: invocation)
            let profile = try cloudOnly(resolved.profile)
            let api = try cloudAPI(profile, root: resolved.root), drive = profile.cloudDriveID!, folder = resolved.path
            switch action {
            case .list:
                // Rules on the folder, around it and inside it: everything that decides access there.
                let rules = try api.accessRules(driveID: drive).filter { folder == "/" || within($0.path, folder) || within(folder, $0.path) }
                let text = rules.map { "\($0.path)\t\(principalText($0))\t\($0.access)" }.joined(separator: "\n")
                return try render(AccessList(path: folder, rules: rules), invocation: invocation, text: text.isEmpty ? "No folder rules.\n" : text + "\n")
            case .set(let principal, let level):
                let rule = try api.setAccess(driveID: drive, principal: principal, path: folder, access: level)
                return try render(AccessSet(rule: rule), invocation: invocation, text: "\(principalText(rule)) now has \(rule.access) access at \(displayName(rule.path)).\n")
            case .remove(let principal):
                try api.removeAccess(driveID: drive, principal: principal, path: folder)
                let field = principalField(principal)
                return try render(AccessRemoved(path: folder, principal: [field.name: field.value], removed: true), invocation: invocation,
                                  text: "Removed the rule for \(displayName(field.value)) at \(displayName(folder)).\n")
            }
        case .credentials(let action, let accountID, let workspace):
            let found = try signedInAccount(accountID, roots: knownRoots(explicit: invocation.stateDirectory))
            let api = try accountAPI(root: found.root, accountID: accountID)
            switch action {
            case .create(let name):
                // The token goes to standard output once, in this reply only; nothing here keeps or logs it.
                let created = try credentialCall { try api.createCredential(workspaceID: workspace, name: name) }
                let id = created.credential.id
                let text = "Created service credential \(id) (\(displayName(created.credential.name))) in \(workspace).\n"
                    + "Its token is the next line. Store it now in the backend's secret store: it can't be shown again and ParaAir keeps no copy.\n"
                    + created.token + "\n"
                    + "It sees nothing yet. Give it one folder, for example:\n"
                    + "  paraair access set PROFILE /admin/finance --credential \(id) --level write\n"
                return try render(CredentialCreated(workspaceId: workspace, credential: created.credential, token: created.token),
                                  invocation: invocation, text: text)
            case .list:
                let credentials = try credentialCall { try api.credentials(workspaceID: workspace) }
                let text = credentials.map { credential in
                    let state = credential.revokedAt.map { "revoked " + $0 } ?? "active"
                    return "\(credential.id)\t\(state)\t\(credential.lastUsedAt.map { "last used " + $0 } ?? "never used")\t\(displayName(credential.name))"
                }.joined(separator: "\n")
                return try render(CredentialList(workspaceId: workspace, credentials: credentials), invocation: invocation,
                                  text: text.isEmpty ? "This workspace has no service credentials.\n" : text + "\n")
            case .revoke(let id):
                try credentialCall { try api.revokeCredential(workspaceID: workspace, credentialID: id) }
                return try render(CredentialRevoked(workspaceId: workspace, id: id, revoked: true), invocation: invocation,
                                  text: "Revoked \(id). Its token no longer works and its folder rules are deleted.\n")
            }
        case .members(let action, let accountID, let workspaceID):
            let found = try signedInAccount(accountID, roots: knownRoots(explicit: invocation.stateDirectory))
            return try members(action, workspaceID: workspaceID, api: accountAPI(root: found.root, accountID: accountID), invocation: invocation)
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
        // The app's folders, then those under "Cloud Drives" it hasn't learned yet (connect --new-state-folder).
        let cloudDrives = (try? FileManager.default.contentsOfDirectory(at: CloudDriveSetup.cloudDrivesFolder(home: home), includingPropertiesForKeys: nil)) ?? []
        for url in system.appStateFolders(bundleID).map({ URL(fileURLWithPath: $0, isDirectory: true) })
            + cloudDrives.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let url = url.standardizedFileURL
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
        let appFolders = Set(system.appStateFolders(info?.bundleID ?? ParaAirBundle.releaseApp).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path })
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
                                           healthy: healthy, conflictCopies: profile.conflictCopies ?? false,
                                           knownToApp: appFolders.contains(root.standardizedFileURL.path))
            }
        }
        let others = info == nil ? [] : system.otherAppCopies(appPath, info?.bundleID)
        return SetupStatus(app: app, extension: .init(state: state, otherCopies: others), accounts: accountItems(roots), profiles: profiles)
    }

    private func setupStatusText(_ value: SetupStatus) -> String {
        var lines = ["App: " + (value.app.installed ? "installed\(value.app.version.map { " " + $0 } ?? "")\(value.app.running ? ", running" : ", not running")" : "not installed"),
                     "File System Extension: \(value.extension.state)"]
        if value.app.installed, value.extension.state != "enabled" { lines.append("  " + ExtensionSetupGuidance.turnOn) }
        lines += value.extension.otherCopies.map { "Other copy of ParaAir: \(displayName($0)) (keep only the one in Applications)" }
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
                                  message: ExtensionSetupGuidance.turnOn)
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
                throw CLIOutcomeError(outcome: .extensionDisabled, message: ExtensionSetupGuidance.turnOn)
            }
            throw DriveError(ETIMEDOUT, "ParaAir didn’t finish mounting '\(profile.name)' within \(waitSeconds) seconds. Open ParaAir to see why")
        }
        return try render(ProfileReference(profile: profile.name, backend: profile.backend.rawValue, mountPoint: point, mounted: true),
                          invocation: invocation, text: "Mounted '\(profile.name)' at \(point).\n")
    }
    // MARK: Shared editing (versions, change feed, conflict copies, folder rules)

    private struct ResolvedTarget { var profile: DriveProfile; var root: URL; var path: String }

    /// The profile, state folder and drive path a target names. A mounted path picks the mounted ParaAir drive that
    /// contains it, then the profile mounted there in the known state folders (or, failing that, the profile named
    /// like the volume, as the app mounts drives at /Volumes/<Finder name>).
    private func resolve(_ target: CLITarget, invocation: CLIInvocation) throws -> ResolvedTarget {
        switch target {
        case .drive(let name, let path):
            let root = ProfileStore.resolveRoot(explicit: invocation.stateDirectory, environment: environment)
            return ResolvedTarget(profile: try ProfileStore(root: root).load(name), root: root, path: try canonicalPath(path))
        case .mounted(let value):
            let full = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
            let volume = system.mountedVolumes().filter { $0.isStreamDrive && (full == $0.mountPoint || full.hasPrefix($0.mountPoint + "/")) }
                .max { $0.mountPoint.utf8.count < $1.mountPoint.utf8.count }
            guard let volume else {
                throw CLIOutcomeError(outcome: .notMounted, message: "\(displayName(value)) isn’t on a mounted ParaAir drive")
            }
            let candidates = knownRoots(explicit: invocation.stateDirectory).flatMap { root in
                ((try? ProfileStore(root: root).list()) ?? []).map { (root: root, profile: $0) }
            }
            let volumeName = (volume.mountPoint as NSString).lastPathComponent
            guard let found = candidates.first(where: { $0.profile.mountPoint == volume.mountPoint })
                    ?? candidates.first(where: { ($0.profile.finderName == volumeName || $0.profile.name == volumeName) && $0.profile.mountPoint == nil }) else {
                throw CLIOutcomeError(outcome: .notMounted, message: "No ParaAir profile in the known state folders is mounted at \(displayName(volume.mountPoint)); pass --state-dir")
            }
            let rest = String(full.dropFirst(volume.mountPoint.count))
            return ResolvedTarget(profile: found.profile, root: found.root, path: try canonicalPath(rest.isEmpty ? "/" : rest))
        }
    }

    private func cloudOnly(_ profile: DriveProfile) throws -> DriveProfile {
        guard profile.backend == .paraairCloud else { throw CLIUsageError(message: "Only ParaAir Cloud drives keep versions, a change feed and folder rules") }
        return profile
    }

    /// Version conflicts and missing files, versions or copies get exit codes of their own here.
    private func collaboration<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as DriveError where error.code == ESTALE { throw CLIOutcomeError(outcome: .versionConflict, message: error.message) }
        catch let error as DriveError where error.code == ENOENT { throw CLIOutcomeError(outcome: .notFound, message: error.message) }
    }

    /// `changes`: with --json one JSON object per line, as the service sends each change; a `reset` line when changes
    /// were pruned (rescan, then follow on); with --follow, first a `following` line with the cursor it starts from.
    /// Each page's paths are dropped from this Mac's caches first, so reading them through the mount right after a line
    /// gets the new contents. Only changes at or under the target's folder are printed. With --push, a followed feed
    /// waits for the drive's change stream to tell of a new cursor instead of polling, and polls every `interval`
    /// seconds only while the stream is down (ChangeNotices).
    private func changes(_ resolved: ResolvedTarget, follow: Bool, since: Int64?, interval: Int, push: Bool, json: Bool) throws -> CLIExecution {
        // A follower outlives whoever started it if that process quits or crashes (it is reparented to launchd) and
        // would only notice at its next line. The parent is taken first, before opening the drive or asking for a
        // cursor, so a launcher that dies meanwhile is still noticed; a reader already gone means nothing to do.
        let parent = system.parentProcess()
        guard follow else {
            return try changesFeed(resolved, follow: false, since: since, interval: interval, push: false, json: json, parent: parent)
        }
        system.ignoreBrokenPipe()
        if system.outputClosed() { return CLIExecution(stdout: "", stderr: "", exitCode: 0) }
        do { return try changesFeed(resolved, follow: true, since: since, interval: interval, push: push, json: json, parent: parent) }
        catch let error as DriveError where error.code == EPIPE {
            // The reader closed between the check and a write: that is the end of following, not a failure.
            return CLIExecution(stdout: "", stderr: "", exitCode: 0)
        }
    }
    private func changesFeed(_ resolved: ResolvedTarget, follow: Bool, since: Int64?, interval: Int, push: Bool, json: Bool,
                             parent: pid_t) throws -> CLIExecution {
        let engine = try open(cloudOnly(resolved.profile), root: resolved.root), folder = resolved.path
        let notices = follow && push ? ChangeNotices(open: { try engine.changeStream($0) }) : nil
        defer { notices?.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func emit<T: Encodable>(_ value: T, text: String) throws {
            try output(json ? try encoder.encode(value) + Data("\n".utf8) : Data((text + "\n").utf8))
        }
        func shows(_ change: ParaAirCloudChange) -> Bool {
            folder == "/" || within(change.path, folder) || change.fromPath.map { within($0, folder) } ?? false
        }
        var cursor: Int64
        if let since { cursor = since }
        else {
            cursor = try engine.readChanges(since: nil).cursor
            if !follow {
                try emit(FeedCursor(cursor: cursor), text: "Cursor \(cursor). Pass --since \(cursor) later to see what changed after now.")
                return CLIExecution(stdout: "", stderr: "", exitCode: 0)
            }
        }
        if follow { try emit(FeedStart(following: true, cursor: cursor), text: "Following changes from cursor \(cursor).") }
        var polls = 0, failures = 0
        while true {
            // Stop as soon as the parent changes or nobody reads the output.
            if follow, system.parentProcess() != parent || system.outputClosed() {
                return CLIExecution(stdout: "", stderr: "", exitCode: 0)
            }
            let page: ParaAirCloudChangePage, folders: [String]
            notices?.pulling()
            do { (page, folders) = try engine.readChangesAndFolders(since: cursor) ; failures = 0 }
            catch let error as DriveError where follow && Self.passing(error) {
                // Offline or the service is busy: keep following, waiting longer each time, up to a minute.
                failures += 1
                system.sleep(TimeInterval(min(60, interval << min(failures, 5))))
                continue
            }
            refreshMounted(folders, engine: engine, profile: resolved.profile)
            if page.reset { try emit(FeedReset(reset: true, cursor: page.cursor), text: "Changes were pruned: rescan, then follow from cursor \(page.cursor).") }
            for change in page.changes where shows(change) {
                try emit(change, text: "\(change.cursor)\t\(change.change)\t\(change.kind)\t\(displayName(change.fromPath.map { $0 + " -> " } ?? ""))\(displayName(change.path))")
            }
            cursor = page.cursor
            if page.more { continue }
            guard follow else { return CLIExecution(stdout: "", stderr: "", exitCode: 0) }
            polls += 1
            if let limit = maxFollowPolls, polls >= limit { return CLIExecution(stdout: "", stderr: "", exitCode: 0) }
            if let notices {
                // A healthy stream on a quiet drive means no poll for minutes: check for a gone parent or reader
                // at least every `interval` seconds while waiting too (the check at the top of the loop then ends it).
                notices.wait(after: cursor, poll: TimeInterval(interval), gone: { self.system.parentProcess() != parent || self.system.outputClosed() })
            } else {
                system.sleep(TimeInterval(interval))
            }
        }
    }

    /// Failures a followed feed waits out: no connection, timeouts and the service being briefly unavailable.
    private static func passing(_ error: DriveError) -> Bool {
        [EIO, EAGAIN, EBUSY, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNRESET, ECONNREFUSED, ETIMEDOUT, ENOTCONN].contains(error.code)
    }

    /// A credential the workspace doesn't have is exit 17; a workspace the account isn't in stays 14, as for drives.
    private func credentialCall<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as DriveError where error.code == ENOENT && ParaAirCloudOutcome.of(error) == nil {
            throw CLIOutcomeError(outcome: .notFound, message: error.message)
        }
    }

    private func within(_ path: String, _ folder: String) -> Bool { folder == "/" || path == folder || path.hasPrefix(folder + "/") }
    private func principalText(_ rule: ParaAirCloudAccessRule) -> String {
        if let role = rule.role { return "role:" + role }
        if let credential = rule.credential { return "credential:" + credential + (rule.name.map { " (\(displayName($0)))" } ?? "") }
        return displayName(rule.email ?? rule.userId ?? "-")
    }
    private func principalField(_ principal: ParaAirCloudAccessPrincipal) -> (name: String, value: String) {
        switch principal {
        case .email(let value): return ("email", value)
        case .role(let value): return ("role", value)
        case .credential(let value): return ("credential", value)
        }
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
    /// On a mounted drive, makes what a page of changes names safe to read through the mount before the page is
    /// reported: creates and removes the refresh marker in each folder it named, as the app does, then waits (up to
    /// 3 s) for the drive's extension to drop the kernel's caches for what changed there. Without that, a reader who
    /// acts on a line at once could get a file's new bytes cut to its old size until the app's own feed catches up.
    private func refreshMounted(_ folders: [String], engine: Engine, profile: DriveProfile) {
        guard !folders.isEmpty, let point = profile.mountPoint,
              system.mountedVolumes().contains(where: { $0.mountPoint == point && $0.isStreamDrive }) else { return }
        // The extension records its refresh in wall-clock time. At most 60 waits of 50 ms.
        let since = Date()
        let touched = folders.filter { system.refreshFolder($0, point) }
        guard !touched.isEmpty else { return }
        for _ in 0..<60 {
            if touched.allSatisfy({ (try? engine.folderRefreshed($0, since: since)) ?? true }) { return }
            system.sleep(0.05)
        }
    }
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
    /// `members`: a workspace's members, managed by its owners and admins with their own sign-in (cloud README, "Members").
    /// role and remove find the member by email in the list first, since the service names members by user id.
    private func members(_ action: CLIMembersAction, workspaceID: String, api: ParaAirCloudAPI, invocation: CLIInvocation) throws -> CLIExecution {
        func member(_ email: String) throws -> ParaAirCloudWorkspaceMember {
            let wanted = email.trimmingCharacters(in: .whitespaces).lowercased()
            guard let found = try api.members(workspaceID: workspaceID).members.first(where: { $0.email.lowercased() == wanted }) else {
                throw CLIOutcomeError(outcome: .notFound, message: "\(displayName(email)) isn’t a member of this workspace (see members list)")
            }
            return found
        }
        /// A member who left between the list and the change is "not found" too. Outcomes the cloud errors already name
        /// (a workspace the account is no longer in: 14) keep their exit code.
        func change<T>(_ body: () throws -> T) throws -> T {
            do { return try body() }
            catch let error as DriveError where error.code == ENOENT && ParaAirCloudOutcome.of(error) == nil {
                throw CLIOutcomeError(outcome: .notFound, message: error.message)
            }
        }
        switch action {
        case .list:
            let list = try api.members(workspaceID: workspaceID)
            let rows = list.members.map { "\($0.userId)\t\($0.role)\t\($0.status)\t\(displayName($0.email))" }
            let seats = "\(displayName(list.workspace.name)): \(list.workspace.seatsUsed) of \(list.workspace.seats) seat\(list.workspace.seats == 1 ? "" : "s") used\n"
            return try render(list, invocation: invocation, text: seats + rows.map { $0 + "\n" }.joined())
        case .add(let email, let role, let notify):
            // notified is the service's word: an older service ignores notify and emails nothing.
            let result = try api.addMember(workspaceID: workspaceID, email: email, role: role, notify: notify)
            let name = displayName(result.member.email)
            let mail = result.notified ? " ParaAir emailed them how to start."
                : " Nothing was emailed: tell them to sign in to ParaAir with this address."
            let text = result.added ? "Added \(name) as \(result.member.role).\(mail)\n"
                : "\(name) is already a member (\(result.member.role)).\(result.notified ? mail : "")\n"
            return try render(result, invocation: invocation, text: text)
        case .role(let email, let role):
            let target = try member(email)
            let updated = try change { try api.setMemberRole(workspaceID: workspaceID, userID: target.userId, role: role) }
            return try render(MemberChanged(member: updated), invocation: invocation, text: "\(displayName(updated.email)) is now \(updated.role).\n")
        case .remove(let email):
            let target = try member(email)
            try change { try api.removeMember(workspaceID: workspaceID, userID: target.userId) }
            return try render(MemberRemoved(userId: target.userId, email: target.email, removed: true), invocation: invocation,
                              text: "Removed \(displayName(target.email)) from the workspace.\n")
        }
    }

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
    /// The published CLI contract this build follows (contract/paraair-cli-v1). Within a version only fields, commands
    /// and codes are added; a rename or removal is a new version. Integrations gate on this, not on the app's build.
    static let currentContractVersion = 1
    var contractVersion = SetupStatus.currentContractVersion
    /// Additions within the contract version that an integration may want to check before using them (open set):
    /// `changes.push`, `changes --follow --push`.
    static let currentCapabilities = ["changes.push"]
    var capabilities = SetupStatus.currentCapabilities
    struct App: Encodable { var installed: Bool; var path: String?; var running: Bool; var version: String?; var build: String? }
    /// `otherCopies`: other registered copies of the app that still exist. macOS can pick the wrong copy's extension,
    /// so a setup guide asks the person to keep only the installed one.
    struct Extension: Encodable { var state: String; var otherCopies: [String] = [] }
    struct Account: Encodable { var id: String; var email: String; var issuer: String; var state: String; var stateDirectory: String; var workspaceIds: [String] }
    struct Profile: Encodable {
        var profile: String; var stateDirectory: String; var backend: String
        var cloudAccountId: String?; var cloudDriveId: String?; var workspaceId: String?
        var mountPoint: String?; var mounted: Bool; var healthy: Bool
        var conflictCopies: Bool
        /// Whether the app has learned this state folder (it mounts its drive at login); a mount request teaches it.
        var knownToApp: Bool
    }
    var app: App
    var `extension`: Extension
    var accounts: [Account]
    var profiles: [Profile]
}
private struct ProfileReference: Encodable {
    var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool
    /// The state folder, for a drive attached in one of its own (connect --new-state-folder).
    var stateDirectory: String? = nil
}
private struct ProfileStatus: Encodable { var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool; var connectionState: String; var drive: DriveStatus }
private struct CacheResult: Encodable { var profile: String; var evictedBytes: Int64; var drive: DriveStatus }
private struct PinResult: Encodable { var profile: String; var path: String; var pinned: Bool; var drive: DriveStatus }
private struct RevealResult: Encodable { var profile: String; var path: String; var localPath: String }
private struct ResolveResult: Encodable {
    var profile: String; var path: String; var resolution: String
    var copyPath: String?; var uploaded: Bool?; var exportedTo: String?
}
private struct SettingsResult: Encodable { var profile: String; var conflictCopies: Bool; var mounted: Bool; var appliesAtNextMount: Bool }
private struct RestoreVersionResult: Encodable { var path: String; var restoredVersion: String; var version: String; var size: Int64 }
private struct AccessList: Encodable { var path: String; var rules: [ParaAirCloudAccessRule] }
private struct AccessSet: Encodable { var rule: ParaAirCloudAccessRule }
private struct AccessRemoved: Encodable { var path: String; var principal: [String: String]; var removed: Bool }
private struct CredentialCreated: Encodable { var workspaceId: String; var credential: ParaAirCloudServiceCredential; var token: String }
private struct CredentialList: Encodable { var workspaceId: String; var credentials: [ParaAirCloudServiceCredential] }
private struct CredentialRevoked: Encodable { var workspaceId: String; var id: String; var revoked: Bool }
private struct MemberChanged: Encodable { var member: ParaAirCloudWorkspaceMember }
private struct MemberRemoved: Encodable { var userId: String; var email: String; var removed: Bool }
private struct FeedCursor: Encodable { var cursor: Int64 }
/// `extension-settings`: the extension's state afterwards, and whether System Settings was opened.
private struct ExtensionSettingsResult: Encodable { var state: String; var opened: Bool }
private struct FeedStart: Encodable { var following: Bool; var cursor: Int64 }
private struct FeedReset: Encodable { var reset: Bool; var cursor: Int64 }
private struct DoctorCheck: Encodable { var name: String; var state: String; var detail: String }
private struct DoctorResult: Encodable { var stateDirectory: String; var profiles: [String]; var checks: [DoctorCheck] }
