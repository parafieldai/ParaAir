import Foundation
import Darwin

/// Passed only in memory or stored in Keychain; never part of a drive profile
/// or the JuiceFS metadata format created by StreamDrive.
public struct S3Credentials: Codable, Sendable {
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String?

    public init(accessKey: String, secretKey: String, sessionToken: String? = nil) throws {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken?.isEmpty == true ? nil : sessionToken
        try validate()
    }

    public func validate() throws {
        guard !accessKey.isEmpty, !secretKey.isEmpty,
              accessKey.utf8.count <= 1024, secretKey.utf8.count <= 4096,
              (sessionToken?.utf8.count ?? 0) <= 16384,
              ![accessKey, secretKey, sessionToken ?? ""].contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }) else {
            throw DriveError(EINVAL, "Storage credentials are empty or invalid")
        }
    }

    var nativeConfiguration: [String: String] {
        var value = ["accessKey": accessKey, "secretKey": secretKey]
        if let sessionToken { value["sessionToken"] = sessionToken }
        return value
    }
}

/// Calls the pinned, FUSE-free JuiceFS engine. The application owns persistent
/// caching and journaling; the native engine uses memory buffers only.
public final class JuiceFSBackend: StorageBackend {
    private typealias Call = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private let callNative: Call
    private let freeNative: Free
    private let lock = NSRecursiveLock()
    private var handle: UInt64 = 0

    /// Optional live-test payload budget. One identifier shares cumulative
    /// counters across native handles in this process; reopening never resets it.
    public struct ObjectBudget: Sendable {
        public let id: UUID
        public let maxUploadBytes: Int64
        public let maxDownloadBytes: Int64
        public let maxRequests: Int64
        public init(id: UUID = UUID(), maxUploadBytes: Int64, maxDownloadBytes: Int64, maxRequests: Int64) throws {
            guard maxUploadBytes > 0, maxDownloadBytes > 0, maxRequests > 0 else {
                throw DriveError(EINVAL, "Object budget limits must be positive")
            }
            self.id = id; self.maxUploadBytes = maxUploadBytes
            self.maxDownloadBytes = maxDownloadBytes; self.maxRequests = maxRequests
        }
        fileprivate var configuration: [String: Any] {
            ["id": id.uuidString.lowercased(), "maxUploadBytes": maxUploadBytes,
             "maxDownloadBytes": maxDownloadBytes, "maxRequests": maxRequests]
        }
    }
    public struct ObjectBudgetMetrics: Codable, Sendable {
        public let requests: Int64
        public let uploadBytes: Int64
        public let downloadBytes: Int64
        /// Conservative allowance reserved before dispatch, including in-flight
        /// requests. Older native builds omit this diagnostic field.
        public let downloadReservedBytes: Int64?
    }
    public struct Metrics: Codable, Sendable {
        public let objectReadBytes: Int64
        public let objectGetRequests: Int64
        public let applicationReadBytes: Int64
        public let objectBudget: ObjectBudgetMetrics?
    }

    public convenience init(libraryURL: URL, metadataURL: String, volumeName: String = "", cacheMemoryMiB: Int = 64,
                            objectCredentials: S3Credentials? = nil) throws {
        try objectCredentials?.validate()
        var configuration: [String: Any] = ["metadataURL": metadataURL, "memoryMiB": cacheMemoryMiB]
        if let objectCredentials { configuration["objectCredentials"] = objectCredentials.nativeConfiguration }
        try self.init(libraryURL: libraryURL, configuration: configuration)
    }

    public convenience init(libraryURL: URL, metadataURL: String, connection: StorageConnection, secrets: ConnectionSecrets,
                            objectBudget: ObjectBudget? = nil) throws {
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["metadataURL"] = metadataURL; configuration["memoryMiB"] = 64
        if let objectBudget { configuration["objectBudget"] = objectBudget.configuration }
        try self.init(libraryURL: libraryURL, configuration: configuration)
    }

