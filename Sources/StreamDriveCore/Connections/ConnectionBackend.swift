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
        let provider: S3EndpointProvider = self.provider == .awsS3 ? .aws : self.provider == .backblazeB2 ? .backblazeB2
            : usesR2APIToken ? .r2 : .custom
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

/// One authorized native session for a connection. JuiceFSBackend in production.
protocol ConnectionSession: StorageBackend {
    func volumeIdentity() throws -> String
}
extension JuiceFSBackend: ConnectionSession {}

/// A connection's authorization may rotate independently of its mounted volume.
/// File operations are path based, so a new native session can replace an old
/// session between operations without invalidating application file handles.
///
/// `lock` covers only choosing the session; calls run outside it. A replaced
/// session finishes its in-flight calls, then closes on a utility queue.
final class ConnectionBackend: StorageBackend {
    typealias OpenSession = (StorageConnection, ConnectionSecrets) throws -> ConnectionSession
    /// A session and the calls currently using it.
    private final class Session {
        let backend: ConnectionSession
        let inFlight = DispatchGroup()
        init(_ backend: ConnectionSession) { self.backend = backend }
    }
    /// A session entered for one call, with the traffic of sessions retired before it.
    private struct Lease { let session: Session; let retired: TransferMetrics }
    private static let retirement = DispatchQueue(label: "dev.streamdrive.connection.retire", qos: .utility)
    private let connectionID: String
    private let store: ConnectionStore
    private let vault: any ConnectionVault
    private let bindVolume: (String) throws -> Void
    private let openSession: OpenSession
    private let now: () -> Date
    private let lock = NSLock()
    private var session: Session?
    private var fingerprint: Data?
    /// When credentials last checked out, the record file they came from, and their expiry.
    private var checked: (at: Date, stamp: ConnectionStore.RecordStamp, expiresAt: Date?)?
    private var retired = TransferMetrics()
    private var closed = false

    convenience init(libraryURL: URL, metadataURL: String, connectionID: String, store: ConnectionStore,
                     vault: any ConnectionVault = KeychainConnectionVault(), owner: DriveOwner? = nil,
                     bindVolume: @escaping (String) throws -> Void) throws {
        try self.init(connectionID: connectionID, store: store, vault: vault, bindVolume: bindVolume, openSession: { record, secrets in
            try JuiceFSBackend(libraryURL: libraryURL, metadataURL: metadataURL, connection: record, secrets: secrets, owner: owner)
        })
    }
    init(connectionID: String, store: ConnectionStore, vault: any ConnectionVault, bindVolume: @escaping (String) throws -> Void,
         openSession: @escaping OpenSession, now: @escaping () -> Date = { Date() }) throws {
        self.connectionID = connectionID; self.store = store; self.vault = vault
        self.bindVolume = bindVolume; self.openSession = openSession; self.now = now
        let lease = try acquire()
        lease.session.inFlight.leave()
    }
    deinit { try? close() }

