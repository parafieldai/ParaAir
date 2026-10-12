import Foundation
import Security
import Darwin
import CryptoKit

public enum DriveBackendKind: String, Codable, Sendable { case juicefs, local, paraairCloud }

public struct DriveProfile: Codable, Equatable, Sendable {
    public var name: String
    /// Finder presentation; `name` remains the stable storage/state identifier.
    public var displayName: String?
    public var finderName: String { displayName ?? name }
    public var backend: DriveBackendKind
    public var metadataURL: String?
    public var localRoot: String?
    public var libraryPath: String?
    public var mountPoint: String?
    public var cacheLimitBytes: Int64
    public var minFreeBytes: Int64
    public var blockSize: Int
    public var maxJournalBytes: Int64
    public var credentialID: String?
    public var objectCredentialID: String?
    public var connectionID: String?
    /// ParaAir Cloud service issuer, account record and drive. Only for `.paraairCloud`.
    public var cloudIssuer: String?
    public var cloudAccountID: String?
    public var cloudDriveID: String?

    public init(name: String, backend: DriveBackendKind = .juicefs, metadataURL: String? = nil,
                localRoot: String? = nil, libraryPath: String? = nil, mountPoint: String? = nil,
                cacheLimitBytes: Int64 = 1_073_741_824, minFreeBytes: Int64 = 5_368_709_120,
                blockSize: Int = 1_048_576, maxJournalBytes: Int64 = 4_294_967_296,
                credentialID: String? = nil, objectCredentialID: String? = nil, connectionID: String? = nil,
                displayName: String? = nil, cloudIssuer: String? = nil, cloudAccountID: String? = nil, cloudDriveID: String? = nil) {
        self.name = name; self.backend = backend; self.metadataURL = metadataURL
        self.displayName = displayName
        self.localRoot = localRoot; self.libraryPath = libraryPath; self.mountPoint = mountPoint
        self.cacheLimitBytes = cacheLimitBytes; self.minFreeBytes = minFreeBytes
        self.blockSize = blockSize; self.maxJournalBytes = maxJournalBytes; self.credentialID = credentialID
        self.objectCredentialID = objectCredentialID; self.connectionID = connectionID
        self.cloudIssuer = cloudIssuer; self.cloudAccountID = cloudAccountID; self.cloudDriveID = cloudDriveID
    }

    public func validate() throws {
        try Self.validateName(name)
        if let displayName { try Self.validateFinderName(displayName) }
        guard cacheLimitBytes > 0, minFreeBytes >= 0, blockSize >= 4096, blockSize <= 8 * 1024 * 1024,
              maxJournalBytes > 0 else {
            throw DriveError(EINVAL, "Cache and journal limits must be positive; block size must be 4 KiB–8 MiB")
        }
        if let mountPoint { try Self.validateLocalPath(mountPoint, field: "mount point") }
        if let libraryPath { try Self.validateLocalPath(libraryPath, field: "library") }
        for credentialID in [credentialID, objectCredentialID].compactMap({ $0 }) {
            guard !credentialID.isEmpty, credentialID.utf8.count <= 256, !credentialID.contains("\0") else {
                throw DriveError(EINVAL, "Invalid Keychain credential identifier")
            }
        }
        if let connectionID {
            try ConnectionStore.validateID(connectionID)
            guard objectCredentialID == nil else { throw DriveError(EINVAL, "Select one storage credential source") }
        }
        if let metadataURL { try Self.validatePublicMetadataURL(metadataURL) }
        if backend != .paraairCloud {
            guard cloudIssuer == nil, cloudAccountID == nil, cloudDriveID == nil else {
                throw DriveError(EINVAL, "Only ParaAir Cloud profiles can name a ParaAir Cloud account or drive")
            }
        }
        switch backend {
        case .paraairCloud:
            guard let cloudIssuer, let cloudAccountID, let cloudDriveID else {
                throw DriveError(EINVAL, "ParaAir Cloud profile requires a service, account and drive")
            }
            _ = try ParaAirCloudIssuer.validate(cloudIssuer)
            try ConnectionStore.validateID(cloudAccountID)
            guard UUID(uuidString: cloudDriveID) != nil, cloudDriveID == cloudDriveID.lowercased() else {
                throw DriveError(EINVAL, "Invalid ParaAir Cloud drive identifier")
            }
            guard blockSize == ParaAirCloudConfiguration.chunkSize else { throw DriveError(EINVAL, "ParaAir Cloud drives use 4 MiB blocks") }
            guard metadataURL == nil, localRoot == nil, libraryPath == nil, credentialID == nil, objectCredentialID == nil, connectionID == nil else {
                throw DriveError(EINVAL, "ParaAir Cloud profile cannot contain storage credentials, metadata or local paths")
            }
        case .local:
            guard let localRoot else { throw DriveError(EINVAL, "Local fixture profile requires an explicit fixture root") }
            try Self.validateLocalPath(localRoot, field: "fixture root")
            guard metadataURL == nil, credentialID == nil, objectCredentialID == nil, connectionID == nil else { throw DriveError(EINVAL, "Local fixture profile cannot contain remote credentials") }
        case .juicefs:
            guard localRoot == nil, metadataURL != nil || credentialID != nil else {
                throw DriveError(EINVAL, "JuiceFS profile requires a nonsecret metadata URL or a Keychain credential identifier")
            }
        }
    }

