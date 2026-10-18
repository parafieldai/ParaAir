import Foundation
import SystemConfiguration
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
/// This Mac as the owner of one drive. One Mac writes a drive at a time: each keeps its
/// own copy of the index, and two writing one bucket would overwrite each other's data.
/// The identity is a random ID kept in the drive's state folder, so a lost state folder
/// (recovered from the bucket) is a new owner; the name is shown to the other Mac.
public struct DriveOwner: Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    /// Reads, or creates, the owner ID in a drive's state directory.
    public static func load(directory: URL) throws -> DriveOwner {
        let file = directory.appendingPathComponent("owner.id")
        // The computer name from SystemConfiguration; Host.current() may block on name lookups.
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "another Mac"
        func stored() -> String? {
            guard let data = try? Data(contentsOf: file), data.count <= 64, let value = String(data: data, encoding: .utf8),
                  UUID(uuidString: value) != nil else { return nil }
            return value
        }
        if let id = stored() { return DriveOwner(id: id, name: name) }
        try DurableIO.directory(directory)
        // Created exclusively: two processes opening the drive for the first time must
        // agree on one ID, or each would see the other as another Mac.
        let id = UUID().uuidString.lowercased()
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if descriptor >= 0 {
            let written = id.withCString { write(descriptor, $0, strlen($0)) }
            let synced = fsync(descriptor)
            close(descriptor)
            guard written == id.utf8.count, synced == 0 else {
                try? FileManager.default.removeItem(at: file)
                throw DriveError(EIO, "Cannot record this Mac's owner ID")
            }
            return DriveOwner(id: id, name: name)
        }
        guard errno == EEXIST, let winner = stored() else { throw DriveError(errno == EEXIST ? EIO : errno, "Cannot read this Mac's owner ID") }
        return DriveOwner(id: winner, name: name)
    }
    fileprivate var configuration: [String: String] { ["ownerID": id, "ownerName": name] }
}

private extension Dictionary where Key == String, Value == Any {
    /// The native configuration plus this Mac's owner identity, when there is one.
    func owned(by owner: DriveOwner?) -> [String: Any] {
        merging(owner?.configuration ?? [:]) { _, new in new }
    }
}

/// The bridge's C ABI: JSON in, JSON out, errors reduced to a POSIX code and the operation.
private struct NativeLibrary {
    private typealias Call = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private let call: Call
    private let free: Free

    init(_ libraryURL: URL) throws {
        guard libraryURL.isFileURL else { throw DriveError(EINVAL, "Native library requires a local file URL") }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw DriveError(ENOENT, "Cannot load the pinned JuiceFS library; run scripts/build-juicefs.sh")
        }
        guard let call = dlsym(library, "sd_call"), let free = dlsym(library, "sd_free") else {
            throw DriveError(ENOSYS, "Native library is missing the StreamDrive bridge ABI")
        }
        // Go's runtime owns background threads: unloading its dylib is unsafe.
        // dlopen handles intentionally remain loaded for this process lifetime.
        self.call = unsafeBitCast(call, to: Call.self)
        self.free = unsafeBitCast(free, to: Free.self)
    }

    func send(_ fields: [String: Any]) throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: fields)
        guard let json = String(data: encoded, encoding: .utf8) else { throw DriveError(EINVAL, "Invalid native request") }
        let result = try json.withCString { source -> [String: Any] in
            guard let output = call(source) else { throw DriveError(EIO, "Native bridge returned no response") }
            defer { free(output) }
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
            // The bridge reports how far a failed commit got; older bridges omit it.
            let disposition = (result["disposition"] as? String).flatMap(CommitDisposition.init(rawValue:)) ?? .ambiguous
            throw DriveError(code, "JuiceFS \(fields["op"] as? String ?? "operation") failed: \(description)", disposition: disposition)
        }
        return result
    }
}

