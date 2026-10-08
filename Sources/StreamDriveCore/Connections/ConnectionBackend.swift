import Foundation
import CryptoKit
import Darwin

extension StorageConnection {
    /// Nonsecret, exact storage address checked against the JuiceFS format before credentials are used.
    public func nativeBucketURL() throws -> String {
        try validate()
        guard let endpoint, let bucket else { throw DriveError(EINVAL, "Select a verified storage target first") }
        if provider == .cloudflareR2 {
            guard let accountID,
                  endpoint == (try CloudflareR2Provider.bucketEndpoint(accountID: accountID, bucketName: bucket)).absoluteString else {
                throw DriveError(EINVAL, "R2 connection does not match its account and bucket")
            }
            return endpoint
        }
        guard let url = URL(string: endpoint), let region else {
            throw DriveError(EINVAL, "S3 connections require an HTTPS origin and signing region")
        }
        let provider: S3EndpointProvider = self.provider == .awsS3 ? .aws : self.provider == .backblazeB2 ? .backblazeB2 : .custom
        return try S3ConnectionTarget(provider: provider, endpoint: url, bucket: bucket, region: region).bucketURL.absoluteString
    }

    func nativeConfiguration(secrets: ConnectionSecrets) throws -> [String: Any] {
        guard state == .storageReady, secrets.binding == credentialBinding else {
            throw DriveError(EXDEV, "Credentials do not match the selected storage target")
        }
        var config: [String: Any] = ["expectedBucketURL": try nativeBucketURL()]
        if provider == .cloudflareR2 {
            guard let token = secrets.oauth, token.tokenType.lowercased() == "bearer", !token.accessToken.isEmpty else {
                throw DriveError(EACCES, "Sign in to Cloudflare in ParaAir Connections")
            }
            config["cloudflareToken"] = token.accessToken
        } else {
            guard let keys = secrets.s3 else { throw DriveError(EACCES, "Storage credentials are unavailable") }
            try keys.validate()
            config["objectCredentials"] = keys.nativeConfiguration
            config["s3Region"] = region
        }
        return config
    }
}

/// A connection's authorization may rotate independently of its mounted volume.
/// File operations are path based, so a new native session can replace an old
/// session between operations without invalidating application file handles.
final class ConnectionBackend: StorageBackend {
    private let libraryURL: URL
    private let metadataURL: String
    private let connectionID: String
    private let store: ConnectionStore
    private let vault: any ConnectionVault
    private let bindVolume: (String) throws -> Void
    private let lock = NSRecursiveLock()
    private var backend: JuiceFSBackend?
    private var fingerprint: Data?
    private var retiredBytes: Int64 = 0
    private var retiredGets: Int64 = 0
    private var closed = false

    init(libraryURL: URL, metadataURL: String, connectionID: String, store: ConnectionStore,
         vault: any ConnectionVault = KeychainConnectionVault(), bindVolume: @escaping (String) throws -> Void) throws {
        self.libraryURL = libraryURL; self.metadataURL = metadataURL; self.connectionID = connectionID
        self.store = store; self.vault = vault; self.bindVolume = bindVolume
        _ = try current()
    }
    deinit { try? close() }

    private func current() throws -> JuiceFSBackend {
        guard !closed else { throw DriveError(EBADF, "Storage connection is closed") }
        let (record, secrets) = try store.credentials(connectionID, vault: vault)
        let configuration = try record.nativeConfiguration(secrets: secrets)
        let encoded = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let nextFingerprint = Data(SHA256.hash(data: encoded))
        if let backend, fingerprint == nextFingerprint { return backend }
        let next = try JuiceFSBackend(libraryURL: libraryURL, metadataURL: metadataURL, connection: record, secrets: secrets)
        do { try bindVolume(next.volumeIdentity()) }
        catch { try? next.close(); throw error }
        if let old = backend {
            // Capture completed network work before replacing its counters.
            let metrics: JuiceFSBackend.Metrics
            do { metrics = try old.metrics() }
            catch { try? next.close(); throw error }
            retiredBytes += metrics.objectReadBytes; retiredGets += metrics.objectGetRequests
            backend = next; fingerprint = nextFingerprint
            // close invalidates its handle even on an error. The replacement is
            // already identity checked; never leave a closed session current.
            try? old.close()
            return next
        }
        backend = next; fingerprint = nextFingerprint
        return next
    }
    private func perform<T>(_ action: (JuiceFSBackend) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try action(current())
    }
    func stat(_ path: String) throws -> FileEntry { try perform { try $0.stat(path) } }
    func list(_ path: String) throws -> [FileEntry] { try perform { try $0.list(path) } }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data { try perform { try $0.read(path, offset: offset, length: length) } }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        try perform { try $0.readSnapshot(path, version: version, offset: offset, length: length) }
    }
    func commit(_ value: FileCommit) throws -> FileEntry { try perform { try $0.commit(value) } }
    func createDirectory(_ path: String) throws -> FileEntry { try perform { try $0.createDirectory(path) } }
    func move(_ source: String, to destination: String) throws { try perform { try $0.move(source, to: destination) } }
    func remove(_ path: String, directory: Bool) throws { try perform { try $0.remove(path, directory: directory) } }
    func transferMetrics() throws -> TransferMetrics? {
        try perform {
            let metrics = try $0.metrics()
            return TransferMetrics(objectReadBytes: retiredBytes + metrics.objectReadBytes, objectGetRequests: retiredGets + metrics.objectGetRequests)
        }
    }
    func close() throws {
        lock.lock(); defer { lock.unlock() }
        closed = true
        try backend?.close(); backend = nil
    }
}

public enum ConnectedDrive {
    /// Only initializes a fresh local metadata database and a unique managed
    /// object prefix. Existing ordinary bucket files are never imported/deleted.
    public static func create(name: String, connectionID: String, stateRoot: URL, libraryURL: URL,
                              vault: any ConnectionVault = KeychainConnectionVault()) throws -> DriveProfile {
        try DriveProfile.validateName(name)
        let profiles = ProfileStore(root: stateRoot)
        guard try profiles.list().isEmpty else {
            throw DriveError(EEXIST, "This Finder state folder already has a drive. Choose another state folder for another drive.")
        }
        let (record, secrets) = try ConnectionStore(root: stateRoot).credentials(connectionID, vault: vault)
        let metadataDirectory = stateRoot.appendingPathComponent("metadata", isDirectory: true)
        try DurableIO.directory(metadataDirectory)
        let metadata = metadataDirectory.appendingPathComponent(name + ".sqlite3")
        let backend = try JuiceFSBackend.initializeCloud(libraryURL: libraryURL, metadataURL: metadata,
                                                        connection: record, secrets: secrets)
        try backend.close()
        let profile = DriveProfile(name: name, metadataURL: "sqlite3://" + metadata.path,
                                   libraryPath: libraryURL.path, mountPoint: stateRoot.deletingLastPathComponent().appendingPathComponent("ParaAir-" + name + "-" + String(connectionID.prefix(8))).path,
                                   connectionID: connectionID)
        // A failed save retains the new database for recovery; never format it a second time.
        try profiles.save(profile)
        return profile
    }
}