    public static func validateName(_ value: String) throws {
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64, let first = bytes.first, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }) else {
            throw DriveError(EINVAL, "Invalid profile name: use 1–64 letters, digits, dots, underscores or hyphens, starting with a letter or digit")
        }
    }

    public static func validateFinderName(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 255,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value != ".", value != "..", !value.contains("/"), !value.contains(":"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DriveError(EINVAL, "Use a drive name of up to 255 bytes without slashes, colons or control characters")
        }
    }

    public static func validatePublicMetadataURL(_ value: String) throws {
        guard !value.contains("\0"), value.utf8.count <= 8192,
              let components = URLComponents(string: value), let scheme = components.scheme, !scheme.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw DriveError(EINVAL, "Metadata URL must have a scheme and contain no userinfo, query or fragment. Enter credential-bearing URLs through the app's secure Keychain workflow.")
        }
    }

    public func targetsSameStorage(as other: DriveProfile) -> Bool {
        backend == other.backend && metadataURL == other.metadataURL && localRoot == other.localRoot && credentialID == other.credentialID && objectCredentialID == other.objectCredentialID && connectionID == other.connectionID
            && cloudIssuer == other.cloudIssuer && cloudDriveID == other.cloudDriveID
    }

    private static func validateLocalPath(_ value: String, field: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw DriveError(EINVAL, "The \(field) must be an absolute local path")
        }
    }
}

