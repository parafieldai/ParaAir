import Foundation
import CryptoKit

public enum S3EndpointProvider: String, Codable, Sendable { case aws, r2, backblazeB2, custom, nas }

public enum S3ConnectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidTarget, invalidCredentials, accessDenied, bucketUnavailable, requestFailed, cancelled
    case wrongRegion(String), httpStatus(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Check the HTTPS storage endpoint, bucket name and signing region."
        case .invalidCredentials: return "Storage credentials are empty or invalid."
        case .accessDenied: return "The storage service denied bucket access. Check the selected account, role or bucket permissions."
        case .bucketUnavailable: return "The storage bucket is unavailable or inaccessible."
        case .requestFailed: return "The storage service could not be reached."
        case .cancelled: return "The storage connection check was cancelled."
        case .wrongRegion(let region): return "The bucket uses signing region \(region). Update the region and endpoint, then retry."
        case .httpStatus(let code): return "The storage service rejected the bucket check (HTTP \(code))."
        }
    }
}

/// Public, nonsecret service origin and bucket. B2/custom/NAS use explicit S3 keys;
/// this type does not claim an OAuth flow for providers without one.
public struct S3ConnectionTarget: Codable, Sendable {
    public let provider: S3EndpointProvider
    public let endpoint: URL
    public let bucket: String
    public let region: String
    public var bucketURL: URL { endpoint.appendingPathComponent(bucket, isDirectory: false) }

