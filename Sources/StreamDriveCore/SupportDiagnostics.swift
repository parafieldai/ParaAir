import Foundation

/// The text the app's Copy Diagnostics puts on the clipboard for a support request: the app's version, what
/// `paraair setup-status --json` and the selected drive's `paraair status --json` report, and recent log lines. What
/// must never leave the Mac is removed first: sign-in tokens and keys, file names and paths inside drives, error text
/// (it can name files), the name of another Mac, and every email address except this Mac's own ParaAir Cloud accounts.
/// The home folder becomes `~`. Pure, so tests check exactly what is copied.
public enum SupportDiagnostics {
    /// One section of the bundle: JSON a command printed, log lines, or why it is missing.
    public enum Part: Sendable, Equatable {
        case json(Data)
        case lines([String])
        case unavailable(String)
    }

    public struct Input: Sendable {
        /// "0.1.0 alpha 11 (72)".
        public var appVersion: String
        /// The `X-ParaAir-Client` value, "mac/0.1.72".
        public var clientHeader: String
        /// "Version 27.3 (Build 27D60)".
        public var system: String
        public var createdAt: Date
        public var setupStatus: Part
        /// The selected drive's profile name and its `status --json`; nil when the selected folder has no drive.
        public var drive: (name: String, status: Part)?
        public var logs: Part
        /// Addresses that may stay: the signed-in accounts. Those `setup-status` lists are added.
        public var accountEmails: [String]
        public var home: String

        public init(appVersion: String, clientHeader: String, system: String, createdAt: Date, setupStatus: Part,
                    drive: (name: String, status: Part)?, logs: Part, accountEmails: [String], home: String) {
            self.appVersion = appVersion; self.clientHeader = clientHeader; self.system = system; self.createdAt = createdAt
            self.setupStatus = setupStatus; self.drive = drive; self.logs = logs; self.accountEmails = accountEmails; self.home = home
        }
    }

    public static let removedNote = "Removed before copying: sign-in tokens and keys, file names and paths inside drives, error text, "
        + "other Macs' names, and email addresses other than this Mac's ParaAir Cloud accounts."

    public static func text(_ input: Input) -> String {
        var emails = Set(input.accountEmails.map { $0.lowercased() })
        if case .json(let data) = input.setupStatus { emails.formUnion(accountEmails(inSetupStatus: data)) }
        let scrubber = Scrubber(allowedEmails: emails, home: input.home)
        let created = ISO8601DateFormatter().string(from: input.createdAt)
        var lines = ["ParaAir diagnostics", "Created: \(created)", "ParaAir: \(scrubber.scrub(input.appVersion))",
                     "Sent to ParaAir Cloud as: \(scrubber.scrub(input.clientHeader))", "macOS: \(scrubber.scrub(input.system))",
                     removedNote, "", "## paraair setup-status --json", section(input.setupStatus, scrubber)]
        if let drive = input.drive {
            lines += ["", "## paraair status --json (\(scrubber.scrub(drive.name)))", section(drive.status, scrubber)]
        } else {
            lines += ["", "## paraair status --json", "The selected state folder has no drive."]
        }
        lines += ["", "## Recent log lines (dev.streamdrive, this app, last 30 minutes)", section(input.logs, scrubber)]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ part: Part, _ scrubber: Scrubber) -> String {
        switch part {
        case .json(let data): return redactJSON(data, scrubber: scrubber) ?? "The command printed something other than JSON, so it was left out."
        case .lines(let lines): return lines.isEmpty ? "None." : lines.map(scrubber.scrub).joined(separator: "\n")
        case .unavailable(let reason): return scrubber.scrub(reason)
        }
    }

    /// `accounts[].email` of `setup-status --json`: this Mac's own accounts.
    static func accountEmails(inSetupStatus data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return [] }
        return Set(accounts.compactMap { ($0["email"] as? String)?.lowercased() })
    }

    // MARK: Redaction

    /// Keys whose values can name files or people, whatever they hold.
    static let removedKeys: Set<String> = ["path", "paths", "localPath", "copyPath", "exportedTo", "lastError", "ownerName", "message"]
    /// Keys that look like secrets.
    static let secretKey = try! NSRegularExpression(
        pattern: "(?i)(token|secret|password|passphrase|apikey|api_key|accesskey|access_key|privatekey|private_key|credential|authorization|cookie|signature)")

    /// The JSON re-printed with sorted keys, or nil when `data` isn't JSON.
    public static func redactJSON(_ data: Data, scrubber: Scrubber) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let cleaned = redact(object, key: nil, scrubber: scrubber)
        guard let output = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    private static func redact(_ value: Any, key: String?, scrubber: Scrubber) -> Any {
        if value is NSNull { return value }
        if let key {
            if key == "pins", let pins = value as? [Any] { return pins.isEmpty ? pins : "[\(pins.count) pinned \(pins.count == 1 ? "path" : "paths") removed]" }
            if removedKeys.contains(key) { return "[removed]" }
            let range = NSRange(key.startIndex..., in: key)
            if secretKey.firstMatch(in: key, range: range) != nil { return "[redacted]" }
        }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, redact($0.value, key: $0.key, scrubber: scrubber)) })
        }
        if let array = value as? [Any] { return array.map { redact($0, key: nil, scrubber: scrubber) } }
        if let string = value as? String { return scrubber.scrub(string) }
        return value
    }

    /// Text-level redaction for strings and log lines.
    public struct Scrubber: Sendable {
        public var allowedEmails: Set<String>
        public var home: String

        public init(allowedEmails: Set<String>, home: String) {
            self.allowedEmails = Set(allowedEmails.map { $0.lowercased() }); self.home = home
        }

        private static let rules: [(NSRegularExpression, String)] = [
            ("Bearer\\s+[^\\s\"',]+", "Bearer [redacted]"),
            // ParaAir Cloud access, refresh, service-credential and read tokens.
            ("\\b(pca|pcr|pcs)_[A-Za-z0-9._~+/=-]+", "[token]"),
            ("\\bprt1\\.[^\\s\"',]+", "[token]"),
            // JSON Web Tokens and processor keys.
            ("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "[token]"),
            ("\\b(sk|rk|pk|whsec)_(live|test)_[A-Za-z0-9]+", "[key]"),
            ("(?i)\\b(access_token|refresh_token|id_token|client_secret|token|secret|password|key|signature|x-amz-signature|x-amz-credential)=[^&\\s\"']+",
             "$1=[redacted]"),
            // A sign-in code; the logs' numeric error codes ("code=-1") stay.
            ("\\bcode=(?![-0-9]+(?:[&\\s\"']|$))[^&\\s\"']+", "code=[redacted]"),
            // A path inside a mounted drive names files; the mount point stays.
            ("(/Volumes/[^/\\s\"']+)/[^\\s\"']+", "$1/[path]"),
        ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
        private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

        public func scrub(_ text: String) -> String {
            var result = text
            for (pattern, template) in Self.rules {
                result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
            }
            let matches = Self.email.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                if !allowedEmails.contains(result[range].lowercased()) { result.replaceSubrange(range, with: "[email]") }
            }
            if home.count > 1 {
                let prefix = home.hasSuffix("/") ? String(home.dropLast()) : home
                result = result.replacingOccurrences(of: prefix + "/", with: "~/")
                if result == prefix { result = "~" }
                result = result.replacingOccurrences(of: prefix + "\"", with: "~\"").replacingOccurrences(of: prefix + " ", with: "~ ")
            }
            return result
        }
    }
}
