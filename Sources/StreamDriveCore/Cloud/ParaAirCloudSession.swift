import Foundation
import CryptoKit
import Darwin

public protocol ParaAirCloudTokenProvider: AnyObject, Sendable {
    func accessToken() throws -> String
    /// The service answered 401 for this token; the next `accessToken()` must not return it.
    func tokenRejected(_ token: String)
}

/// Access tokens for one saved account, shared by every engine in a process.
/// Reads the vault rarely, refreshes once for concurrent callers and serializes
/// refreshes across processes with `<stateRoot>/cloud-accounts/.lock`.
public final class ParaAirCloudSession: ParaAirCloudTokenProvider, @unchecked Sendable {
    public struct Options: Sendable, Hashable {
        public var minimumValidity: TimeInterval = 30
        public var reloadInterval: TimeInterval = 60
        public var lockTimeout: TimeInterval = 10
        public var proactiveWindow: TimeInterval? = nil
        public init() {}
    }

    public let accountID: String
    public let options: Options
    let store: CloudAccountStore
    private let vault: any ConnectionVault
    private let configuration: URLSessionConfiguration
    private let policy: ParaAirCloudTransportPolicy
    private let now: () -> Date
    private let condition = NSCondition()
    private var account: CloudAccount?
    private var tokens: OAuthTokens?
    private var loadedAt: Date?
    private var rejected: String?
    private var reloadRetryAt: Date?
    private var reloadDelay: TimeInterval = 0
    /// Rotated tokens the vault has not accepted yet, for the record version they belong to, and
    /// the refresh token the vault held when those rotations began. The previous tokens are never
    /// used again. A new sign-in (a newer record) supersedes them, and so do tokens another process
    /// saved since (the vault no longer holds `vaultBase`): those are newer, and saving ours over
    /// them would present a refresh token whose successor already rotated (spec 3.4 case 4).
    private var pendingSave: (secrets: ConnectionSecrets, recordUpdatedAt: Date, vaultBase: String?)?
    private var refreshing = false
    private var refreshGeneration = 0
    private var lastRefreshFailure: (generation: Int, error: Error)?
    private var cooldown: (fingerprint: Data, updatedAt: Date, checkedAt: Date, error: DriveError)?
    private var client: ParaAirCloudHTTP?

    private struct Key: Hashable {
        var root: String; var accountID: String; var configuration: ObjectIdentifier
        var policy: ParaAirCloudTransportPolicy; var options: Options
    }
    private final class WeakSession { weak var value: ParaAirCloudSession? }
    private static let registryLock = NSLock()
    private static var registry: [Key: WeakSession] = [:]

    /// One live session per (state root, account, URL configuration, policy, options) in this process.
    public static func shared(root: URL, accountID: String, vault: any ConnectionVault, configuration: URLSessionConfiguration,
                              policy: ParaAirCloudTransportPolicy, options: Options = .init()) throws -> ParaAirCloudSession {
        try ConnectionStore.validateID(accountID)
        let key = Key(root: root.standardizedFileURL.path, accountID: accountID, configuration: ObjectIdentifier(configuration),
                      policy: policy, options: options)
        registryLock.lock(); defer { registryLock.unlock() }
        registry = registry.filter { $0.value.value != nil }
        if let existing = registry[key]?.value { return existing }
        let session = try ParaAirCloudSession(root: root, accountID: accountID, vault: vault, configuration: configuration,
                                              policy: policy, options: options)
        let box = WeakSession(); box.value = session
        registry[key] = box
        return session
    }

    init(root: URL, accountID: String, vault: any ConnectionVault, configuration: URLSessionConfiguration,
         policy: ParaAirCloudTransportPolicy, options: Options = .init(), now: @escaping () -> Date = { Date() }) throws {
        try ConnectionStore.validateID(accountID)
        guard options.minimumValidity >= 0, options.reloadInterval > 0, options.lockTimeout >= 0 else {
            throw DriveError(EINVAL, "Invalid ParaAir Cloud session options")
        }
        self.store = CloudAccountStore(root: root); self.accountID = accountID; self.vault = vault
        self.configuration = configuration; self.policy = policy; self.options = options; self.now = now
    }

