import XCTest
import Darwin
@testable import StreamDriveCore

/// An in-memory vault whose loads and saves can be counted or made to fail like a locked Keychain.
final class CountingVault: ConnectionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ConnectionSecrets] = [:]
    private var loadCount = 0
    var failLoads = false
    var failSaves = false
    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    func load(id: String) throws -> ConnectionSecrets {
        lock.lock(); defer { lock.unlock() }
        loadCount += 1
        if failLoads { throw DriveError(EACCES, "Test Keychain is locked") }
        guard let value = values[id] else { throw DriveError(EACCES, "Test vault entry is missing") }
        return value
    }
    func save(_ secrets: ConnectionSecrets, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw DriveError(EACCES, "Test Keychain is locked") }
        values[id] = secrets
    }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
    func stored(_ id: String) -> OAuthTokens? { lock.lock(); defer { lock.unlock() }; return values[id]?.oauth }
}

/// One process's view of a shared vault whose own saves can fail (its Keychain write failing).
private final class SplitVault: ConnectionVault, @unchecked Sendable {
    let base: CountingVault
    var failSaves = false
    init(_ base: CountingVault) { self.base = base }
    func load(id: String) throws -> ConnectionSecrets { try base.load(id: id) }
    func save(_ secrets: ConnectionSecrets, id: String) throws {
        if failSaves { throw DriveError(EACCES, "Test Keychain write failed") }
        try base.save(secrets, id: id)
    }
    func remove(id: String) throws { try base.remove(id: id) }
}

