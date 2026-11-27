import Foundation
import os

/// What ParaAir Cloud last said about this version of ParaAir (contract README "Client versions"): 426
/// `client_too_old` when the app is older than the service's `MIN_CLIENT_VERSION` (every call under /v1 but
/// /v1/health), or older than `MIN_CLIENT_VERSION_BILLING` (the /v1/billing calls only).
///
/// That answer doesn't change until ParaAir is updated or the service lowers its floor, so asking again on every call
/// only fails the same way. On 2026-11-27 a refused build sent every Finder request and a feed read every 30 s, each
/// failing with ENOTSUP. After a refusal, calls of the refused scope to that service get the same 426 from here,
/// without the network, except one every `recheckInterval` that goes out to ask again. An answer the service gives only
/// after its version check (anything but 426, 429 and 5xx) lets the scope's calls through again.
///
/// One per process, keyed by the service's origin: the app, its file system extension and the CLI each learn on their
/// own, and every session, drive and connection of a process to that service shares what it learned.
public final class ParaAirCloudVersionGate: @unchecked Sendable {
    public enum Scope: String, Sendable {
        /// Every call under /v1 except /v1/health: files, drives, the account, billing.
        case service
        /// The /v1/billing calls only (plans, checkout, the billing portal); files keep working.
        case billing
    }

    public static let shared = ParaAirCloudVersionGate()
    /// Posted (on no particular queue) when a service starts or stops refusing this version; `object` is the gate.
    public static let didChange = Notification.Name("ParaAirCloudVersionGate.didChange")

    /// How long a refused scope waits before one call asks the service again.
    public var recheckInterval: TimeInterval {
        get { lock.withLock { interval } }
        set { lock.withLock { interval = max(0, newValue) } }
    }

    private let lock = NSLock()
    private var interval: TimeInterval = 900
    private let now: () -> Date
    /// By origin, then scope: when the next call may go out to ask again.
    private var refused: [String: [Scope: Date]] = [:]
    private static let logger = Logger(subsystem: "dev.streamdrive.cloud", category: "version")

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    /// The scope a request path belongs to; nil for paths the service never refuses by version (/v1/health, which
    /// reports the floor, and everything outside /v1: sign-in, tokens, the account pages).
    static func scope(of path: String) -> Scope? {
        guard path.hasPrefix("/v1/"), path != "/v1/health" else { return nil }
        return path.hasPrefix("/v1/billing/") ? .billing : .service
    }

    /// The scope the service refuses this version for (`.service` covers billing too), or nil. With `baseURL` nil, the
    /// strongest refusal from any service this process has called.
    public func refusal(for baseURL: URL? = nil) -> Scope? {
        lock.withLock {
            let scopes = baseURL.map { refused[Self.origin($0)].map { [$0] } ?? [] } ?? Array(refused.values)
            if scopes.contains(where: { $0[.service] != nil }) { return .service }
            return scopes.contains { $0[.billing] != nil } ? .billing : nil
        }
    }

    /// Whether a request to `path` may go out now. False while its scope is refused, except once every
    /// `recheckInterval`, when this call goes out to ask again.
    func admits(_ baseURL: URL, path: String) -> Bool {
        guard let scope = Self.scope(of: path) else { return true }
        return lock.withLock {
            let key = Self.origin(baseURL)
            guard var scopes = refused[key] else { return true }
            // A service-wide refusal covers billing calls too: their floor is never below the service's.
            let blocking: Scope? = scopes[.service] != nil ? .service : scope == .billing && scopes[.billing] != nil ? .billing : nil
            guard let blocking, let due = scopes[blocking] else { return true }
            let clock = now()
            guard clock >= due else { return false }
            scopes[blocking] = clock.addingTimeInterval(interval)
            refused[key] = scopes
            return true
        }
    }

    /// The service's answer to a request for `path` (an HTTP status; 101 for a WebSocket that opened).
    func answered(_ baseURL: URL, path: String, status: Int) {
        guard let scope = Self.scope(of: path) else { return }
        let key = Self.origin(baseURL)
        let changed: Bool = lock.withLock {
            var scopes = refused[key] ?? [:]
            let before = scopes.keys.sorted { $0.rawValue < $1.rawValue }
            if status == 426 {
                // Ask again after the interval, counted from this answer.
                scopes[scope] = now().addingTimeInterval(interval)
            } else if status == 429 || status >= 500 {
                // Answered before the version check (rate limits, an unavailable service): says nothing about it.
                return false
            } else {
                // Past the version check: a billing call passed both floors, any other call the service's.
                scopes[.service] = nil
                if scope == .billing { scopes[.billing] = nil }
            }
            refused[key] = scopes.isEmpty ? nil : scopes
            return before != scopes.keys.sorted { $0.rawValue < $1.rawValue }
        }
        guard changed else { return }
        if status == 426 {
            Self.logger.error("ParaAir Cloud refuses mac/\(ParaAirCloudConfiguration.clientVersion, privacy: .public) for \(scope.rawValue, privacy: .public) calls; asking again every \(Int(self.recheckInterval), privacy: .public) s")
        } else {
            Self.logger.notice("ParaAir Cloud accepts mac/\(ParaAirCloudConfiguration.clientVersion, privacy: .public) again for \(scope.rawValue, privacy: .public) calls")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The reply a refused request gets without the network: what the service itself sends, so callers handle both
    /// alike. Nothing was sent, so no request id.
    static let refusedResponse = ParaAirCloudHTTP.Response(
        status: ParaAirCloudErrorCode.clientTooOld.httpStatus, headers: ["content-type": "application/json"],
        body: Data(#"{"error":{"code":"client_too_old","message":"Update ParaAir to keep using ParaAir Cloud."}}"#.utf8))

    /// Forgets every refusal (tests).
    func reset() { lock.withLock { refused = [:] } }

    /// scheme://host:port, lowercased; the change stream's ws/wss count as http/https.
    static func origin(_ url: URL) -> String {
        let scheme: String
        switch url.scheme?.lowercased() {
        case "wss": scheme = "https"
        case "ws": scheme = "http"
        case let other: scheme = other ?? ""
        }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        return "\(scheme)://\((url.host ?? "").lowercased()):\(port)"
    }
}
