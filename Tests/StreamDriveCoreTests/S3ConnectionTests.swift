import Foundation
import XCTest
@testable import StreamDriveCore

private actor S3FixtureTransport: OAuthTransport {
    var response: OAuthHTTPResponse
    var requests: [URLRequest] = []
    init(_ status: Int, headers: [String: String] = [:]) { response = OAuthHTTPResponse(statusCode: status, data: Data("private-provider-body".utf8), headers: headers) }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse { requests.append(request); return response }
    func captured() -> [URLRequest] { requests }
}
final class S3ConnectionTests: XCTestCase {
    func testB2EndpointRequiresItsActualRegion() throws {
        let target = try S3ConnectionTarget(provider: .backblazeB2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, bucket: "test-bucket", region: "us-west-004")
        XCTAssertEqual(target.bucketURL.absoluteString, "https://s3.us-west-004.backblazeb2.com/test-bucket")
        XCTAssertThrowsError(try S3ConnectionTarget(provider: .backblazeB2, endpoint: target.endpoint, bucket: target.bucket, region: "us-east-1"))
    }
    func testUnsafeEndpointAndBucketShapesAreRejected() throws {
        for endpoint in ["http://nas.example", "https://person:secret@example.com", "https://example.com/path", "https://example.com?token=secret", "https://example.com#fragment"] {
            XCTAssertThrowsError(try S3ConnectionTarget(provider: .custom, endpoint: URL(string: endpoint)!, bucket: "test-bucket", region: "us-east-1"))
        }
        for bucket in ["../other", "with/slash", "", "UPPERCASE", "a..b", "127.0.0.1"] {
            XCTAssertThrowsError(try S3ConnectionTarget(provider: .custom, endpoint: URL(string: "https://nas.example")!, bucket: bucket, region: "us-east-1"))
        }
        XCTAssertNoThrow(try S3ConnectionTarget(provider: .nas, endpoint: URL(string: "https://nas.tailnet.ts.net:9000")!, bucket: "media", region: "us-east-1"))
    }
    func testR2APITokenEndpointIsBuiltFromTheAccountID() throws {
        let account = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(try CloudflareR2Provider.s3Endpoint(accountID: account).absoluteString,
                       "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
        XCTAssertEqual(try CloudflareR2Provider.s3Endpoint(accountID: " 0123456789ABCDEF0123456789ABCDEF\n", jurisdiction: .eu).absoluteString,
                       "https://0123456789abcdef0123456789abcdef.eu.r2.cloudflarestorage.com")
        for bad in ["", "0123456789abcdef", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcdef.evil.example"] {
            XCTAssertThrowsError(try CloudflareR2Provider.s3Endpoint(accountID: bad), bad)
        }
        XCTAssertTrue(CloudflareR2Provider.isS3Endpoint(URL(string: "https://\(account).r2.cloudflarestorage.com")!))
        XCTAssertTrue(CloudflareR2Provider.isS3Endpoint(URL(string: "https://\(account).eu.r2.cloudflarestorage.com")!))
        XCTAssertEqual(try CloudflareR2Provider.s3Endpoint(accountID: account, jurisdiction: .us).absoluteString,
                       "https://0123456789abcdef0123456789abcdef.us.r2.cloudflarestorage.com")
        XCTAssertTrue(CloudflareR2Provider.isS3Endpoint(try CloudflareR2Provider.s3Endpoint(accountID: account, jurisdiction: .us)))
        for other in ["http://\(account).r2.cloudflarestorage.com", "https://\(account).r2.cloudflarestorage.com.evil.example",
                      "https://r2.cloudflarestorage.com", "https://\(account).fedramp.r2.cloudflarestorage.com", "https://s3.us-west-004.backblazeb2.com"] {
            XCTAssertFalse(CloudflareR2Provider.isS3Endpoint(URL(string: other)!), other)
        }
    }
    func testR2APITokenConnectionUsesTheR2TargetAndItsOwnTitle() throws {
        let endpoint = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
        let token = StorageConnection(provider: .customS3, name: "Studio R2", state: .storageReady, bucket: "studio-footage", endpoint: endpoint, region: "auto")
        XCTAssertTrue(token.usesR2APIToken)
        XCTAssertEqual(token.providerTitle, "Cloudflare R2 (API token)")
        XCTAssertEqual(try token.nativeBucketURL(), endpoint + "/studio-footage")
        // The R2 target only signs for "auto" (or us-east-1), so a wrong region fails before any request.
        var wrongRegion = token; wrongRegion.region = "us-west-2"
        XCTAssertThrowsError(try wrongRegion.nativeBucketURL())
        let nas = StorageConnection(provider: .customS3, name: "NAS", state: .storageReady, bucket: "media", endpoint: "https://nas.example", region: "us-east-1")
        XCTAssertFalse(nas.usesR2APIToken)
        XCTAssertEqual(nas.providerTitle, "Custom S3 / NAS")
    }
    func testAWSAndR2EndpointRegionsAreBoundToProvider() throws {
        XCTAssertNoThrow(try S3ConnectionTarget(provider: .aws, endpoint: URL(string: "https://s3.us-west-2.amazonaws.com")!, bucket: "test-bucket", region: "us-west-2"))
        XCTAssertThrowsError(try S3ConnectionTarget(provider: .aws, endpoint: URL(string: "https://s3.attacker.invalid")!, bucket: "test-bucket", region: "us-west-2"))
        XCTAssertNoThrow(try S3ConnectionTarget(provider: .r2, endpoint: URL(string: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")!, bucket: "test-bucket", region: "auto"))
    }
    func testSignerMatchesIndependentAWSGoSDKVector() throws {
        // Public AWS documentation credentials, independently signed by the pinned Go AWS SDK.
        let credentials = try S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"; request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let signed = try S3RequestSigner.sign(request, region: "us-east-1", credentials: credentials, date: Date(timeIntervalSince1970: 1369353600))
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }
    func testHeadBucketIsReadOnlyAndSignsTemporarySessionToken() async throws {
        let transport = S3FixtureTransport(200)
        let target = try S3ConnectionTarget(provider: .custom, endpoint: URL(string: "https://storage.example:9443")!, bucket: "test-bucket", region: "us-east-1")
        let result = try await S3ConnectionProbe(transport: transport).headBucket(target: target, credentials: S3Credentials(accessKey: "key", secretKey: "secret", sessionToken: "session"))
        XCTAssertEqual(result.statusCode, 200)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "storage.example:9443")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "session")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("x-amz-security-token"))
    }
    func testWrongRegionOrDeniedAccessNeverFollowsRedirectOrLeaksBody() async throws {
        let target = try S3ConnectionTarget(provider: .aws, endpoint: URL(string: "https://s3.us-east-1.amazonaws.com")!, bucket: "test-bucket", region: "us-east-1")
        for status in [301, 403] {
            let transport = S3FixtureTransport(status, headers: ["Location": "https://untrusted.invalid", "x-amz-bucket-region": "us-west-2"])
            do { _ = try await S3ConnectionProbe(transport: transport).headBucket(target: target, credentials: S3Credentials(accessKey: "key", secretKey: "secret")); XCTFail("Expected rejection") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-provider-body")); XCTAssertFalse(error.localizedDescription.contains("untrusted")) }
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 1)
        }
    }
}
