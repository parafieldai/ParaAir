import Foundation

public enum OAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration, invalidCallback, expired, cancelled, noPendingAuthorization
    case authorizationDenied, requestFailed, invalidTokenResponse, missingRefreshToken
    case alreadyInProgress, listenerFailed, timedOut, responseTooLarge
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "OAuth configuration is invalid. Check the public client ID, HTTPS endpoints and loopback callback."
        case .invalidCallback: return "The authorization callback did not match this sign-in attempt."
        case .expired: return "The sign-in attempt expired. Start sign-in again."
        case .cancelled: return "Sign-in was cancelled."
        case .noPendingAuthorization: return "There is no unused sign-in attempt. Start sign-in again."
        case .authorizationDenied: return "The provider did not authorize this sign-in attempt."
        case .requestFailed: return "The authorization service could not be reached."
        case .invalidTokenResponse: return "The authorization service returned an invalid token response."
        case .missingRefreshToken: return "Sign in again to renew this connection."
        case .alreadyInProgress: return "An authorization operation is already in progress."
        case .listenerFailed: return "The local sign-in callback could not start. Check whether its port is already in use."
        case .timedOut: return "Sign-in timed out. Start sign-in again."
        case .responseTooLarge: return "The authorization service response exceeded the permitted size."
        case .httpStatus(let code): return "The authorization service rejected the request (HTTP \(code))."
        }
    }
}

public struct OAuthConfiguration: Sendable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let additionalAuthorizationParameters: [String: String]
    public let expectedIssuer: URL?

    public init(authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, redirectURI: URL,
                scopes: [String], additionalAuthorizationParameters: [String: String] = [:], expectedIssuer: URL? = nil) throws {
        func validHTTPS(_ url: URL) -> Bool {
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            return c.scheme == "https" && !(c.host ?? "").isEmpty && c.user == nil && c.password == nil && c.fragment == nil
        }
        let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
        let reserved: Set<String> = ["response_type", "client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method", "code_verifier", "client_secret", "access_token", "refresh_token"]
        guard validHTTPS(authorizationEndpoint), validHTTPS(tokenEndpoint),
              !clientID.isEmpty, clientID.utf8.count <= 1024, !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              redirect?.scheme == "http", redirect?.host == "127.0.0.1", let port = redirect?.port, (0...65535).contains(port),
              redirect?.user == nil, redirect?.password == nil, redirect?.query == nil, redirect?.fragment == nil,
              !(redirect?.path ?? "").isEmpty, scopes.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x21...0x7e).contains($0) && $0 != 0x22 && $0 != 0x5c } }),
              additionalAuthorizationParameters.keys.allSatisfy({ !reserved.contains($0) && !$0.isEmpty }),
              scopes.reduce(0, { $0 + $1.utf8.count }) <= 8192,
              additionalAuthorizationParameters.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 8192,
              expectedIssuer.map(validHTTPS) ?? true else { throw OAuthError.invalidConfiguration }
        let endpointItems = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !endpointItems.contains(where: { reserved.contains($0.name) }), Set(endpointItems.map(\.name)).count == endpointItems.count,
              !endpointItems.contains(where: { additionalAuthorizationParameters[$0.name] != nil }) else { throw OAuthError.invalidConfiguration }
        self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID; self.redirectURI = redirectURI; self.scopes = scopes
        self.additionalAuthorizationParameters = additionalAuthorizationParameters; self.expectedIssuer = expectedIssuer
    }

    public func replacingRedirectURI(_ uri: URL) throws -> OAuthConfiguration {
        try OAuthConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, clientID: clientID,
                               redirectURI: uri, scopes: scopes, additionalAuthorizationParameters: additionalAuthorizationParameters,
                               expectedIssuer: expectedIssuer)
    }
}

public struct OAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let tokenType: String
    public let scope: String?
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenType: String = "Bearer", scope: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.tokenType = tokenType; self.scope = scope
    }
    public var description: String { "OAuthTokens(<redacted>)" }
    public var debugDescription: String { description }
}

public struct OAuthAuthorization: Sendable {
    /// Safe to open in a browser; contains a random state and PKCE challenge, never tokens or the verifier.
    public let authorizationURL: URL
    public let expiresAt: Date
}

public struct OAuthHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]
    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode; self.data = data; self.headers = headers
    }
}

/// Implementations must not forward token requests across HTTP redirects or log their contents.
public protocol OAuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse
}
