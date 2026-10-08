import Foundation
import CryptoKit
import Security

public actor OAuthClient {
    public let configuration: OAuthConfiguration
    private let transport: any OAuthTransport
    private let now: @Sendable () -> Date
    private struct Attempt { let state: String; let verifier: String; let expiresAt: Date }
    private var attempt: Attempt?
    private var generation: UInt64 = 0
    private var refreshing = false
    private var requestTask: (id: UUID, task: Task<OAuthHTTPResponse, Error>)?

    public init(configuration: OAuthConfiguration, transport: any OAuthTransport = URLSessionOAuthTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.transport = transport; self.now = now
    }

    public func begin(lifetime: TimeInterval = 300) throws -> OAuthAuthorization {
        guard lifetime.isFinite, lifetime > 0, lifetime <= 900, configuration.redirectURI.port != 0 else { throw OAuthError.invalidConfiguration }
        guard requestTask == nil, attempt == nil || attempt!.expiresAt <= now() else { throw OAuthError.alreadyInProgress }
        let state = try randomURLSafe(), verifier = try randomURLSafe()
        let expiresAt = now().addingTimeInterval(lifetime)
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: configuration.clientID),
                  URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString), URLQueryItem(name: "state", value: state),
                  URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).oauthBase64URL),
                  URLQueryItem(name: "code_challenge_method", value: "S256")]
        if !configuration.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " "))) }
        items += configuration.additionalAuthorizationParameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw OAuthError.invalidConfiguration }
        generation &+= 1; attempt = Attempt(state: state, verifier: verifier, expiresAt: expiresAt)
        return OAuthAuthorization(authorizationURL: url, expiresAt: expiresAt)
    }

    public func complete(callbackURL: URL) async throws -> OAuthTokens {
        guard let attempt else { throw OAuthError.noPendingAuthorization }
        guard attempt.expiresAt > now() else { self.attempt = nil; throw OAuthError.expired }
        let values = try oauthCallbackParameters(callbackURL, redirectURI: configuration.redirectURI, expectedState: attempt.state)
        if let issuer = configuration.expectedIssuer, values["iss"] != issuer.absoluteString { throw OAuthError.invalidCallback }
        guard !(values["code"] != nil && values["error"] != nil) else { throw OAuthError.invalidCallback }
        self.attempt = nil // Codes and attempts are consumed before the asynchronous exchange, including provider rejection.
        if values["error"] != nil { throw OAuthError.authorizationDenied }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8192 else { throw OAuthError.invalidCallback }
        let operation = generation
        let tokens = try await exchange(["grant_type": "authorization_code", "code": code, "code_verifier": attempt.verifier,
                                         "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI.absoluteString])
        guard operation == generation else { throw OAuthError.cancelled }
        return tokens
    }

    public func cancel() { attempt = nil; generation &+= 1; requestTask?.task.cancel() }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { throw OAuthError.missingRefreshToken }
        guard refreshToken.utf8.count <= 65536 else { throw OAuthError.invalidTokenResponse }
        guard !refreshing, requestTask == nil else { throw OAuthError.alreadyInProgress }
        refreshing = true; defer { refreshing = false }
        let operation = generation
        let renewed = try await exchange(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": configuration.clientID])
        guard operation == generation else { throw OAuthError.cancelled }
        return OAuthTokens(accessToken: renewed.accessToken, refreshToken: renewed.refreshToken ?? refreshToken,
                           expiresAt: renewed.expiresAt, tokenType: renewed.tokenType, scope: renewed.scope ?? tokens.scope)
    }

    private func exchange(_ fields: [String: String]) async throws -> OAuthTokens {
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = oauthFormBody(fields)
        let response: OAuthHTTPResponse
        let id = UUID(), transport = self.transport
        let task = Task { try await transport.send(request) }
        requestTask = (id, task)
        defer { if requestTask?.id == id { requestTask = nil } }
        do {
            response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as OAuthError { throw error }
        catch { throw OAuthError.requestFailed }
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            if (response.statusCode == 400 || response.statusCode == 401), response.data.count <= 1_048_576,
               let body = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let code = body["error"] as? String, code == "invalid_grant" || code == "invalid_token" { throw OAuthError.expired }
            throw OAuthError.httpStatus(response.statusCode)
        }
        guard response.data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], object["error"] == nil,
              let access = object["access_token"] as? String, !access.isEmpty, access.utf8.count <= 65536,
              !access.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let type = object["token_type"] as? String, type.lowercased() == "bearer" else { throw OAuthError.invalidTokenResponse }
        let refresh = object["refresh_token"] as? String
        guard object["refresh_token"] == nil || (refresh != nil && !refresh!.isEmpty && refresh!.utf8.count <= 65536) else { throw OAuthError.invalidTokenResponse }
        var expiry: Date?
        if let value = object["expires_in"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 315_360_000 else { throw OAuthError.invalidTokenResponse }
            expiry = now().addingTimeInterval(number.doubleValue)
        }
        guard object["scope"] == nil || object["scope"] is String else { throw OAuthError.invalidTokenResponse }
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: expiry, tokenType: type, scope: object["scope"] as? String)
    }
}

func oauthCallbackParameters(_ url: URL, redirectURI: URL, expectedState: String) throws -> [String: String] {
    guard let incoming = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let expected = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
          incoming.scheme == expected.scheme, incoming.host == "127.0.0.1", incoming.host == expected.host,
          incoming.port == expected.port, incoming.percentEncodedPath == expected.percentEncodedPath,
          incoming.user == nil, incoming.password == nil, incoming.fragment == nil,
          let query = incoming.percentEncodedQuery, query.utf8.count <= 16384,
          let decoded = URLComponents(string: "http://127.0.0.1/?" + query.replacingOccurrences(of: "+", with: "%20"))?.queryItems else { throw OAuthError.invalidCallback }
    var values: [String: String] = [:]
    for item in decoded {
        guard values[item.name] == nil, let value = item.value else { throw OAuthError.invalidCallback }
        values[item.name] = value
    }
    guard let state = values["state"], oauthConstantTimeEqual(state, expectedState) else { throw OAuthError.invalidCallback }
    return values
}

func oauthFormBody(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(fields.sorted(by: { $0.key < $1.key }).map {
        $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }.joined(separator: "&").utf8)
}

private func randomURLSafe() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthError.requestFailed }
    return Data(bytes).oauthBase64URL
}
private func oauthConstantTimeEqual(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8), rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
private extension Data {
    var oauthBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
