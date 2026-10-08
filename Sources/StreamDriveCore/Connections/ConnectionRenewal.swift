import Foundation

public struct ConnectionRenewalReport: Sendable, Equatable {
    public var renewed: [String] = []
    public var errors: [String: String] = [:]
    public var alreadyRunning = false
    public init() {}
}

/// Retains previous credentials on transient failures and never changes a storage target.
/// Use one long-lived actor per app process; overlapping timer callbacks do not issue duplicate renewals.
public actor ConnectionRenewal {
    private let root: URL
    private let vault: any ConnectionVault
    private let transport: any OAuthTransport
    private let now: @Sendable () -> Date
    private var running = false
    private var denied: [String: (updatedAt: Date, binding: String, message: String)] = [:]

    public init(root: URL, vault: any ConnectionVault = KeychainConnectionVault(),
                transport: any OAuthTransport = URLSessionOAuthTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.vault = vault; self.transport = transport; self.now = now
    }

    public func renewDueConnections() async -> ConnectionRenewalReport {
        var report = ConnectionRenewalReport()
        guard !running else { report.alreadyRunning = true; return report }
        running = true; defer { running = false }
        let store = ConnectionStore(root: root)
        let records: [StorageConnection]
        do { records = try store.list() }
        catch { report.errors["connections"] = "Saved connections could not be read."; return report }
        let activeIDs = Set(records.filter { $0.state == .storageReady }.map(\.id))
        denied = denied.filter { activeIDs.contains($0.key) }
        for record in records where record.state == .storageReady {
            if Task.isCancelled { break }
            if let blocked = denied[record.id], blocked.updatedAt == record.updatedAt,
               blocked.binding == record.credentialBinding {
                report.errors[record.id] = blocked.message
                continue
            }
            denied[record.id] = nil
            do {
                let secrets = try vault.load(id: record.id)
                guard secrets.binding == record.credentialBinding else { throw RenewalError.changed }
                let dates = [secrets.storageExpiresAt, record.provider == .cloudflareR2 ? secrets.oauth?.expiresAt : nil].compactMap { $0 }
                guard let expiry = dates.min(), expiry <= now().addingTimeInterval(120) else { continue }
                switch record.provider {
                case .cloudflareR2:
                    guard let oauth = secrets.oauth else { throw OAuthError.invalidTokenResponse }
                    let registration = try CloudflareClientRegistration.load(stateRoot: root)
                    let config = try CloudflareR2Provider.oauthConfiguration(clientID: registration.clientID, redirectURI: registration.redirectURI)
                    let client = OAuthClient(configuration: config, transport: transport, now: now)
                    let refreshed = try await client.refresh(oauth)
                    var updated = secrets
                    updated.oauth = refreshed; updated.s3 = nil
                    // Preserve refresh rotation even if the provider omitted its required access expiry.
                    updated.storageExpiresAt = refreshed.expiresAt ?? now()
                    try saveIfUnchanged(updated, expected: secrets, record: record)
                    guard refreshed.expiresAt != nil else { throw OAuthError.invalidTokenResponse }
                case .awsS3:
                    guard let data = secrets.providerSession, data.count <= 131072,
                          var session = try? JSONDecoder().decode(AWSAccessSession.self, from: data),
                          let account = record.accountID, let role = record.roleName,
                          record.startURL == nil || record.startURL == session.startURL.absoluteString else { throw OAuthError.invalidConfiguration }
                    let client = AWSIdentityCenterClient(transport: transport, now: now)
                    var expected = secrets
                    if session.expiresAt <= now().addingTimeInterval(120) {
                        session = try await client.refresh(session: session)
                        var checkpoint = expected
                        checkpoint.providerSession = try JSONEncoder().encode(session)
                        // A rotated refresh token must survive a later failure fetching role credentials.
                        try saveIfUnchanged(checkpoint, expected: expected, record: record)
                        expected = checkpoint
                    }
                    let credentials = try await client.credentials(accountID: account, roleName: role, session: session)
                    var updated = expected
                    updated.s3 = credentials.credentials; updated.storageExpiresAt = credentials.expiresAt
                    try saveIfUnchanged(updated, expected: expected, record: record)
                case .backblazeB2, .customS3:
                    throw RenewalError.manualCredentials
                }
                report.renewed.append(record.id)
            } catch is CancellationError { break }
            catch {
                let message = sanitized(error)
                report.errors[record.id] = message
                if let access = error as? DriveError, access.code == EACCES {
                    denied[record.id] = (record.updatedAt, record.credentialBinding, message)
                }
            }
        }
        return report
    }

    private func saveIfUnchanged(_ updated: ConnectionSecrets, expected: ConnectionSecrets, record: StorageConnection) throws {
        try Task.checkCancellation()
        let lock = try StateLock(root.appendingPathComponent("connections/.lock"))
        try lock.withLock {
            try Task.checkCancellation()
            let current = try ConnectionStore(root: root).load(record.id)
            guard current.state == .storageReady, current.credentialBinding == record.credentialBinding,
                  updated.binding == current.credentialBinding else { throw RenewalError.changed }
            let stored = try vault.load(id: record.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(stored) == encoder.encode(expected) else { throw RenewalError.changed }
            try Task.checkCancellation()
            try vault.save(updated, id: record.id)
        }
    }

    private enum RenewalError: Error { case changed, manualCredentials }
    private func sanitized(_ error: Error) -> String {
        if let error = error as? RenewalError {
            switch error {
            case .changed: return "Connection changed during renewal. Its current credentials were retained."
            case .manualCredentials: return "This connection needs renewed storage credentials in Connections."
            }
        }
        if let error = error as? OAuthError {
            switch error {
            case .expired, .authorizationDenied, .missingRefreshToken: return "Authorization cannot be renewed. Sign in again in Connections."
            default: return error.localizedDescription
            }
        }
        if let error = error as? DriveError, error.code == EACCES {
            return "Saved credentials are unavailable to this build. Automatic access is paused until the connection is updated. No password dialog will be opened."
        }
        if error is DriveError { return "Connection credentials or registration are unavailable. Open Storage settings to review access." }
        return "Storage authorization could not be renewed. Existing credentials were retained."
    }
}