    /// Credentials are re-read when the record file changes, every 15 s, and on
    /// every call within 30 s of expiry, not on every call.
    private func isCurrent(_ stamp: ConnectionStore.RecordStamp?, at clock: Date) -> Bool {
        guard session != nil, let checked, let stamp, checked.stamp == stamp else { return false }
        let age = clock.timeIntervalSince(checked.at)
        guard age >= 0, age < 15 else { return false }
        return checked.expiresAt.map { $0.timeIntervalSince(clock) > 30 } ?? true
    }
    /// Chooses the session for one call and enters it. Call `leave()` on its group after the call.
    private func acquire() throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw DriveError(EBADF, "Storage connection is closed") }
        let stamp = store.recordStamp(connectionID), clock = now()
        if let current = session, isCurrent(stamp, at: clock) {
            current.inFlight.enter()
            return Lease(session: current, retired: retired)
        }
        let record: StorageConnection, secrets: ConnectionSecrets, nextFingerprint: Data
        do {
            (record, secrets) = try store.credentials(connectionID, vault: vault)
            let configuration = try record.nativeConfiguration(secrets: secrets)
            nextFingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])))
        } catch {
            // Credentials that no longer check out (disconnect, sign-out, a changed
            // target) stop all further I/O on the old session.
            if let old = session { retire(old) }
            session = nil; fingerprint = nil; checked = nil
            throw error
        }
        let expiry = [record.provider == .cloudflareR2 ? secrets.oauth?.expiresAt : nil, secrets.storageExpiresAt].compactMap { $0 }.min()
        let checkedNow = stamp.map { (at: clock, stamp: $0, expiresAt: expiry) }
        if let current = session, fingerprint == nextFingerprint {
            checked = checkedNow
            current.inFlight.enter()
            return Lease(session: current, retired: retired)
        }
        let next = Session(try openSession(record, secrets))
        do { try bindVolume(next.backend.volumeIdentity()) }
        catch { try? next.backend.close(); throw error }
        if let old = session { retire(old) }
        session = next; fingerprint = nextFingerprint; checked = checkedNow
        next.inFlight.enter()
        return Lease(session: next, retired: retired)
    }
    /// Under `lock`: counts the old session's traffic now, closes it once its
    /// in-flight calls finish, then counts what they added. Totals only grow.
    private func retire(_ old: Session) {
        let first = (try? old.backend.transferMetrics()) ?? nil
        if let first { add(first) }
        Self.retirement.async { [weak self] in
            _ = old.inFlight.wait(timeout: .now() + 120)
            let last = (try? old.backend.transferMetrics()) ?? nil
            try? old.backend.close()
            guard let self, let first, let last else { return }
            self.lock.withLock {
                self.add(TransferMetrics(objectReadBytes: max(0, last.objectReadBytes - first.objectReadBytes),
                                         objectGetRequests: max(0, last.objectGetRequests - first.objectGetRequests)))
            }
        }
    }
    private func add(_ value: TransferMetrics) {
        retired.objectReadBytes += value.objectReadBytes; retired.objectGetRequests += value.objectGetRequests
    }
    /// Retries once when the call hit a handle closed by rotation or close.
    private func perform<T>(_ action: (StorageBackend) throws -> T) throws -> T {
        let lease = try acquire()
        defer { lease.session.inFlight.leave() }
        do { return try action(lease.session.backend) }
        catch let error as DriveError where error.code == EBADF {
            let next = try acquire()
            defer { next.session.inFlight.leave() }
            guard next.session !== lease.session else { throw error }
            return try action(next.session.backend)
        }
    }
    func stat(_ path: String) throws -> FileEntry { try perform { try $0.stat(path) } }
    func list(_ path: String) throws -> [FileEntry] { try perform { try $0.list(path) } }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data { try perform { try $0.read(path, offset: offset, length: length) } }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        try perform { try $0.readSnapshot(path, version: version, offset: offset, length: length) }
    }
    func commit(_ value: FileCommit) throws -> FileEntry {
        // A credential or session failure here happens before anything is sent.
        func lease() throws -> Lease {
            do { return try acquire() }
            catch let error as DriveError { throw error.with(.attemptNotDispatched) }
            catch { throw DriveError(EIO, "Storage connection is unavailable", disposition: .attemptNotDispatched) }
        }
        let first = try lease()
        defer { first.session.inFlight.leave() }
        do { return try first.session.backend.commit(value) }
        catch let error as DriveError where error.code == EBADF && error.disposition == .attemptNotDispatched {
            let next = try lease()
            defer { next.session.inFlight.leave() }
            guard next.session !== first.session else { throw error }
            return try next.session.backend.commit(value)
        }
    }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try perform { try $0.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion) }
    }
    func createDirectory(_ path: String) throws -> FileEntry { try perform { try $0.createDirectory(path) } }
    func move(_ source: String, to destination: String) throws { try perform { try $0.move(source, to: destination) } }
    func remove(_ path: String, directory: Bool) throws { try perform { try $0.remove(path, directory: directory) } }
    func backupIndex(replacing previous: String?) throws -> String? { try perform { try $0.backupIndex(replacing: previous) } }
    /// Only from the current session: asking must never open one.
    func ownership(refresh: Bool) throws -> StorageOwnership? { try lock.withLock { session }?.backend.ownership(refresh: refresh) }
    /// Retired sessions' traffic plus the current session's, from one consistent lease.
    func transferMetrics() throws -> TransferMetrics? {
        let lease = try acquire()
        defer { lease.session.inFlight.leave() }
        let current = try lease.session.backend.transferMetrics() ?? TransferMetrics()
        return TransferMetrics(objectReadBytes: lease.retired.objectReadBytes + current.objectReadBytes,
                               objectGetRequests: lease.retired.objectGetRequests + current.objectGetRequests)
    }
    func close() throws {
        let current = lock.withLock { () -> Session? in
            closed = true
            defer { session = nil; fingerprint = nil; checked = nil }
            return session
        }
        try current?.backend.close()
    }
}

