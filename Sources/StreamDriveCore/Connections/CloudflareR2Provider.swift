import Foundation

public enum CloudflareConnectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidAccount, invalidBucket, invalidCredential, invalidScope
    case unauthorized, insufficientPermission, accountNotAuthorized, bucketNotFound
    case rateLimited, unavailable, rejected, redirectRejected, malformedResponse, paginationLimit
    case s3CredentialProvisioningUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidAccount: return "Choose a valid Cloudflare account."
        case .invalidBucket: return "Choose a valid R2 bucket name."
        case .invalidCredential: return "Sign in to Cloudflare again."
        case .invalidScope: return "The registered Cloudflare OAuth scopes are invalid."
        case .unauthorized: return "Cloudflare authorization expired. Sign in again."
        case .insufficientPermission: return "Cloudflare denied this request. Check R2 activation and the selected account’s permissions, then retry."
        case .accountNotAuthorized: return "The selected account is not available to this Cloudflare authorization."
        case .bucketNotFound: return "The selected R2 bucket is unavailable in this account."
        case .rateLimited: return "Cloudflare temporarily limited requests. Try again later."
        case .unavailable: return "Cloudflare could not be reached. Try again later."
        case .rejected: return "Cloudflare rejected the request. Check the selected account and bucket."
        case .redirectRejected: return "Cloudflare returned an unexpected redirect. No credentials were forwarded."
        case .malformedResponse: return "Cloudflare returned an invalid response."
        case .paginationLimit: return "Cloudflare discovery exceeded its safety limit. Narrow the selection and try again."
        case .s3CredentialProvisioningUnavailable:
            return "Cloudflare OAuth does not expose the account-token permission needed to create S3 credentials. Use the R2 OAuth connection."
        }
    }
}

public struct CloudflareAccount: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Discovery below is for ordinary R2 buckets. Jurisdiction-specific buckets need
/// a separate endpoint/header in the storage adapter and are not silently mixed in.
public struct CloudflareBucket: Codable, Equatable, Sendable {
    public let accountID: String
    public let name: String
    public let location: String?
    public let creationDate: String?
    public init(accountID: String, name: String, location: String? = nil, creationDate: String? = nil) {
        self.accountID = accountID; self.name = name
        self.location = location; self.creationDate = creationDate
    }
}

public struct CloudflareOAuthScope: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String?
    public let scopes: [String]?
}

public enum CloudflareR2LocationHint: String, Codable, Sendable {
    case westernNorthAmerica = "wnam", easternNorthAmerica = "enam"
    case westernEurope = "weur", easternEurope = "eeur", asiaPacific = "apac", oceania = "oc"
}

/// Cloudflare's API hostname and OAuth endpoints are fixed. The transport must
/// reject redirects; the shared URLSessionOAuthTransport does so. Tokens are only
/// sent as headers and never placed in URLs, logs, errors or persisted by this type.
public struct CloudflareR2Provider: Sendable {
    public static let authorizationEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    public static let tokenEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    /// Verified against /oauth/scopes on 2026-10-02. offline_access is a protocol
    /// scope requiring refresh_token support in the registered public client.
    public static let readWriteOAuthScopes = ["account-settings.read", "workers-r2.write", "offline_access"]
    public static let apiBase = URL(string: "https://api.cloudflare.com/client/v4")!
    public static let supportsOAuthS3CredentialProvisioning = false

    private let transport: any OAuthTransport
    private let maximumPages = 100
    private let maximumResponseBytes = 4 * 1024 * 1024

    public init(transport: any OAuthTransport) { self.transport = transport }

