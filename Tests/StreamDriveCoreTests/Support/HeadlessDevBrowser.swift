import Foundation
@testable import StreamDriveCore

/// Test-only "browser" for the dev-mode sign-in pages (spec 3.7). It drives the
/// email, code and consent steps with a non-redirecting ephemeral session and a
/// manual cookie, reads the code from `/__dev/outbox`, and finally requests the
/// loopback callback so `runLoopbackOAuth` completes. No real browser, no Keychain.
final class HeadlessDevBrowser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case step(String)
        var description: String { switch self { case .step(let text): return "Headless sign-in failed: " + text } }
    }
    private let admin: String
    private let email: String
    private let configuration: URLSessionConfiguration
    private let decision: String
    /// How long to wait for the code to appear in the dev outbox.
    var outboxWait: TimeInterval = 5

    /// `configuration` reaches the service (tests pass a stubbed one); the loopback
    /// callback always uses a plain ephemeral session.
    init(admin: String, email: String, configuration: URLSessionConfiguration = .ephemeral, decision: String = "allow") {
        self.admin = admin; self.email = email; self.decision = decision
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil; copy.httpShouldSetCookies = false; copy.urlCache = nil
        self.configuration = copy
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func open(_ authorizationURL: URL) async throws {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard var origin = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false) else { throw Failure.step("authorize URL") }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        let base = origin.url!.absoluteString

        let (page, first) = try await send(session, URLRequest(url: authorizationURL))
        if first.statusCode == 302 { try await deliver(first); return }
        guard first.statusCode == 200, let ar = Self.inputValue("ar", in: page) else { throw Failure.step("authorize page (HTTP \(first.statusCode))") }
        guard let cookie = Self.cookie(first) else { throw Failure.step("authorize cookie") }

        // Codes already in the outbox belong to earlier sign-ins of the same address.
        let earlier = Set(try await outbox(session, base: base).map(\.key))
        let (_, emailed) = try await send(session, form(base + "/oauth/authorize/email", ["ar": ar, "email": email], cookie: cookie))
        guard emailed.statusCode == 200 else { throw Failure.step("email step (HTTP \(emailed.statusCode))") }

        // The service writes the message in waitUntil, after the page is sent: poll for it.
        var code: String?
        let deadline = Date().addingTimeInterval(outboxWait)
        while code == nil {
            code = try await outbox(session, base: base).first { !earlier.contains($0.key) }?.code
            if code == nil {
                guard Date() < deadline else { throw Failure.step("dev outbox has no new code") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard let code else { throw Failure.step("dev outbox") }

        let (consent, verified) = try await send(session, form(base + "/oauth/authorize/verify", ["ar": ar, "code": code], cookie: cookie))
        guard verified.statusCode == 200, consent.contains("decision") else { throw Failure.step("code step") }

        let (_, decided) = try await send(session, form(base + "/oauth/authorize/consent", ["ar": ar, "decision": decision], cookie: cookie))
        guard decided.statusCode == 302 else { throw Failure.step("consent step (HTTP \(decided.statusCode))") }
        try await deliver(decided)
    }

    /// Messages for this address, newest first (X1). The key tells messages apart.
    private func outbox(_ session: URLSession, base: String) async throws -> [(key: String, code: String)] {
        var request = URLRequest(url: URL(string: base + "/__dev/outbox?email=" + ParaAirCloudHTTP.encodeComponent(email))!)
        request.setValue("Bearer " + admin, forHTTPHeaderField: "Authorization")
        let (mail, delivered) = try await send(session, request)
        guard delivered.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: Data(mail.utf8)) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else {
            throw Failure.step("dev outbox (HTTP \(delivered.statusCode))")
        }
        return messages.compactMap { message in
            guard let code = message["code"] as? String else { return nil }
            return (code + "|" + ((message["createdAt"] as? String) ?? ""), code)
        }
    }

    /// Hands the redirect to the local listener, the way a browser would.
    private func deliver(_ response: HTTPURLResponse) async throws {
        guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              url.scheme == "http", url.host == "127.0.0.1" else { throw Failure.step("redirect target") }
        let loopback = URLSession(configuration: .ephemeral)
        defer { loopback.finishTasksAndInvalidate() }
        let (_, reply) = try await loopback.data(from: url)
        guard (reply as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.step("loopback callback") }
    }

    private func send(_ session: URLSession, _ request: URLRequest) async throws -> (String, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.step("response") }
        return (String(decoding: data, as: UTF8.self), http)
    }

    private func form(_ url: String, _ fields: [String: String], cookie: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = oauthFormBody(fields)
        return request
    }

    /// The value of `<input … name="NAME" … value="…">`, in any attribute order.
    static func inputValue(_ name: String, in html: String) -> String? {
        var search = html[...]
        while let open = search.range(of: "<input", options: .caseInsensitive) {
            guard let close = search[open.upperBound...].firstIndex(of: ">") else { return nil }
            let tag = String(search[open.upperBound..<close])
            if attribute("name", in: tag) == name, let value = attribute("value", in: tag) { return value }
            search = search[close...]
        }
        return nil
    }

    /// Attribute values may be double-quoted, single-quoted or bare; names are case-insensitive.
    static func attribute(_ name: String, in tag: String) -> String? {
        let scalars = Array(tag.unicodeScalars)
        var index = 0
        func skipSpace() { while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) || scalars[index] == "/" { index += 1 } }
        while index < scalars.count {
            skipSpace()
            var key = ""
            while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]), scalars[index] != "=", scalars[index] != "/" {
                key.unicodeScalars.append(scalars[index]); index += 1
            }
            guard !key.isEmpty else { index += 1; continue }
            var value: String?
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                var text = ""
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]; index += 1
                    while index < scalars.count, scalars[index] != quote { text.unicodeScalars.append(scalars[index]); index += 1 }
                    index += 1
                } else {
                    while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { text.unicodeScalars.append(scalars[index]); index += 1 }
                }
                value = text
            }
            if key.lowercased() == name { return value.map(unescape) ?? "" }
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `name=value` of the sign-in cookie (`pa_ar` or `__Host-pa_ar`).
    private static func cookie(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        for part in header.components(separatedBy: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if pair.hasPrefix("pa_ar=") || pair.hasPrefix("__Host-pa_ar=") { return pair }
        }
        return nil
    }
}