public final class JuiceFSBackend: StorageBackend {
    private let native: NativeLibrary
    /// Guards `handle` only. Calls run outside it: the bridge serializes what must be
    /// serial, and close waits there for in-flight calls.
    private let lock = NSLock()
    private var handle: UInt64 = 0
    /// SQLite metadata lives only on this Mac; the objects alone cannot rebuild names.
    private let localIndex: Bool

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
                            objectCredentials: S3Credentials? = nil, owner: DriveOwner? = nil) throws {
        try objectCredentials?.validate()
        var configuration = (["metadataURL": metadataURL, "memoryMiB": cacheMemoryMiB] as [String: Any]).owned(by: owner)
        if let objectCredentials { configuration["objectCredentials"] = objectCredentials.nativeConfiguration }
        try self.init(libraryURL: libraryURL, configuration: configuration)
    }

    /// `owner` claims the drive for this Mac, and makes writes fail with EROFS once
    /// another Mac has recovered it.
    public convenience init(libraryURL: URL, metadataURL: String, connection: StorageConnection, secrets: ConnectionSecrets,
                            objectBudget: ObjectBudget? = nil, owner: DriveOwner? = nil) throws {
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["metadataURL"] = metadataURL; configuration["memoryMiB"] = 64
        configuration = configuration.owned(by: owner)
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

    /// A drive whose index is backed up in a bucket: its volume (top-level folder) and
    /// its newest backup's key under that folder.
    public struct StoredDrive: Codable, Sendable, Equatable {
        public let volume: String
        public let latestBackup: String
    }
    /// What a restore loaded.
    public struct RestoredIndex: Sendable, Equatable {
        public let backupKey: String
        public let volumeIdentity: String
    }

    /// The Mac that owns a backed-up drive, as its record in the bucket says.
    public struct StoredOwner: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let at: Date
    }
    public static func driveOwner(libraryURL: URL, connection: StorageConnection, secrets: ConnectionSecrets,
                                  volume: String) throws -> StoredOwner? {
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["s3BucketURL"] = try connection.nativeBucketURL()
        configuration["volumeName"] = volume
        return try driveOwner(libraryURL: libraryURL, configuration: configuration)
    }
    static func driveOwner(libraryURL: URL, configuration: [String: Any]) throws -> StoredOwner? {
        guard let owner = try NativeLibrary(libraryURL).send(["op": "driveOwner", "config": configuration])["owner"] else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredOwner.self, from: JSONSerialization.data(withJSONObject: owner))
    }

    /// Loads a drive's backed-up index (the newest, or `backupKey`) from the connection's
    /// bucket into a new SQLite file on this Mac, and records `owner` as the drive's owner.
    /// An existing file is never reused, and a failed restore leaves none behind. The
    /// backup must describe `volume` in this bucket.
    public static func restoreCloud(libraryURL: URL, metadataURL: URL, connection: StorageConnection, secrets: ConnectionSecrets,
                                    volume: String, backupKey: String? = nil, owner: DriveOwner? = nil) throws -> RestoredIndex {
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["s3BucketURL"] = try connection.nativeBucketURL()
        return try restore(libraryURL: libraryURL, configuration: configuration.owned(by: owner), metadataURL: metadataURL,
                           volume: volume, backupKey: backupKey)
    }
    /// The same from a local folder standing in for a bucket (`initializeLocal` drives).
    public static func restoreLocal(libraryURL: URL, metadataURL: URL, objectDirectory: URL, volume: String,
                                    backupKey: String? = nil, owner: DriveOwner? = nil) throws -> RestoredIndex {
        try restore(libraryURL: libraryURL, configuration: (["localObjectDirectory": objectDirectory.path] as [String: Any]).owned(by: owner),
                    metadataURL: metadataURL, volume: volume, backupKey: backupKey)
    }
    private static func restore(libraryURL: URL, configuration: [String: Any], metadataURL: URL, volume: String,
                                backupKey: String?) throws -> RestoredIndex {
        guard metadataURL.isFileURL else { throw DriveError(EINVAL, "A restored drive needs a new local metadata database") }
        var configuration = configuration
        configuration["metadataURL"] = "sqlite3://" + metadataURL.path
        configuration["volumeName"] = volume
        if let backupKey { configuration["backupKey"] = backupKey }
        let reply = try NativeLibrary(libraryURL).send(["op": "restoreMeta", "config": configuration])
        guard let key = reply["backupKey"] as? String, let identity = reply["volumeIdentity"] as? String, !identity.isEmpty else {
            throw DriveError(EIO, "The restore returned no backup or volume identity")
        }
        return RestoredIndex(backupKey: key, volumeIdentity: identity)
    }
    /// Drives backed up in the connection's bucket. Cloudflare sign-in storage cannot list
    /// (ENOTSUP): its drives are restored by volume name.
    public static func listDrives(libraryURL: URL, connection: StorageConnection, secrets: ConnectionSecrets) throws -> [StoredDrive] {
        var configuration = try connection.nativeConfiguration(secrets: secrets)
        configuration["s3BucketURL"] = try connection.nativeBucketURL()
        return try listDrives(libraryURL: libraryURL, configuration: configuration)
    }
    static func listDrives(libraryURL: URL, configuration: [String: Any]) throws -> [StoredDrive] {
        let reply = try NativeLibrary(libraryURL).send(["op": "listDrives", "config": configuration])
        let data = try JSONSerialization.data(withJSONObject: reply["drives"] ?? [Any]())
        return try JSONDecoder().decode([StoredDrive].self, from: data)
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
        native = try NativeLibrary(libraryURL)
        localIndex = (configuration["metadataURL"] as? String)?.hasPrefix("sqlite3://") == true
        let response = try request(["op": "connect", "config": configuration], requiresHandle: false)
        guard let connected = (response["handle"] as? NSNumber)?.uint64Value, connected != 0 else {
            throw DriveError(EIO, "Native connection returned no handle")
        }
        handle = connected
    }

    deinit { try? close() }

    private func request(_ fields: [String: Any], requiresHandle: Bool = true, handle explicit: UInt64? = nil) throws -> [String: Any] {
        let current = explicit ?? lock.withLock { handle }
        if requiresHandle && current == 0 {
            throw DriveError(EBADF, "JuiceFS connection is closed", disposition: fields["op"] as? String == "commit" ? .attemptNotDispatched : .ambiguous)
        }
        var value = fields
        value["handle"] = current
        return try native.send(value)
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
    /// One range of exactly `version`, checked by the bridge around its read. A
    /// library without the operation (ENOSYS) gets the same check from here.
    public func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, length <= 8 * 1024 * 1024, offset <= Int64.max - Int64(length) else {
            throw DriveError(EINVAL, "Read range must be nonnegative and at most 8 MiB")
        }
        let reply: [String: Any]
        do {
            reply = try request(["op": "readSnapshot", "path": canonicalPath(path), "offset": offset, "length": length,
                                 "expectedVersion": version])
        } catch let error as DriveError where error.code == ENOSYS {
            guard try stat(path).version == version else { throw DriveError(ESTALE, "File changed before range read") }
            let bytes = try read(path, offset: offset, length: length)
            guard try stat(path).version == version else { throw DriveError(ESTALE, "File changed during range read") }
            return bytes
        }
        guard let encoded = reply["data"] as? String else { return Data() }
        guard let bytes = Data(base64Encoded: encoded) else { throw DriveError(EIO, "Invalid native read response") }
        return bytes
    }
    public func commit(_ commit: FileCommit) throws -> FileEntry {
        let fields: [String: Any]
        do {
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
            fields = ["op": "commit", "path": try canonicalPath(commit.path), "operationID": commit.transactionID,
                      "expectedVersion": commit.expectedVersion ?? "", "size": commit.finalSize,
                      "baseVisibleSize": commit.baseVisibleSize, "mode": commit.mode & 0o7777, "patches": patches]
        } catch let error as DriveError { throw error.with(.attemptNotDispatched) }
        return try entry(request(fields)["entry"])
    }
    /// Asks the bridge's commit fence about a transaction. A bridge without the
    /// operation (ENOSYS) cannot answer, which is `.unknown`.
    public func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        let reply: [String: Any]
        do {
            reply = try request(["op": "commitStatus", "path": canonicalPath(path), "operationID": transactionID,
                                 "expectedVersion": expectedVersion ?? ""])
        } catch let error as DriveError where error.code == ENOSYS { return .unknown }
        switch reply["commitState"] as? String {
        case "applied": return .applied(try entry(reply["entry"]))
        case "absent": return .absent
        default: return .unknown
        }
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
    /// A JuiceFS metadata dump in the bucket, under the drive's prefix at
    /// `meta/dump-<UTC>.json.gz`, with JuiceFS's own rotation. Excludes secrets. Storage that
    /// cannot list (Cloudflare sign-in) keeps only the newest dump, replacing `previous`.
    public func backupIndex(replacing previous: String?) throws -> String? {
        guard localIndex else { return nil }
        guard let key = try request(["op": "backupMeta", "previousBackup": previous ?? ""])["backupKey"] as? String, !key.isEmpty else {
            throw DriveError(EIO, "The index backup returned no key")
        }
        return key
    }
    public func transferMetrics() throws -> TransferMetrics? {
        let value = try metrics()
        return TransferMetrics(objectReadBytes: value.objectReadBytes, objectGetRequests: value.objectGetRequests)
    }
    /// Later calls fail with EBADF at once; the bridge finishes in-flight calls first.
    public func close() throws {
        let old = lock.withLock { () -> UInt64 in defer { handle = 0 }; return handle }
        guard old != 0 else { return }
        _ = try request(["op": "close"], handle: old)
    }
}