    /// The account's issuer never changes (it is part of the binding), so a loaded record suffices.
    public func issuer() throws -> URL {
        condition.lock(); defer { condition.unlock() }
        if account == nil { try reloadIfNeeded(force: true) }
        guard let account else { throw signedOut() }
        return try ParaAirCloudIssuer.validate(account.issuer)
    }

    /// One HTTP client per session, sharing its configuration and transport policy.
    public func http() throws -> ParaAirCloudHTTP {
        let issuer = try self.issuer()
        condition.lock(); defer { condition.unlock() }
        if let client { return client }
        let created = try ParaAirCloudHTTP(baseURL: issuer, policy: policy, configuration: configuration)
        client = created
        return created
    }

    public func accessToken() throws -> String { try token(validFor: options.minimumValidity, keepWorkingToken: true).token }

    public func tokenRejected(_ token: String) {
        condition.lock(); rejected = token; condition.unlock()
    }

    /// Refreshes when the token expires within `within` seconds; true when it refreshed.
    /// Unlike `accessToken()`, a failed refresh is reported even while the old token still works.
    @discardableResult public func refreshIfDue(within: TimeInterval) throws -> Bool {
        try token(validFor: max(within, 0), keepWorkingToken: false).refreshed
    }

    private func signedOut() -> DriveError { DriveError(EACCES, "Sign in to ParaAir Cloud", disposition: .attemptNotDispatched) }
    private func unreadableCredentials() -> DriveError {
        DriveError(EIO, "Saved ParaAir Cloud credentials could not be read", disposition: .attemptNotDispatched)
    }
    private func valid(_ tokens: OAuthTokens?, for seconds: TimeInterval) -> Bool {
        guard let tokens, let expiry = tokens.expiresAt else { return false }
        return expiry.timeIntervalSince(now()) > seconds
    }

    private func token(validFor seconds: TimeInterval, keepWorkingToken: Bool) throws -> (token: String, refreshed: Bool) {
        condition.lock(); defer { condition.unlock() }
        while true {
            let generation = refreshGeneration
            if refreshing {
                while refreshing { condition.wait() }
                if let failure = lastRefreshFailure, failure.generation == generation {
                    if keepWorkingToken, (failure.error as? DriveError)?.code != EACCES, let tokens, rejected != tokens.accessToken, valid(tokens, for: 1) {
                        return (tokens.accessToken, false)
                    }
                    throw failure.error
                }
                if let tokens, rejected != tokens.accessToken, valid(tokens, for: seconds) { return (tokens.accessToken, false) }
                continue
            }
            try checkCooldown()
            retryPendingSave()
            try reloadIfNeeded(force: false)
            guard let current = tokens else { throw signedOut() }
            if rejected != current.accessToken, valid(current, for: seconds) { return (current.accessToken, false) }
            refreshing = true
            condition.unlock()
            let outcome = Result { try performRefresh(current: current, validFor: seconds) }
            condition.lock()
            refreshing = false; refreshGeneration += 1
            defer { condition.broadcast() }
            switch outcome {
            case .success(let renewed):
                tokens = renewed.tokens; rejected = nil; lastRefreshFailure = nil
                return (renewed.tokens.accessToken, renewed.refreshed)
            case .failure(let error):
                lastRefreshFailure = (generation, error)
                // A transient failure keeps a token that still works and was not rejected.
                if keepWorkingToken, let drive = error as? DriveError, drive.code != EACCES, rejected != current.accessToken, valid(tokens, for: 1) {
                    return (tokens!.accessToken, false)
                }
                throw error
            }
        }
    }