    public static func initializeCloud(libraryURL: URL, metadataURL: URL, connection: StorageConnection,
                                       secrets: ConnectionSecrets, objectBudget: ObjectBudget? = nil) throws -> JuiceFSBackend {
        guard metadataURL.isFileURL else { throw DriveError(EINVAL, "New cloud drives require a fresh local metadata database") }
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["metadataURL"] = "sqlite3://" + metadataURL.path
        configuration["memoryMiB"] = 64
        configuration["s3BucketURL"] = try connection.nativeBucketURL()
        configuration[connection.provider == .cloudflareR2 ? "createCloudflareTest" : "createS3Test"] = true
        if let objectBudget { configuration["objectBudget"] = objectBudget.configuration }
        return try JuiceFSBackend(libraryURL: libraryURL, configuration: configuration)
    }

    /// Explicit local-only fixture creation. Does not format any remote target.
    /// Reopening an existing fixture uses the ordinary initializer instead.
    public static func initializeLocal(libraryURL: URL, directory: URL) throws -> JuiceFSBackend {
        guard directory.isFileURL else { throw DriveError(EINVAL, "Local fixture requires a file URL") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = directory.appendingPathComponent("metadata.sqlite3")
        guard !FileManager.default.fileExists(atPath: database.path) else {
            throw DriveError(EEXIST, "Local fixture already exists; connect without initializing it")
        }
        return try JuiceFSBackend(libraryURL: libraryURL, configuration: [
            "metadataURL": "sqlite3://" + database.path,
            "localObjectDirectory": directory.appendingPathComponent("objects").path,
            "createLocal": true, "memoryMiB": 64,
        ])
    }

    private init(libraryURL: URL, configuration: [String: Any]) throws {
        guard libraryURL.isFileURL else { throw DriveError(EINVAL, "Native library requires a local file URL") }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw DriveError(ENOENT, "Cannot load the pinned JuiceFS library; run scripts/build-juicefs.sh")
        }
        guard let call = dlsym(library, "sd_call"), let free = dlsym(library, "sd_free") else {
            throw DriveError(ENOSYS, "Native library is missing the StreamDrive bridge ABI")
        }
        // Go's runtime owns background threads: unloading its dylib is unsafe.
        // dlopen handles intentionally remain loaded for this process lifetime.
        callNative = unsafeBitCast(call, to: Call.self)
        freeNative = unsafeBitCast(free, to: Free.self)
        let response = try request(["op": "connect", "config": configuration], requiresHandle: false)
        guard let connected = (response["handle"] as? NSNumber)?.uint64Value, connected != 0 else {
            throw DriveError(EIO, "Native connection returned no handle")
        }
        handle = connected
    }

    deinit { try? close() }

