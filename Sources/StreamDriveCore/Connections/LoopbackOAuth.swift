import Foundation
import Network

/// Starts the IPv4 loopback listener before opening the browser. Port zero selects an ephemeral port;
/// a registered fixed port is respected exactly. Cancelling the caller closes the listener.
public func runLoopbackOAuth(configuration: OAuthConfiguration, timeout: TimeInterval = 300,
                             transport: any OAuthTransport = URLSessionOAuthTransport(),
                             openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void) async throws -> OAuthTokens {
    guard timeout.isFinite, timeout > 0, timeout <= 900 else { throw OAuthError.invalidConfiguration }
    let listener = LoopbackOAuthListener(redirectURI: configuration.redirectURI, timeout: timeout)
    return try await withTaskCancellationHandler(operation: {
        do {
            let redirect = try await listener.start()
            let client = OAuthClient(configuration: try configuration.replacingRedirectURI(redirect), transport: transport)
            let authorization = try await client.begin(lifetime: timeout)
            guard let state = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value else { throw OAuthError.invalidConfiguration }
            await listener.expect(state: state)
            try Task.checkCancellation()
            try await openAuthorizationURL(authorization.authorizationURL)
            let callback = try await listener.callback()
            return try await client.complete(callbackURL: callback)
        } catch {
            listener.cancel()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? OAuthError { throw error }
            // Browser and networking errors can contain complete callback or token URLs.
            throw OAuthError.requestFailed
        }
    }, onCancel: { listener.cancel() })
}

final class LoopbackOAuthListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.streamdrive.oauth.loopback")
    private let configuredURI: URL
    private let timeout: TimeInterval
    private var listener: NWListener?
    private var redirectURI: URL?
    private var state: String?
    private var startWaiter: CheckedContinuation<URL, Error>?
    private var callbackWaiter: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timer: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]

    init(redirectURI: URL, timeout: TimeInterval) { self.configuredURI = redirectURI; self.timeout = timeout }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard self.result == nil else { continuation.resume(throwing: CancellationError()); return }
                guard self.listener == nil else { continuation.resume(throwing: OAuthError.alreadyInProgress); return }
                self.startWaiter = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = false
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(self.configuredURI.port ?? 0))!)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port, self.result == nil else { return }
                            var components = URLComponents(url: self.configuredURI, resolvingAgainstBaseURL: false)!
                            components.port = Int(port.rawValue)
                            guard let uri = components.url else { self.finish(.failure(OAuthError.listenerFailed)); return }
                            self.redirectURI = uri
                            let waiter = self.startWaiter; self.startWaiter = nil
                            waiter?.resume(returning: uri)
                        case .failed: self.finish(.failure(OAuthError.listenerFailed))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(OAuthError.timedOut)) }
                    self.timer = timer; self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timer)
                    listener.start(queue: self.queue)
                } catch { self.finish(.failure(OAuthError.listenerFailed)) }
            }
        }
    }

    func expect(state: String) async {
        await withCheckedContinuation { continuation in queue.async { self.state = state; continuation.resume() } }
    }
    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result) }
                else if self.callbackWaiter != nil { continuation.resume(throwing: OAuthError.alreadyInProgress) }
                else { self.callbackWaiter = continuation }
            }
        }
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func finish(_ result: Result<URL, Error>, preserving accepted: UUID? = nil) {
        guard self.result == nil else { return }
        self.result = result; timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let start = startWaiter; startWaiter = nil
        if let start {
            switch result { case .success: start.resume(throwing: OAuthError.listenerFailed); case .failure(let error): start.resume(throwing: error) }
        }
        let callback = callbackWaiter; callbackWaiter = nil; callback?.resume(with: result)
        for (id, connection) in connections where id != accepted { connection.cancel() }
        connections = accepted.flatMap { id in connections[id].map { [id: $0] } } ?? [:]
        state = nil
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        receive(connection, id: id, bytes: Data(), deadline: deadline)
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var bytes = bytes
            if let chunk { bytes.append(chunk) }
            guard bytes.count <= 16_384 else { self.respond(connection, id: id, accepted: false, deadline: deadline); return }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let url = self.parseRequest(bytes, boundary: boundary)
                self.respond(connection, id: id, accepted: url != nil, deadline: deadline)
                if let url { self.finish(.success(url), preserving: id) }
            } else if complete || error != nil {
                deadline.cancel(); self.connections.removeValue(forKey: id)?.cancel()
            } else { self.receive(connection, id: id, bytes: bytes, deadline: deadline) }
        }
    }

    private func parseRequest(_ bytes: Data, boundary: Range<Data.Index>) -> URL? {
        guard result == nil, let redirectURI, let state, boundary.upperBound == bytes.endIndex,
              let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(redirectURI.port!)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0",
              let url = URL(string: "http://127.0.0.1:\(redirectURI.port!)" + first[1]),
              let values = try? oauthCallbackParameters(url, redirectURI: redirectURI, expectedState: state),
              (values["code"] != nil) != (values["error"] != nil),
              values["code"].map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true else { return nil }
        return url
    }

    private func respond(_ connection: NWConnection, id: UUID, accepted: Bool, deadline: DispatchWorkItem) {
        deadline.cancel()
        let body = accepted ? "Sign-in callback received. You may close this window.\n" : "This sign-in callback was not accepted.\n"
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.connections.removeValue(forKey: id)
        })
    }
}
