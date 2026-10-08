import Foundation

/// Secrets are encoded only for the caller's Keychain storage, never a drive profile.
public struct AWSAccessSession: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let region: String
    public let startURL: URL
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let clientID: String
    public let clientSecret: String
    public let registrationExpiresAt: Date
    public var description: String { "AWSAccessSession(redacted)" }
    public var debugDescription: String { description }
}

public struct AWSDeviceAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let verificationURL: URL
    public let userCode: String
    public let expiresAt: Date
    fileprivate let identifier: UUID
    fileprivate let interval: TimeInterval
    fileprivate let region: String
    fileprivate let startURL: URL
    fileprivate let clientID: String
    fileprivate let clientSecret: String
    fileprivate let registrationExpiresAt: Date
    fileprivate let deviceCode: String
    public var description: String { "AWSDeviceAuthorization(redacted)" }
    public var debugDescription: String { description }
}

public struct AWSAccount: Codable, Sendable, Equatable, Identifiable {
    public let accountID: String
    public let accountName: String?
    public let emailAddress: String?
    public var id: String { accountID }
    enum CodingKeys: String, CodingKey { case accountID = "accountId", accountName, emailAddress }
}
public struct AWSAccountRole: Codable, Sendable, Equatable, Identifiable {
    public let accountID: String
    public let roleName: String
    public var id: String { accountID + ":" + roleName }
    enum CodingKeys: String, CodingKey { case accountID = "accountId", roleName }
}
public struct AWSTemporaryCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentials: S3Credentials
    public let expiresAt: Date
    public var description: String { "AWSTemporaryCredentials(redacted)" }
    public var debugDescription: String { description }
}