public enum ConnectedDrive {
    /// Block size of new connected drives (see `profile`).
    public static let blockSize = 4_194_304
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
        let profile = Self.profile(name: name, connectionID: connectionID, metadata: metadata, libraryURL: libraryURL, stateRoot: stateRoot)
        // A failed save retains the new database for recovery; never format it a second time.
        try profiles.save(profile)
        return profile
    }

    /// Opens, in an empty state folder, a drive whose index is backed up in the connection's
    /// bucket: after its Mac or state folder was lost, or to move it to this Mac. The index
    /// comes from the newest backup (or `backupKey`), so changes made after it are missing.
    /// The drive must not be in use on another Mac: two Macs writing one drive with separate
    /// indexes overwrite each other's data.
    /// Another Mac seen as the drive's owner within this long is assumed to be using it.
    public static let ownerActiveSeconds: TimeInterval = 86_400

    public static func recover(name: String, finderName: String? = nil, volume: String, connectionID: String, stateRoot: URL,
                               libraryURL: URL, backupKey: String? = nil, takeOver: Bool = false,
                               vault: any ConnectionVault = KeychainConnectionVault(),
                               now: Date = Date()) throws -> (profile: DriveProfile, backupKey: String) {
        try DriveProfile.validateName(name)
        let profiles = ProfileStore(root: stateRoot)
        guard try profiles.list().isEmpty else {
            throw DriveError(EEXIST, "This Finder state folder already has a drive. Choose another state folder for another drive.")
        }
        let (record, secrets) = try ConnectionStore(root: stateRoot).credentials(connectionID, vault: vault)
        let owner = try DriveOwner.load(directory: Engine.stateDirectory(profileName: name, stateRoot: stateRoot), driveName: finderName ?? name)
        if !takeOver, let current = try JuiceFSBackend.driveOwner(libraryURL: libraryURL, connection: record, secrets: secrets, volume: volume),
           current.id != owner.id, now.timeIntervalSince(current.at) < ownerActiveSeconds {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let seen = formatter.localizedString(for: min(current.at, now), relativeTo: now)
            // A Mac that lost its state folder has a new owner ID but the same name.
            let thisMac = current.name == owner.name ? " If that is this Mac, whose ParaAir state was lost, taking it over is safe." : ""
            throw DriveError(EBUSY, "\(current.name) used this drive \(seen). Quit ParaAir there first, or take the drive over: "
                             + "\(current.name) then stops changing it, and changes made there since the last backup stay on that Mac." + thisMac)
        }
        let metadataDirectory = stateRoot.appendingPathComponent("metadata", isDirectory: true)
        try DurableIO.directory(metadataDirectory)
        let metadata = metadataDirectory.appendingPathComponent(name + ".sqlite3")
        let restored = try JuiceFSBackend.restoreCloud(libraryURL: libraryURL, metadataURL: metadata, connection: record,
                                                       secrets: secrets, volume: volume, backupKey: backupKey, owner: owner)
        let profile = Self.profile(name: name, connectionID: connectionID, metadata: metadata, libraryURL: libraryURL, stateRoot: stateRoot)
        do { try profiles.save(profile) }
        catch {
            // The drive is already recorded as this Mac's; a retry (same owner ID) must start clean.
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: metadata.path + suffix) }
            throw error
        }
        return (profile, restored.backupKey)
    }
    /// Drives backed up in a connection's bucket. Cloudflare sign-in connections cannot
    /// list (ENOTSUP); recover those by volume name.
    public static func storedDrives(connectionID: String, stateRoot: URL, libraryURL: URL,
                                    vault: any ConnectionVault = KeychainConnectionVault()) throws -> [JuiceFSBackend.StoredDrive] {
        let (record, secrets) = try ConnectionStore(root: stateRoot).credentials(connectionID, vault: vault)
        return try JuiceFSBackend.listDrives(libraryURL: libraryURL, connection: record, secrets: secrets)
    }

    /// New connected drives use 4 MiB blocks, matching JuiceFS's 4 MiB objects so
    /// one cache fill costs one object fetch. Existing profiles keep their stored size.
    public static func profile(name: String, connectionID: String, metadata: URL, libraryURL: URL, stateRoot: URL) -> DriveProfile {
        DriveProfile(name: name, metadataURL: "sqlite3://" + metadata.path, libraryPath: libraryURL.path,
                     mountPoint: stateRoot.deletingLastPathComponent().appendingPathComponent("ParaAir-" + name + "-" + String(connectionID.prefix(8))).path,
                     blockSize: blockSize, connectionID: connectionID)
    }
}