    private func request(_ fields: [String: Any], requiresHandle: Bool = true) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if requiresHandle && handle == 0 { throw DriveError(EBADF, "JuiceFS connection is closed") }
        var value = fields
        value["handle"] = handle
        let encoded = try JSONSerialization.data(withJSONObject: value)
        guard let json = String(data: encoded, encoding: .utf8) else { throw DriveError(EINVAL, "Invalid native request") }
        let result = try json.withCString { source -> [String: Any] in
            guard let output = callNative(source) else { throw DriveError(EIO, "Native bridge returned no response") }
            defer { freeNative(output) }
            let data = Data(bytes: output, count: strlen(output))
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DriveError(EIO, "Invalid native bridge response")
            }
            return decoded
        }
        guard result["ok"] as? Bool == true else {
            let code = (result["errno"] as? NSNumber)?.int32Value ?? EIO
            // Native/provider errors may contain credential-bearing URLs. The
            // public boundary returns only the POSIX code and fixed operation.
            let description = String(cString: strerror(code))
            throw DriveError(code, "JuiceFS \(fields["op"] as? String ?? "operation") failed: \(description)")
        }
        return result
    }

    private func entry(_ value: Any?) throws -> FileEntry {
        guard let item = value as? [String: Any],
              let path = item["path"] as? String,
              let kindString = item["kind"] as? String,
              let kind = NodeKind(rawValue: kindString),
              let id = (item["inode"] as? NSNumber)?.uint64Value,
              let size = (item["size"] as? NSNumber)?.int64Value,
              let modified = (item["modifiedNanoseconds"] as? NSNumber)?.int64Value,
              let version = item["version"] as? String,
              let mode = (item["mode"] as? NSNumber)?.uint32Value else {
            throw DriveError(ENOTSUP, "Native entry is unsupported or incomplete (only regular files and directories are supported)")
        }
        return FileEntry(id: id, path: path, kind: kind, size: size, modifiedNanoseconds: modified, version: version, mode: mode,
                         accessedNanoseconds: (item["accessedNanoseconds"] as? NSNumber)?.int64Value)
    }

    public func stat(_ path: String) throws -> FileEntry {
        try entry(request(["op": "stat", "path": canonicalPath(path)])["entry"])
    }
    public func list(_ path: String) throws -> [FileEntry] {
        let reply = try request(["op": "list", "path": canonicalPath(path)])
        return try (reply["entries"] as? [Any] ?? []).map(entry)
    }
    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, length <= 8 * 1024 * 1024, offset <= Int64.max - Int64(length) else {
            throw DriveError(EINVAL, "Read range must be nonnegative and at most 8 MiB")
        }
        let reply = try request(["op": "read", "path": canonicalPath(path), "offset": offset, "length": length])
        guard let encoded = reply["data"] as? String else { return Data() }
        guard let bytes = Data(base64Encoded: encoded) else { throw DriveError(EIO, "Invalid native read response") }
        return bytes
    }
    public func commit(_ commit: FileCommit) throws -> FileEntry {
        guard commit.finalSize >= 0, commit.baseVisibleSize >= 0, commit.baseVisibleSize <= commit.finalSize else {
            throw DriveError(EINVAL, "Invalid commit sizes")
        }
        let patches: [[String: Any]] = try commit.extents.map { extent in
            guard extent.offset >= 0, extent.length >= 0, extent.length <= commit.finalSize,
                  extent.offset <= commit.finalSize - extent.length, extent.blobURL.isFileURL else {
                throw DriveError(EINVAL, "Invalid commit extent")
            }
            return ["offset": extent.offset, "length": extent.length, "localFile": extent.blobURL.path]
        }
        return try entry(request([
            "op": "commit", "path": canonicalPath(commit.path), "operationID": commit.transactionID,
            "expectedVersion": commit.expectedVersion ?? "", "size": commit.finalSize,
            "baseVisibleSize": commit.baseVisibleSize, "mode": commit.mode & 0o7777, "patches": patches,
        ])["entry"])
    }
    public func createDirectory(_ path: String) throws -> FileEntry {
        try entry(request(["op": "mkdir", "path": canonicalPath(path)])["entry"])
    }
    public func move(_ source: String, to destination: String) throws {
        _ = try request(["op": "rename", "path": canonicalPath(source), "destination": canonicalPath(destination)])
    }
    public func remove(_ path: String, directory: Bool) throws {
        _ = try request(["op": "remove", "path": canonicalPath(path), "directory": directory])
    }
    /// Stable metadata format UUID; excludes all addresses and credentials.
    /// Call after connecting, before replaying local state into that volume.
    public func volumeIdentity() throws -> String {
        let response = try request(["op": "identity"])
        guard let identity = response["volumeIdentity"] as? String, !identity.isEmpty else {
            throw DriveError(ENOTSUP, "JuiceFS volume has no stable identity")
        }
        return identity
    }
    public func metrics() throws -> Metrics {
        let response = try request(["op": "metrics"])
        let data = try JSONSerialization.data(withJSONObject: response["metrics"] ?? [:])
        return try JSONDecoder().decode(Metrics.self, from: data)
    }
    public func transferMetrics() throws -> TransferMetrics? {
        let value = try metrics()
        return TransferMetrics(objectReadBytes: value.objectReadBytes, objectGetRequests: value.objectGetRequests)
    }
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return }
        defer { handle = 0 }
        _ = try request(["op": "close"])
    }
}