public final class ProfileStore {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static func resolveRoot(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit, !explicit.isEmpty { return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath).standardizedFileURL }
        if let configured = environment["STREAMDRIVE_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StreamDrive", isDirectory: true)
    }
    public func save(_ profile: DriveProfile, overwrite: Bool = false) throws {
        try profile.validate()
        let directory = root.appendingPathComponent("profiles", isDirectory: true)
        try rejectSymbolicLink(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(profile.name + ".json")
        try rejectSymbolicLink(destination)
        guard overwrite || !FileManager.default.fileExists(atPath: destination.path) else {
            throw DriveError(EEXIST, "Profile already exists; use connect --replace to change it")
        }
        if overwrite, FileManager.default.fileExists(atPath: destination.path),
           !profile.targetsSameStorage(as: try load(profile.name)),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("volumes/" + profile.name).path) {
            throw DriveError(EXDEV, "This profile has persistent state for another storage target. Create a new profile; existing pins and pending writes are retained.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func load(_ name: String) throws -> DriveProfile {
        try DriveProfile.validateName(name)
        let directory = root.appendingPathComponent("profiles", isDirectory: true)
        try rejectSymbolicLink(directory)
        let source = directory.appendingPathComponent(name + ".json")
        try rejectSymbolicLink(source)
        guard FileManager.default.fileExists(atPath: source.path) else { throw DriveError(ENOENT, "Profile '\(name)' is not configured") }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 65_536 else {
            throw DriveError(EINVAL, "Profile configuration exceeds 64 KiB")
        }
        let profile: DriveProfile
        do { profile = try JSONDecoder().decode(DriveProfile.self, from: Data(contentsOf: source)) }
        catch { throw DriveError(EINVAL, "Profile '\(name)' has invalid configuration") }
        guard profile.name == name else { throw DriveError(EINVAL, "Profile name does not match its configuration file") }
        try profile.validate()
        return profile
    }

    public func list() throws -> [DriveProfile] {
        let directory = root.appendingPathComponent("profiles", isDirectory: true)
        try rejectSymbolicLink(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try load($0.deletingPathExtension().lastPathComponent) }
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        var attributes = Darwin.stat()
        if lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFLNK {
            throw DriveError(ELOOP, "Profile configuration paths cannot be symbolic links")
        }
    }
}

/// The only credential persistence seam. Callers obtain secret URLs through
/// secure native entry; the CLI never accepts credentials through arguments,
/// stdin or environment variables. No method includes a URL in its errors.
public final class KeychainSecretStore {
    private let service: String
    private let configuration: KeychainAccessConfiguration
    private let client: any KeychainItemClient
    public convenience init(service: String = "dev.streamdrive.metadata") {
        self.init(service: service, infoDictionary: Bundle.main.infoDictionary ?? [:], client: SystemKeychainItemClient())
    }
    init(service: String = "dev.streamdrive.metadata", infoDictionary: [String: Any], client: any KeychainItemClient) {
        self.service = service
        self.configuration = KeychainAccessConfiguration(infoDictionary: infoDictionary)
        self.client = client
        KeychainInteractionPolicy.disableLegacyUI()
    }

    public func metadataURL(for identifier: String) throws -> String {
        try validateIdentifier(identifier)
        var query = try KeychainInteractionPolicy.prepare(item(identifier), configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = client.copyMatching(query)
        guard status == errSecSuccess, let data = result, let uri = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound { throw DriveError(ENOENT, "Metadata credentials are missing from Keychain. Add them through the app's secure credential workflow.") }
            throw DriveError(EACCES, "Keychain metadata credentials are unavailable or locked")
        }
        try validateSecretURI(uri)
        return uri
    }

    public func storeMetadataURL(_ uri: String, identifier: String) throws {
        try validateIdentifier(identifier)
        try validateSecretURI(uri)
        let data = Data(uri.utf8)
        var value = try KeychainInteractionPolicy.prepare(item(identifier), configuration: configuration)
        value[kSecValueData as String] = data
        value[kSecAttrLabel as String] = "ParaAir — Metadata connection"
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = client.add(value)
        if status == errSecDuplicateItem {
            let updated = client.update(try KeychainInteractionPolicy.prepare(item(identifier), configuration: configuration),
                                        attributes: [kSecValueData as String: data, kSecAttrLabel as String: "ParaAir — Metadata connection"])
            guard updated == errSecSuccess else { throw DriveError(EACCES, "Cannot update metadata credentials in Keychain") }
        } else if status != errSecSuccess {
            throw DriveError(EACCES, "Cannot save metadata credentials in Keychain")
        }
    }

    public func objectCredentials(for identifier: String) throws -> S3Credentials {
        try validateIdentifier(identifier)
        var query = try KeychainInteractionPolicy.prepare(objectItem(identifier), configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = client.copyMatching(query)
        guard status == errSecSuccess, let data = result, data.count <= 32768 else {
            if status == errSecItemNotFound { throw DriveError(ENOENT, "Storage connection credentials are missing from Keychain") }
            throw DriveError(EACCES, "Storage connection credentials are unavailable or locked")
        }
        guard let value = try? JSONDecoder().decode(S3Credentials.self, from: data) else {
            throw DriveError(EINVAL, "Stored storage credentials are invalid")
        }
        try value.validate()
        return value
    }

    public func storeObjectCredentials(_ credentials: S3Credentials, identifier: String) throws {
        try validateIdentifier(identifier)
        try credentials.validate()
        let data = try JSONEncoder().encode(credentials)
        var value = try KeychainInteractionPolicy.prepare(objectItem(identifier), configuration: configuration)
        value[kSecValueData as String] = data
        value[kSecAttrLabel as String] = "ParaAir — S3 storage"
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = client.add(value)
        if status == errSecDuplicateItem {
            let updated = client.update(try KeychainInteractionPolicy.prepare(objectItem(identifier), configuration: configuration),
                                        attributes: [kSecValueData as String: data, kSecAttrLabel as String: "ParaAir — S3 storage"])
            guard updated == errSecSuccess else { throw DriveError(EACCES, "Cannot update storage credentials in Keychain") }
        } else if status != errSecSuccess {
            throw DriveError(EACCES, "Cannot save storage credentials in Keychain")
        }
    }

    private func objectItem(_ identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".s3", kSecAttrAccount as String: identifier]
    }

    private func item(_ identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: identifier]
    }
    private func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 256, !identifier.contains("\0") else {
            throw DriveError(EINVAL, "Invalid Keychain credential identifier")
        }
    }
    private func validateSecretURI(_ uri: String) throws {
        guard !uri.isEmpty, uri.utf8.count <= 16_384, !uri.contains("\0"), URLComponents(string: uri)?.scheme != nil else {
            throw DriveError(EINVAL, "Keychain metadata credential must contain a valid URI")
        }
    }
}