    /// Reload when nothing is cached, after `reloadInterval`, near expiry, or after a rejection.
    /// Keychain or I/O failures keep a still-valid cached token and back off 5 s → 60 s.
    private func reloadIfNeeded(force: Bool) throws {
        let date = now()
        let due = force || tokens == nil || loadedAt.map { date.timeIntervalSince($0) >= options.reloadInterval } ?? true
            || !valid(tokens, for: options.minimumValidity) || (tokens != nil && rejected == tokens!.accessToken)
        guard due else { return }
        if let retryAt = reloadRetryAt, date < retryAt, tokens != nil, valid(tokens, for: 0) { return }
        let record: CloudAccount, secrets: ConnectionSecrets
        do {
            record = try store.load(accountID)
        } catch let error as DriveError where error.code == ENOENT {
            account = nil; tokens = nil; throw signedOut()
        } catch { try reloadFailed(error) ; return }
        guard record.state == .signedIn else { account = nil; tokens = nil; pendingSave = nil; throw signedOut() }
        // The Keychain reports every failure as EACCES; locked or unavailable is not sign-out (spec D9).
        do { secrets = try vault.load(id: accountID) } catch { try reloadFailed(unreadableCredentials()); return }
        guard secrets.binding == record.binding, let stored = secrets.oauth, !(stored.refreshToken ?? "").isEmpty else {
            account = nil; tokens = nil; pendingSave = nil; throw signedOut()
        }
        account = record; loadedAt = date; reloadRetryAt = nil; reloadDelay = 0
        // Unsaved rotated tokens are newer than the vault unless another process saved since they began.
        if let pending = pendingSave, pending.recordUpdatedAt == record.updatedAt, stored.refreshToken == pending.vaultBase { return }
        pendingSave = nil
        tokens = stored
    }

    private func reloadFailed(_ error: Error) throws {
        reloadDelay = reloadDelay == 0 ? 5 : min(60, reloadDelay * 2)
        reloadRetryAt = now().addingTimeInterval(reloadDelay)
        if tokens != nil, valid(tokens, for: 0), rejected != tokens?.accessToken { return }
        if let drive = error as? DriveError { throw DriveError(drive.code, drive.message, disposition: .attemptNotDispatched) }
        throw unreadableCredentials()
    }