final class ParaAirCloudSessionTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var vault: CountingVault!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = CountingVault()
    }

    private func signIn(accessTTL: TimeInterval? = nil, expiresAt: Date? = nil) throws -> CloudAccount {
        let record = try fake.saveAccount(account, root: root, vault: vault, accessTTL: accessTTL)
        if let expiresAt, let tokens = vault.stored(record.id) {
            try vault.save(ConnectionSecrets(binding: record.binding, oauth: OAuthTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                                                                         expiresAt: expiresAt, scope: tokens.scope)), id: record.id)
        }
        return record
    }
    private func session(_ record: CloudAccount, options: ParaAirCloudSession.Options = .init(), now: @escaping () -> Date = { Date() },
                         policy: ParaAirCloudTransportPolicy = .init(allowsLoopbackHTTP: false)) throws -> ParaAirCloudSession {
        try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration, policy: policy,
                                options: options, now: now)
    }

    func testAccessTokenReusedWithoutVaultReads() throws {
        let record = try signIn()
        let session = try session(record)
        let first = try session.accessToken()
        for _ in 0..<50 { XCTAssertEqual(try session.accessToken(), first) }
        XCTAssertEqual(vault.loads, 1)
        XCTAssertEqual(fake.tokenRequests, 0)
        let shared = try ParaAirCloudSession.shared(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                                    policy: .init(allowsLoopbackHTTP: false))
        XCTAssertTrue(shared === (try ParaAirCloudSession.shared(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                                                  policy: .init(allowsLoopbackHTTP: false))))
        var other = ParaAirCloudSession.Options(); other.minimumValidity = 5
        XCTAssertFalse(shared === (try ParaAirCloudSession.shared(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                                                   policy: .init(allowsLoopbackHTTP: false), options: other)))
    }

    func testConcurrentCallersShareOneRefresh() throws {
        let record = try signIn(expiresAt: Date().addingTimeInterval(10))
        let session = try session(record)
        let stale = vault.stored(record.id)!.accessToken
        let tokens = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let token = try? session.accessToken()
            objc_sync_enter(tokens); tokens.add(token ?? "failed"); objc_sync_exit(tokens)
        }
        XCTAssertEqual(fake.tokenRequests, 1)
        XCTAssertEqual(Set(tokens.compactMap { $0 as? String }).count, 1)
        XCTAssertNotEqual(tokens.firstObject as? String, stale)
        XCTAssertEqual(vault.stored(record.id)?.accessToken, tokens.firstObject as? String)
    }

    func testRefreshAdoptsTokenRotatedByAnotherProcess() throws {
        let record = try signIn(expiresAt: Date().addingTimeInterval(10))
        let first = try session(record), second = try session(record)
        XCTAssertEqual(vault.stored(record.id)?.expiresAt.map { $0 < Date().addingTimeInterval(30) }, true)
        let rotated = try first.accessToken()
        XCTAssertEqual(fake.tokenRequests, 1)
        XCTAssertEqual(try second.accessToken(), rotated)
        XCTAssertEqual(fake.tokenRequests, 1)
        // A 401 for a token another process already replaced is answered from the vault.
        let third = try session(record)
        XCTAssertEqual(try third.accessToken(), rotated)
        fake.expireAccessTokens()
        third.tokenRejected(rotated)
        let renewed = try third.accessToken()
        XCTAssertNotEqual(renewed, rotated)
        XCTAssertEqual(fake.tokenRequests, 2)
        first.tokenRejected(rotated)
        XCTAssertEqual(try first.accessToken(), renewed)
        XCTAssertEqual(fake.tokenRequests, 2)
    }

    func testRefreshLockTimesOutAsETIMEDOUT() throws {
        let record = try signIn(expiresAt: Date().addingTimeInterval(-10))
        var options = ParaAirCloudSession.Options(); options.lockTimeout = 0.2
        let session = try session(record, options: options)
        let holder = try StateLock(CloudAccountStore(root: root).lockURL)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread { try? holder.withLock { held.signal(); release.wait() } }
        held.wait()
        expectDriveError(ETIMEDOUT, disposition: .attemptNotDispatched) { _ = try session.accessToken() }
        XCTAssertEqual(fake.tokenRequests, 0)
        release.signal()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNoThrow(try session.accessToken())
        XCTAssertEqual(fake.tokenRequests, 1)
    }

    func testVaultSaveFailureKeepsRotatedTokensInMemory() throws {
        let record = try signIn(expiresAt: Date().addingTimeInterval(-10))
        let original = vault.stored(record.id)!
        let session = try session(record)
        vault.failSaves = true
        let rotated = try session.accessToken()
        XCTAssertNotEqual(rotated, original.accessToken)
        XCTAssertEqual(vault.stored(record.id)?.accessToken, original.accessToken)
        XCTAssertEqual(try session.accessToken(), rotated, "the old tokens are never used again")
        XCTAssertEqual(fake.tokenRequests, 1)
        vault.failSaves = false
        XCTAssertEqual(try session.accessToken(), rotated)
        XCTAssertEqual(vault.stored(record.id)?.accessToken, rotated)
        XCTAssertNotEqual(vault.stored(record.id)?.refreshToken, original.refreshToken)
    }

    func testKeychainLockedKeepsCachedToken() throws {
        let record = try signIn()
        let clock = CloudTestClock()
        let session = try session(record, now: clock.now)
        let token = try session.accessToken()
        XCTAssertEqual(vault.loads, 1)
        clock.advance(61)
        vault.failLoads = true
        XCTAssertEqual(try session.accessToken(), token)
        XCTAssertEqual(vault.loads, 2)
        XCTAssertEqual(try session.accessToken(), token)
        XCTAssertEqual(vault.loads, 2, "reloads back off after a failure")
        clock.advance(6)
        XCTAssertEqual(try session.accessToken(), token)
        XCTAssertEqual(vault.loads, 3)
        clock.advance(3600)
        XCTAssertThrowsError(try session.accessToken())
        XCTAssertEqual(fake.tokenRequests, 0)
        vault.failLoads = false
        clock.advance(120)
        XCTAssertNotEqual(try session.accessToken(), token, "once readable, the expired token is refreshed")
        XCTAssertEqual(fake.tokenRequests, 1)
    }

    /// Spec 6.4: a locked or unavailable Keychain is not sign-out, even with nothing cached.
    func testKeychainReadFailureWithoutCachedTokenIsTransient() throws {
        let record = try signIn()
        vault.failLoads = true
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try self.session(record).accessToken() }
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try self.session(record).http() }
        XCTAssertEqual(fake.tokenRequests, 0)
        vault.failLoads = false
        XCTAssertEqual(try session(record).accessToken(), vault.stored(record.id)?.accessToken)
    }

    /// Process A rotates while its Keychain save fails, then idles; process B rotates three
    /// times. A's retried save must not put its older refresh token back over B's newest:
    /// the next refresh would present a token whose successor is already rotated (spec 3.4
    /// case 4), and the service would revoke the grant.
    func testPendingSaveNeverOverwritesNewerVaultTokens() throws {
        let record = try signIn()
        let viewA = SplitVault(vault)
        let a = try ParaAirCloudSession(root: root, accountID: record.id, vault: viewA, configuration: fake.configuration,
                                        policy: .init(allowsLoopbackHTTP: false))
        let b = try session(record)
        let original = try XCTUnwrap(vault.stored(record.id)?.refreshToken)
        viewA.failSaves = true
        XCTAssertTrue(try a.refreshIfDue(within: 1e6))
        XCTAssertEqual(vault.stored(record.id)?.refreshToken, original)
        for _ in 0..<3 { XCTAssertTrue(try b.refreshIfDue(within: 1e6)) }
        let newest = try XCTUnwrap(vault.stored(record.id))
        viewA.failSaves = false
        XCTAssertEqual(try a.accessToken(), newest.accessToken, "A adopts the newer tokens instead of saving its own")
        XCTAssertEqual(vault.stored(record.id)?.refreshToken, newest.refreshToken, "the vault never moves back to an older refresh token")
        XCTAssertTrue(try b.refreshIfDue(within: 1e6), "the grant survives")
        XCTAssertTrue(try a.refreshIfDue(within: 1e6))
    }

    /// The same, when A's quick save retry is skipped because another process holds the account
    /// lock: A's refresh then waits for the lock and must refresh from the vault's newer tokens.
    func testRefreshWithPendingTokensAdoptsNewerVaultTokens() throws {
        let record = try signIn()
        let viewA = SplitVault(vault)
        let a = try ParaAirCloudSession(root: root, accountID: record.id, vault: viewA, configuration: fake.configuration,
                                        policy: .init(allowsLoopbackHTTP: false))
        let b = try session(record)
        viewA.failSaves = true
        XCTAssertTrue(try a.refreshIfDue(within: 1e6))
        for _ in 0..<3 { XCTAssertTrue(try b.refreshIfDue(within: 1e6)) }
        let newest = try XCTUnwrap(vault.stored(record.id)?.refreshToken)
        viewA.failSaves = false
        let holder = try StateLock(CloudAccountStore(root: root).lockURL)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread { try? holder.withLock { held.signal(); release.wait() } }
        held.wait()
        var outcome: Result<Bool, Error>?
        Thread.detachNewThread { outcome = Result { try a.refreshIfDue(within: 1e6) }; finished.signal() }
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(try XCTUnwrap(outcome).get(), true)
        XCTAssertNotEqual(vault.stored(record.id)?.refreshToken, newest, "A rotated the newest refresh token and saved the result")
        XCTAssertTrue(try b.refreshIfDue(within: 1e6), "the grant survives")
    }

    func testSignedOutRecordIsEACCES() throws {
        let record = try signIn()
        let clock = CloudTestClock()
        let live = try session(record, now: clock.now)
        XCTAssertNoThrow(try live.accessToken())
        _ = try CloudAccountStore(root: root).signOut(record.id, vault: vault)
        expectDriveError(EACCES) { _ = try self.session(record).accessToken() }
        clock.advance(61)
        expectDriveError(EACCES) { _ = try live.accessToken() }
        expectDriveError(EACCES) { _ = try live.http() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("cloud-accounts/\(record.id).json"))
        expectDriveError(EACCES) { _ = try self.session(record).accessToken() }
    }

    func testInvalidGrantCoolsDownUntilVaultChanges() throws {
        let record = try signIn(expiresAt: Date().addingTimeInterval(-10))
        let session = try session(record)
        fake.revokeRefreshTokens()
        expectDriveError(EACCES) { _ = try session.accessToken() }
        XCTAssertEqual(fake.tokenRequests, 1)
        expectDriveError(EACCES) { _ = try session.accessToken() }
        expectDriveError(EACCES) { _ = try session.accessToken() }
        XCTAssertEqual(fake.tokenRequests, 1, "no network until the stored credentials change")
        try CloudAccountStore(root: root).signIn(record, tokens: fake.issueTokens(for: account), vault: vault)
        XCTAssertEqual(try session.accessToken(), vault.stored(record.id)?.accessToken)
        XCTAssertEqual(fake.tokenRequests, 1)
    }

    func testPolicyRejectsHTTPUnlessLoopbackAllowed() throws {
        let loopback = CloudAccount(issuer: "http://127.0.0.1:8787", userID: account.userID, email: account.email)
        try CloudAccountStore(root: root).signIn(loopback, tokens: fake.issueTokens(for: account), vault: vault)
        expectDriveError(EACCES) { _ = try self.session(loopback).http() }
        XCTAssertEqual(try session(loopback, policy: .init(allowsLoopbackHTTP: true)).http().baseURL.absoluteString, "http://127.0.0.1:8787")
        let denied = ParaAirCloudTransportPolicy(allowsLoopbackHTTP: false), allowed = ParaAirCloudTransportPolicy(allowsLoopbackHTTP: true)
        for value in ["http://127.0.0.1:8787", "http://localhost:8787", "https://user@cloud.example", "https://cloud.example/path", "https://cloud.example?x=1"] {
            expectDriveError(EACCES) { try denied.validate(URL(string: value)!) }
        }
        XCTAssertNoThrow(try denied.validate(URL(string: "https://cloud.example")!))
        XCTAssertNoThrow(try denied.validate(URL(string: "https://cloud.example/")!))
        XCTAssertNoThrow(try allowed.validate(URL(string: "http://127.0.0.1:8787")!))
        expectDriveError(EACCES) { try allowed.validate(URL(string: "http://127.0.0.1")!) }
        expectDriveError(EACCES) { try allowed.validate(URL(string: "http://[::1]:8787")!) }
        for value in ["https://cloud.example", "https://cloud.example:8443", "http://127.0.0.1:8787"] { XCTAssertNoThrow(try ParaAirCloudIssuer.validate(value)) }
        for value in ["https://cloud.example/", "http://cloud.example", "https://user@cloud.example", "http://localhost:8787", "https://", "https://a..b", "ftp://x"] {
            expectDriveError(EINVAL) { _ = try ParaAirCloudIssuer.validate(value) }
        }
        XCTAssertEqual(ParaAirCloudTransportPolicy.current(info: ["ParaAirCloudAllowLoopbackHTTP": true], environment: [:]).allowsLoopbackHTTP, true)
        XCTAssertEqual(ParaAirCloudTransportPolicy.current(info: [:], environment: [:]).allowsLoopbackHTTP, false)
        let state = try cloudTestRoot(self)
        expectDriveError(EACCES) { try ParaAirCloudConfiguration.saveDeveloperBaseURL(URL(string: "http://127.0.0.1:8787")!, stateRoot: state, policy: denied) }
        try ParaAirCloudConfiguration.saveDeveloperBaseURL(URL(string: "http://127.0.0.1:8787")!, stateRoot: state, policy: allowed)
        XCTAssertEqual(ParaAirCloudConfiguration.baseURL(stateRoot: state, policy: allowed, info: [:])?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(ParaAirCloudConfiguration.baseURL(stateRoot: state, policy: denied, info: [:]))
        XCTAssertEqual(ParaAirCloudConfiguration.baseURL(stateRoot: state, policy: denied, info: ["ParaAirCloudBaseURL": "https://cloud.example"])?.absoluteString,
                       "https://cloud.example")
        XCTAssertNil(ParaAirCloudConfiguration.baseURL(stateRoot: state, policy: denied, info: ["ParaAirCloudBaseURL": "http://127.0.0.1:8787"]))
        let oauth = try ParaAirCloudConfiguration.oauthConfiguration(issuer: URL(string: "http://127.0.0.1:8787")!, policy: allowed)
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "http://127.0.0.1:8787/oauth/authorize")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "http://127.0.0.1:8787/oauth/token")
        XCTAssertEqual(oauth.expectedIssuer?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(oauth.clientID, "paraair-macos"); XCTAssertEqual(oauth.scopes, ["drive", "offline_access"])
        XCTAssertTrue(oauth.allowsLoopbackHTTP)
        expectDriveError(EACCES) { _ = try ParaAirCloudConfiguration.oauthConfiguration(issuer: URL(string: "http://127.0.0.1:8787")!, policy: denied) }
    }

    func testRenewalRefreshesOnlyDueSignedInAccounts() async throws {
        let due = try signIn(expiresAt: Date().addingTimeInterval(60))
        let later = try fake.saveAccount(fake.createAccount(), root: root, vault: vault)
        let gone = try fake.saveAccount(fake.createAccount(), root: root, vault: vault)
        _ = try CloudAccountStore(root: root).signOut(gone.id, vault: vault)
        try Data("{".utf8).write(to: root.appendingPathComponent("cloud-accounts/\(UUID().uuidString.lowercased()).json"))
        let renewal = CloudAccountRenewal(root: root, vault: vault, configuration: fake.configuration, policy: .init(allowsLoopbackHTTP: false))
        var outcomes = await renewal.renewDue(within: 120)
        XCTAssertEqual(outcomes[due.id], .renewed); XCTAssertEqual(outcomes[later.id], .notDue); XCTAssertNil(outcomes[gone.id])
        XCTAssertEqual(outcomes.values.filter { $0 == .failed }.count, 1, "the unreadable record is reported")
        XCTAssertEqual(fake.tokenRequests, 1)
        outcomes = await renewal.renewDue(within: 120)
        XCTAssertEqual(outcomes[due.id], .notDue)
        XCTAssertEqual(fake.tokenRequests, 1)
        outcomes = await renewal.renewDue(within: 7200)
        XCTAssertEqual(outcomes[due.id], .renewed); XCTAssertEqual(outcomes[later.id], .renewed)
        fake.revokeRefreshTokens()
        fake.injectTransport(.cannotConnectToHost, route: "POST /oauth/token")
        outcomes = await CloudAccountRenewal(root: root, vault: vault, configuration: fake.configuration, policy: .init(allowsLoopbackHTTP: false))
            .renewDue(within: 7200)
        XCTAssertEqual(Set([outcomes[due.id], outcomes[later.id]]), [.transientFailure, .authorizationEnded])
        XCTAssertTrue(outcomes.values.contains { $0.blocksAutoMount })
    }

    /// Spec D9 and 6.4: a Keychain read hiccup is not sign-out, so it never blocks auto-mount.
    func testRenewalTreatsKeychainReadFailureAsTransient() async throws {
        let record = try signIn()
        vault.failLoads = true
        let renewal = CloudAccountRenewal(root: root, vault: vault, configuration: fake.configuration, policy: .init(allowsLoopbackHTTP: false))
        var outcomes = await renewal.renewDue(within: 120)
        XCTAssertEqual(outcomes[record.id], .transientFailure)
        XCTAssertEqual(outcomes[record.id]?.blocksAutoMount, false)
        vault.failLoads = false
        outcomes = await renewal.renewDue(within: 120)
        XCTAssertEqual(outcomes[record.id], .notDue)
        XCTAssertEqual(fake.tokenRequests, 0)
    }
}
