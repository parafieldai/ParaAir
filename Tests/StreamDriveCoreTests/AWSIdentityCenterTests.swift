import Foundation
import XCTest
@testable import StreamDriveCore

private actor AWSFixtureTransport: OAuthTransport {
    var replies: [OAuthHTTPResponse]
    var requests: [URLRequest] = []
    init(_ replies: [OAuthHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw OAuthError.requestFailed }
        return replies.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}
private final class AWSFixtureClock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    var waits: [TimeInterval] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func sleep(_ duration: TimeInterval) { lock.lock(); defer { lock.unlock() }; waits.append(duration); date.addTimeInterval(duration) }
}
final class AWSIdentityCenterTests: XCTestCase {
    private func reply(_ body: String, status: Int = 200) -> OAuthHTTPResponse {
        OAuthHTTPResponse(statusCode: status, data: Data(body.utf8))
    }
    private var register: OAuthHTTPResponse { reply(#"{"clientId":"fixture-client","clientSecret":"fixture-private","clientSecretExpiresAt":1800000000}"#) }
    private var start: OAuthHTTPResponse { reply(#"{"deviceCode":"fixture-device","userCode":"ABCD-EFGH","verificationUriComplete":"https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH","expiresIn":600,"interval":2}"#) }
    private var token: OAuthHTTPResponse { reply(#"{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresIn":3600,"tokenType":"Bearer"}"#) }
    private func client(_ transport: AWSFixtureTransport, _ clock: AWSFixtureClock) -> AWSIdentityCenterClient {
        AWSIdentityCenterClient(transport: transport, now: { clock.now() }, sleep: { clock.sleep($0) })
    }
    func testDeviceAuthorizationPollHonorsPendingAndSlowDown() async throws {
        let transport = AWSFixtureTransport([register, start, reply(#"{"error":"authorization_pending"}"#, status: 400), reply(#"{"error":"slow_down"}"#, status: 400), token])
        let clock = AWSFixtureClock(), service = client(transport, clock)
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        let session = try await service.pollAuthorization(device)
        XCTAssertEqual(session.accessToken, "fixture-access")
        XCTAssertEqual(clock.waits, [2, 2, 7])
        let requests = await transport.captured()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/client/register", "/device_authorization", "/token", "/token", "/token"])
        let registration = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(registration["scopes"] as? [String], ["sso:account:access"])
        XCTAssertTrue(requests.allSatisfy { !$0.url!.absoluteString.contains("fixture-private") })
    }
    func testAccountsRolesAndCredentialsUseExplicitSelectionAndHeaderToken() async throws {
        let transport = AWSFixtureTransport([register, start, token,
            reply(#"{"accountList":[{"accountId":"123456789012","accountName":"Chosen"}],"nextToken":"page2"}"#),
            reply(#"{"accountList":[{"accountId":"222222222222","accountName":"Other"}]}"#),
            reply(#"{"roleList":[{"accountId":"123456789012","roleName":"StorageRole"}]}"#),
            reply(#"{"roleCredentials":{"accessKeyId":"fixture-key","secretAccessKey":"fixture-secret","sessionToken":"fixture-session","expiration":1700007200000}}"#)])
        let service = client(transport, AWSFixtureClock())
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        let session = try await service.pollAuthorization(device)
        let accounts = try await service.listAccounts(session: session)
        XCTAssertEqual(accounts.map(\.accountID), ["123456789012", "222222222222"])
        let roles = try await service.listRoles(accountID: accounts[0].accountID, session: session)
        let credentials = try await service.credentials(accountID: accounts[0].accountID, roleName: roles[0].roleName, session: session)
        XCTAssertEqual(credentials.credentials.accessKey, "fixture-key")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1700007200))
        let requests = await transport.captured()
        let roleRequest = requests.last!
        XCTAssertEqual(roleRequest.url!.host, "portal.sso.us-east-1.amazonaws.com")
        XCTAssertTrue(roleRequest.url!.query!.contains("account_id=123456789012"))
        XCTAssertTrue(roleRequest.url!.query!.contains("role_name=StorageRole"))
        XCTAssertEqual(roleRequest.value(forHTTPHeaderField: "x-amz-sso_bearer_token"), "fixture-access")
    }
    func testRefreshRotatesTokensAndCodableSessionPreservesRegistration() async throws {
        let transport = AWSFixtureTransport([register, start, token, reply(#"{"accessToken":"rotated","refreshToken":"rotated-refresh","expiresIn":7200,"tokenType":"Bearer"}"#)])
        let service = client(transport, AWSFixtureClock())
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        let session = try await service.pollAuthorization(device)
        let restored = try JSONDecoder().decode(AWSAccessSession.self, from: JSONEncoder().encode(session))
        let refreshed = try await service.refresh(session: restored)
        XCTAssertEqual(refreshed.accessToken, "rotated")
        XCTAssertEqual(refreshed.refreshToken, "rotated-refresh")
        XCTAssertEqual(refreshed.clientID, session.clientID)
        let request = await transport.captured().last!
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(body["grantType"], "refresh_token")
        XCTAssertEqual(body["refreshToken"], "fixture-refresh")
        XCTAssertFalse(String(describing: refreshed).contains("rotated"))
    }
    func testDeniedAndUnexpectedProviderBodiesAreRedacted() async throws {
        let transport = AWSFixtureTransport([register, start, reply(#"{"error":"access_denied","error_description":"secret-do-not-print"}"#, status: 400)])
        let service = client(transport, AWSFixtureClock())
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        do { _ = try await service.pollAuthorization(device); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? OAuthError, .authorizationDenied); XCTAssertFalse(error.localizedDescription.contains("secret-do-not-print")) }
    }
    func testUnsafeStartURLAndBrowserURLAreRejected() async throws {
        let transport = AWSFixtureTransport([]), service = client(transport, AWSFixtureClock())
        do { _ = try await service.registerAndStart(startURL: URL(string: "https://unrelated.invalid/start")!, region: "us-east-1"); XCTFail("Expected unsafe URL rejection") }
        catch { XCTAssertEqual(error as? OAuthError, .invalidConfiguration) }
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
        let bad = AWSFixtureTransport([register, reply(#"{"deviceCode":"device","userCode":"ABCD","verificationUriComplete":"https://attacker.invalid/login","expiresIn":600,"interval":2}"#)])
        do { _ = try await client(bad, AWSFixtureClock()).registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1"); XCTFail("Expected unsafe browser URL rejection") }
        catch { XCTAssertEqual(error as? OAuthError, .invalidTokenResponse) }
    }
    func testPollingCancellationSendsNoTokenRequest() async throws {
        let transport = AWSFixtureTransport([register, start])
        let clock = AWSFixtureClock()
        let service = AWSIdentityCenterClient(transport: transport, now: { clock.now() }, sleep: { _ in throw CancellationError() })
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        do { _ = try await service.pollAuthorization(device); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? OAuthError, .cancelled) }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
    }
    func testTransientRefreshFailureDoesNotInvalidateUsableSession() async throws {
        let transport = AWSFixtureTransport([register, start, token, reply(#"{"error":"server_error","error_description":"do-not-print"}"#, status: 400)])
        let service = client(transport, AWSFixtureClock())
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        let original = try await service.pollAuthorization(device)
        do { _ = try await service.refresh(session: original); XCTFail("Expected temporary failure") }
        catch { XCTAssertEqual(error as? OAuthError, .httpStatus(400)) }
        XCTAssertEqual(original.accessToken, "fixture-access")
    }
    func testPollingExpiresBeforeAnotherRequestAndCannotReplay() async throws {
        let short = reply(#"{"deviceCode":"fixture-device","userCode":"ABCD","verificationUriComplete":"https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD","expiresIn":3,"interval":2}"#)
        let transport = AWSFixtureTransport([register, short, reply(#"{"error":"authorization_pending"}"#, status: 400)])
        let service = client(transport, AWSFixtureClock())
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        do { _ = try await service.pollAuthorization(device); XCTFail("Expected expiry") }
        catch { XCTAssertEqual(error as? OAuthError, .expired) }
        do { _ = try await service.pollAuthorization(device); XCTFail("Expected replay rejection") }
        catch { XCTAssertEqual(error as? OAuthError, .noPendingAuthorization) }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 3)
    }
    func testRegistrationExpiryPreventsCredentialRenewalNetworkRequest() async throws {
        let transport = AWSFixtureTransport([register, start, token])
        let clock = AWSFixtureClock(), service = client(transport, clock)
        let device = try await service.registerAndStart(startURL: URL(string: "https://example.awsapps.com/start")!, region: "us-east-1")
        let session = try await service.pollAuthorization(device)
        clock.sleep(100_000_000)
        do { _ = try await service.refresh(session: session); XCTFail("Expected expired registration") }
        catch { XCTAssertEqual(error as? OAuthError, .expired) }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 3)
    }

}