/// What `Engine.open` needs beyond the profile. Tests inject a vault and URL configuration.
public struct EngineOpenDependencies: @unchecked Sendable {
    public var cloudVault: any ConnectionVault
    public var cloudConfiguration: URLSessionConfiguration
    public var cloudPolicy: ParaAirCloudTransportPolicy
    public var cloudSessionOptions: ParaAirCloudSession.Options
    public init(cloudVault: any ConnectionVault, cloudConfiguration: URLSessionConfiguration,
                cloudPolicy: ParaAirCloudTransportPolicy, cloudSessionOptions: ParaAirCloudSession.Options = .init()) {
        self.cloudVault = cloudVault; self.cloudConfiguration = cloudConfiguration
        self.cloudPolicy = cloudPolicy; self.cloudSessionOptions = cloudSessionOptions
    }
    /// One configuration object for the process, so engines share a ParaAir Cloud session.
    private static let liveConfiguration = URLSessionConfiguration.ephemeral
    public static var live: EngineOpenDependencies {
        EngineOpenDependencies(cloudVault: DeferredCloudVault(), cloudConfiguration: liveConfiguration, cloudPolicy: .current)
    }
}

/// Touches the Keychain only when a ParaAir Cloud profile actually needs its tokens.
private struct DeferredCloudVault: ConnectionVault {
    func load(id: String) throws -> ConnectionSecrets { try CloudAccountStore.liveVault.load(id: id) }
    func save(_ secrets: ConnectionSecrets, id: String) throws { try CloudAccountStore.liveVault.save(secrets, id: id) }
    func remove(id: String) throws { try CloudAccountStore.liveVault.remove(id: id) }
}

