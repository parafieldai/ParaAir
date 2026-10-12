import Foundation
import Darwin
import Network
import os

/// One hardened URLSession per ParaAir Cloud session. Requests never follow
/// redirects, never use cookies, caches or stored credentials, and responses are
/// bounded. Blocking callers use `sendSync`; never call it from the main queue
/// of the app or from the delegate queue.
public final class ParaAirCloudHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// Begins with "/"; only unreserved URL characters. Queries go in `query`.
        public var path: String
        public var query: [URLQueryItem] = []
        public var headers: [String: String] = [:]
        public var body: Data? = nil
        public var maxResponseBytes = 4 << 20
        /// Route template for logs, for example "GET /v1/drives/{d}/stat". Paths are never logged.
        public var route: String? = nil
        /// Shorter idle timeout than the session's, for calls on latency-sensitive queues.
        public var timeout: TimeInterval? = nil
        public init(method: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                    body: Data? = nil, maxResponseBytes: Int = 4 << 20, route: String? = nil) {
            self.method = method; self.path = path; self.query = query; self.headers = headers
            self.body = body; self.maxResponseBytes = maxResponseBytes; self.route = route
        }
    }
    public struct Response: Sendable {
        public let status: Int
        /// Header names are lowercased.
        public let headers: [String: String]
        public let body: Data
        public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
        public var requestID: String? { headers["x-request-id"].flatMap(ParaAirCloudErrorMap.validRequestID) }
    }

    public let baseURL: URL
    let policy: ParaAirCloudTransportPolicy
    /// Fail-fast window after an offline-class transport failure; tests shorten it.
    var offlineBackoffInterval: TimeInterval = 5
    private let queue = DispatchQueue(label: "dev.streamdrive.cloud.http")
    private let lock = NSLock()
    private var session: URLSession!
    private var pending: [Int: Pending] = [:]
    private var closed = false
    private var offlineUntil: Date?
    private var probeInFlight = false
    private var monitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?
    private static let logger = Logger(subsystem: "dev.streamdrive.cloud", category: "http")
    private static let signposter = OSSignposter(subsystem: "dev.streamdrive.cloud", category: "http")

    private final class Pending {
        let limit: Int
        let route: String
        let probe: Bool
        let started = DispatchTime.now()
        var response: HTTPURLResponse?
        var body = Data()
        var completion: ((Result<Response, DriveError>) -> Void)?
        /// Keeps the client alive until every started request has completed.
        var owner: ParaAirCloudHTTP?
        let signpost: OSSignpostIntervalState
        init(limit: Int, route: String, probe: Bool, signpost: OSSignpostIntervalState,
             completion: @escaping (Result<Response, DriveError>) -> Void) {
            self.limit = limit; self.route = route; self.probe = probe; self.signpost = signpost; self.completion = completion
        }
    }

    /// Keeps the session from retaining this object; the session retains its delegate until invalidated.
    private final class DelegateProxy: NSObject, URLSessionDataDelegate {
        weak var owner: ParaAirCloudHTTP?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.urlSession(session, dataTask: dataTask, didReceive: data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let owner else { completionHandler(nil); return }
            owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.urlSession(session, task: task, didCompleteWithError: error)
        }
    }

    public init(baseURL: URL, policy: ParaAirCloudTransportPolicy = .current, configuration: URLSessionConfiguration = .ephemeral) throws {
        let issuer = try ParaAirCloudIssuer.validate(baseURL.absoluteString)
        try policy.validate(issuer)
        self.baseURL = issuer; self.policy = policy
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = min(config.timeoutIntervalForRequest, 30)
        config.timeoutIntervalForResource = min(config.timeoutIntervalForResource, 600)
        config.httpMaximumConnectionsPerHost = 8
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue; delegateQueue.maxConcurrentOperationCount = 1
        let proxy = DelegateProxy(); proxy.owner = self
        session = URLSession(configuration: config, delegate: proxy, delegateQueue: delegateQueue)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(satisfied: path.status == .satisfied) }
        monitor.start(queue: queue)
        self.monitor = monitor
    }
    deinit { monitor?.cancel(); session?.invalidateAndCancel() }

    public func sendSync(_ request: Request, bearer: String?) throws -> Response {
        if Self.forbidsMainThread { dispatchPrecondition(condition: .notOnQueue(.main)) }
        dispatchPrecondition(condition: .notOnQueue(queue))
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = start(request, bearer: bearer) { box.result = $0; semaphore.signal() }
        if semaphore.wait(timeout: .now() + 605) == .timedOut {
            task?.cancel()
            fail(task, DriveError(ETIMEDOUT, "ParaAir Cloud did not respond in time", disposition: .ambiguous))
            semaphore.wait()
        }
        return try box.result!.get()
    }

    public func send(_ request: Request, bearer: String?) async throws -> Response {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                holder.set(start(request, bearer: bearer) { continuation.resume(with: $0.mapError { $0 as Error }) })
            }
        }, onCancel: { holder.cancel() })
    }

    /// Cancels in-flight requests (they fail with EBADF) and rejects later calls with EBADF.
    public func invalidate() {
        lock.lock(); closed = true; lock.unlock()
        monitor?.cancel()
        session.invalidateAndCancel()
    }

    /// Strict query encoding: only `A–Z a–z 0–9 - . _ ~ /` stay literal; "+" is always %2B.
    static func encodeQuery(_ items: [URLQueryItem]) -> String {
        items.map { encodeComponent($0.name) + "=" + encodeComponent($0.value ?? "") }.joined(separator: "&")
    }
    static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed)!
    }
    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    private static let pathAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    /// The app's main thread must never wait on the network; the CLI and tests may.
    static var forbidsMainThread: Bool { Bundle.main.bundleIdentifier == "dev.streamdrive.app" }
    static let offlineClass: Set<Int32> = [ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNREFUSED, ECONNRESET, ETIMEDOUT, ENOTCONN]

    /// True while requests fail fast because the service looked unreachable.
    var inOfflineBackoff: Bool {
        lock.lock(); defer { lock.unlock() }
        return offlineUntil.map { Date() < $0 || probeInFlight } ?? false
    }

    private final class ResultBox: @unchecked Sendable { var result: Result<Response, DriveError>? }
    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock(); private var task: URLSessionTask?; private var cancelled = false
        func set(_ task: URLSessionTask?) {
            lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
            if cancel { task?.cancel() }
        }
        func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
    }

    @discardableResult
    private func start(_ request: Request, bearer: String?, completion: @escaping (Result<Response, DriveError>) -> Void) -> URLSessionTask? {
        let route = request.route ?? request.method
        guard request.path.hasPrefix("/"), !request.path.hasPrefix("//"),
              request.path.unicodeScalars.allSatisfy(Self.pathAllowed.contains), !request.path.contains("/../"),
              request.method.range(of: "^[A-Z]{3,7}$", options: .regularExpression) != nil,
              request.maxResponseBytes > 0, bearer.map(Self.validBearer) ?? true else {
            completion(.failure(DriveError(EINVAL, "Invalid ParaAir Cloud request", disposition: .attemptNotDispatched))); return nil
        }
        let query = request.query.isEmpty ? "" : "?" + Self.encodeQuery(request.query)
        guard let url = URL(string: baseURL.absoluteString + request.path + query) else {
            completion(.failure(DriveError(EINVAL, "Invalid ParaAir Cloud request", disposition: .attemptNotDispatched))); return nil
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = min(request.timeout ?? .infinity, session.configuration.timeoutIntervalForRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("mac/" + ParaAirCloudConfiguration.clientVersion, forHTTPHeaderField: "X-ParaAir-Client")
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if let bearer { urlRequest.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        lock.lock()
        if closed {
            lock.unlock()
            completion(.failure(DriveError(EBADF, "The ParaAir Cloud connection is closed", disposition: .attemptNotDispatched))); return nil
        }
        var probe = false
        if let until = offlineUntil {
            if Date() < until || probeInFlight {
                lock.unlock()
                completion(.failure(DriveError(ENETDOWN, "ParaAir Cloud is unreachable; retrying shortly", disposition: .attemptNotDispatched)))
                return nil
            }
            probeInFlight = true; probe = true
        }
        let task = session.dataTask(with: urlRequest)
        let state = Self.signposter.beginInterval("request", id: Self.signposter.makeSignpostID())
        let entry = Pending(limit: request.maxResponseBytes, route: route, probe: probe, signpost: state, completion: completion)
        entry.owner = self
        pending[task.taskIdentifier] = entry
        lock.unlock()
        task.resume()
        return task
    }

    private static func validBearer(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private func take(_ task: URLSessionTask?) -> Pending? {
        guard let task else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let state = pending.removeValue(forKey: task.taskIdentifier), state.completion != nil else { return nil }
        return state
    }

    private func finish(_ state: Pending, _ result: Result<Response, DriveError>) {
        lock.lock()
        switch result {
        case .success:
            offlineUntil = nil; probeInFlight = false
        case .failure(let error):
            // Only connection-level failures (the request never reached the service) mean "offline".
            if error.disposition == .attemptNotDispatched, Self.offlineClass.contains(error.code) {
                offlineUntil = Date().addingTimeInterval(offlineBackoffInterval)
            }
            if state.probe { probeInFlight = false }
        }
        let completion = state.completion; state.completion = nil; state.owner = nil
        lock.unlock()
        Self.signposter.endInterval("request", state.signpost)
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - state.started.uptimeNanoseconds) / 1_000_000
        switch result {
        case .success(let response):
            Self.logger.debug("\(state.route, privacy: .public) \(response.status, privacy: .public) \(milliseconds, privacy: .public)ms \(response.requestID ?? "-", privacy: .public)")
        case .failure(let error):
            Self.logger.notice("\(state.route, privacy: .public) failed errno \(error.code, privacy: .public) after \(milliseconds, privacy: .public)ms")
        }
        completion?(result)
    }

    private func fail(_ task: URLSessionTask?, _ error: DriveError) {
        guard let state = take(task) else { return }
        finish(state, .failure(error))
    }

    private func pathChanged(satisfied: Bool) {
        lock.lock()
        if satisfied, lastPathSatisfied == false { offlineUntil = nil; probeInFlight = false }
        lastPathSatisfied = satisfied
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = pending[dataTask.taskIdentifier]
        lock.unlock()
        guard let state else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); fail(dataTask, DriveError(EIO, "ParaAir Cloud returned an invalid response", disposition: .ambiguous)); return
        }
        guard http.expectedContentLength <= Int64(state.limit) else {
            completionHandler(.cancel); fail(dataTask, DriveError(EIO, "ParaAir Cloud response exceeded the permitted size", disposition: .ambiguous)); return
        }
        lock.lock(); state.response = http; lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        let oversized = data.count > state.limit - state.body.count
        if !oversized { state.body.append(data) }
        lock.unlock()
        if oversized {
            dataTask.cancel()
            fail(dataTask, DriveError(EIO, "ParaAir Cloud response exceeded the permitted size", disposition: .ambiguous))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a bearer token (or a request body) to another address.
        completionHandler(nil)
        task.cancel()
        fail(task, DriveError(EIO, "ParaAir Cloud returned an unexpected redirect", disposition: .ambiguous))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = take(task) else { return }
        if let error { finish(state, .failure(ParaAirCloudErrorMap.transport(error))); return }
        lock.lock(); let response = state.response, body = state.body; lock.unlock()
        guard let response else { finish(state, .failure(DriveError(EIO, "ParaAir Cloud returned an invalid response", disposition: .ambiguous))); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String { headers[key.lowercased()] = String(describing: value) } }
        finish(state, .success(Response(status: response.statusCode, headers: headers, body: body)))
    }
}

/// UI code runs blocking ParaAir Cloud calls here so the cooperative pool never blocks.
public enum ParaAirCloudBlocking {
    private static let queue = DispatchQueue(label: "dev.streamdrive.cloud.blocking", qos: .userInitiated, attributes: .concurrent)
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
