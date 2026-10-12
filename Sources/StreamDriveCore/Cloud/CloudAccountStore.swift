import Foundation
import CryptoKit
import Darwin

public enum CloudAccountState: String, Codable, Sendable { case signedIn, signedOut }

/// A public ParaAir Cloud account reference in `<stateRoot>/cloud-accounts/<id>.json`.
/// Tokens live only in the vault (Keychain service `dev.streamdrive.cloud`), bound to `binding`.
public struct CloudAccount: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    /// Lowercase UUID; also the Keychain account name.
    public var id: String
    public var issuer: String
    public var userID: String
    public var email: String
    public var state: CloudAccountState
    public var updatedAt: Date
    /// sha256 hex of the JSON array `[id, issuer, userID]`.
    public var binding: String

    public init(id: String = UUID().uuidString.lowercased(), issuer: String, userID: String, email: String,
                state: CloudAccountState = .signedIn, updatedAt: Date = Date()) {
        self.id = id; self.issuer = issuer; self.userID = userID; self.email = email
        self.state = state; self.updatedAt = updatedAt
        binding = Self.binding(id: id, issuer: issuer, userID: userID)
    }

    public static func binding(id: String, issuer: String, userID: String) -> String {
        let data = try! JSONEncoder().encode([id, issuer, userID])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        try ConnectionStore.validateID(id)
        _ = try ParaAirCloudIssuer.validate(issuer)
        guard schemaVersion == 1, ParaAirCloudIDs.isUserID(userID), !email.isEmpty, email.utf8.count <= 254,
              !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              binding == Self.binding(id: id, issuer: issuer, userID: userID) else {
            throw DriveError(EINVAL, "Invalid saved ParaAir Cloud account")
        }
    }
}

public final class CloudAccountStore: @unchecked Sendable {
    public static let keychainService = "dev.streamdrive.cloud"
    public static var liveVault: any ConnectionVault { KeychainConnectionVault(service: keychainService) }
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    var directory: URL { root.appendingPathComponent("cloud-accounts", isDirectory: true) }
    public var lockURL: URL { directory.appendingPathComponent(".lock") }

    private func check(_ url: URL, directory: Bool) throws {
        var s = Darwin.stat()
        if lstat(url.path, &s) == 0 {
            guard s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
                throw DriveError(EACCES, "Account state cannot use symbolic links or special files")
            }
            if !directory && s.st_size > 65536 { throw DriveError(EINVAL, "Account record exceeds the permitted size") }
        } else if errno != ENOENT { throw DriveError(errno, "Cannot access account state") }
    }
    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    private func write(_ account: CloudAccount) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableIO.write(encoder.encode(account), to: file(account.id))
    }
    /// Account changes are serialized with token refreshes in every process.
    func withLock<T>(timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        try check(directory, directory: true); try DurableIO.directory(directory)
        return try StateLock(lockURL).withLock(timeout: timeout, body)
    }

    /// Never throws because of one bad record; unreadable ids (or file names) are reported.
    public func list() -> (accounts: [CloudAccount], unreadable: [String]) {
        do { try check(directory, directory: true) } catch { return ([], ["cloud-accounts"]) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return ([], []) }
        var accounts: [CloudAccount] = [], unreadable: [String] = []
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = url.deletingPathExtension().lastPathComponent
            if let account = try? load(id) { accounts.append(account) } else { unreadable.append(id) }
        }
        return (accounts, unreadable)
    }

    /// ENOENT when missing; EINVAL when invalid; EACCES for symbolic links or special files.
    public func load(_ id: String) throws -> CloudAccount {
        try ConnectionStore.validateID(id); try check(directory, directory: true)
        let url = file(id); try check(url, directory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DriveError(ENOENT, "ParaAir Cloud account is not saved on this Mac") }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(CloudAccount.self, from: data), value.id == id else {
            throw DriveError(EINVAL, "Saved ParaAir Cloud account is invalid")
        }
        try value.validate()
        return value
    }

    public func existing(issuer: String, userID: String) -> CloudAccount? {
        list().accounts.first { $0.issuer == issuer && $0.userID == userID }
    }

    /// Saves the tokens first; the record says `.signedIn` only once they are in the vault.
    public func signIn(_ account: CloudAccount, tokens: OAuthTokens, vault: any ConnectionVault) throws {
        var record = account
        record.state = .signedIn; record.updatedAt = Date()
        try record.validate()
        guard tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty, !(tokens.refreshToken ?? "").isEmpty else {
            throw DriveError(EINVAL, "ParaAir Cloud sign-in returned incomplete credentials")
        }
        try withLock {
            try check(file(record.id), directory: false)
            if FileManager.default.fileExists(atPath: file(record.id).path) {
                let previous = try load(record.id)
                guard previous.binding == record.binding else {
                    throw DriveError(EXDEV, "This saved account belongs to another ParaAir Cloud user. Sign in again to add it.")
                }
            }
            try vault.save(ConnectionSecrets(binding: record.binding, oauth: tokens), id: record.id)
            try write(record)
        }
    }

    /// Marks the record signed out first, so no process can use it, then removes and
    /// returns the stored tokens for a best-effort revoke outside the lock.
    @discardableResult
    public func signOut(_ id: String, vault: any ConnectionVault) throws -> OAuthTokens? {
        try withLock {
            var record = try load(id)
            let captured = (try? vault.load(id: id)).flatMap { $0.binding == record.binding ? $0.oauth : nil }
            record.state = .signedOut; record.updatedAt = Date()
            try write(record)
            try vault.remove(id: id)
            return captured
        }
    }

    /// `.signedOut` → EACCES; tokens bound to another record → EXDEV; no refresh token → EACCES.
    public func credentials(_ id: String, vault: any ConnectionVault) throws -> (CloudAccount, OAuthTokens) {
        let record = try load(id)
        guard record.state == .signedIn else { throw DriveError(EACCES, "Sign in to ParaAir Cloud") }
        let secrets = try vault.load(id: id)
        guard secrets.binding == record.binding else { throw DriveError(EXDEV, "Saved ParaAir Cloud credentials belong to a different account") }
        guard let tokens = secrets.oauth, tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty,
              !(tokens.refreshToken ?? "").isEmpty else { throw DriveError(EACCES, "Sign in to ParaAir Cloud") }
        return (record, tokens)
    }
}
