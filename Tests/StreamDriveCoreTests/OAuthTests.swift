import XCTest
import CryptoKit
@testable import StreamDriveCore

private actor OAuthTestTransport: OAuthTransport {
    var responses: [OAuthHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [OAuthHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw OAuthError.requestFailed }
        return responses.removeFirst()
    }
}
private struct OAuthSlowTransport: OAuthTransport {
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw OAuthError.requestFailed
    }
}
private final class OAuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

final class OAuthTests: XCTestCase {
    private func config(port: Int = 49731, issuer: URL? = nil) throws -> OAuthConfiguration {
        try OAuthConfiguration(authorizationEndpoint: URL(string: "https://provider.example/authorize")!,
                               tokenEndpoint: URL(string: "https://provider.example/token")!, clientID: "public-client",
                               redirectURI: URL(string: "http://127.0.0.1:\(port)/oauth/callback")!, scopes: ["files.read", "offline_access"], expectedIssuer: issuer)
    }
    private func token(_ refresh: String? = "refresh-1") -> OAuthHTTPResponse {
        var object: [String: Any] = ["access_token": "access-1", "token_type": "Bearer", "expires_in": 3600]
        object["refresh_token"] = refresh
        return OAuthHTTPResponse(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: object))
    }
    private func parameters(_ authorization: OAuthAuthorization) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    }
    private func callback(_ authorization: OAuthAuthorization, code: String = "a-code", extra: [String: String] = [:]) -> URL {
        let parameters = parameters(authorization)
        var fields = extra; fields["state"] = parameters["state"]; fields["code"] = code
        return URL(string: parameters["redirect_uri"]! + "?" + String(data: oauthFormBody(fields), encoding: .utf8)!)!
    }
    private func expect(_ expected: OAuthError, _ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? OAuthError, expected, file: file, line: line) }
    }

    func testPKCEVerifierIsPrivateAndTokenFormPreservesPlus() async throws {
        let clock = OAuthTestClock(), transport = OAuthTestTransport([token()])
        let client = OAuthClient(configuration: try config(), transport: transport, now: { clock.now() })
        let start = try await client.begin(), params = parameters(start)
        XCTAssertNil(params["code_verifier"]); XCTAssertNil(params["client_secret"])
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["state"]?.count, 43)
        let result = try await client.complete(callbackURL: callback(start, code: "code +&= value"))
        XCTAssertEqual(result.expiresAt, clock.now().addingTimeInterval(3600))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let body = String(data: requests[0].httpBody!, encoding: .utf8)!
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(string: "https://example.test/?" + body)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(fields["code"], "code +&= value")
        let verifier = fields["code_verifier"]!
        XCTAssertEqual(verifier.count, 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(challenge, params["code_challenge"])
        await expect(.noPendingAuthorization) { _ = try await client.complete(callbackURL: self.callback(start)) }
    }

    func testInvalidCallbacksDoNotConsumePendingAttempt() async throws {
        let transport = OAuthTestTransport([token()])
        let client = OAuthClient(configuration: try config(), transport: transport)
        let start = try await client.begin(), good = callback(start).absoluteString
        let bad = [good.replacingOccurrences(of: "127.0.0.1", with: "localhost"), good.replacingOccurrences(of: ":49731", with: ":49732"),
                   good.replacingOccurrences(of: "/oauth/callback", with: "/wrong"), good + "&state=duplicate", good + "&code=duplicate", good + "#fragment",
                   good.replacingOccurrences(of: "state=", with: "state=wrong")]
        for value in bad { await expect(.invalidCallback) { _ = try await client.complete(callbackURL: URL(string: value)!) } }
        _ = try await client.complete(callbackURL: callback(start))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExpiryAndCancelInvalidateAttempts() async throws {
        let clock = OAuthTestClock(), client = OAuthClient(configuration: try config(), transport: OAuthTestTransport([]), now: { clock.now() })
        let first = try await client.begin(lifetime: 1)
        clock.advance(2)
        await expect(.expired) { _ = try await client.complete(callbackURL: self.callback(first)) }
        let second = try await client.begin()
        XCTAssertNotEqual(parameters(first)["state"], parameters(second)["state"])
        await client.cancel()
        await expect(.noPendingAuthorization) { _ = try await client.complete(callbackURL: self.callback(second)) }
    }

    func testIssuerAndProviderErrorsAreValidatedAndSanitized() async throws {
        let issuer = URL(string: "https://provider.example")!
        let client = OAuthClient(configuration: try config(issuer: issuer), transport: OAuthTestTransport([]))
        let start = try await client.begin()
        await expect(.invalidCallback) { _ = try await client.complete(callbackURL: self.callback(start, extra: ["iss": "https://attacker.example"])) }
        let params = parameters(start)
        let denied = URL(string: params["redirect_uri"]! + "?" + String(data: oauthFormBody(["state": params["state"]!, "iss": issuer.absoluteString, "error": "sensitive-provider-error", "error_description": "token=secret"]), encoding: .utf8)!)!
        await expect(.authorizationDenied) { _ = try await client.complete(callbackURL: denied) }
        XCTAssertFalse(OAuthError.authorizationDenied.localizedDescription.contains("secret"))
        await expect(.noPendingAuthorization) { _ = try await client.complete(callbackURL: denied) }
    }

    func testRefreshRotationAndMissingRotationPreserveCredential() async throws {
        let transport = OAuthTestTransport([token("rotated"), token(nil)])
        let client = OAuthClient(configuration: try config(), transport: transport)
        let first = try await client.refresh(OAuthTokens(accessToken: "old", refreshToken: "original+token", scope: "files.read"))
        XCTAssertEqual(first.refreshToken, "rotated")
        let second = try await client.refresh(first)
        XCTAssertEqual(second.refreshToken, "rotated"); XCTAssertEqual(second.scope, "files.read")
        let requests = await transport.requests
        XCTAssertTrue(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("original%2Btoken"))
        await expect(.missingRefreshToken) { _ = try await client.refresh(OAuthTokens(accessToken: "old")) }
    }

    func testRedirectAndMalformedTokensAreRejectedWithoutExposingBody() async throws {
        for response in [OAuthHTTPResponse(statusCode: 302, data: Data("secret".utf8), headers: ["Location": "https://attacker.example"]),
                         OAuthHTTPResponse(statusCode: 200, data: Data(#"{"access_token":"secret","token_type":"Bearer","expires_in":true}"#.utf8))] {
            let transport = OAuthTestTransport([response])
            let client = OAuthClient(configuration: try config(), transport: transport)
            let start = try await client.begin()
            await expect(response.statusCode == 302 ? .httpStatus(302) : .invalidTokenResponse) { _ = try await client.complete(callbackURL: self.callback(start)) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testExplicitCancellationStopsInFlightExchange() async throws {
        let client = OAuthClient(configuration: try config(), transport: OAuthSlowTransport())
        let start = try await client.begin()
        let task = Task { try await client.complete(callbackURL: self.callback(start)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await client.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRejectsUntrustedConfiguration() throws {
        for redirect in ["http://localhost:49731/oauth/callback", "http://0.0.0.0:49731/oauth/callback", "https://example.test/callback", "http://127.0.0.1:49731/oauth/callback?code=x"] {
            XCTAssertThrowsError(try OAuthConfiguration(authorizationEndpoint: URL(string: "https://provider.example/authorize")!, tokenEndpoint: URL(string: "https://provider.example/token")!, clientID: "id", redirectURI: URL(string: redirect)!, scopes: []))
        }
        XCTAssertThrowsError(try OAuthConfiguration(authorizationEndpoint: URL(string: "https://provider.example/authorize?state=injected")!, tokenEndpoint: URL(string: "https://provider.example/token")!, clientID: "id", redirectURI: config().redirectURI, scopes: []))
    }

    func testListenerIsReadyBeforeBrowserAndIgnoresInvalidCallback() async throws {
        let result = try await runLoopbackOAuth(configuration: config(port: 0), timeout: 5, transport: OAuthTestTransport([token()])) { url in
            let params = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            let wrong = URL(string: params["redirect_uri"]! + "?state=wrong&code=ignored")!
            let (_, rejected) = try await URLSession.shared.data(from: wrong)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
            let accepted = URL(string: params["redirect_uri"]! + "?" + String(data: oauthFormBody(["state": params["state"]!, "code": "local-code"]), encoding: .utf8)!)!
            let (_, response) = try await URLSession.shared.data(from: accepted)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        XCTAssertEqual(result.accessToken, "access-1")
    }

    func testLoopbackTimeoutAndOccupiedPort() async throws {
        let uri = try config(port: 0).redirectURI
        let first = LoopbackOAuthListener(redirectURI: uri, timeout: 2)
        let bound = try await first.start()
        let second = LoopbackOAuthListener(redirectURI: bound, timeout: 2)
        await expect(.listenerFailed) { _ = try await second.start() }
        first.cancel(); second.cancel()
        let expiry = LoopbackOAuthListener(redirectURI: uri, timeout: 0.05)
        _ = try await expiry.start()
        await expect(.timedOut) { _ = try await expiry.callback() }
    }

    func testLoopbackRejectsWrongPathHostMethodAndDuplicateState() async throws {
        let listener = LoopbackOAuthListener(redirectURI: try config(port: 0).redirectURI, timeout: 5)
        let bound = try await listener.start()
        await listener.expect(state: "expected-state")
        let valid = URL(string: bound.absoluteString + "?state=expected-state&code=ok")!
        var wrongMethod = URLRequest(url: valid); wrongMethod.httpMethod = "POST"; wrongMethod.httpBody = Data("body".utf8)
        var wrongHost = URLRequest(url: valid); wrongHost.setValue("attacker.example", forHTTPHeaderField: "Host")
        let bad = [URLRequest(url: URL(string: valid.absoluteString.replacingOccurrences(of: "/oauth/callback", with: "/wrong"))!),
                   URLRequest(url: URL(string: valid.absoluteString + "&state=expected-state")!), wrongMethod, wrongHost]
        for request in bad {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        }
        let (_, response) = try await URLSession.shared.data(from: valid)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await listener.callback()
        XCTAssertEqual(received, valid)
    }

    func testAuthorizationEncodesLiteralPlusAndTokensRedactDescriptions() async throws {
        let original = try config()
        let config = try OAuthConfiguration(authorizationEndpoint: original.authorizationEndpoint, tokenEndpoint: original.tokenEndpoint,
                                            clientID: "public+client", redirectURI: original.redirectURI, scopes: ["files.read"],
                                            additionalAuthorizationParameters: ["audience": "space + plus"])
        let authorization = try await OAuthClient(configuration: config).begin()
        let query = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
        XCTAssertTrue(query.contains("public%2Bclient")); XCTAssertTrue(query.contains("space%20%2B%20plus"))
        let tokens = OAuthTokens(accessToken: "private-access", refreshToken: "private-refresh")
        XCTAssertFalse(String(describing: tokens).contains("private")); XCTAssertFalse(String(reflecting: tokens).contains("private"))
    }

    func testCancellationOfBrowserFlowReleasesTheListener() async throws {
        let started = expectation(description: "Browser closure invoked")
        let task = Task {
            try await runLoopbackOAuth(configuration: config(port: 0), timeout: 5, transport: OAuthTestTransport([])) { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