public extension Engine {
    static func open(profile: DriveProfile, stateRoot: URL, dependencies: EngineOpenDependencies = .live) throws -> Engine {
        try profile.validate()
        let root = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("volumes/" + profile.name, isDirectory: true)
        if let source = profile.localRoot {
            let resolved = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            guard root.path != resolved, !root.path.hasPrefix(resolved + "/") else {
                throw DriveError(EINVAL, "Fixture root cannot contain application state")
            }
        }
        try ProfileStateBinding.bindConfiguration(profile, directory: directory)
        // Without Keychain or network: a readable account record must name this profile's service.
        func checkIssuer(_ account: CloudAccount) throws {
            guard account.issuer == profile.cloudIssuer else {
                throw DriveError(EXDEV, "This drive belongs to another ParaAir Cloud service. Sign in to that service or create a new drive.")
            }
        }
        if profile.backend == .paraairCloud, let account = try? CloudAccountStore(root: root).load(profile.cloudAccountID!) { try checkIssuer(account) }
        let makeBackend: () throws -> StorageBackend = {
            switch profile.backend {
            case .paraairCloud:
                try checkIssuer(try CloudAccountStore(root: root).load(profile.cloudAccountID!))
                let session = try ParaAirCloudSession.shared(root: root, accountID: profile.cloudAccountID!, vault: dependencies.cloudVault,
                                                             configuration: dependencies.cloudConfiguration, policy: dependencies.cloudPolicy,
                                                             options: dependencies.cloudSessionOptions)
                return try ParaAirCloudBackend(driveID: profile.cloudDriveID!, session: session, bindVolume: {
                    try ProfileStateBinding.bindVolume($0, directory: directory)
                })
            case .local:
                let source = URL(fileURLWithPath: profile.localRoot!).resolvingSymlinksInPath()
                if Bundle.main.bundleIdentifier == "dev.streamdrive.app.filesystem", !ProfileStateBinding.isInside(source, root) {
                    throw DriveError(EACCES, "Filesystem extension fixture root must be inside the granted state directory")
                }
                return try LocalDirectoryBackend(root: source)
            case .juicefs:
                let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("libstreamdrive.dylib")
                let library: URL
                if let bundled, FileManager.default.fileExists(atPath: bundled.path) { library = bundled }
                else if let configured = profile.libraryPath { library = URL(fileURLWithPath: configured).resolvingSymlinksInPath() }
                else { library = root.appendingPathComponent("native/libstreamdrive.dylib") }
                if Bundle.main.bundleIdentifier == "dev.streamdrive.app.filesystem", library != bundled, !ProfileStateBinding.isInside(library, root) {
                    throw DriveError(EACCES, "Native library must be bundled with the signed extension or inside its granted state directory")
                }
                guard FileManager.default.fileExists(atPath: library.path) else {
                    throw DriveError(EIO, "Pinned libstreamdrive.dylib is unavailable; build it and connect with --library, or bundle it with the signed extension")
                }
                let uri = try profile.credentialID.map { try KeychainSecretStore().metadataURL(for: $0) } ?? profile.metadataURL!
                if let connectionID = profile.connectionID {
                    return try ConnectionBackend(libraryURL: library, metadataURL: uri, connectionID: connectionID,
                                                 store: ConnectionStore(root: root), bindVolume: {
                        try ProfileStateBinding.bindVolume($0, directory: directory)
                    })
                }
                let objectCredentials = try profile.objectCredentialID.map { try KeychainSecretStore().objectCredentials(for: $0) }
                let backend = try JuiceFSBackend(libraryURL: library, metadataURL: uri, volumeName: profile.name,
                                                objectCredentials: objectCredentials)
                do { try ProfileStateBinding.bindVolume(try backend.volumeIdentity(), directory: directory) }
                catch { try? backend.close(); throw error }
                return backend
            }
        }
        let backend = LazyProfileBackend(makeBackend)
        // ParaAir Cloud holds no lock across network I/O, so one instance serves reads and uploads
        // and its quota cooldown and capacity cache see both (spec 6.10 step 9).
        return try Engine(backend: backend, stateDirectory: directory,
                          cacheLimitBytes: profile.cacheLimitBytes, minFreeBytes: profile.minFreeBytes,
                          blockSize: profile.blockSize, maxJournalBytes: profile.maxJournalBytes,
                          publishingBackend: profile.backend == .paraairCloud ? backend : LazyProfileBackend(makeBackend),
                          tuning: profile.backend == .paraairCloud ? .paraairCloud : .byo)
    }
}