    public init(provider: S3EndpointProvider, endpoint: URL, bucket: String, region: String) throws {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), components.scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty, host.utf8.allSatisfy({ $0 < 128 }),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", components.port.map({ (1...65535).contains($0) }) ?? true,
              Self.validRegion(region), Self.validBucket(bucket) else { throw S3ConnectionError.invalidTarget }
        switch provider {
        case .aws:
            let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
            guard host == "s3.\(region).\(suffix)" || (region == "us-east-1" && host == "s3.amazonaws.com"),
                  components.port == nil || components.port == 443 else { throw S3ConnectionError.invalidTarget }
        case .r2:
            guard Self.matches(host, "^[a-f0-9]{32}(\\.eu)?\\.r2\\.cloudflarestorage\\.com$"),
                  region == "auto" || region == "us-east-1", components.port == nil || components.port == 443
            else { throw S3ConnectionError.invalidTarget }
        case .backblazeB2:
            // https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api
            guard host == "s3.\(region).backblazeb2.com", Self.matches(region, "^[a-z]{2}-[a-z]+-[0-9]{3}$"),
                  components.port == nil || components.port == 443 else { throw S3ConnectionError.invalidTarget }
        case .custom, .nas: break // Explicit user-supplied HTTPS origin, including private/Tailscale hosts.
        }
        components.host = host; components.path = ""
        guard let normalized = components.url else { throw S3ConnectionError.invalidTarget }
        self.provider = provider; self.endpoint = normalized; self.bucket = bucket; self.region = region
    }

    public func validateCredentials(_ credentials: S3Credentials) throws {
        do { try credentials.validate() } catch { throw S3ConnectionError.invalidCredentials }
        for value in [credentials.accessKey, credentials.secretKey, credentials.sessionToken ?? ""] {
            guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
            else { throw S3ConnectionError.invalidCredentials }
        }
    }
    // Re-run validation after decoding any public connection metadata.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: values.decode(S3EndpointProvider.self, forKey: .provider), endpoint: values.decode(URL.self, forKey: .endpoint),
                      bucket: values.decode(String.self, forKey: .bucket), region: values.decode(String.self, forKey: .region))
    }
    static func validRegion(_ region: String) -> Bool { matches(region, "^[a-z0-9][a-z0-9-]{0,62}$") }
    private static func validBucket(_ bucket: String) -> Bool {
        matches(bucket, "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$") && !bucket.contains("..") && !bucket.contains(".-") && !bucket.contains("-.")
        && !matches(bucket, "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
}

public struct S3BucketProbeResult: Sendable {
    public let statusCode: Int
    public let bucketRegion: String?
    public let elapsedSeconds: TimeInterval
}

/// Performs one signed HEAD request. A successful result verifies bucket access;
/// it does not infer object-write permission or benchmark upload/download speed.
public struct S3ConnectionProbe: Sendable {
    private let transport: any OAuthTransport
    public init(transport: any OAuthTransport = URLSessionOAuthTransport()) { self.transport = transport }
    public func headBucket(target: S3ConnectionTarget, credentials: S3Credentials) async throws -> S3BucketProbeResult {
        if Task.isCancelled { throw S3ConnectionError.cancelled }
        try target.validateCredentials(credentials)
        var request = URLRequest(url: target.bucketURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        request = try S3RequestSigner.sign(request, region: target.region, credentials: credentials, date: Date())
        let started = ContinuousClock.now
        let response: OAuthHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw S3ConnectionError.cancelled }
        catch { throw S3ConnectionError.requestFailed }
        if Task.isCancelled { throw S3ConnectionError.cancelled }
        let duration = started.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let advertised = response.headers.first(where: { $0.key.lowercased() == "x-amz-bucket-region" })?.value
        let region = advertised.flatMap { S3ConnectionTarget.validRegion($0) ? $0 : nil }
        guard (200..<300).contains(response.statusCode) else {
            if (response.statusCode == 301 || response.statusCode == 307 || response.statusCode == 400), let region, region != target.region {
                throw S3ConnectionError.wrongRegion(region)
            }
            if response.statusCode == 401 || response.statusCode == 403 { throw S3ConnectionError.accessDenied }
            if response.statusCode == 404 { throw S3ConnectionError.bucketUnavailable }
            throw S3ConnectionError.httpStatus(response.statusCode)
        }
        return S3BucketProbeResult(statusCode: response.statusCode, bucketRegion: region, elapsedSeconds: elapsed)
    }
}

/// SigV4 for read-only S3 probes. Credentials stay in headers and signing memory.
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
/// The known-answer test is cross-checked against AWS SDK for Go's v4 signer.
enum S3RequestSigner {
    static func sign(_ original: URLRequest, region: String, credentials: S3Credentials, date: Date) throws -> URLRequest {
        guard let url = original.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host, S3ConnectionTarget.validRegion(region),
              original.httpBody == nil || original.httpBody!.isEmpty,
              let method = original.httpMethod, ["GET", "HEAD"].contains(method) else { throw S3ConnectionError.invalidTarget }
        do { try credentials.validate() } catch { throw S3ConnectionError.invalidCredentials }
        var request = original
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        var hostHeader = host.lowercased()
        if hostHeader.contains(":"), !hostHeader.hasPrefix("[") { hostHeader = "[\(hostHeader)]" }
        if let port = components.port { hostHeader += ":\(port)" }
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        let payloadHash = hex(SHA256.hash(data: Data()))
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(credentials.sessionToken, forHTTPHeaderField: "x-amz-security-token")
        let headers = (request.allHTTPHeaderFields ?? [:]).map { key, value in
            (key.lowercased(), value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " "))
        }.sorted { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { $0.0 + ":" + $0.1 + "\n" }.joined()
        var queryPairs: [(String, String)] = (components.queryItems ?? []).map { (encode($0.name), encode($0.value ?? "")) }
        queryPairs.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        let encodedQuery = queryPairs.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let uri = encode(decodedPath.isEmpty ? "/" : decodedPath, preserveSlash: true)
        let canonical = [method, uri, encodedQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let dateKey = hmac(Data(("AWS4" + credentials.secretKey).utf8), day)
        let regionKey = hmac(dateKey, region), serviceKey = hmac(regionKey, "s3"), signingKey = hmac(serviceKey, "aws4_request")
        let signature = hex(hmac(signingKey, stringToSign))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
    private static func hmac(_ key: Data, _ value: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key))) }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func encode(_ value: String, preserveSlash: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) || (preserveSlash && byte == 47) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
