import Foundation

/// The text the app's Copy Diagnostics puts on the clipboard for a support request: the app's version, what
/// `paraair setup-status --json` and the selected drive's `paraair status --json` report, and recent log lines. What
/// must never leave the Mac is removed first: sign-in tokens and keys, file names and paths inside drives, error text
/// (it can name files), the name of another Mac, and every email address except this Mac's own ParaAir Cloud accounts.
/// Of the commands' JSON only the documented fields are kept, so a field added later can't carry any of that out. The
/// home folder becomes `~`. Pure, so tests check exactly what is copied.
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
        /// Where this Mac's drives are mounted, from the app's own profiles. Those `setup-status` and `status` report are
        /// added. Whatever follows one of them and "/" names files.
        public var mountPoints: [String]

        public init(appVersion: String, clientHeader: String, system: String, createdAt: Date, setupStatus: Part,
                    drive: (name: String, status: Part)?, logs: Part, accountEmails: [String], home: String, mountPoints: [String] = []) {
            self.appVersion = appVersion; self.clientHeader = clientHeader; self.system = system; self.createdAt = createdAt
            self.setupStatus = setupStatus; self.drive = drive; self.logs = logs; self.accountEmails = accountEmails; self.home = home
            self.mountPoints = mountPoints
        }
    }

    public static let removedNote = "Removed before copying: sign-in tokens and keys, file names and paths inside drives, error text, "
        + "other Macs' names, email addresses other than this Mac's ParaAir Cloud accounts, and any field this app doesn't list."

    public static func text(_ input: Input) -> String {
        var emails = Set(input.accountEmails.map { $0.lowercased() })
        var mounts = input.mountPoints
        // Every drive's mount point is known only from setup-status, which lists the drives of every state folder.
        var mountsKnown = false
        if case .json(let data) = input.setupStatus {
            emails.formUnion(accountEmails(inSetupStatus: data))
            if let points = profileMountPoints(inSetupStatus: data) { mounts += points; mountsKnown = true }
        }
        if case .json(let data)? = input.drive?.status { mounts += mountPoints(in: data) }
        let scrubber = Scrubber(allowedEmails: emails, home: input.home, mountPoints: mounts)
        let created = ISO8601DateFormatter().string(from: input.createdAt)
        var lines = ["ParaAir diagnostics", "Created: \(created)", "ParaAir: \(scrubber.scrub(input.appVersion))",
                     "Sent to ParaAir Cloud as: \(scrubber.scrub(input.clientHeader))", "macOS: \(scrubber.scrub(input.system))",
                     removedNote, "", "## paraair setup-status --json", section(input.setupStatus, setupStatusFields, scrubber)]
        if let drive = input.drive {
            lines += ["", "## paraair status --json (\(scrubber.scrub(drive.name)))", section(drive.status, driveStatusFields, scrubber)]
        } else {
            lines += ["", "## paraair status --json", "The selected state folder has no drive."]
        }
        // A log line is free text: a path inside a drive mounted outside /Volumes can be removed only when its mount point
        // is known, so without setup-status the lines are left out.
        let logs: String
        if mountsKnown { logs = section(input.logs, .value, scrubber) }
        else if case .unavailable = input.logs { logs = section(input.logs, .value, scrubber) }
        else { logs = logsWithheld }
        lines += ["", "## Recent log lines (dev.streamdrive, this app, last 30 minutes)", logs]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ part: Part, _ fields: Field, _ scrubber: Scrubber) -> String {
        switch part {
        case .json(let data):
            return redactJSON(data, fields: fields, scrubber: scrubber) ?? "The command printed something other than JSON, so it was left out."
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

    /// `mountPoint` of `status --json`.
    static func mountPoints(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return [object["mountPoint"]].compactMap { $0 as? String }
    }

    /// `profiles[].mountPoint` of `setup-status --json`: every drive's mount point. Nil when it lists no profiles (it
    /// failed), so the mount points aren't known.
    static func profileMountPoints(inSetupStatus data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = object["profiles"] as? [Any] else { return nil }
        return profiles.compactMap { ($0 as? [String: Any])?["mountPoint"] as? String }
    }

    public static let logsWithheld = "Left out: setup-status didn’t report where the drives are mounted, so file names in these lines "
        + "couldn’t be removed. To read them yourself: log show --last 30m --info --predicate 'subsystem BEGINSWITH \"dev.streamdrive\"'"

    // MARK: Redaction

    /// What a field of the CLI's JSON becomes. Fields a schema doesn't name are left out.
    indirect enum Field: Sendable {
        /// A number, true or false as is; a string scrubbed. An object or list in its place is removed.
        case value
        /// Only "[removed]": it can name files, people or other Macs.
        case removed
        /// Pinned paths: only how many.
        case pins
        case list(Field)
        case object([String: Field])
    }

    /// A failing command's `{"error","exitCode","code"}` (contract/paraair-cli-v1 "Errors"): the code and exit status
    /// stay; the message can name files.
    static let errorFields: [String: Field] = ["code": .value, "exitCode": .value, "error": .removed]

    /// `setup-status --json` as contract/paraair-cli-v1 documents it.
    static let setupStatusFields = Field.object([
        "contractVersion": .value, "capabilities": .list(.value),
        "app": .object(["installed": .value, "path": .value, "running": .value, "version": .value, "build": .value]),
        "extension": .object(["state": .value, "otherCopies": .list(.value)]),
        "accounts": .list(.object(["id": .value, "email": .value, "issuer": .value, "state": .value, "stateDirectory": .value,
                                   "workspaceIds": .list(.value)])),
        "profiles": .list(.object(["profile": .value, "stateDirectory": .value, "backend": .value, "cloudAccountId": .value,
                                   "cloudDriveId": .value, "workspaceId": .value, "mountPoint": .value, "mounted": .value,
                                   "healthy": .value, "conflictCopies": .value, "knownToApp": .value])),
    ].merging(errorFields) { kept, _ in kept })

    /// `status NAME --json`: the CLI's `ProfileStatus` and Core's `DriveStatus`.
    static let driveStatusFields = Field.object([
        "profile": .value, "backend": .value, "mountPoint": .value, "mounted": .value, "connectionState": .value,
        "drive": .object(Dictionary(uniqueKeysWithValues: [
            "cacheBytes", "pinnedBytes", "pendingWriteBytes", "stateBytes", "totalAllocatedBytes", "cacheLimitBytes", "maxJournalBytes",
            "minFreeBytes", "availableBytes", "pendingUploads", "conflictedUploads", "offline", "objectReadBytes", "objectGetRequests",
        ].map { ($0, Field.value) }).merging([
            "pins": .pins,
            "indexBackup": .object(["lastBackupNanoseconds": .value, "pendingSinceNanoseconds": .value, "lastErrno": .value, "lastError": .removed]),
            "ownedElsewhere": .object(["seenNanoseconds": .value, "ownerName": .removed]),
            "failingUploads": .object(["count": .value, "errno": .value, "oldestChangeNanoseconds": .value]),
        ]) { kept, _ in kept }),
    ].merging(errorFields) { kept, _ in kept })

    /// The JSON's documented `fields`, re-printed with sorted keys, or nil when `data` isn't JSON.
    static func redactJSON(_ data: Data, fields: Field, scrubber: Scrubber) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let cleaned = redact(object, as: fields, scrubber: scrubber)
        guard let output = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    private static func redact(_ value: Any, as field: Field, scrubber: Scrubber) -> Any {
        if value is NSNull { return value }
        switch field {
        case .removed:
            return "[removed]"
        case .value:
            if let string = value as? String { return scrubber.scrub(string) }
            return value is NSNumber ? value : "[removed]"
        case .pins:
            guard let pins = value as? [Any] else { return "[removed]" }
            return pins.isEmpty ? pins : "[\(pins.count) pinned \(pins.count == 1 ? "path" : "paths") removed]"
        case .list(let element):
            guard let array = value as? [Any] else { return "[removed]" }
            return array.map { redact($0, as: element, scrubber: scrubber) }
        case .object(let fields):
            guard let dictionary = value as? [String: Any] else { return "[removed]" }
            var result: [String: Any] = [:]
            for (key, value) in dictionary { if let field = fields[key] { result[key] = redact(value, as: field, scrubber: scrubber) } }
            return result
        }
    }

    /// Text-level redaction for strings and log lines.
    public struct Scrubber: Sendable {
        public var allowedEmails: Set<String>
        public var home: String
        /// Drives' mount points, longest first.
        public var mountPoints: [String]

        public init(allowedEmails: Set<String>, home: String, mountPoints: [String] = []) {
            self.allowedEmails = Set(allowedEmails.map { $0.lowercased() }); self.home = home
            let trimmed = mountPoints.map { point -> String in
                var point = point
                while point.hasSuffix("/") { point.removeLast() }
                return point
            }
            self.mountPoints = Set(trimmed.filter { $0.hasPrefix("/") && $0.count > 1 }).sorted { ($0.count, $0) > ($1.count, $1) }
        }

        private static let rules: [(NSRegularExpression, String)] = [
            ("Bearer\\s+[^\\s\"',]+", "Bearer [redacted]"),
            // ParaAir Cloud access, refresh, service-credential and read tokens.
            ("(?<![A-Za-z0-9])(pca|pcr|pcs)_[A-Za-z0-9._~+/=-]+", "[token]"),
            ("(?<![A-Za-z0-9])prt1\\.[^\\s\"',]+", "[token]"),
            // JSON Web Tokens, processor keys and AWS access key IDs.
            ("(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "[token]"),
            ("(?<![A-Za-z0-9])(sk|rk|pk|whsec)_(live|test)_[A-Za-z0-9]+", "[key]"),
            ("(?<![A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])", "[key]"),
            // name=value where the name ends in a secret's word: token=, session_token=, aws_secret_access_key=, api_key=,
            // apikey=, X-Amz-Signature=. The whole name is matched from its start, so its end can follow "_" or a letter.
            ("(?i)(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]*(?:token|secret|password|passwd|passphrase|key|signature|credential))=[^&\\s\"']+",
             "$1=[redacted]"),
            // name: value for the same secrets' longer names, as AWS prints them ("SecretAccessKey": "…", SessionToken: …).
            ("(?i)(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]*(?:token|secret|password|passphrase|access_?key|api_?key|private_?key|credential))"
             + "([\"']?\\s*:\\s*[\"']?)[^\\s\"',}]+", "$1$2[redacted]"),
            // A sign-in code (eight digits, or letters and digits); the logs' short error codes ("code=-1", "Code=516") stay.
            ("(?i)(?<![A-Za-z])(code)=(?!(?:-[0-9]+|[0-9]{1,5})(?![0-9A-Za-z]))[^&\\s\"']+", "$1=[redacted]"),
        ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
        /// A path inside a drive this Mac doesn't list: the volume's name (spaces and all) stays, the rest of the line or
        /// quoted text goes.
        private static let volumePath = try! NSRegularExpression(pattern: "(?i)(/Volumes/[^/\\r\\n\"“”]+)/[^\\r\\n\"”]+")
        private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

        public func scrub(_ text: String) -> String {
            // Decoded first, so "%22pca_…" or "lena%40studio.example" in a URL is found too.
            var result = Self.percentDecoded(text)
            func replace(_ pattern: NSRegularExpression, _ template: String) {
                result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
            }
            for (pattern, template) in Self.rules { replace(pattern, template) }
            // Everything after a drive's mount point and "/", up to the end of the line or a closing quote, names files.
            for point in mountPoints {
                guard let pattern = try? NSRegularExpression(pattern: "(" + NSRegularExpression.escapedPattern(for: point) + ")/[^\\r\\n\"”]+",
                                                             options: [.caseInsensitive]) else { continue }
                replace(pattern, "$1/[path]")
            }
            replace(Self.volumePath, "$1/[path]")
            let matches = Self.email.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                if !allowedEmails.contains(result[range].lowercased()) { result.replaceSubrange(range, with: "[email]") }
            }
            var prefix = home
            while prefix.hasSuffix("/") { prefix.removeLast() }
            // The home folder itself, wherever it ends: before "/", a quote, a space, punctuation or the end of the line,
            // but not "/Users/thomasina" or "/Users/thomas.old".
            if prefix.count > 1, let pattern = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: prefix) + "(?![A-Za-z0-9_-]|\\.[A-Za-z0-9_-])", options: [.caseInsensitive]) {
                replace(pattern, "~")
            }
            return result
        }

        /// `%XX` sequences decoded, twice over for text encoded twice. Bytes that aren't UTF-8 become U+FFFD.
        static func percentDecoded(_ text: String) -> String {
            func hex(_ byte: UInt8) -> UInt8? {
                switch byte {
                case 0x30...0x39: return byte - 0x30
                case 0x41...0x46: return byte - 0x37
                case 0x61...0x66: return byte - 0x57
                default: return nil
                }
            }
            var current = text
            for _ in 0..<2 where current.contains("%") {
                let input = Array(current.utf8)
                var output: [UInt8] = []
                output.reserveCapacity(input.count)
                var index = 0, changed = false
                while index < input.count {
                    if input[index] == 0x25, index + 2 < input.count, let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                        output.append(high << 4 | low); index += 3; changed = true
                    } else {
                        output.append(input[index]); index += 1
                    }
                }
                guard changed else { break }
                current = String(decoding: output, as: UTF8.self)
            }
            return current
        }
    }
}