/// Connects on first use. The lock covers only creating the backend; operations
/// run outside it so one slow call never serializes the others.
private final class LazyProfileBackend: StorageBackend {
    private let lock = NSLock()
    private let make: () throws -> StorageBackend
    private var connected: StorageBackend?
    private var closed = false
    init(_ make: @escaping () throws -> StorageBackend) { self.make = make }
    deinit { try? close() }
    private func current() throws -> StorageBackend {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw DriveError(EBADF, "Storage backend is closed", disposition: .attemptNotDispatched) }
        if let connected { return connected }
        // Nothing has been sent to storage yet, so a commit can safely retry.
        do { let made = try make(); connected = made; return made }
        catch let error as DriveError where error.code == EXDEV { throw error.with(.attemptNotDispatched) }
        catch { throw DriveError(EIO, "Storage backend is unavailable: " + error.localizedDescription, disposition: .attemptNotDispatched) }
    }
    private func withBackend<T>(_ action: (StorageBackend) throws -> T) throws -> T { try action(current()) }
    func stat(_ path: String) throws -> FileEntry { try withBackend { try $0.stat(path) } }
    func list(_ path: String) throws -> [FileEntry] { try withBackend { try $0.list(path) } }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data { try withBackend { try $0.read(path, offset: offset, length: length) } }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data { try withBackend { try $0.readSnapshot(path, version: version, offset: offset, length: length) } }
    func commit(_ value: FileCommit) throws -> FileEntry { try withBackend { try $0.commit(value) } }
    func createDirectory(_ path: String) throws -> FileEntry { try withBackend { try $0.createDirectory(path) } }
    func move(_ source: String, to destination: String) throws { try withBackend { try $0.move(source, to: destination) } }
    func remove(_ path: String, directory: Bool) throws { try withBackend { try $0.remove(path, directory: directory) } }
    func transferMetrics() throws -> TransferMetrics? { try withBackend { try $0.transferMetrics() } }
    // Forwarded explicitly; the protocol defaults would hide the backend's answers.
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try withBackend { try $0.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion) }
    }
    func capacity() throws -> VolumeCapacity? { try withBackend { try $0.capacity() } }
    func close() throws {
        lock.lock(); closed = true; let backend = connected; connected = nil; lock.unlock()
        try backend?.close()
    }
}

private enum ProfileStateBinding {
    /// Nil fields are omitted, so digests of existing profiles are unchanged.
    private struct Configuration: Encodable {
        var backend: DriveBackendKind
        var metadataURL: String?
        var localRoot: String?
        var credentialID: String?
        var objectCredentialID: String?
        var connectionID: String?
        var localDevice: UInt64?
        var localInode: UInt64?
        var cloudIssuer: String?
        var cloudDriveID: String?
    }
    static func bindConfiguration(_ profile: DriveProfile, directory: URL) throws {
        var value = Configuration(backend: profile.backend, metadataURL: profile.metadataURL,
                                  localRoot: profile.localRoot, credentialID: profile.credentialID, objectCredentialID: profile.objectCredentialID, connectionID: profile.connectionID,
                                  cloudIssuer: profile.cloudIssuer, cloudDriveID: profile.cloudDriveID)
        if let local = profile.localRoot {
            let resolved = URL(fileURLWithPath: local).resolvingSymlinksInPath().path
            var attributes = Darwin.stat()
            guard lstat(resolved, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
                throw DriveError(ENOENT, "Explicit fixture directory is unavailable")
            }
            value.localRoot = resolved
            value.localDevice = UInt64(attributes.st_dev)
            value.localInode = UInt64(attributes.st_ino)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        try DurableIO.directory(directory)
        let lock = try StateLock(directory.appendingPathComponent("identity.lock"))
        try lock.withLock {
            let file = directory.appendingPathComponent("target.sha256")
            if !FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.sqlite3").path) {
                throw DriveError(EXDEV, "Unbound existing state cannot be attached to this profile. Use a new profile; existing data is retained.")
            }
            try bind(digest, to: file)
        }
    }
    static func bindVolume(_ identity: String, directory: URL) throws {
        guard !identity.isEmpty, identity.utf8.count <= 256, !identity.contains("\0") else { throw DriveError(EIO, "Storage volume identity is unavailable") }
        let lock = try StateLock(directory.appendingPathComponent("identity.lock"))
        try lock.withLock { try bind(identity, to: directory.appendingPathComponent("volume.identity")) }
    }
    private static func bind(_ value: String, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 1024 else {
                throw DriveError(EACCES, "Storage identity record is not a bounded regular file")
            }
            guard try String(contentsOf: file, encoding: .utf8) == value else {
                throw DriveError(EXDEV, "Persistent state belongs to a different storage volume. Create a new profile; existing pins and pending writes are retained.")
            }
        } else { try DurableIO.write(Data(value.utf8), to: file) }
    }
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let child = child.resolvingSymlinksInPath().path, parent = parent.resolvingSymlinksInPath().path
        return child == parent || child.hasPrefix(parent + "/")
    }
}
