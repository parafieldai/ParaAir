import Foundation
import Security
import CryptoKit
import Darwin

public enum ConnectionProvider: String, Codable, CaseIterable, Sendable {
    case cloudflareR2, awsS3, backblazeB2, customS3
    public var title: String {
        switch self {
        case .cloudflareR2: return "Cloudflare R2"
        case .awsS3: return "Amazon S3"
        case .backblazeB2: return "Backblaze B2"
        case .customS3: return "Custom S3 / NAS"
        }
    }
}

public enum StorageConnectionState: String, Codable, Sendable {
    case authorized, storageReady, needsSignIn, disconnected
}

/// A public connection reference. No authorization codes, tokens or keys belong here.
public struct StorageConnection: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var provider: ConnectionProvider
    public var name: String
    public var state: StorageConnectionState
    public var accountID: String?
    public var bucket: String?
    public var endpoint: String?
    public var region: String?
    public var roleName: String?
    public var startURL: String?
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), provider: ConnectionProvider, name: String,
                state: StorageConnectionState = .authorized, accountID: String? = nil, bucket: String? = nil,
                endpoint: String? = nil, region: String? = nil, roleName: String? = nil, startURL: String? = nil) {
        self.id = id; self.provider = provider; self.name = name; self.state = state
        self.accountID = accountID; self.bucket = bucket; self.endpoint = endpoint
        self.region = region; self.roleName = roleName; self.startURL = startURL; updatedAt = Date()
    }

    public func validate() throws {
        try ConnectionStore.validateID(id)
        guard schemaVersion == 1, !name.isEmpty, name.utf8.count <= 128,
              ![name, accountID, bucket, endpoint, region, roleName, startURL].compactMap({ $0 }).contains(where: {
                  $0.utf8.count > 2048 || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { throw DriveError(EINVAL, "Invalid saved connection") }
        for value in [endpoint, startURL].compactMap({ $0 }) {
            guard let url = URLComponents(string: value), url.scheme == "https", !(url.host ?? "").isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw DriveError(EINVAL, "Connection addresses must use HTTPS without credentials, queries or fragments")
            }
        }
        if let bucket {
            guard bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
                  !bucket.contains("..") else { throw DriveError(EINVAL, "Invalid storage bucket name") }
        }
        if state == .storageReady {
            guard bucket != nil, endpoint != nil else { throw DriveError(EINVAL, "Connection has no verified storage target") }
        }
    }

    /// Bound into the Keychain payload so editing a public JSON cannot retarget keys.
    public var credentialBinding: String {
        let fields = [id, provider.rawValue, accountID ?? "", bucket ?? "", endpoint ?? "", region ?? "", roleName ?? "", startURL ?? ""]
        let data = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Serialized only into the OS Keychain, never the connection directory.
public struct ConnectionSecrets: Codable, Sendable {
    public var binding: String
    public var oauth: OAuthTokens?
    public var s3: S3Credentials?
    public var storageExpiresAt: Date?
    /// Provider-specific device registration and refresh state, kept opaque to the CLI.
    public var providerSession: Data?
    public init(binding: String, oauth: OAuthTokens? = nil, s3: S3Credentials? = nil,
                storageExpiresAt: Date? = nil, providerSession: Data? = nil) {
        self.binding = binding; self.oauth = oauth; self.s3 = s3
        self.storageExpiresAt = storageExpiresAt; self.providerSession = providerSession
    }
}

public protocol ConnectionVault: Sendable {
    func load(id: String) throws -> ConnectionSecrets
    func save(_ secrets: ConnectionSecrets, id: String) throws
    func remove(id: String) throws
}

public struct KeychainConnectionVault: ConnectionVault {
    private let service: String
    private let configuration: KeychainAccessConfiguration
    private let client: any KeychainItemClient
    public init(service: String = "dev.streamdrive.connections") {
        self.init(service: service, infoDictionary: Bundle.main.infoDictionary ?? [:], client: SystemKeychainItemClient())
    }
    init(service: String = "dev.streamdrive.connections", infoDictionary: [String: Any], client: any KeychainItemClient) {
        self.service = service
        self.configuration = KeychainAccessConfiguration(infoDictionary: infoDictionary)
        self.client = client
        KeychainInteractionPolicy.disableLegacyUI()
    }
    private func query(_ id: String) throws -> [String: Any] {
        try ConnectionStore.validateID(id)
        return try KeychainInteractionPolicy.prepare([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id
        ], configuration: configuration)
    }
    public func load(id: String) throws -> ConnectionSecrets {
        var q = try query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = client.copyMatching(q)
        guard status == errSecSuccess, let data = result, data.count <= 131072,
              let value = try? JSONDecoder().decode(ConnectionSecrets.self, from: data) else {
            throw DriveError(EACCES, "Saved credentials are unavailable to this ParaAir build. Automatic access is paused; no password dialog will be opened.")
        }
        return value
    }
    public func save(_ secrets: ConnectionSecrets, id: String) throws {
        let data = try JSONEncoder().encode(secrets)
        guard data.count <= 131072 else { throw DriveError(EINVAL, "Connection credentials exceed the permitted size") }
        var q = try query(id); q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "ParaAir — Storage connection"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = client.add(q)
        if status == errSecDuplicateItem {
            guard client.update(try query(id), attributes: [kSecValueData as String: data, kSecAttrLabel as String: "ParaAir — Storage connection"]) == errSecSuccess else {
                throw DriveError(EACCES, "Cannot renew credentials in Keychain")
            }
        } else if status != errSecSuccess { throw DriveError(EACCES, "Cannot save connection credentials in Keychain") }
    }
    public func remove(id: String) throws {
        let status = client.delete(try query(id))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveError(EACCES, "Cannot disconnect credentials from Keychain") }
    }
}

public final class ConnectionStore: @unchecked Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    private var directory: URL { root.appendingPathComponent("connections", isDirectory: true) }
    public static func validateID(_ id: String) throws {
        guard UUID(uuidString: id) != nil, id == id.lowercased() else { throw DriveError(EINVAL, "Invalid connection identifier") }
    }
    private func check(_ url: URL, directory: Bool) throws {
        var s = Darwin.stat()
        if lstat(url.path, &s) == 0 {
            guard s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
                throw DriveError(EACCES, "Connection state cannot use symbolic links or special files")
            }
            if !directory && s.st_size > 65536 { throw DriveError(EINVAL, "Connection record exceeds the permitted size") }
        } else if errno != ENOENT { throw DriveError(errno, "Cannot access connection state") }
    }
    public func save(_ connection: StorageConnection) throws {
        try connection.validate(); try check(directory, directory: true); try DurableIO.directory(directory)
        let file = directory.appendingPathComponent(connection.id + ".json")
        let lock = try StateLock(directory.appendingPathComponent(".lock"))
        try lock.withLock {
            try check(file, directory: false)
            if FileManager.default.fileExists(atPath: file.path) {
                let old = try load(connection.id)
                if old.bucket != nil && old.credentialBinding != connection.credentialBinding {
                    throw DriveError(EXDEV, "Create a new connection for a different storage target. Existing drive state is retained.")
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try DurableIO.write(encoder.encode(connection), to: file)
        }
    }
    public func load(_ id: String) throws -> StorageConnection {
        try Self.validateID(id); try check(directory, directory: true)
        let file = directory.appendingPathComponent(id + ".json"); try check(file, directory: false)
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(StorageConnection.self, from: data), value.id == id else {
            throw DriveError(ENOENT, "Saved connection is missing or invalid")
        }
        try value.validate(); return value
    }
    public func list() throws -> [StorageConnection] {
        try check(directory, directory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try load($0.deletingPathExtension().lastPathComponent) }
    }
    /// Explicit user-authorized sign-in/reconnect. Keep renewal and disconnect
    /// serialized with credential replacement; failed persistence stays blocked.
    public func authorize(_ connection: StorageConnection, secrets: ConnectionSecrets,
                          vault: any ConnectionVault = KeychainConnectionVault()) throws {
        try connection.validate()
        guard connection.state == .storageReady, secrets.binding == connection.credentialBinding else {
            throw DriveError(EINVAL, "Authorization does not match the verified connection")
        }
        _ = try connection.nativeConfiguration(secrets: secrets)
        try check(directory, directory: true); try DurableIO.directory(directory)
        let file = directory.appendingPathComponent(connection.id + ".json")
        let lock = try StateLock(directory.appendingPathComponent(".lock"))
        try lock.withLock {
            try check(file, directory: false)
            if FileManager.default.fileExists(atPath: file.path) {
                let previous = try load(connection.id)
                guard previous.bucket == nil || previous.credentialBinding == connection.credentialBinding else {
                    throw DriveError(EXDEV, "Reconnect to the original storage target or create a new connection")
                }
            }
            var pending = connection; pending.state = .authorized
            try DurableIO.write(JSONEncoder().encode(pending), to: file)
            try vault.save(secrets, id: connection.id)
            try DurableIO.write(JSONEncoder().encode(connection), to: file)
        }
    }
    public func credentials(_ id: String, vault: any ConnectionVault = KeychainConnectionVault()) throws -> (StorageConnection, ConnectionSecrets) {
        let record = try load(id)
        guard record.state == .storageReady else { throw DriveError(ENOTCONN, "Finish connecting storage in ParaAir Connections") }
        let secrets = try vault.load(id: id)
        guard secrets.binding == record.credentialBinding else { throw DriveError(EXDEV, "Connection credentials belong to a different storage target") }
        if record.provider == .cloudflareR2 {
            guard let tokens = secrets.oauth, tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty,
                  let expiry = tokens.expiresAt, expiry.timeIntervalSince1970.isFinite,
                  expiry > Date().addingTimeInterval(15) else {
                throw DriveError(EACCES, "Cloudflare authorization expired. Open ParaAir Connections to sign in.")
            }
        } else {
            guard let keys = secrets.s3 else { throw DriveError(EACCES, "Storage credentials are unavailable") }
            try keys.validate()
            if record.provider == .awsS3 && secrets.storageExpiresAt == nil {
                throw DriveError(EACCES, "AWS role authorization has no expiration. Sign in again.")
            }
        }
        if let expiry = secrets.storageExpiresAt, expiry <= Date().addingTimeInterval(15) {
            throw DriveError(EACCES, "Storage authorization expired. Open ParaAir Connections to renew it.")
        }
        return (record, secrets)
    }
    public func disconnect(_ id: String, vault: any ConnectionVault = KeychainConnectionVault()) throws {
        try Self.validateID(id); try check(directory, directory: true)
        let lock = try StateLock(directory.appendingPathComponent(".lock"))
        try lock.withLock {
            var record = try load(id)
            // Block future opens before removing credentials. Keep this under
            // the renewal/reconnect lock so a new sign-in cannot be erased.
            record.state = .disconnected; record.updatedAt = Date()
            try DurableIO.write(JSONEncoder().encode(record), to: directory.appendingPathComponent(id + ".json"))
            try vault.remove(id: id)
        }
    }
}

public struct CloudflareClientRegistration: Codable, Sendable {
    public var clientID: String
    public var callbackPort: UInt16
    public init(clientID: String, callbackPort: UInt16 = 49731) { self.clientID = clientID; self.callbackPort = callbackPort }
    public var redirectURI: URL { URL(string: "http://127.0.0.1:\(callbackPort)/oauth/callback")! }
    public func save(stateRoot: URL) throws {
        guard !clientID.isEmpty, clientID.count <= 1024, callbackPort > 1023,
              clientID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw DriveError(EINVAL, "Enter the registered public OAuth client ID and an unprivileged callback port")
        }
        try DurableIO.directory(stateRoot)
        try DurableIO.write(JSONEncoder().encode(self), to: stateRoot.appendingPathComponent("cloudflare-oauth-client.json"))
    }
    public static func load(stateRoot: URL) throws -> CloudflareClientRegistration {
        let url = stateRoot.appendingPathComponent("cloudflare-oauth-client.json")
        var s = Darwin.stat()
        let status = lstat(url.path, &s)
        if status != 0, errno == ENOENT,
           let clientID = Bundle.main.object(forInfoDictionaryKey: "StreamDriveCloudflareClientID") as? String,
           !clientID.isEmpty, clientID.count <= 1024,
           clientID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            return CloudflareClientRegistration(clientID: clientID)
        }
        guard status == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size <= 8192,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.clientID.isEmpty, value.clientID.count <= 1024, value.callbackPort > 1023,
              value.clientID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw DriveError(ENOENT, "This development build needs a registered Cloudflare OAuth client. Configure its public client ID in Connections.")
        }
        return value
    }
}
