import Foundation

/// Per-record result of one renewal pass, keyed by connection id in the report.
public enum RenewalOutcome: String, Sendable, Equatable {
    case notDue, renewed, deniedCached, registrationMissing, registrationMissingNotYetDue
    case authorizationEnded, changed, manualCredentials, transientFailure, failed

    /// Transient and not-yet-due problems keep existing credentials usable.
    public var blocksAutoMount: Bool {
        switch self {
        case .deniedCached, .registrationMissing, .authorizationEnded, .manualCredentials, .failed: return true
        case .notDue, .renewed, .registrationMissingNotYetDue, .changed, .transientFailure: return false
        }
    }
}

public struct ConnectionRenewalReport: Sendable, Equatable {
    public var renewed: [String] = []
    public var errors: [String: String] = [:]
    public var alreadyRunning = false
    public var outcomes: [String: RenewalOutcome] = [:]
    /// Connection records skipped because they could not be decoded or validated.
    public var unreadableRecords = 0
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
        do {
            let listing = try store.listReport()
            records = listing.records; report.unreadableRecords = listing.unreadable.count
        } catch { report.errors["connections"] = "Saved connections could not be read."; return report }
        let activeIDs = Set(records.filter { $0.state == .storageReady }.map(\.id))
        denied = denied.filter { activeIDs.contains($0.key) }
        for record in records where record.state == .storageReady {
            if Task.isCancelled { break }
            if let blocked = denied[record.id], blocked.updatedAt == record.updatedAt,
               blocked.binding == record.credentialBinding {
                report.errors[record.id] = blocked.message
                report.outcomes[record.id] = .deniedCached
                continue
            }
            denied[record.id] = nil
            do {
                let secrets = try vault.load(id: record.id)
                // A storageReady record's binding never changes (ConnectionStore refuses it), so a
                // mismatch here is persistent and the extension would refuse these credentials.
                guard secrets.binding == record.credentialBinding else { throw RenewalError.bindingMismatch }
                // Resolve the registration before the due check, so a build that
                // could never renew is reported while the token still works.
                var registration: CloudflareClientRegistration?
                if record.provider == .cloudflareR2 { registration = try? CloudflareClientRegistration.load(stateRoot: root) }
                let dates = [secrets.storageExpiresAt, record.provider == .cloudflareR2 ? secrets.oauth?.expiresAt : nil].compactMap { $0 }
                guard let expiry = dates.min(), expiry <= now().addingTimeInterval(120) else {
                    if record.provider == .cloudflareR2, registration == nil {
                        report.errors[record.id] = sanitized(RenewalError.registrationMissing)
                        report.outcomes[record.id] = .registrationMissingNotYetDue
                    } else { report.outcomes[record.id] = .notDue }
                    continue
                }
                switch record.provider {
                case .cloudflareR2:
                    guard let oauth = secrets.oauth else { throw OAuthError.invalidTokenResponse }
                    guard let registration else { throw RenewalError.registrationMissing }
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
                report.outcomes[record.id] = .renewed
            } catch is CancellationError { break }
            catch {
                let message = sanitized(error)
                report.errors[record.id] = message
                report.outcomes[record.id] = outcome(for: error)
                if let access = error as? DriveError, access.code == EACCES {
                    denied[record.id] = (record.updatedAt, record.credentialBinding, message)
                }
            }
        }
        return report
    }

    /// Only failures that leave current credentials usable are non-blocking.
    private func outcome(for error: Error) -> RenewalOutcome {
        if let error = error as? RenewalError {
            switch error {
            case .changed: return .changed
            case .bindingMismatch: return .failed
            case .manualCredentials: return .manualCredentials
            case .registrationMissing: return .registrationMissing
            }
        }
        if let error = error as? OAuthError {
            switch error {
            case .expired, .authorizationDenied, .missingRefreshToken: return .authorizationEnded
            case .requestFailed, .timedOut: return .transientFailure
            case .httpStatus(let status) where status == 408 || status == 429 || status >= 500: return .transientFailure
            default: return .failed
            }
        }
        if error is URLError { return .transientFailure }
        if let error = error as? DriveError,
           [ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNRESET, ECONNREFUSED, ETIMEDOUT, ENOTCONN].contains(error.code) {
            return .transientFailure
        }
        return .failed
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

    private enum RenewalError: Error { case changed, bindingMismatch, manualCredentials, registrationMissing }
    private func sanitized(_ error: Error) -> String {
        if let error = error as? RenewalError {
            switch error {
            case .changed: return "Connection changed during renewal. Its current credentials were retained."
            case .bindingMismatch: return "Saved credentials belong to a different storage target. Sign in again in Connections."
            case .manualCredentials: return "This connection needs renewed storage credentials in Connections."
            case .registrationMissing:
                return "This build has no Cloudflare OAuth client registration, so sign-in can't be renewed. Add the public client ID in Storage Settings, or rebuild with STREAMDRIVE_CLOUDFLARE_CLIENT_ID."
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
