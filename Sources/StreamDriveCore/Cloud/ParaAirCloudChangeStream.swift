import Foundation
import Darwin
import os

/// The pushed side of a drive's change feed (cloud README "Change feed": `GET /v1/drives/{d}/changes/stream`, a
/// WebSocket). The service first sends the newest cursor it knows of for the drive (nil when it knows none), then the
/// cursor of each change that commits. A cursor greater than the one a follower reached means "pull the feed"; the
/// socket never says what changed, so folder rules stay with the feed.
///
/// One instance is one connection: it reports `.closed` exactly once, and is done after that; open a new one to
/// reconnect. It keeps the connection alive with WebSocket pings, which the service answers without waking anything
/// or counting a request, and treats a ping that gets no pong as a lost connection.
public final class ParaAirCloudChangeStream: NSObject, @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// `first`: the newest cursor the service knows of for the drive, sent on connecting (nil when it knows none).
        /// Then one per committed change.
        case cursor(Int64?, first: Bool)
        case closed(Closure)
    }
    public enum Closure: Sendable, Equatable {
        /// The token's time ran out (close 4001 "expired"): reconnect now, with a current token.
        case expired
        /// A newer connection of the same person or credential to this drive replaced it (close 4008): wait long.
        case replaced
        /// The service refused the request: `errno` EACCES (signed out, 401), ENOENT (no such drive or no access),
        /// EPERM (forbidden or suspended), ENOTSUP (this version of ParaAir is too old, 426; also without connecting
        /// while ParaAirCloudVersionGate holds that answer), EINVAL (anything else it refused).
        case refused(Int32)
        /// The connection failed, went quiet, the Mac slept, or the service closed it (a deploy).
        case dropped
        /// `close()` was called.
        case closedByClient
    }
    public struct Options: Sendable, Equatable {
        public var pingInterval: TimeInterval = 30
        public var pongTimeout: TimeInterval = 15
        /// The handshake, from connecting to the first message.
        public var openTimeout: TimeInterval = 30
        public init() {}
    }

    public let driveID: String
    private let url: URL
    /// The service's https (or loopback http) origin, for the version gate.
    private let issuer: URL
    /// What the service said about this version of ParaAir; tests use their own.
    var versionGate: ParaAirCloudVersionGate = .shared
    private let tokens: any ParaAirCloudTokenProvider
    private let options: Options
    private let configuration: URLSessionConfiguration
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.streamdrive.cloud.changestream")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var bearer: String?
    private var timer: DispatchSourceTimer?
    private var pingSent: DispatchTime?
    private var opened = DispatchTime.now()
    /// The wall clock and uptime at the last check: the wall clock running ahead of uptime means the Mac slept, and
    /// the connection from before can't be trusted.
    private var lastCheck = (wall: Date(), uptime: DispatchTime.now())
    private var received = false
    private var finished = false
    private static let logger = Logger(subsystem: "dev.streamdrive.cloud", category: "changestream")

    /// `baseURL` is the service issuer, held to `policy` like ParaAirCloudHTTP (https; loopback http only where the
    /// policy allows it); nothing is sent until `start()`.
    public init(baseURL: URL, driveID: String, tokens: any ParaAirCloudTokenProvider, options: Options = .init(),
                policy: ParaAirCloudTransportPolicy = .current, configuration: URLSessionConfiguration = .ephemeral,
                handler: @escaping @Sendable (Event) -> Void) throws {
        guard ParaAirCloudIDs.isDriveID(driveID) else { throw DriveError(EINVAL, "Invalid ParaAir Cloud drive identifier") }
        let issuer = try ParaAirCloudIssuer.validate(baseURL.absoluteString)
        try policy.validate(issuer)
        guard var parts = URLComponents(url: issuer, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { throw DriveError(EINVAL, "Invalid ParaAir Cloud address") }
        parts.scheme = scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/drives/\(driveID)/changes/stream"
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw DriveError(EINVAL, "Invalid ParaAir Cloud address") }
        self.driveID = driveID; self.url = url; self.issuer = issuer; self.tokens = tokens; self.options = options; self.handler = handler
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        // A quiet drive sends nothing for hours. URLSession's own timeouts must not end the connection; the handshake
        // and pong checks below decide when it is lost.
        config.timeoutIntervalForRequest = Self.longest; config.timeoutIntervalForResource = Self.longest
        self.configuration = config
        super.init()
    }

    deinit {
        timer?.cancel()
        session?.invalidateAndCancel()
    }

    /// Connects in the background. The token may need a refresh (network), so this never blocks the caller.
    public func start() {
        queue.async { self.connect() }
    }

    /// Closes the connection; the handler then gets `.closed(.closedByClient)` unless it was already closed.
    public func close() {
        queue.async { self.finish(.closedByClient) }
    }

    // MARK: Connection (on `queue`)

    private func connect() {
        guard !finished, task == nil else { return }
        // Refused as too old: not again until the gate lets a call ask.
        guard versionGate.admits(issuer, path: url.path) else { finish(.refused(ENOTSUP)); return }
        let token: String
        do { token = try tokens.accessToken() }
        catch let error as DriveError {
            finish(error.code == EACCES ? .refused(EACCES) : .dropped); return
        } catch { finish(.dropped); return }
        bearer = token
        var request = URLRequest(url: url, timeoutInterval: Self.longest)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("mac/" + ParaAirCloudConfiguration.clientVersion, forHTTPHeaderField: "X-ParaAir-Client")
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue; delegateQueue.maxConcurrentOperationCount = 1
        let proxy = DelegateProxy(); proxy.owner = self
        let session = URLSession(configuration: configuration, delegate: proxy, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4096
        self.session = session; self.task = task
        opened = .now()
        lastCheck = (Date(), .now())
        task.resume()
        receive(task)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Every few seconds, with leeway, so an idle Mac isn't woken every second per drive.
        timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.finished, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let cursor = Self.cursor(in: text) {
                        let first = !self.received
                        self.received = true
                        if first { self.versionGate.answered(self.issuer, path: self.url.path, status: 101) }
                        self.handler(.cursor(cursor, first: first))
                    }
                    self.receive(task)
                case .failure:
                    self.finishFromTask(task)
                }
            }
        }
    }

    private static let tick: DispatchTimeInterval = .seconds(5)
    static let closeExpired = 4001, closeReplaced = 4008
    private static let longest: TimeInterval = 7 * 86_400

    /// Every few seconds: gives up on a handshake that takes too long, sends a ping every `pingInterval` and treats a
    /// ping without a pong after `pongTimeout` as a lost connection.
    private func tick() {
        guard !finished, let task else { return }
        let now = DispatchTime.now(), wall = Date()
        let slept = wall.timeIntervalSince(lastCheck.wall) - Double(now.uptimeNanoseconds - lastCheck.uptime.uptimeNanoseconds) / 1e9
        lastCheck = (wall, now)
        if slept > 10 { Self.logger.notice("change stream: the Mac slept"); finish(.dropped); return }
        if !received {
            if now > opened + options.openTimeout { Self.logger.notice("change stream handshake timed out"); finish(.dropped) }
            return
        }
        if let sent = pingSent {
            if now > sent + options.pongTimeout { Self.logger.notice("change stream ping got no pong"); finish(.dropped) }
            return
        }
        guard now > (lastPong ?? opened) + options.pingInterval else { return }
        pingSent = now
        task.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished, self.task === task else { return }
                if error != nil { self.finishFromTask(task); return }
                self.pingSent = nil; self.lastPong = .now()
            }
        }
    }
    private var lastPong: DispatchTime?

    /// The task ended: a close frame, an HTTP refusal of the upgrade, or a network failure.
    private func finishFromTask(_ task: URLSessionWebSocketTask, code: Int? = nil, reason: Data? = nil) {
        guard !finished else { return }
        let closeCode = code ?? task.closeCode.rawValue
        let closeReason = (reason ?? task.closeReason).map { String(decoding: $0, as: UTF8.self) }
        if closeCode == Self.closeExpired || closeReason == "expired" { finish(.expired); return }
        if closeCode == Self.closeReplaced || closeReason == "replaced" { finish(.replaced); return }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            versionGate.answered(issuer, path: url.path, status: status)
            switch status {
            case 401:
                if let bearer { tokens.tokenRejected(bearer) }
                finish(.refused(EACCES))
            case 404: finish(.refused(ENOENT))
            case 403: finish(.refused(EPERM))
            case 426: finish(.refused(ENOTSUP))
            case 400...499: finish(.refused(EINVAL))
            default: finish(.dropped)
            }
            return
        }
        finish(.dropped)
    }

    private func finish(_ closure: Closure) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        if let task { task.cancel(with: .goingAway, reason: nil) }
        session?.invalidateAndCancel()
        task = nil; session = nil; bearer = nil
        handler(.closed(closure))
    }

    fileprivate func closed(_ task: URLSessionTask, code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let task = task as? URLSessionWebSocketTask, self.task === task else { return }
        finishFromTask(task, code: code.rawValue, reason: reason)
    }
    fileprivate func completed(_ task: URLSessionTask) {
        guard let task = task as? URLSessionWebSocketTask, self.task === task else { return }
        finishFromTask(task)
    }

    /// `{"cursor": N}` or `{"cursor": null}`; nil for anything else (the text "pong", a future message type), which is
    /// ignored. An invalid cursor is reported as nil, which only makes the follower pull.
    static func cursor(in text: String) -> Int64?? {
        guard text.utf8.count <= 256, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let value = object["cursor"] else { return nil }
        if value is NSNull { return .some(nil) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .some(nil) }
        let cursor = number.int64Value
        return .some(cursor >= 0 && NSNumber(value: cursor) == number ? cursor : nil)
    }

    /// Keeps the session from retaining the stream; refuses redirects like ParaAirCloudHTTP.
    private final class DelegateProxy: NSObject, URLSessionWebSocketDelegate {
        weak var owner: ParaAirCloudChangeStream?
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                        reason: Data?) {
            owner?.closed(webSocketTask, code: closeCode, reason: reason)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.completed(task)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