/// IAM Identity Center device flow, scoped to the operator's explicit account/role selection.
/// API contracts: docs.aws.amazon.com/singlesignon/latest/{OIDCAPIReference,PortalAPIReference}/.
/// No browser, account registration, or network activity occurs until a method is invoked.
public actor AWSIdentityCenterClient {
    private let transport: any OAuthTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var attemptedAuthorizations: Set<UUID> = []
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    public init(transport: any OAuthTransport = URLSessionOAuthTransport(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.transport = transport; self.now = now; self.sleep = sleep
    }

    public func registerAndStart(startURL: URL, region: String) async throws -> AWSDeviceAuthorization {
        try checkCancellation()
        guard Self.validRegion(region), Self.validStartURL(startURL, region: region) else { throw OAuthError.invalidConfiguration }
        let registration: Registration = try await post("/client/register", region: region, body: [
            "clientName": "ParaAir", "clientType": "public", "scopes": ["sso:account:access"],
            "grantTypes": [Self.deviceGrant, "refresh_token"]
        ])
        guard Self.validSecret(registration.clientId), Self.validSecret(registration.clientSecret),
              registration.clientSecretExpiresAt > now().timeIntervalSince1970 else { throw OAuthError.invalidTokenResponse }
        let device: Device = try await post("/device_authorization", region: region, body: [
            "clientId": registration.clientId, "clientSecret": registration.clientSecret, "startUrl": startURL.absoluteString
        ])
        guard Self.validSecret(device.deviceCode), Self.validSecret(device.userCode, limit: 128),
              device.expiresIn > 0, device.expiresIn <= 3600,
              (1...300).contains(device.interval ?? 5),
              let browser = URL(string: device.verificationUriComplete), Self.validVerificationURL(browser, region: region)
        else { throw OAuthError.invalidTokenResponse }
        let expiry = min(now().addingTimeInterval(min(device.expiresIn, 900)), Date(timeIntervalSince1970: registration.clientSecretExpiresAt))
        return AWSDeviceAuthorization(verificationURL: browser, userCode: device.userCode, expiresAt: expiry,
            identifier: UUID(), interval: device.interval ?? 5, region: region, startURL: startURL,
            clientID: registration.clientId, clientSecret: registration.clientSecret,
            registrationExpiresAt: Date(timeIntervalSince1970: registration.clientSecretExpiresAt), deviceCode: device.deviceCode)
    }

    /// The caller opens verificationURL. Cancellation of this task immediately stops polling.
    /// Each authorization can be polled once; retries require a fresh browser authorization.
    public func pollAuthorization(_ authorization: AWSDeviceAuthorization) async throws -> AWSAccessSession {
        try checkCancellation()
        guard !attemptedAuthorizations.contains(authorization.identifier) else { throw OAuthError.noPendingAuthorization }
        guard attemptedAuthorizations.count < 1024 else { throw OAuthError.alreadyInProgress }
        attemptedAuthorizations.insert(authorization.identifier)
        var interval = authorization.interval
        var remaining = min(authorization.expiresAt.timeIntervalSince(now()), 900)
        // The cumulative wait budget also bounds polling if the wall clock moves backwards.
        for _ in 0..<900 {
            try checkCancellation()
            guard remaining > interval, now() < authorization.expiresAt else { throw OAuthError.expired }
            do { try await sleep(interval) }
            catch is CancellationError { throw OAuthError.cancelled }
            catch let error as OAuthError { throw error }
            catch { throw OAuthError.requestFailed }
            remaining -= interval
            try checkCancellation()
            guard now() < authorization.expiresAt else { throw OAuthError.expired }
            let response = try await send(Self.request("/token", region: authorization.region, body: [
                "clientId": authorization.clientID, "clientSecret": authorization.clientSecret,
                "deviceCode": authorization.deviceCode, "grantType": Self.deviceGrant
            ]))
            if response.statusCode == 200 {
                let value: Token = try Self.decode(response.data)
                return try session(value, region: authorization.region, startURL: authorization.startURL,
                    clientID: authorization.clientID, clientSecret: authorization.clientSecret,
                    registrationExpiresAt: authorization.registrationExpiresAt, priorRefreshToken: nil)
            }
            let code = (try? JSONDecoder().decode(ServiceError.self, from: response.data))?.error
            if code == "authorization_pending" { continue }
            if code == "slow_down" || response.statusCode == 429 {
                interval += 5 // RFC 8628: increase the minimum interval for every subsequent poll.
                if let retry = response.headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
                   let seconds = TimeInterval(retry), seconds.isFinite, seconds > 0 { interval = max(interval, min(seconds, 900)) }
                continue
            }
            if code == "access_denied" { throw OAuthError.authorizationDenied }
            if code == "expired_token" { throw OAuthError.expired }
            throw OAuthError.httpStatus(response.statusCode)
        }
        throw OAuthError.expired
    }

    public func refresh(session previous: AWSAccessSession) async throws -> AWSAccessSession {
        try checkSession(previous, requireAccess: false)
        guard let refresh = previous.refreshToken, Self.validSecret(refresh) else { throw OAuthError.missingRefreshToken }
        let response = try await send(Self.request("/token", region: previous.region, body: [
            "clientId": previous.clientID, "clientSecret": previous.clientSecret,
            "grantType": "refresh_token", "refreshToken": refresh
        ]))
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(ServiceError.self, from: response.data))?.error
            let terminalCodes: Set<String> = ["invalid_grant", "invalid_client", "unauthorized_client", "expired_token", "access_denied"]
            if response.statusCode == 401 || (response.statusCode == 400 && code.map(terminalCodes.contains) == true) { throw OAuthError.expired }
            throw OAuthError.httpStatus(response.statusCode)
        }
        let value: Token = try Self.decode(response.data)
        return try session(value, region: previous.region, startURL: previous.startURL, clientID: previous.clientID,
            clientSecret: previous.clientSecret, registrationExpiresAt: previous.registrationExpiresAt, priorRefreshToken: refresh)
    }

    public func listAccounts(session: AWSAccessSession) async throws -> [AWSAccount] {
        var values: [AWSAccount] = [], next: String?, seen: Set<String> = []
        for _ in 0..<100 {
            let page: AccountPage = try await portal("/assignment/accounts", session: session, query: pageQuery(next))
            guard page.accountList.allSatisfy({ Self.validAccount($0.accountID) }) else { throw OAuthError.invalidTokenResponse }
            values.append(contentsOf: page.accountList)
            guard let token = page.nextToken, !token.isEmpty else { return values }
            guard Self.validSecret(token), seen.insert(token).inserted else { throw OAuthError.invalidTokenResponse }
            next = token
        }
        throw OAuthError.responseTooLarge
    }

    public func listRoles(accountID: String, session: AWSAccessSession) async throws -> [AWSAccountRole] {
        guard Self.validAccount(accountID) else { throw OAuthError.invalidConfiguration }
        var values: [AWSAccountRole] = [], next: String?, seen: Set<String> = []
        for _ in 0..<100 {
            var query = pageQuery(next); query.append(URLQueryItem(name: "account_id", value: accountID))
            let page: RolePage = try await portal("/assignment/roles", session: session, query: query)
            guard page.roleList.allSatisfy({ $0.accountID == accountID && Self.validRole($0.roleName) }) else { throw OAuthError.invalidTokenResponse }
            values.append(contentsOf: page.roleList)
            guard let token = page.nextToken, !token.isEmpty else { return values }
            guard Self.validSecret(token), seen.insert(token).inserted else { throw OAuthError.invalidTokenResponse }
            next = token
        }
        throw OAuthError.responseTooLarge
    }

    public func credentials(accountID: String, roleName: String, session: AWSAccessSession) async throws -> AWSTemporaryCredentials {
        guard Self.validAccount(accountID), Self.validRole(roleName) else { throw OAuthError.invalidConfiguration }
        let reply: RoleCredentialsResponse = try await portal("/federation/credentials", session: session, query: [
            URLQueryItem(name: "account_id", value: accountID), URLQueryItem(name: "role_name", value: roleName)
        ])
        let value = reply.roleCredentials
        guard Self.validSecret(value.accessKeyId, limit: 1024), Self.validSecret(value.secretAccessKey, limit: 4096),
              Self.validSecret(value.sessionToken), value.expiration / 1000 > now().timeIntervalSince1970 else { throw OAuthError.invalidTokenResponse }
        let credentials: S3Credentials
        do { credentials = try S3Credentials(accessKey: value.accessKeyId, secretKey: value.secretAccessKey, sessionToken: value.sessionToken) }
        catch { throw OAuthError.invalidTokenResponse }
        return AWSTemporaryCredentials(credentials: credentials, expiresAt: Date(timeIntervalSince1970: value.expiration / 1000))
    }

    private func session(_ value: Token, region: String, startURL: URL, clientID: String, clientSecret: String,
                         registrationExpiresAt: Date, priorRefreshToken: String?) throws -> AWSAccessSession {
        guard Self.validSecret(value.accessToken), value.expiresIn > 0, value.expiresIn <= 86400,
              value.tokenType?.lowercased() ?? "bearer" == "bearer",
              value.refreshToken.map({ Self.validSecret($0) }) ?? true else { throw OAuthError.invalidTokenResponse }
        return AWSAccessSession(region: region, startURL: startURL, accessToken: value.accessToken,
            refreshToken: value.refreshToken ?? priorRefreshToken, expiresAt: now().addingTimeInterval(value.expiresIn),
            clientID: clientID, clientSecret: clientSecret, registrationExpiresAt: registrationExpiresAt)
    }
    private func checkSession(_ session: AWSAccessSession, requireAccess: Bool = true) throws {
        try checkCancellation()
        guard Self.validRegion(session.region), Self.validStartURL(session.startURL, region: session.region),
              Self.validSecret(session.clientID), Self.validSecret(session.clientSecret), Self.validSecret(session.accessToken)
        else { throw OAuthError.invalidConfiguration }
        guard session.registrationExpiresAt > now(), !requireAccess || session.expiresAt > now() else { throw OAuthError.expired }
    }
    private func pageQuery(_ token: String?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "max_result", value: "100")]
        if let token { query.append(URLQueryItem(name: "next_token", value: token)) }
        return query
    }
    private func portal<T: Decodable>(_ path: String, session: AWSAccessSession, query: [URLQueryItem]) async throws -> T {
        try checkSession(session)
        var url = URLComponents(string: "https://portal.sso.\(session.region).\(Self.suffix(session.region))\(path)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"; request.setValue(session.accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let response = try await send(request)
        guard response.statusCode == 200 else { throw response.statusCode == 401 ? OAuthError.expired : OAuthError.httpStatus(response.statusCode) }
        return try Self.decode(response.data)
    }
    private func post<T: Decodable>(_ path: String, region: String, body: [String: Any]) async throws -> T {
        let response = try await send(Self.request(path, region: region, body: body))
        guard response.statusCode == 200 else { throw OAuthError.httpStatus(response.statusCode) }
        return try Self.decode(response.data)
    }
    private func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        try checkCancellation()
        do {
            let response = try await transport.send(request)
            try checkCancellation()
            guard response.data.count <= 1_048_576 else { throw OAuthError.responseTooLarge }
            return response
        } catch is CancellationError { throw OAuthError.cancelled }
        catch let error as OAuthError { throw error }
        catch { throw OAuthError.requestFailed }
    }
    private func checkCancellation() throws { if Task.isCancelled { throw OAuthError.cancelled } }
    private static func request(_ path: String, region: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oidc.\(region).\(suffix(region))\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OAuthError.invalidTokenResponse }
    }
    private static func validSecret(_ value: String, limit: Int = 16384) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    }
    private static func matches(_ value: String, _ expression: String) -> Bool { value.range(of: expression, options: .regularExpression) != nil }
    private static func validRegion(_ value: String) -> Bool { value.count <= 32 && matches(value, "^[a-z]{2}(-[a-z]+)+-[0-9]+$") }
    private static func validAccount(_ value: String) -> Bool { matches(value, "^[0-9]{12}$") }
    private static func validRole(_ value: String) -> Bool { matches(value, "^[A-Za-z0-9_+=,.@-]{1,128}$") }
    private static func suffix(_ region: String) -> String { region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com" }
    private static func validStartURL(_ url: URL, region: String) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.user == nil,
              c.password == nil, c.port == nil, c.query == nil, c.fragment == nil, let host = c.host?.lowercased() else { return false }
        return host.hasSuffix(".awsapps.com") || host.hasSuffix(".\(region).portal.\(suffix(region))") || host.hasSuffix(".portal.\(region).app.aws")
    }
    private static func validVerificationURL(_ url: URL, region: String) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.user == nil,
              c.password == nil, c.port == nil, c.fragment == nil, let host = c.host?.lowercased() else { return false }
        return host == "device.sso.\(region).\(suffix(region))" || host == "device.sso.\(region).api.aws"
    }
    private struct Registration: Decodable { let clientId: String; let clientSecret: String; let clientSecretExpiresAt: Double }
    private struct Device: Decodable { let deviceCode: String; let userCode: String; let verificationUriComplete: String; let expiresIn: Double; let interval: Double? }
    private struct Token: Decodable { let accessToken: String; let refreshToken: String?; let expiresIn: Double; let tokenType: String? }
    private struct ServiceError: Decodable { let error: String }
    private struct AccountPage: Decodable { let accountList: [AWSAccount]; let nextToken: String? }
    private struct RolePage: Decodable { let roleList: [AWSAccountRole]; let nextToken: String? }
    private struct RoleCredentialsResponse: Decodable {
        struct Value: Decodable { let accessKeyId: String; let secretAccessKey: String; let sessionToken: String; let expiration: Double }
        let roleCredentials: Value
    }
}
