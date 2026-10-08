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
    init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }
    func run(_ arguments: [String]) -> CLIExecution {
        do { return try execute(CLIParser.parse(arguments)) }
        catch {
            let code: Int32 = error is CLIUsageError ? 2 : 1
            let message = error.localizedDescription
            if arguments.contains("--json") {
                let result = Failure(error: message, exitCode: code)
                return CLIExecution(stdout: (try? json(result)) ?? "{\"error\":\"Operation failed\"}\n", stderr: "", exitCode: code)
            }
            return CLIExecution(stdout: "", stderr: "paraair: \(message)\n", exitCode: code)
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
            let profile = DriveProfile(
                name: arguments.profile, backend: fixture == nil ? .juicefs : .local,
                metadataURL: values["metadata-url"], localRoot: fixture,
                libraryPath: values["library"].map(absolutePath), mountPoint: values["mount-point"].map(absolutePath),
                cacheLimitBytes: try bytes(values["cache-mib"], default: 1_073_741_824),
                minFreeBytes: try bytes(values["min-free-mib"], default: 5_368_709_120),
                blockSize: values["block-size"].flatMap(Int.init) ?? 1_048_576,
                maxJournalBytes: try bytes(values["journal-mib"], default: 4_294_967_296),
                credentialID: values["credential-id"], connectionID: values["connection"]
            )
            if arguments.overwrite, let previous = try? store.load(arguments.profile), mounted(previous) {
                throw DriveError(EBUSY, "Unmount the profile before replacing its configuration")
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
        case .mount(let name, let override):
            var profile = try store.load(name)
            guard !mounted(profile) else { throw DriveError(EBUSY, "This profile is already mounted; unmount it before choosing another mount point") }
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
                throw DriveError(ENOTSUP, "This Finder filesystem extension requires macOS 26 or later")
            }
            guard let requested = override.map(absolutePath) ?? profile.mountPoint else {
                throw CLIUsageError(message: "Set --mount-point when connecting or mounting this profile")
            }
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

    private func open(_ profile: DriveProfile, root: URL) throws -> Engine { try Engine.open(profile: profile, stateRoot: root) }
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
        "Uploads: \(value.drive.pendingUploads); conflicts: \(value.drive.conflictedUploads). Network connectivity was not probed.\n"
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

private struct Failure: Encodable { var error: String; var exitCode: Int32 }
private struct ProfileReference: Encodable { var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool }
private struct ProfileStatus: Encodable { var profile: String; var backend: String; var mountPoint: String?; var mounted: Bool; var connectionState: String; var drive: DriveStatus }
private struct CacheResult: Encodable { var profile: String; var evictedBytes: Int64; var drive: DriveStatus }
private struct PinResult: Encodable { var profile: String; var path: String; var pinned: Bool; var drive: DriveStatus }
private struct RevealResult: Encodable { var profile: String; var path: String; var localPath: String }
private struct DoctorCheck: Encodable { var name: String; var state: String; var detail: String }
private struct DoctorResult: Encodable { var stateDirectory: String; var profiles: [String]; var checks: [DoctorCheck] }
