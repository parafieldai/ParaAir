import Foundation
import Darwin

/// Which service addresses this build may contact. Release builds reach HTTPS only;
/// loopback HTTP exists for `wrangler dev` and is opted into per build.
public struct ParaAirCloudTransportPolicy: Sendable, Hashable {
    public var allowsLoopbackHTTP: Bool
    public init(allowsLoopbackHTTP: Bool) { self.allowsLoopbackHTTP = allowsLoopbackHTTP }

    /// Info.plist `ParaAirCloudAllowLoopbackHTTP == true`; in DEBUG builds also
    /// the environment variable `PARAAIR_CLOUD_ALLOW_LOOPBACK_HTTP == "1"`.
    public static var current: ParaAirCloudTransportPolicy {
        current(info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment)
    }
    static func current(info: [String: Any], environment: [String: String]) -> ParaAirCloudTransportPolicy {
        var allowed = (info["ParaAirCloudAllowLoopbackHTTP"] as? Bool) == true
        #if DEBUG
        if environment["PARAAIR_CLOUD_ALLOW_LOOPBACK_HTTP"] == "1" { allowed = true }
        #endif
        return ParaAirCloudTransportPolicy(allowsLoopbackHTTP: allowed)
    }

    /// https with a host, or (when allowed) `http://127.0.0.1:<port>`; never
    /// credentials, a query or a fragment; the path is empty or "/".
    public func validate(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.percentEncodedPath.isEmpty || c.percentEncodedPath == "/",
              (c.scheme == "https" && !(c.host ?? "").isEmpty)
                || (allowsLoopbackHTTP && c.scheme == "http" && c.host == "127.0.0.1" && c.port != nil) else {
            throw DriveError(EACCES, "This ParaAir build can’t reach that service address")
        }
    }
}

public enum ParaAirCloudIssuer {
    /// Syntactic only and independent of the build's transport policy:
    /// `https://host[:port]` or `http://127.0.0.1:port`, with no trailing slash.
    public static func validate(_ value: String) throws -> URL {
        let pattern = "^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$|^http://127\\.0\\.0\\.1:[0-9]{2,5}$"
        guard value.utf8.count <= 300, value.range(of: pattern, options: .regularExpression) != nil,
              let url = URL(string: value), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host, !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              c.port.map({ (1...65535).contains($0) }) ?? true, c.percentEncodedPath.isEmpty else {
            throw DriveError(EINVAL, "Invalid ParaAir Cloud service address")
        }
        return url
    }
}

public enum ParaAirCloudConfiguration {
    public static let clientID = "paraair-macos"
    public static let scopes = ["drive", "offline_access"]
    public static let chunkSize = 4_194_304
    static let developerOverrideFile = "paraair-cloud-service.json"

    /// Sent as `X-ParaAir-Client: mac/<version>`. The service accepts `major[.minor[.patch]]`
    /// (up to 6 digits each); anything else is sent as `dev`, which only a dev-mode service accepts.
    public static var clientVersion: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              value.range(of: "^[0-9]{1,6}(\\.[0-9]{1,6}){0,2}$", options: .regularExpression) != nil else { return "dev" }
        return value
    }

    /// The developer override `<stateRoot>/paraair-cloud-service.json` is read only
    /// when the policy allows loopback HTTP; otherwise Info.plist `ParaAirCloudBaseURL`;
    /// otherwise nil, meaning ParaAir Cloud is not available in this build.
    public static func baseURL(stateRoot: URL, policy: ParaAirCloudTransportPolicy = .current,
                               info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> URL? {
        if policy.allowsLoopbackHTTP, let override = developerBaseURL(stateRoot: stateRoot, policy: policy) { return override }
        guard let value = info["ParaAirCloudBaseURL"] as? String, let url = try? ParaAirCloudIssuer.validate(value),
              (try? policy.validate(url)) != nil else { return nil }
        return url
    }

    public static func saveDeveloperBaseURL(_ url: URL, stateRoot: URL, policy: ParaAirCloudTransportPolicy) throws {
        guard policy.allowsLoopbackHTTP else { throw DriveError(EACCES, "This ParaAir build has no developer service address") }
        let issuer = try ParaAirCloudIssuer.validate(url.absoluteString)
        try policy.validate(issuer)
        try DurableIO.directory(stateRoot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try DurableIO.write(encoder.encode(["baseURL": issuer.absoluteString]), to: stateRoot.appendingPathComponent(developerOverrideFile))
    }

    public static func oauthConfiguration(issuer: URL, policy: ParaAirCloudTransportPolicy) throws -> OAuthConfiguration {
        let issuer = try ParaAirCloudIssuer.validate(issuer.absoluteString)
        try policy.validate(issuer)
        return try OAuthConfiguration(authorizationEndpoint: issuer.appendingPathComponent("oauth/authorize"),
                                      tokenEndpoint: issuer.appendingPathComponent("oauth/token"), clientID: clientID,
                                      redirectURI: URL(string: "http://127.0.0.1:0/oauth/callback")!, scopes: scopes,
                                      expectedIssuer: issuer, allowsLoopbackHTTP: policy.allowsLoopbackHTTP)
    }

    private static func developerBaseURL(stateRoot: URL, policy: ParaAirCloudTransportPolicy) -> URL? {
        let file = stateRoot.appendingPathComponent(developerOverrideFile)
        var s = Darwin.stat()
        guard lstat(file.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size <= 4096,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode([String: String].self, from: data)["baseURL"],
              let url = try? ParaAirCloudIssuer.validate(value), (try? policy.validate(url)) != nil else { return nil }
        return url
    }
}
