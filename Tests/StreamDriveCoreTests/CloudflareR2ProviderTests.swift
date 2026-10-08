import Foundation
import XCTest
@testable import StreamDriveCore

final class CloudflareR2ProviderTests: XCTestCase {
    private let accountID = String(repeating: "a", count: 32)
    private let otherAccountID = String(repeating: "b", count: 32)
    private let accessToken = "mock-oauth-token"

    func testPublicPKCEConfigurationUsesRegisteredClientAndNewScopes() throws {
        let config = try CloudflareR2Provider.oauthConfiguration(clientID: "registered-test-client",
            redirectURI: URL(string: "http://127.0.0.1:43210/oauth/callback")!)
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://dash.cloudflare.com/oauth2/auth")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://dash.cloudflare.com/oauth2/token")
        XCTAssertEqual(config.clientID, "registered-test-client")
        XCTAssertEqual(config.scopes, ["account-settings.read", "workers-r2.write", "offline_access"])
        XCTAssertThrowsError(try CloudflareR2Provider.oauthConfiguration(clientID: "client",
            redirectURI: config.redirectURI, scopes: ["workers:write"])) {
            XCTAssertEqual($0 as? CloudflareConnectionError, .invalidScope)
        }
    }

    func testAccountPaginationAndAuthorizationHeader() async throws {
        let transport = CloudflareMockTransport([
            json(#"{"success":true,"result":[{"id":"\#(accountID)","name":"First"}],"result_info":{"page":1,"total_pages":2}}"#),
            json(#"{"success":true,"result":[{"id":"\#(otherAccountID)","name":"Second"}],"result_info":{"page":2,"total_pages":2}}"#)
        ])
        let accounts = try await provider(transport).listAccounts(accessToken: accessToken)
        XCTAssertEqual(accounts.map(\.id), [accountID, otherAccountID])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "api.cloudflare.com")
        XCTAssertEqual(requests[0].url?.path, "/client/v4/accounts")
        XCTAssertFalse(requests[0].url!.absoluteString.contains(accessToken))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(accessToken)")
        XCTAssertEqual(queryValue("page", in: requests[1]), "2")
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testEmptyAccountResponseIsAnHonestEmptyState() async throws {
        let transport = CloudflareMockTransport([json(#"{"success":true,"result":[],"result_info":{"page":1,"total_pages":0,"total_count":0}}"#)])
        let accounts = try await provider(transport).listAccounts(accessToken: accessToken)
        XCTAssertEqual(accounts, [])
    }

    func testBucketDiscoveryFollowsCursorAndDoesNotCreateBuckets() async throws {
        let transport = CloudflareMockTransport([
            json(#"{"success":true,"result":{"buckets":[{"name":"first-bucket","jurisdiction":"default","location":"wnam"}]},"result_info":{"cursor":"next+/="}}"#),
            json(#"{"success":true,"result":{"buckets":[{"name":"second-bucket"}]},"result_info":{}}"#)
        ])
        let buckets = try await provider(transport).listBuckets(accountID: accountID, accessToken: accessToken)
        XCTAssertEqual(buckets.map(\.name), ["first-bucket", "second-bucket"])
        XCTAssertTrue(buckets.allSatisfy { $0.accountID == accountID })
        let requests = await transport.capturedRequests()
        XCTAssertEqual(queryValue("cursor", in: requests[1]), "next+/=")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "cf-r2-jurisdiction"), "default")
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    func testSuccessfulEmptyBucketListIsDistinctFromForbiddenList() async throws {
        let empty = CloudflareMockTransport([json(#"{"success":true,"result":{"buckets":[]}}"#)])
        let buckets = try await provider(empty).listBuckets(accountID: accountID, accessToken: accessToken)
        XCTAssertTrue(buckets.isEmpty)

        let denied = CloudflareMockTransport([OAuthHTTPResponse(statusCode: 403,
            data: Data(#"{"errors":[{"message":"secret-must-not-leak"}]}"#.utf8))])
        do {
            _ = try await provider(denied).listBuckets(accountID: accountID, accessToken: accessToken)
            XCTFail("A forbidden bucket list must fail instead of appearing empty")
        } catch {
            XCTAssertEqual(error as? CloudflareConnectionError, .insufficientPermission)
            XCTAssertFalse(error.localizedDescription.contains("secret-must-not-leak"))
            XCTAssertFalse(error.localizedDescription.lowercased().contains("reauthorize"))
            XCTAssertTrue(error.localizedDescription.contains("R2 activation"))
            XCTAssertTrue(error.localizedDescription.contains("permissions"))
        }
    }

    func testRepeatedBucketCursorCannotLoop() async throws {
        let transport = CloudflareMockTransport([
            json(#"{"success":true,"result":{"buckets":[{"name":"first-bucket"}]},"result_info":{"cursor":"same"}}"#),
            json(#"{"success":true,"result":{"buckets":[{"name":"second-bucket"}]},"result_info":{"cursor":"same"}}"#)
        ])
        await assertError(.malformedResponse) {
            _ = try await self.provider(transport).listBuckets(accountID: self.accountID, accessToken: self.accessToken)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testDuplicateAccountsCannotChangeSelection() async throws {
        let transport = CloudflareMockTransport([
            json(#"{"success":true,"result":[{"id":"\#(accountID)","name":"First"},{"id":"\#(accountID)","name":"Second"}]}"#)
        ])
        await assertError(.malformedResponse) { _ = try await self.provider(transport).listAccounts(accessToken: self.accessToken) }
    }

    func testValidateBucketRejectsUnauthorizedAccountBeforeBucketRequest() async throws {
        let transport = CloudflareMockTransport([accountsResponse(id: otherAccountID)])
        await assertError(.accountNotAuthorized) {
            _ = try await self.provider(transport).validateBucket(accountID: self.accountID, bucketName: "my-bucket", accessToken: self.accessToken)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/client/v4/accounts")
    }

    func testValidateBucketRequiresExactReturnedBucket() async throws {
        let transport = CloudflareMockTransport([
            accountsResponse(id: accountID), json(#"{"success":true,"result":{"name":"different-bucket"}}"#)
        ])
        await assertError(.malformedResponse) {
            _ = try await self.provider(transport).validateBucket(accountID: self.accountID, bucketName: "my-bucket", accessToken: self.accessToken)
        }
    }

    func testValidateSelectedBucketReturnsItsActualMetadata() async throws {
        let transport = CloudflareMockTransport([
            accountsResponse(id: accountID), json(#"{"success":true,"result":{"name":"my-bucket","location":"enam","jurisdiction":"default","creation_date":"2026-10-02T00:00:00Z"}}"#)
        ])
        let bucket = try await provider(transport).validateBucket(accountID: accountID, bucketName: "my-bucket", accessToken: accessToken)
        XCTAssertEqual(bucket.accountID, accountID)
        XCTAssertEqual(bucket.location, "enam")
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testExplicitCreateScopesExactAccountAndBucketAndStandardStorage() async throws {
        let transport = CloudflareMockTransport([
            accountsResponse(id: accountID), json(#"{"success":true,"result":{"name":"new-bucket","location":"apac"}}"#)
        ])
        let bucket = try await provider(transport).createBucket(accountID: accountID, bucketName: "new-bucket",
                                                               accessToken: accessToken, locationHint: .asiaPacific)
        XCTAssertEqual(bucket.name, "new-bucket")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/client/v4/accounts/\(accountID)/r2/buckets")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["name": "new-bucket", "locationHint": "apac", "storageClass": "Standard"])
        XCTAssertFalse(String(decoding: requests[1].httpBody!, as: UTF8.self).contains(accessToken))
    }

    func testInvalidSelectionAndHeaderInjectionNeverReachTransport() async throws {
        let transport = CloudflareMockTransport([])
        await assertError(.invalidAccount) {
            _ = try await self.provider(transport).listBuckets(accountID: "../../user", accessToken: self.accessToken)
        }
        await assertError(.invalidBucket) {
            _ = try await self.provider(transport).createBucket(accountID: self.accountID, bucketName: "../bucket", accessToken: self.accessToken)
        }
        await assertError(.invalidCredential) {
            _ = try await self.provider(transport).listAccounts(accessToken: "token\r\nInjected: x")
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPFailuresAndProviderErrorsNeverExposeRawBody() async throws {
        for (status, expected) in [(401, CloudflareConnectionError.unauthorized), (403, .insufficientPermission),
                                   (302, .redirectRejected), (429, .rateLimited), (503, .unavailable)] {
            let transport = CloudflareMockTransport([OAuthHTTPResponse(statusCode: status, data: Data("secret-must-not-leak".utf8),
                                                                       headers: ["Location": "https://unexpected.example/"])])
            await assertError(expected) { _ = try await self.provider(transport).listAccounts(accessToken: self.accessToken) }
            XCTAssertFalse(expected.localizedDescription.contains("secret-must-not-leak"))
        }
        let transport = CloudflareMockTransport([json(#"{"success":false,"errors":[{"message":"secret-must-not-leak"}],"result":[]}"#)])
        await assertError(.rejected) { _ = try await self.provider(transport).listAccounts(accessToken: self.accessToken) }
    }

    func testOAuthCannotMintAccountS3TokensAndMakesNoMutation() async throws {
        let transport = CloudflareMockTransport([])
        XCTAssertFalse(CloudflareR2Provider.supportsOAuthS3CredentialProvisioning)
        await assertError(.s3CredentialProvisioningUnavailable) {
            try await self.provider(transport).createBucketScopedS3Credential(accountID: self.accountID,
                                                                            bucketName: "my-bucket", accessToken: self.accessToken)
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testScopeDiscoveryUsesActualOAuthRouteAndEndpointHelperIsBounded() async throws {
        let transport = CloudflareMockTransport([json(#"{"success":true,"result":[{"id":"workers-r2.write","name":"Workers R2 Storage Write","scopes":["com.cloudflare.api.account"]}]}"#)])
        let scopes = try await provider(transport).listOAuthScopes(accessToken: accessToken)
        XCTAssertEqual(scopes.first?.id, "workers-r2.write")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.first?.url?.path, "/client/v4/oauth/scopes")
        let endpoint = try CloudflareR2Provider.bucketEndpoint(accountID: accountID, bucketName: "my-bucket")
        XCTAssertEqual(endpoint.absoluteString, "https://api.cloudflare.com/client/v4/accounts/\(accountID)/r2/buckets/my-bucket")
        XCTAssertThrowsError(try CloudflareR2Provider.bucketEndpoint(accountID: accountID, bucketName: "bucket?token=x"))
    }

    func testJurisdictionIsNotSilentlyChanged() async throws {
        let transport = CloudflareMockTransport([json(#"{"success":true,"result":{"buckets":[{"name":"eu-bucket","jurisdiction":"eu"}]}}"#)])
        await assertError(.malformedResponse) {
            _ = try await self.provider(transport).listBuckets(accountID: self.accountID, accessToken: self.accessToken)
        }
    }

    private func provider(_ transport: CloudflareMockTransport) -> CloudflareR2Provider {
        CloudflareR2Provider(transport: transport)
    }
    private func json(_ value: String) -> OAuthHTTPResponse {
        OAuthHTTPResponse(statusCode: 200, data: Data(value.utf8))
    }
    private func accountsResponse(id: String) -> OAuthHTTPResponse {
        json(#"{"success":true,"result":[{"id":"\#(id)","name":"Available account"}]}"#)
    }
    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }
    private func assertError(_ expected: CloudflareConnectionError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected provider error", file: file, line: line) }
        catch { XCTAssertEqual(error as? CloudflareConnectionError, expected, file: file, line: line) }
    }
}

private actor CloudflareMockTransport: OAuthTransport {
    private var responses: [OAuthHTTPResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [OAuthHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
    func capturedRequests() -> [URLRequest] { requests }
}
