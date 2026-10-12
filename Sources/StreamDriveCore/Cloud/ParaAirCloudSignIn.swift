import Foundation
import Darwin

/// The sign-in path shared by the app and the end-to-end tests: loopback PKCE,
/// `/v1/me`, choice of state folder, account record and drive list.
public enum ParaAirCloudSignIn {
    public struct Result: Sendable {
        public let account: CloudAccount
        public let stateRoot: URL
        public let me: ParaAirCloudMe
        public let drives: [ParaAirCloudDrive]
        public let createdStateRoot: Bool
        let transport: Transport
    }

    /// URL session settings travel with the result so a cancelled sign-in can be revoked the same way.
    struct Transport: @unchecked Sendable {
        let policy: ParaAirCloudTransportPolicy
        let configuration: URLSessionConfiguration
    }

    public static func run(issuer: URL, currentStateRoot: URL, policy: ParaAirCloudTransportPolicy = .current,
                           vault: any ConnectionVault = CloudAccountStore.liveVault, configuration: URLSessionConfiguration = .ephemeral,
                           minimumValidity: TimeInterval = 30,
                           openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void) async throws -> Result {
        try await run(issuer: issuer, currentStateRoot: currentStateRoot, policy: policy, vault: vault, configuration: configuration,
                      minimumValidity: minimumValidity, home: FileManager.default.homeDirectoryForCurrentUser,
                      openAuthorizationURL: openAuthorizationURL)
    }

    static func run(issuer: URL, currentStateRoot: URL, policy: ParaAirCloudTransportPolicy, vault: any ConnectionVault,
                    configuration: URLSessionConfiguration, minimumValidity: TimeInterval, home: URL,
                    openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void) async throws -> Result {
        let transport = Transport(policy: policy, configuration: configuration.copy() as! URLSessionConfiguration)
        let oauth = try ParaAirCloudConfiguration.oauthConfiguration(issuer: issuer, policy: policy)
        let issuer = oauth.expectedIssuer!
        let tokenTransport = URLSessionOAuthTransport(timeout: 30, maximumResponseBytes: 1 << 20, allowsLoopbackHTTP: policy.allowsLoopbackHTTP,
                                                      configurationFactory: { transport.configuration.copy() as! URLSessionConfiguration })
        let tokens = try await runLoopbackOAuth(configuration: oauth, transport: tokenTransport, openAuthorizationURL: openAuthorizationURL)
        let scopes = Set((tokens.scope ?? ParaAirCloudConfiguration.scopes.joined(separator: " ")).split(separator: " ").map(String.init))
        guard scopes.contains("drive"), !(tokens.refreshToken ?? "").isEmpty,
              let expiry = tokens.expiresAt, expiry > Date().addingTimeInterval(minimumValidity) else {
            throw DriveError(EACCES, "ParaAir Cloud did not grant drive access. Sign in again.")
        }
        return try await ParaAirCloudBlocking.run {
            let http = try ParaAirCloudHTTP(baseURL: issuer, policy: transport.policy, configuration: transport.configuration)
            defer { http.invalidate() }
            let api = ParaAirCloudAPI(http: http, tokens: StaticAccessToken(tokens.accessToken))
            let me = try api.me()
            let target = try chooseRoot(issuer: issuer.absoluteString, userID: me.user.id, current: currentStateRoot, home: home)
            let account = CloudAccount(id: target.accountID, issuer: issuer.absoluteString, userID: me.user.id, email: me.user.email)
            do {
                try CloudAccountStore(root: target.root).signIn(account, tokens: tokens, vault: vault)
            } catch {
                if target.created { try? FileManager.default.removeItem(at: target.root) }
                throw error
            }
            let saved = try CloudAccountStore(root: target.root).load(account.id)
            return Result(account: saved, stateRoot: target.root, me: me, drives: try api.drives(),
                          createdStateRoot: target.created, transport: transport)
        }
    }

    /// Signs out and revokes an account whose drive choice was abandoned, and removes
    /// the state folder sign-in created for it.
    public static func cancelUnfinished(_ result: Result, vault: any ConnectionVault) async {
        let tokens = try? CloudAccountStore(root: result.stateRoot).signOut(result.account.id, vault: vault)
        if let tokens, let issuer = try? ParaAirCloudIssuer.validate(result.account.issuer) {
            await revoke(tokens, issuer: issuer, policy: result.transport.policy, configuration: result.transport.configuration)
        }
        if result.createdStateRoot, (try? ProfileStore(root: result.stateRoot).list().isEmpty) ?? false {
            try? FileManager.default.removeItem(at: result.stateRoot)
        }
    }

    /// Best effort and outside every lock (spec 3.5): end the session with the access
    /// token, or revoke the refresh token when that fails.
    public static func revoke(_ tokens: OAuthTokens, issuer: URL, policy: ParaAirCloudTransportPolicy,
                              configuration: URLSessionConfiguration = .ephemeral) async {
        let transport = Transport(policy: policy, configuration: configuration)
        _ = try? await ParaAirCloudBlocking.run {
            let http = try ParaAirCloudHTTP(baseURL: issuer, policy: transport.policy, configuration: transport.configuration)
            defer { http.invalidate() }
            let api = ParaAirCloudAPI(http: http, tokens: StaticAccessToken(tokens.accessToken))
            api.retryDelays = [0.25]
            if (try? api.endSession()) != nil { return }
            guard let refresh = tokens.refreshToken else { return }
            let body = oauthFormBody(["token": refresh, "token_type_hint": "refresh_token", "client_id": ParaAirCloudConfiguration.clientID])
            _ = try? http.sendSync(ParaAirCloudHTTP.Request(method: "POST", path: "/oauth/revoke",
                                                            headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                            body: body, maxResponseBytes: 64 << 10, route: "POST /oauth/revoke"), bearer: nil)
        }
    }

    /// The current folder when it already holds this account or holds nothing;
    /// otherwise this account's own folder under "Cloud Drives".
    static func chooseRoot(issuer: String, userID: String, current: URL, home: URL) throws -> (root: URL, accountID: String, created: Bool) {
        let store = CloudAccountStore(root: current)
        if let existing = store.existing(issuer: issuer, userID: userID) { return (current, existing.id, false) }
        let listed = store.list()
        if listed.accounts.isEmpty, listed.unreadable.isEmpty, try ProfileStore(root: current).list().isEmpty {
            return (current, UUID().uuidString.lowercased(), false)
        }
        let drives = CloudDriveSetup.defaultStateRoot(accountID: "x", home: home).deletingLastPathComponent()
        if let folders = try? FileManager.default.contentsOfDirectory(at: drives, includingPropertiesForKeys: nil) {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let existing = CloudAccountStore(root: folder).existing(issuer: issuer, userID: userID), existing.id == folder.lastPathComponent {
                    return (folder, existing.id, false)
                }
            }
        }
        let id = UUID().uuidString.lowercased()
        let root = CloudDriveSetup.defaultStateRoot(accountID: id, home: home)
        try DurableIO.directory(root)
        return (root, id, true)
    }
}