    private func fingerprint(_ secrets: ConnectionSecrets) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: (try? encoder.encode(secrets)) ?? Data()))
    }

    /// After `invalid_grant`, fail without network until the vault holds different tokens.
    private func checkCooldown() throws {
        guard let blocked = cooldown else { return }
        let record = try? store.load(accountID)
        let changedRecord = record.map { $0.updatedAt != blocked.updatedAt } ?? false
        guard changedRecord || now().timeIntervalSince(blocked.checkedAt) >= options.reloadInterval else { throw blocked.error }
        if let record, record.state == .signedIn, let secrets = try? vault.load(id: accountID),
           fingerprint(secrets) != blocked.fingerprint {
            cooldown = nil; loadedAt = nil; rejected = nil
            return
        }
        cooldown = (blocked.fingerprint, record?.updatedAt ?? blocked.updatedAt, now(), blocked.error)
        throw blocked.error
    }

    private func retryPendingSave() {
        guard let pending = pendingSave else { return }
        do {
            try store.withLock(timeout: 0) {
                guard let record = try? store.load(accountID), record.state == .signedIn, record.updatedAt == pending.recordUpdatedAt,
                      record.binding == pending.secrets.binding,
                      try vault.load(id: accountID).oauth?.refreshToken == pending.vaultBase else { loadedAt = nil; return }
                try vault.save(pending.secrets, id: accountID)
            }
            pendingSave = nil
        } catch {}
    }

    private struct Renewed { var tokens: OAuthTokens; var refreshed: Bool }

    /// Runs without the in-process lock held; only the cross-process account lock.
    private func performRefresh(current: OAuthTokens, validFor seconds: TimeInterval) throws -> Renewed {
        let http = try self.http()
        let rejectedToken: String? = { condition.lock(); defer { condition.unlock() }; return rejected }()
        do {
            return try store.withLock(timeout: options.lockTimeout) {
                let record = try store.load(accountID)
                guard record.state == .signedIn else { throw signedOut() }
                let pending: (secrets: ConnectionSecrets, vaultBase: String?)? = {
                    condition.lock(); defer { condition.unlock() }
                    if let saved = pendingSave, saved.recordUpdatedAt != record.updatedAt { pendingSave = nil }
                    return pendingSave.map { ($0.secrets, $0.vaultBase) }
                }()
                let secrets: ConnectionSecrets
                do { secrets = try vault.load(id: accountID) } catch { throw unreadableCredentials() }
                guard secrets.binding == record.binding, let stored = secrets.oauth, !(stored.refreshToken ?? "").isEmpty else { throw signedOut() }
                var base = stored, vaultBase = stored.refreshToken
                if let pending, let ours = pending.secrets.oauth, stored.refreshToken == pending.vaultBase {
                    // Nobody saved since our unsaved rotations began, so ours are the newest tokens.
                    base = ours; vaultBase = pending.vaultBase
                    if (try? vault.save(pending.secrets, id: accountID)) != nil { clearPendingSave(); vaultBase = ours.refreshToken }
                } else {
                    // Tokens another process saved since replace ours. It may already have rotated them.
                    if pending != nil { clearPendingSave() }
                    if stored.accessToken != current.accessToken, stored.accessToken != rejectedToken, valid(stored, for: max(seconds, 30)) {
                        return Renewed(tokens: stored, refreshed: false)
                    }
                }
                guard let refreshToken = base.refreshToken, !refreshToken.isEmpty else { throw signedOut() }
                let renewed = try exchange(refreshToken: refreshToken, previous: base, http: http, record: record)
                let rotated = ConnectionSecrets(binding: record.binding, oauth: renewed)
                do { try vault.save(rotated, id: accountID); clearPendingSave() }
                catch { condition.lock(); pendingSave = (rotated, record.updatedAt, vaultBase); condition.unlock() }
                return Renewed(tokens: renewed, refreshed: true)
            }
        } catch let error as DriveError where error.code == EBUSY {
            throw DriveError(ETIMEDOUT, "Another ParaAir process is renewing ParaAir Cloud access", disposition: .attemptNotDispatched)
        }
    }

    private func clearPendingSave() { condition.lock(); pendingSave = nil; condition.unlock() }

    private func exchange(refreshToken: String, previous: OAuthTokens, http: ParaAirCloudHTTP, record: CloudAccount) throws -> OAuthTokens {
        let body = oauthFormBody(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": ParaAirCloudConfiguration.clientID])
        let request = ParaAirCloudHTTP.Request(method: "POST", path: "/oauth/token",
                                               headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body,
                                               maxResponseBytes: 1 << 20, route: "POST /oauth/token")
        let response: ParaAirCloudHTTP.Response
        do { response = try http.sendSync(request, bearer: nil) }
        catch let error as DriveError { throw error.with(.attemptNotDispatched) }
        do {
            let renewed = try OAuthTokenResponse.parse(OAuthHTTPResponse(statusCode: response.status, data: response.body, headers: response.headers), now: now())
            guard renewed.expiresAt != nil else { throw OAuthError.invalidTokenResponse }
            return OAuthTokens(accessToken: renewed.accessToken, refreshToken: renewed.refreshToken ?? refreshToken,
                               expiresAt: renewed.expiresAt, tokenType: renewed.tokenType, scope: renewed.scope ?? previous.scope)
        } catch let error as OAuthError {
            switch error {
            case .expired, .httpStatus(400), .httpStatus(401), .httpStatus(403):
                let denied = DriveError(EACCES, "ParaAir Cloud sign-in ended. Sign in again.", disposition: .attemptNotDispatched)
                let stored = (try? vault.load(id: accountID)) ?? ConnectionSecrets(binding: record.binding, oauth: previous)
                condition.lock()
                cooldown = (fingerprint(stored), record.updatedAt, now(), denied)
                condition.unlock()
                throw denied
            case .httpStatus(429):
                throw DriveError(EAGAIN, "ParaAir Cloud is busy. Try again shortly", disposition: .attemptNotDispatched)
            case .httpStatus(let status) where status >= 500:
                throw DriveError(EIO, "ParaAir Cloud is temporarily unavailable (HTTP \(status))", disposition: .attemptNotDispatched)
            default:
                throw DriveError(EPROTO, "ParaAir Cloud returned an invalid sign-in response", disposition: .attemptNotDispatched)
            }
        }
    }
}

/// A fixed token for calls made before an account record exists (sign-in).
public final class StaticAccessToken: ParaAirCloudTokenProvider, @unchecked Sendable {
    private let token: String
    private let lock = NSLock()
    private var rejected = false
    public init(_ token: String) { self.token = token }
    public func accessToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !rejected else { throw DriveError(EACCES, "Sign in to ParaAir Cloud", disposition: .attemptNotDispatched) }
        return token
    }
    public func tokenRejected(_ token: String) { lock.lock(); if token == self.token { rejected = true }; lock.unlock() }
}
