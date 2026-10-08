import Foundation
import CryptoKit
import Security
import Darwin
import StreamDriveCore

private let mib = 1_048_576
private let payloadBytes = 32 * mib
private let uploadCap: Int64 = 64 * 1_048_576
private let downloadCap: Int64 = 128 * 1_048_576
private let requestCap: Int64 = 200

private struct SmokeFailure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SmokeFailure(message: message) }
}
private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private struct Options {
    let run: Bool
    let connectionID: String?
    let stateRoot: URL
    let projectRoot: URL
    let library: URL
    let timeout: Int

    init(_ arguments: [String]) throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        var values: [String: String] = [:], run = false, index = 0
        let accepted = Set(["--connection-id", "--state-dir", "--workspace", "--library", "--timeout"])
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--run" {
                try require(!run, "Duplicate run option"); run = true; index += 1; continue
            }
            try require(accepted.contains(flag) && values[flag] == nil && index + 1 < arguments.count,
                        "Invalid arguments; use --help for nonsecret options")
            values[flag] = arguments[index + 1]; index += 2
        }
        let project = URL(fileURLWithPath: values["--workspace"] ?? sourceRoot.path).standardizedFileURL.resolvingSymlinksInPath()
        try require(project == sourceRoot, "The smoke workspace must be this script's project directory")
        let library = URL(fileURLWithPath: values["--library"] ?? project.appendingPathComponent("native/lib/libstreamdrive.dylib").path).standardizedFileURL.resolvingSymlinksInPath()
        try require(library.path.hasPrefix(project.path + "/"), "The native library must be inside the project workspace")
        let timeout = Int(values["--timeout"] ?? "300") ?? 0
        try require((120...300).contains(timeout), "Timeout must be between 120 and 300 seconds")
        if let id = values["--connection-id"] { try ConnectionStore.validateID(id) }
        try require(!run || values["--connection-id"] != nil, "Live run requires --connection-id")
        self.run = run; connectionID = values["--connection-id"]
        stateRoot = ProfileStore.resolveRoot(explicit: values["--state-dir"])
        projectRoot = project; self.library = library; self.timeout = timeout
    }
}

/// Reports only explicitly selected nonsecret fields. The timeout thread never
/// inspects a connection, native configuration, error body or Keychain payload.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]
    private let destination: URL
    private var finished = false
    init(destination: URL, initial: [String: Any]) throws {
        self.destination = destination; value = initial
        try persist()
    }
    private func persist() throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func update(_ fields: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        value.merge(fields) { _, new in new }; try persist()
    }
    func append(_ measurement: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        var measurements = value["measurements"] as? [[String: Any]] ?? []
        measurements.append(measurement); value["measurements"] = measurements; try persist()
    }
    func finish(status: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }; finished = true
        value.merge(fields) { _, new in new }; value["status"] = status
        value["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            try persist()
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } catch { fputs("Could not persist the sanitized smoke report.\n", stderr) }
    }
}