    public static func oauthConfiguration(clientID: String, redirectURI: URL,
                                           scopes: [String] = readWriteOAuthScopes) throws -> OAuthConfiguration {
        guard !scopes.isEmpty, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ validScopeID($0) }) else { throw CloudflareConnectionError.invalidScope }
        return try OAuthConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint,
                                      clientID: clientID, redirectURI: redirectURI, scopes: scopes)
    }

    public func listOAuthScopes(accessToken: String) async throws -> [CloudflareOAuthScope] {
        let envelope: Envelope<[CloudflareOAuthScope]> = try await request(path: "/oauth/scopes", accessToken: accessToken)
        guard let result = envelope.result, result.count <= 2000,
              Set(result.map(\.id)).count == result.count,
              result.allSatisfy({ Self.validScopeID($0.id) && Self.validDisplayName($0.name) }) else {
            throw CloudflareConnectionError.malformedResponse
        }
        return result
    }

    public func listAccounts(accessToken: String) async throws -> [CloudflareAccount] {
        var accounts: [CloudflareAccount] = []
        var seen: Set<String> = []
        for page in 1...maximumPages {
            let envelope: Envelope<[CloudflareAccount]> = try await request(path: "/accounts", accessToken: accessToken,
                query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "50")])
            guard let result = envelope.result, result.count <= 50 else { throw CloudflareConnectionError.malformedResponse }
            for account in result {
                guard Self.validAccountID(account.id), Self.validDisplayName(account.name), seen.insert(account.id).inserted else {
                    throw CloudflareConnectionError.malformedResponse
                }
                accounts.append(account)
            }
            let info = envelope.resultInfo
            if page == 1, result.isEmpty, info?.totalPages == 0,
               info?.totalCount == nil || info?.totalCount == 0 { return [] }
            guard info?.page == nil || info?.page == page,
                  info?.totalPages == nil || (info!.totalPages! >= page && info!.totalPages! <= maximumPages) else {
                throw CloudflareConnectionError.malformedResponse
            }
            if let totalPages = info?.totalPages {
                if page == totalPages { return accounts }
            } else if let totalCount = info?.totalCount {
                guard totalCount >= accounts.count else { throw CloudflareConnectionError.malformedResponse }
                if totalCount == accounts.count { return accounts }
            } else if result.count < 50 { return accounts }
            guard !result.isEmpty else { throw CloudflareConnectionError.malformedResponse }
        }
        throw CloudflareConnectionError.paginationLimit
    }

    /// Lists default-jurisdiction buckets only. It never creates a bucket.
    public func listBuckets(accountID: String, accessToken: String) async throws -> [CloudflareBucket] {
        try Self.validateAccountID(accountID)
        var buckets: [CloudflareBucket] = []
        var seenNames: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?
        for _ in 0..<maximumPages {
            var query = [URLQueryItem(name: "per_page", value: "1000")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let envelope: Envelope<BucketList> = try await request(path: "/accounts/\(accountID)/r2/buckets", accessToken: accessToken, query: query)
            guard let result = envelope.result, result.buckets.count <= 1000 else { throw CloudflareConnectionError.malformedResponse }
            for wire in result.buckets {
                let bucket = try convert(wire, accountID: accountID)
                guard seenNames.insert(bucket.name).inserted else { throw CloudflareConnectionError.malformedResponse }
                buckets.append(bucket)
            }
            guard let next = envelope.resultInfo?.cursor, !next.isEmpty else { return buckets }
            guard !result.buckets.isEmpty, next.utf8.count <= 4096,
                  !next.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seenCursors.insert(next).inserted else { throw CloudflareConnectionError.malformedResponse }
            cursor = next
        }
        throw CloudflareConnectionError.paginationLimit
    }

    /// Validates the exact account/bucket selection with read-only API calls.
    public func validateBucket(accountID: String, bucketName: String, accessToken: String) async throws -> CloudflareBucket {
        try Self.validateAccountID(accountID); try Self.validateBucketName(bucketName)
        try await requireAuthorizedAccount(accountID: accountID, accessToken: accessToken)
        let envelope: Envelope<WireBucket> = try await request(path: "/accounts/\(accountID)/r2/buckets/\(bucketName)", accessToken: accessToken)
        guard let result = envelope.result, result.name == bucketName else { throw CloudflareConnectionError.malformedResponse }
        return try convert(result, accountID: accountID)
    }

    /// Call only after an explicit user action approving this exact account/name.
    /// Login and discovery never call this operation. Always creates Standard
    /// storage, without public access or automatic lifecycle configuration.
    public func createBucket(accountID: String, bucketName: String, accessToken: String,
                             locationHint: CloudflareR2LocationHint? = nil) async throws -> CloudflareBucket {
        try Self.validateAccountID(accountID); try Self.validateBucketName(bucketName)
        try await requireAuthorizedAccount(accountID: accountID, accessToken: accessToken)
        let body = CreateBucketBody(name: bucketName, locationHint: locationHint?.rawValue, storageClass: "Standard")
        let envelope: Envelope<WireBucket> = try await request(path: "/accounts/\(accountID)/r2/buckets", accessToken: accessToken,
                                                              method: "POST", body: try JSONEncoder().encode(body))
        guard let result = envelope.result, result.name == bucketName else { throw CloudflareConnectionError.malformedResponse }
        return try convert(result, accountID: accountID)
    }

    public static func bucketEndpoint(accountID: String, bucketName: String) throws -> URL {
        try validateAccountID(accountID); try validateBucketName(bucketName)
        return URL(string: "\(apiBase.absoluteString)/accounts/\(accountID)/r2/buckets/\(bucketName)")!
    }

    /// The current OAuth scope inventory omits Account API Tokens Write. Refuse
    /// locally rather than silently creating broad credentials or asking for a
    /// long-lived API token. R2 OAuth uses the authenticated REST object adapter.
    public func createBucketScopedS3Credential(accountID: String, bucketName: String, accessToken: String) async throws -> Never {
        try Self.validateAccountID(accountID); try Self.validateBucketName(bucketName)
        try Self.validateCredential(accessToken)
        throw CloudflareConnectionError.s3CredentialProvisioningUnavailable
    }

    private func requireAuthorizedAccount(accountID: String, accessToken: String) async throws {
        guard try await listAccounts(accessToken: accessToken).contains(where: { $0.id == accountID }) else {
            throw CloudflareConnectionError.accountNotAuthorized
        }
    }

    private func convert(_ wire: WireBucket, accountID: String) throws -> CloudflareBucket {
        guard Self.validBucketName(wire.name), wire.jurisdiction == nil || wire.jurisdiction == "default",
              wire.location.map({ Self.validDisplayName($0) }) ?? true,
              wire.creationDate.map({ Self.validDisplayName($0) }) ?? true else {
            throw CloudflareConnectionError.malformedResponse
        }
        return CloudflareBucket(accountID: accountID, name: wire.name, location: wire.location, creationDate: wire.creationDate)
    }

    private func request<Result: Decodable>(path: String, accessToken: String, query: [URLQueryItem] = [],
                                             method: String = "GET", body: Data? = nil) async throws -> Envelope<Result> {
        try Self.validateCredential(accessToken)
        var components = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        components.path += path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.host == "api.cloudflare.com", url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil else { throw CloudflareConnectionError.rejected }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpShouldHandleCookies = false; request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("default", forHTTPHeaderField: "cf-r2-jurisdiction")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: OAuthHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CloudflareConnectionError.unavailable }
        switch response.statusCode {
        case 200..<300: break
        case 300..<400: throw CloudflareConnectionError.redirectRejected
        case 401: throw CloudflareConnectionError.unauthorized
        case 403: throw CloudflareConnectionError.insufficientPermission
        case 404: throw CloudflareConnectionError.bucketNotFound
        case 429: throw CloudflareConnectionError.rateLimited
        case 500..<600: throw CloudflareConnectionError.unavailable
        default: throw CloudflareConnectionError.rejected
        }
        guard response.data.count <= maximumResponseBytes else { throw CloudflareConnectionError.malformedResponse }
        let envelope: Envelope<Result>
        do { envelope = try JSONDecoder().decode(Envelope<Result>.self, from: response.data) }
        catch { throw CloudflareConnectionError.malformedResponse }
        guard envelope.success else { throw CloudflareConnectionError.rejected }
        return envelope
    }

    private static func validAccountID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    private static func validateAccountID(_ value: String) throws {
        guard validAccountID(value) else { throw CloudflareConnectionError.invalidAccount }
    }
    private static func validBucketName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ value: UInt8) -> Bool { (48...57).contains(value) || (97...122).contains(value) }
        return (3...63).contains(bytes.count) && bytes.first.map(alphanumeric) == true && bytes.last.map(alphanumeric) == true
            && bytes.allSatisfy({ alphanumeric($0) || $0 == 45 })
    }
    private static func validateBucketName(_ value: String) throws {
        guard validBucketName(value) else { throw CloudflareConnectionError.invalidBucket }
    }
    private static func validDisplayName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validScopeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy({
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        })
    }
    private static func validateCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8192, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw CloudflareConnectionError.invalidCredential
        }
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let success: Bool
        let result: Result?
        let resultInfo: PageInfo?
        enum CodingKeys: String, CodingKey { case success, result; case resultInfo = "result_info" }
    }
    private struct PageInfo: Decodable {
        let page: Int?
        let totalPages: Int?
        let totalCount: Int?
        let cursor: String?
        enum CodingKeys: String, CodingKey { case page, cursor; case totalPages = "total_pages"; case totalCount = "total_count" }
    }
    private struct BucketList: Decodable { let buckets: [WireBucket] }
    private struct WireBucket: Decodable {
        let name: String
        let location: String?
        let jurisdiction: String?
        let creationDate: String?
        enum CodingKeys: String, CodingKey { case name, location, jurisdiction; case creationDate = "creation_date" }
    }
    private struct CreateBucketBody: Encodable {
        let name: String
        let locationHint: String?
        let storageClass: String
    }
}
