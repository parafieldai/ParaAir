import Foundation

public struct URLSessionOAuthTransport: OAuthTransport {
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int
    private let configurationFactory: @Sendable () -> URLSessionConfiguration
    public init(timeout: TimeInterval = 30, maximumResponseBytes: Int = 1_048_576) {
        self.timeout = timeout.isFinite ? min(max(timeout, 1), 120) : 30
        self.maximumResponseBytes = min(max(maximumResponseBytes, 1024), 4_194_304)
        configurationFactory = { .ephemeral }
    }
    init(timeout: TimeInterval = 30, maximumResponseBytes: Int = 1_048_576,
         configurationFactory: @escaping @Sendable () -> URLSessionConfiguration) {
        self.timeout = timeout.isFinite ? min(max(timeout, 1), 120) : 30
        self.maximumResponseBytes = min(max(maximumResponseBytes, 1024), 4_194_304)
        self.configurationFactory = configurationFactory
    }

    public func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            throw OAuthError.invalidConfiguration
        }
        let operation = OAuthRequestOperation(timeout: timeout, limit: maximumResponseBytes, configuration: configurationFactory())
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        }, onCancel: { operation.cancel() })
    }
}

private final class OAuthRequestOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let limit: Int
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<OAuthHTTPResponse, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancelled = false
    private var finished = false

    init(timeout: TimeInterval, limit: Int, configuration: URLSessionConfiguration) {
        self.timeout = timeout; self.limit = limit; self.configuration = configuration
    }
    func start(_ request: URLRequest, continuation: CheckedContinuation<OAuthHTTPResponse, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var bounded = request; bounded.timeoutInterval = timeout
        let task = session.dataTask(with: bounded)
        self.session = session; self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true; let started = continuation != nil; lock.unlock()
        if started { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<OAuthHTTPResponse, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session, task = self.task
        self.session = nil; self.task = nil; body = Data()
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // In particular, never disclose an authorization code or refresh token to a redirect destination.
        completionHandler(nil)
        // Complete with the original status immediately. Redirect bodies are not
        // useful to callers, and a custom URLProtocol need not deliver another
        // response callback after redirect refusal.
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { output, item in
            if let key = item.key as? String { output[key] = String(describing: item.value) }
        }
        finish(.success(OAuthHTTPResponse(statusCode: response.statusCode, data: Data(), headers: headers)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(OAuthError.requestFailed)); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(OAuthError.responseTooLarge)); return
        }
        lock.lock(); self.response = response; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let oversized = data.count > limit - body.count
        if !oversized { body.append(data) }
        lock.unlock()
        if oversized { finish(.failure(OAuthError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = self.response, data = body, cancelled = self.cancelled
        lock.unlock()
        if cancelled { finish(.failure(CancellationError())); return }
        guard error == nil, let response else { finish(.failure(OAuthError.requestFailed)); return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { output, item in
            if let key = item.key as? String { output[key] = String(describing: item.value) }
        }
        finish(.success(OAuthHTTPResponse(statusCode: response.statusCode, data: data, headers: headers)))
    }
}