@main
private struct ConnectedSmoke {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print("""
            Usage: connected-smoke [--run --connection-id UUID] [--state-dir PATH]
                   [--workspace PROJECT_ROOT] [--library WORKSPACE_DYLIB] [--timeout 120..300]
            Default is a dry run with no Keychain access or network calls.
            Live run creates a private workspace fixture and retains its fresh remote object prefix.
            Fixed limits: 32 MiB file, 64 MiB upload, 128 MiB download, 200 requests.
            Credentials come only from the saved connection's Keychain entry.
            """)
            return
        }
        do { try run(Options(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            let message = (error as? SmokeFailure)?.message ?? "Smoke setup failed; no provider error text is emitted"
            fputs(message + "\n", stderr); exit(1)
        }
    }

    private static func run(_ options: Options) throws {
        let plan: [String: Any] = [
            "status": "dry-run", "provider": "cloudflareR2", "fileBytes": payloadBytes,
            "maxUploadBytes": uploadCap, "maxDownloadBytes": downloadCap, "maxRequests": requestCap,
            "timeoutSeconds": options.timeout, "remoteDeletes": false,
            "metadata": "fresh local SQLite", "cache": "fresh native client and separate StreamDrive block cache",
            "budgetAccounting": "Upload bytes reserve complete request bodies, including failed attempts. Download bytes count consumed response bodies; downloadReservedBytes conservatively reserves each response before dispatch and is never refunded.",
            "limitations": "Budgeted transport uses fresh HTTP/1.1 connections without keepalive or automatic request replay, so timing is conservative and differs from normal reuse. Payload counters exclude HTTP/TLS overhead. No Finder, Quick Look or player timing. Fresh client cache does not flush provider caches."
        ]
        guard options.run else {
            let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])); return
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: options.projectRoot.path)
        try require((attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 >= 100 * 1024 * 1024 * 1024,
                    "At least 100 GiB free disk space is required")
        umask(0o077)
        let runtime = options.projectRoot.appendingPathComponent(".runtime", isDirectory: true)
        try require(runtime.resolvingSymlinksInPath().path.hasPrefix(options.projectRoot.path + "/"), "Runtime directory escapes the project")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runDirectory = runtime.appendingPathComponent("connected-smoke-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let reporter = try Reporter(destination: runDirectory.appendingPathComponent("report.json"), initial: plan.merging([
            "status": "running", "stage": "credentials", "startedAt": ISO8601DateFormatter().string(from: Date()),
            "runDirectory": runDirectory.path, "remoteObjectsRetained": true, "measurements": [[String: Any]]()
        ]) { _, new in new })
        let started = DispatchTime.now().uptimeNanoseconds
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + .seconds(options.timeout))
        watchdog.setEventHandler {
            reporter.finish(status: "timed-out", fields: ["elapsedMilliseconds": milliseconds(since: started)])
            _exit(124)
        }
        watchdog.resume(); defer { watchdog.cancel() }
        var current: JuiceFSBackend?
        do {
            let (connection, secrets) = try ConnectionStore(root: options.stateRoot).credentials(options.connectionID!)
            try require(connection.provider == .cloudflareR2, "This smoke runner accepts a saved Cloudflare R2 connection only")
            try require((secrets.oauth?.expiresAt?.timeIntervalSinceNow ?? 0) > Double(options.timeout + 30),
                        "Renew authorization in Connections before starting this bounded run")
            let budget = try JuiceFSBackend.ObjectBudget(maxUploadBytes: uploadCap, maxDownloadBytes: downloadCap, maxRequests: requestCap)
            let metadata = runDirectory.appendingPathComponent("metadata.sqlite3")
            try reporter.update(["stage": "initialize"])
            let writer = try JuiceFSBackend.initializeCloud(libraryURL: options.library, metadataURL: metadata,
                connection: connection, secrets: secrets, objectBudget: budget)
            current = writer
            guard let initialBudget = try writer.metrics().objectBudget, let initialReserved = initialBudget.downloadReservedBytes else {
                throw SmokeFailure(message: "Native library does not enforce the required pre-dispatch object budget")
            }
            try require(initialBudget.requests == 0 && initialBudget.uploadBytes == 0 && initialBudget.downloadBytes == 0 && initialReserved == 0,
                        "Fresh native budget unexpectedly contains prior transfers")
            try reporter.update(["volumeIdentity": writer.volumeIdentity(), "stage": "generate-synthetic-payload"])
            let payloadURL = runDirectory.appendingPathComponent("payload.bin")
            try Data().write(to: payloadURL, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: payloadURL)
            var expectedDigest = SHA256()
            for _ in 0..<8 {
                var data = Data(count: 4 * mib)
                let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
                try require(status == errSecSuccess, "Cannot generate synthetic payload")
                expectedDigest.update(data: data); try output.write(contentsOf: data)
            }
            try output.synchronize(); try output.close()
            let digest = Data(expectedDigest.finalize())
            try reporter.update(["stage": "upload"])
            let uploadStart = DispatchTime.now().uptimeNanoseconds
            _ = try writer.commit(FileCommit(transactionID: UUID().uuidString.lowercased(), path: "/payload.bin",
                expectedVersion: nil, finalSize: Int64(payloadBytes), baseVisibleSize: 0, mode: 0o600,
                extents: [WriteExtent(offset: 0, length: Int64(payloadBytes), blobURL: payloadURL)]))
            let afterWrite = try writer.metrics()
            try reporter.update(["uploadMilliseconds": milliseconds(since: uploadStart), "cumulativeMetrics": jsonObject(afterWrite), "stage": "reopen-cold-client"])
            try writer.close(); current = nil
            let reader = try JuiceFSBackend(libraryURL: options.library, metadataURL: "sqlite3://" + metadata.path,
                connection: connection, secrets: secrets, objectBudget: budget)
            current = reader
            let reopened = try reader.metrics()
            guard let budgetBefore = afterWrite.objectBudget, let budgetAfter = reopened.objectBudget,
                  let reservedBefore = budgetBefore.downloadReservedBytes, let reservedAfter = budgetAfter.downloadReservedBytes else {
                throw SmokeFailure(message: "Native object budget disappeared across reopen")
            }
            try require(budgetAfter.requests >= budgetBefore.requests && budgetAfter.uploadBytes >= budgetBefore.uploadBytes
                        && budgetAfter.downloadBytes >= budgetBefore.downloadBytes && reservedAfter >= reservedBefore,
                        "Native object budget reset across reopen")
            let drive = try Engine(backend: reader, stateDirectory: runDirectory.appendingPathComponent("reader-cache"),
                cacheLimitBytes: 64 * 1024 * 1024, minFreeBytes: 100 * 1024 * 1024 * 1024)
            let reference = try FileHandle(forReadingFrom: payloadURL); defer { try? reference.close() }
            func measure(_ name: String, offset: Int64? = nil, _ operation: () throws -> Int) throws -> JuiceFSBackend.Metrics {
                try reporter.update(["stage": name])
                let before = try reader.metrics(), start = DispatchTime.now().uptimeNanoseconds
                let count = try operation(), after = try reader.metrics()
                var sample: [String: Any] = ["name": name, "milliseconds": milliseconds(since: start), "applicationBytes": count,
                    "objectReadBytes": after.objectReadBytes - before.objectReadBytes,
                    "objectGetRequests": after.objectGetRequests - before.objectGetRequests]
                if let offset { sample["offset"] = offset }
                try reporter.append(sample); try reporter.update(["cumulativeMetrics": jsonObject(after)])
                return after
            }
            let listed = try measure("metadata-list") {
                let entries = try drive.list("/")
                try require(entries.count == 1 && entries[0].name == "payload.bin" && entries[0].size == payloadBytes,
                            "Metadata listing did not match the synthetic file")
                return 0
            }
            try require(listed.objectReadBytes == 0 && listed.objectGetRequests == 0, "Metadata listing fetched object contents")
            let head = try measure("cold-head-64KiB", offset: 0) {
                let data = try drive.read("/payload.bin", offset: 0, length: 65_536)
                try reference.seek(toOffset: 0)
                try require(data.count == 65_536 && data == reference.read(upToCount: 65_536), "Head range integrity failed")
                return data.count
            }
            try require(head.objectReadBytes > 0 && head.objectReadBytes < payloadBytes, "Cold head range did not demonstrate partial download")
            let distant = Int64(payloadBytes - 131_072)
            let sought = try measure("distant-seek-64KiB", offset: distant) {
                let data = try drive.read("/payload.bin", offset: distant, length: 65_536)
                try reference.seek(toOffset: UInt64(distant))
                try require(data.count == 65_536 && data == reference.read(upToCount: 65_536), "Distant range integrity failed")
                return data.count
            }
            try require(sought.objectReadBytes < payloadBytes, "Distant seek did not demonstrate access before full download")
            let beforeWarm = try reader.metrics()
            let warm = try measure("warm-streamdrive-cache-64KiB", offset: 0) {
                let data = try drive.read("/payload.bin", offset: 0, length: 65_536)
                try reference.seek(toOffset: 0)
                try require(data.count == 65_536 && data == reference.read(upToCount: 65_536), "Cached range integrity failed")
                return data.count
            }
            try require(warm.objectReadBytes == beforeWarm.objectReadBytes && warm.objectGetRequests == beforeWarm.objectGetRequests,
                        "Repeated cached read fetched additional objects")
            _ = try measure("full-integrity-32MiB-native-direct-may-be-warm") {
                var hasher = SHA256(), count = 0
                for offset in stride(from: 0, to: payloadBytes, by: 4 * mib) {
                    let data = try reader.read("/payload.bin", offset: Int64(offset), length: 4 * mib)
                    try require(data.count == 4 * mib, "Full integrity read returned a short block")
                    hasher.update(data: data); count += data.count
                }
                try require(Data(hasher.finalize()) == digest, "Full file integrity failed")
                return count
            }
            let final = try reader.metrics()
            guard let finalBudget = final.objectBudget, let finalReserved = finalBudget.downloadReservedBytes else {
                throw SmokeFailure(message: "Final budget metrics are missing")
            }
            try require(finalBudget.uploadBytes <= uploadCap && finalBudget.downloadBytes <= downloadCap
                        && finalReserved <= downloadCap && finalBudget.requests <= requestCap,
                        "Native payload budget exceeded its configured limit")
            let cacheStatus = try jsonObject(drive.status())
            try reader.close(); current = nil
            reporter.finish(status: "passed", fields: ["stage": "complete", "elapsedMilliseconds": milliseconds(since: started),
                "sha256": digest.map { String(format: "%02x", $0) }.joined(), "cumulativeMetrics": try jsonObject(final),
                "localCacheStatus": cacheStatus, "integrityVerified": true])
        } catch {
            var fields: [String: Any] = ["elapsedMilliseconds": milliseconds(since: started)]
            if let failure = error as? SmokeFailure { fields["reason"] = failure.message }
            else if let failure = error as? DriveError { fields["errno"] = failure.code }
            else { fields["reason"] = "Local or provider operation failed; diagnostic text is redacted" }
            if let current, let metrics = try? current.metrics(), let object = try? jsonObject(metrics) { fields["cumulativeMetrics"] = object }
            reporter.finish(status: "failed", fields: fields)
            try? current?.close(); exit(1)
        }
    }
}
