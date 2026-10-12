import XCTest
@testable import StreamDriveCore

private actor RenewalTransport: OAuthTransport {
    private var responses: [OAuthHTTPResponse]
    private var beforeResponse: (@Sendable () async throws -> Void)?
    private(set) var count = 0
    init(_ responses: [OAuthHTTPResponse], beforeResponse: (@Sendable () async throws -> Void)? = nil) {
        self.responses = responses; self.beforeResponse = beforeResponse
    }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        count += 1
        if let action = beforeResponse { beforeResponse = nil; try await action() }
        guard !responses.isEmpty else { throw NSError(domain: "private", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-must-not-leak"]) }
        return responses.removeFirst()
    }
}

private final class DeniedRenewalVault: ConnectionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    func load(id: String) throws -> ConnectionSecrets {
        lock.lock(); attempts += 1; lock.unlock()
        throw DriveError(EACCES, "Credential access denied")
    }
    func save(_ secrets: ConnectionSecrets, id: String) throws { }
    func remove(id: String) throws { }
}

final class OAuthRenewalTests: XCTestCase {
    func testDeniedCredentialAccessIsNotRepeatedUntilConnectionChanges() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = DeniedRenewalVault()
        var connection = record()
        try store.save(connection)
        let transport = RenewalTransport([])
        let renewal = ConnectionRenewal(root: root, vault: vault, transport: transport)
        for _ in 0..<3 {
            let report = await renewal.renewDueConnections()
            XCTAssertNotNil(report.errors[connection.id])
        }
        XCTAssertEqual(vault.readCount, 1, "A timer must not repeatedly request denied credentials")
        connection.updatedAt = connection.updatedAt.addingTimeInterval(1)
        try store.save(connection)
        _ = await renewal.renewDueConnections()
        XCTAssertEqual(vault.readCount, 2, "An explicit connection update permits one new attempt")
        let networkRequests = await transport.count
        XCTAssertEqual(networkRequests, 0)
    }
    private func fixture(registration: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/connection-tests/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        if registration { try CloudflareClientRegistration(clientID: "registered-public-client").save(stateRoot: root) }
        return root
    }
    private func record(provider: ConnectionProvider = .cloudflareR2) -> StorageConnection {
        StorageConnection(provider: provider, name: "Connection", state: .storageReady,
                          accountID: provider == .awsS3 ? "123456789012" : String(repeating: "a", count: 32),
                          bucket: "test-bucket", endpoint: "https://storage.example.test", region: "us-east-1",
                          roleName: provider == .awsS3 ? "Reader" : nil,
                          startURL: provider == .awsS3 ? "https://d-example.awsapps.com/start" : nil)
    }
    private func r2Secrets(_ record: StorageConnection, expiry: Date) -> ConnectionSecrets {
        ConnectionSecrets(binding: record.credentialBinding,
                          oauth: OAuthTokens(accessToken: "prior-access", refreshToken: "prior-refresh", expiresAt: expiry), storageExpiresAt: expiry)
    }
    private func response(_ body: String, status: Int = 200) -> OAuthHTTPResponse { OAuthHTTPResponse(statusCode: status, data: Data(body.utf8)) }
    private var refreshed: OAuthHTTPResponse { response(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#) }

    func testR2RefreshUpdatesOnlyBoundVaultAndKeepsPublicJSONUnchanged() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record(), date = Date()
        try store.save(record); try vault.save(r2Secrets(record, expiry: date.addingTimeInterval(60)), id: record.id)
        let file = root.appendingPathComponent("connections/\(record.id).json"), before = try Data(contentsOf: root.appendingPathComponent("connections/\(record.id).json"))
        let transport = RenewalTransport([refreshed])
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport, now: { date }).renewDueConnections()
        XCTAssertEqual(report.renewed, [record.id]); XCTAssertTrue(report.errors.isEmpty)
        let updated = try vault.load(id: record.id)
        XCTAssertEqual(updated.oauth?.refreshToken, "new-refresh"); XCTAssertEqual(updated.storageExpiresAt, date.addingTimeInterval(3600))
        XCTAssertNil(updated.s3); XCTAssertEqual(try Data(contentsOf: file), before)
        let count = await transport.count; XCTAssertEqual(count, 1)
    }

    func testTransientAndTerminalFailuresRetainCredentialsAndPublicState() async throws {
        for replies in [[], [response(#"{"error":"invalid_grant","error_description":"secret-must-not-leak"}"#, status: 400)]] {
            let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
            let previous = r2Secrets(record, expiry: Date().addingTimeInterval(-5))
            try store.save(record); try vault.save(previous, id: record.id)
            let report = await ConnectionRenewal(root: root, vault: vault, transport: RenewalTransport(replies)).renewDueConnections()
            XCTAssertTrue(report.renewed.isEmpty); XCTAssertNotNil(report.errors[record.id])
            XCTAssertFalse(report.errors[record.id]!.contains("secret-must-not-leak"))
            XCTAssertEqual(try vault.load(id: record.id).oauth, previous.oauth)
            XCTAssertEqual(try store.load(record.id).state, .storageReady)
        }
    }

    func testDisconnectDuringRefreshCannotRestoreCredentials() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        try store.save(record); try vault.save(r2Secrets(record, expiry: Date()), id: record.id)
        let transport = RenewalTransport([refreshed]) { try store.disconnect(record.id, vault: vault) }
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport).renewDueConnections()
        XCTAssertTrue(report.renewed.isEmpty); XCTAssertNotNil(report.errors[record.id])
        XCTAssertEqual(try store.load(record.id).state, .disconnected)
        XCTAssertThrowsError(try vault.load(id: record.id))
    }

    func testNewSignInDuringRefreshIsNotOverwritten() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        try store.save(record); try vault.save(r2Secrets(record, expiry: Date()), id: record.id)
        var newer = r2Secrets(record, expiry: Date().addingTimeInterval(3600))
        newer.oauth = OAuthTokens(accessToken: "new-sign-in", refreshToken: "new-sign-in-refresh", expiresAt: newer.storageExpiresAt)
        let replacement = newer
        let transport = RenewalTransport([refreshed]) { try vault.save(replacement, id: record.id) }
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport).renewDueConnections()
        XCTAssertTrue(report.renewed.isEmpty)
        XCTAssertEqual(try vault.load(id: record.id).oauth?.refreshToken, "new-sign-in-refresh")
        // A change during renewal leaves working credentials, so it must not block mounting.
        XCTAssertEqual(report.outcomes[record.id], .changed)
        XCTAssertFalse(try XCTUnwrap(report.outcomes[record.id]).blocksAutoMount)
    }

    func testPersistentBindingMismatchBlocksAutoMount() async throws {
        // A restored or edited record whose saved credentials belong to another target:
        // the extension refuses them (EXDEV), so mounting must wait for a new sign-in.
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        let previous = ConnectionSecrets(binding: String(repeating: "0", count: 64),
                                         oauth: OAuthTokens(accessToken: "prior-access", refreshToken: "prior-refresh",
                                                            expiresAt: Date().addingTimeInterval(3600)),
                                         storageExpiresAt: Date().addingTimeInterval(3600))
        try store.save(record); try vault.save(previous, id: record.id)
        XCTAssertThrowsError(try store.credentials(record.id, vault: vault)) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
        let transport = RenewalTransport([refreshed])
        let renewal = ConnectionRenewal(root: root, vault: vault, transport: transport)
        for _ in 0..<2 {
            let report = await renewal.renewDueConnections()
            let outcome = try XCTUnwrap(report.outcomes[record.id])
            XCTAssertTrue(outcome.blocksAutoMount, "outcome \(outcome) would let a mount start with refused credentials")
            XCTAssertNotEqual(outcome, .changed)
            let message = try XCTUnwrap(report.errors[record.id])
            XCTAssertFalse(message.contains("changed during renewal"), message)
            XCTAssertTrue(report.renewed.isEmpty)
        }
        XCTAssertEqual(try vault.load(id: record.id).oauth, previous.oauth)
        let count = await transport.count; XCTAssertEqual(count, 0)
    }

    func testOverlappingRenewalsIssueOneRequestAndCancellationPreventsSave() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        try store.save(record); try vault.save(r2Secrets(record, expiry: Date()), id: record.id)
        let started = expectation(description: "Refresh started")
        let transport = RenewalTransport([refreshed]) {
            started.fulfill(); try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let renewal = ConnectionRenewal(root: root, vault: vault, transport: transport)
        let first = Task { await renewal.renewDueConnections() }
        await fulfillment(of: [started], timeout: 2)
        let overlap = await renewal.renewDueConnections()
        XCTAssertTrue(overlap.alreadyRunning)
        first.cancel(); _ = await first.value
        XCTAssertEqual(try vault.load(id: record.id).oauth?.refreshToken, "prior-refresh")
        let count = await transport.count; XCTAssertEqual(count, 1)
    }

    func testHealthyAndDisconnectedConnectionsDoNotTriggerNetwork() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), healthy = record(), disconnected = record()
        try store.save(healthy); try vault.save(r2Secrets(healthy, expiry: Date().addingTimeInterval(3600)), id: healthy.id)
        try store.save(disconnected); try vault.save(r2Secrets(disconnected, expiry: Date()), id: disconnected.id)
        try store.disconnect(disconnected.id, vault: vault)
        let transport = RenewalTransport([])
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport).renewDueConnections()
        XCTAssertTrue(report.errors.isEmpty); XCTAssertTrue(report.renewed.isEmpty)
        let count = await transport.count; XCTAssertEqual(count, 0)
    }

    func testAWSRefreshRotationSurvivesSubsequentRoleRequestFailure() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record(provider: .awsS3), date = Date()
        let session = AWSAccessSession(region: "us-east-1", startURL: URL(string: record.startURL!)!, accessToken: "aws-old-access", refreshToken: "aws-old-refresh",
                                       expiresAt: date.addingTimeInterval(-1), clientID: "aws-client", clientSecret: "aws-client-secret", registrationExpiresAt: date.addingTimeInterval(7200))
        let previous = ConnectionSecrets(binding: record.credentialBinding, s3: try S3Credentials(accessKey: "prior-key", secretKey: "prior-secret", sessionToken: "prior-session"),
                                         storageExpiresAt: date.addingTimeInterval(5), providerSession: try JSONEncoder().encode(session))
        try store.save(record); try vault.save(previous, id: record.id)
        let transport = RenewalTransport([response(#"{"accessToken":"aws-new-access","refreshToken":"aws-rotated-refresh","expiresIn":3600,"tokenType":"Bearer"}"#), response("unavailable", status: 503)])
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport, now: { date }).renewDueConnections()
        XCTAssertTrue(report.renewed.isEmpty); XCTAssertNotNil(report.errors[record.id])
        let saved = try vault.load(id: record.id)
        let restored = try JSONDecoder().decode(AWSAccessSession.self, from: saved.providerSession!)
        XCTAssertEqual(restored.refreshToken, "aws-rotated-refresh")
        XCTAssertEqual(saved.s3?.accessKey, "prior-key"); XCTAssertEqual(saved.storageExpiresAt, previous.storageExpiresAt)
    }

    private let registrationMessage = "This build has no Cloudflare OAuth client registration, so sign-in can't be renewed. Add the public client ID in Storage Settings, or rebuild with STREAMDRIVE_CLOUDFLARE_CLIENT_ID."

    func testMissingCloudflareRegistrationIsReportedDistinctlyWithoutNetwork() async throws {
        let root = try fixture(registration: false), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        let previous = r2Secrets(record, expiry: Date().addingTimeInterval(30))
        try store.save(record); try vault.save(previous, id: record.id)
        let transport = RenewalTransport([refreshed])
        let renewal = ConnectionRenewal(root: root, vault: vault, transport: transport)
        let report = await renewal.renewDueConnections()
        XCTAssertEqual(report.outcomes[record.id], .registrationMissing)
        XCTAssertTrue(try XCTUnwrap(report.outcomes[record.id]).blocksAutoMount)
        XCTAssertEqual(report.errors[record.id], registrationMessage)
        XCTAssertTrue(report.renewed.isEmpty)
        XCTAssertEqual(try vault.load(id: record.id).oauth, previous.oauth)
        // The distinct outcome is stable across timer passes and never reaches the network.
        let again = await renewal.renewDueConnections()
        XCTAssertEqual(again.outcomes[record.id], .registrationMissing)
        let count = await transport.count; XCTAssertEqual(count, 0)
        // Adding the registration lets the next pass renew.
        try CloudflareClientRegistration(clientID: "registered-public-client").save(stateRoot: root)
        let renewed = await renewal.renewDueConnections()
        XCTAssertEqual(renewed.outcomes[record.id], .renewed)
        XCTAssertEqual(renewed.renewed, [record.id])
    }

    func testMissingRegistrationIsWarnedBeforeTokenIsDue() async throws {
        let root = try fixture(registration: false), store = ConnectionStore(root: root), vault = TestConnectionVault()
        let r2 = record(), aws = record(provider: .awsS3), date = Date()
        try store.save(r2); try vault.save(r2Secrets(r2, expiry: date.addingTimeInterval(3600)), id: r2.id)
        let session = AWSAccessSession(region: "us-east-1", startURL: URL(string: aws.startURL!)!, accessToken: "aws-access", refreshToken: "aws-refresh",
                                       expiresAt: date.addingTimeInterval(3600), clientID: "aws-client", clientSecret: "aws-client-secret", registrationExpiresAt: date.addingTimeInterval(7200))
        try store.save(aws)
        try vault.save(ConnectionSecrets(binding: aws.credentialBinding, s3: try S3Credentials(accessKey: "key", secretKey: "secret", sessionToken: "session"),
                                         storageExpiresAt: date.addingTimeInterval(3600), providerSession: try JSONEncoder().encode(session)), id: aws.id)
        let transport = RenewalTransport([])
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport, now: { date }).renewDueConnections()
        let warning = try XCTUnwrap(report.outcomes[r2.id])
        XCTAssertEqual(warning, .registrationMissingNotYetDue)
        XCTAssertFalse(warning.blocksAutoMount, "A token that still works must not block mounting")
        XCTAssertEqual(report.errors[r2.id], registrationMessage)
        // Only Cloudflare connections need the OAuth client registration.
        XCTAssertEqual(report.outcomes[aws.id], .notDue)
        XCTAssertNil(report.errors[aws.id])
        let count = await transport.count; XCTAssertEqual(count, 0)
    }

    func testTransientRenewalFailureDoesNotBlockAutoMount() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record()
        let previous = r2Secrets(record, expiry: Date().addingTimeInterval(60))
        try store.save(record); try vault.save(previous, id: record.id)
        for (replies, expected) in [([OAuthHTTPResponse](), RenewalOutcome.transientFailure),
                                    ([response("unavailable", status: 503)], .transientFailure),
                                    ([response(#"{"error":"invalid_grant"}"#, status: 400)], .authorizationEnded)] {
            let report = await ConnectionRenewal(root: root, vault: vault, transport: RenewalTransport(replies)).renewDueConnections()
            let outcome = try XCTUnwrap(report.outcomes[record.id])
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(outcome.blocksAutoMount, expected == .authorizationEnded)
            XCTAssertNotNil(report.errors[record.id], "Transient failures are still shown as a notice")
            XCTAssertEqual(try vault.load(id: record.id).oauth, previous.oauth)
        }
    }

    func testUnreadableConnectionRecordDoesNotStopRenewalOfOthers() async throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault(), record = record(), date = Date()
        try store.save(record); try vault.save(r2Secrets(record, expiry: date.addingTimeInterval(60)), id: record.id)
        // A record written by a newer build (unknown provider) and a truncated one.
        let foreign = UUID().uuidString.lowercased(), damaged = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent("connections")
        try Data(#"{"schemaVersion":1,"id":"\#(foreign)","provider":"paraairCloud","name":"Future","state":"storageReady","updatedAt":0}"#.utf8)
            .write(to: directory.appendingPathComponent(foreign + ".json"))
        try Data("{".utf8).write(to: directory.appendingPathComponent(damaged + ".json"))
        let transport = RenewalTransport([refreshed])
        let report = await ConnectionRenewal(root: root, vault: vault, transport: transport, now: { date }).renewDueConnections()
        XCTAssertEqual(report.unreadableRecords, 2)
        XCTAssertNil(report.errors["connections"])
        XCTAssertEqual(report.renewed, [record.id])
        XCTAssertEqual(report.outcomes, [record.id: .renewed])
        XCTAssertEqual(try vault.load(id: record.id).oauth?.refreshToken, "new-refresh")
    }
}
