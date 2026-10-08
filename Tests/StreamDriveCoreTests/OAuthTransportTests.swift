import XCTest
@testable import StreamDriveCore

/// Test-only responses contain synthetic bytes; no credential or global session state.
private final class OAuthProtocolStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "oauth.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/redirect" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://oauth.invalid/redirected"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://oauth.invalid/redirected")!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let headers = path == "/declared-oversize" ? ["Content-Length": "2048"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/stream-oversize" || path == "/declared-oversize" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 700))
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 700))
        } else { client?.urlProtocol(self, didLoad: Data("ok".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OAuthTransportTests: XCTestCase {
    private func transport() -> URLSessionOAuthTransport {
        URLSessionOAuthTransport(timeout: 2, maximumResponseBytes: 1024) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OAuthProtocolStub.self]
            return configuration
        }
    }
    func testSessionTransportBoundsDeclaredAndStreamedBodies() async throws {
        for path in ["declared-oversize", "stream-oversize"] {
            do {
                _ = try await transport().send(URLRequest(url: URL(string: "https://oauth.invalid/\(path)")!))
                XCTFail("Expected bounded response failure")
            } catch { XCTAssertEqual(error as? OAuthError, .responseTooLarge) }
        }
    }
    func testSessionTransportRefusesRedirects() async throws {
        var request = URLRequest(url: URL(string: "https://oauth.invalid/redirect")!)
        request.httpMethod = "POST"; request.httpBody = Data("synthetic-token".utf8)
        let response = try await transport().send(request)
        XCTAssertEqual(response.statusCode, 302)
    }
    func testSessionTransportRejectsInsecureEndpoint() async {
        do {
            _ = try await transport().send(URLRequest(url: URL(string: "http://oauth.invalid/token")!))
            XCTFail("Expected HTTPS enforcement")
        } catch { XCTAssertEqual(error as? OAuthError, .invalidConfiguration) }
    }
}
