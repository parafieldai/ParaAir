import Foundation
import StreamDriveCore

struct CLIInvocation: Equatable {
    var stateDirectory: String?
    var json: Bool
    var command: CLICommand
}

struct ConnectArguments: Equatable {
    var profile: String
    var values: [String: String]
    var overwrite: Bool
    var conflictCopies = false
    /// Attach the drive in a state folder of its own (`Cloud Drives/<uuid>`), sharing a sign-in from another folder.
    var newStateFolder = false
}

enum CLICommand: Equatable {
    case help(String?)
    case connect(ConnectArguments)
    case connections
    case mount(profile: String, mountPoint: String?, waitSeconds: Int?)
    case unmount(profile: String)
    case list(profile: String, path: String)
    case reveal(profile: String, path: String)
    case status(profile: String?)
    case cache(profile: String, trim: Bool, limitMiB: Int?)
    case pin(profile: String, path: String)
    case unpin(profile: String, path: String)
    case uploads(profile: String, retry: Bool)
    case doctor(profile: String?)
    case cloudAccounts
    case cloudDrives(account: String)
    case cloudSignIn(waitSeconds: Int?)
    case setupStatus
    case extensionSettings(waitSeconds: Int?)
    case trash(profile: String)
    case restore(profile: String, nodeID: Int64, to: String?)
    case storedDrives(connection: String, library: String?)
    case recover(profile: String, connection: String, volume: String, backup: String?, takeOver: Bool, library: String?)
    case conflicts(profile: String)
    case resolve(profile: String, path: String, choice: CLIResolution)
    case settings(profile: String, conflictCopies: Bool?)
    case versions(target: CLITarget, before: Int64?, limit: Int?)
    case catVersion(target: CLITarget, version: String)
    case restoreVersion(target: CLITarget, version: String, expectedVersion: String?)
    case conflictInfo(target: CLITarget)
    case changes(target: CLITarget, follow: Bool, since: Int64?, intervalSeconds: Int?)
    case access(CLIAccessAction, target: CLITarget)
}

/// A path in a drive: a profile and a drive path (`PROFILE /records/x.json`), or a path under a mounted ParaAir drive
/// (`/Volumes/ParaOS/records/x.json`), from which the profile and its state folder are worked out.
enum CLITarget: Equatable {
    case drive(profile: String, path: String)
    case mounted(String)
}

/// What `access` does with a drive's folder rules.
enum CLIAccessAction: Equatable {
    case list
    case set(ParaAirCloudAccessPrincipal, ParaAirCloudAccessLevel)
    case remove(ParaAirCloudAccessPrincipal)
}

/// How `resolve` settles a change that needs a decision.
enum CLIResolution: Equatable {
    case keepMine(name: String)
    case keepTheirs
    case export(to: String, replace: Bool)
}

struct CLIUsageError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

enum CLIParser {
    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var remaining: [String] = []
        var globals: [String: String] = [:]
        var json = false
        var help = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                remaining.append(contentsOf: arguments[index...])
                break
            }
            if argument == "--json" {
                guard !json else { throw usage("Duplicate --json") }
                json = true
            } else if argument == "--help" || argument == "-h" {
                help = true
            } else if let option = matchingOption(argument, names: ["state-dir", "profile"]) {
                guard globals[option.name] == nil else { throw usage("Duplicate --\(option.name)") }
                globals[option.name] = try optionValue(option.inlineValue, name: option.name, arguments: arguments, index: &index)
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        let commandName = remaining.first
        if commandName == nil || help {
            return CLIInvocation(stateDirectory: globals["state-dir"], json: json, command: .help(commandName))
        }
        let name = commandName!
        var commandArguments = Array(remaining.dropFirst())
        if name == "help" {
            guard commandArguments.count <= 1, !commandArguments.contains(where: { $0.hasPrefix("-") }) else {
                throw usage("Usage: paraair help [command]")
            }
            return CLIInvocation(stateDirectory: globals["state-dir"], json: json, command: .help(commandArguments.first))
        }
        let command: CLICommand
        switch name {
        case "connections":
            try noExtraArguments(commandArguments, command: name)
            command = .connections
        case "connect":
            let options = try parseOptions(commandArguments, valueNames: ["metadata-url", "library", "mount-point", "fixture-root", "credential-id", "connection", "cache-mib", "min-free-mib", "block-size", "journal-mib", "cloud-account", "cloud-drive", "cloud-drive-name"], switchNames: ["replace", "conflict-copies", "new-state-folder"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            for flag in ["cache-mib", "min-free-mib", "block-size", "journal-mib"] {
                if let value = options.values[flag] { _ = try integer(value, option: flag, allowsZero: flag == "min-free-mib") }
            }
            if options.values["cloud-drive"] != nil, options.values["cloud-account"] == nil { throw usage("--cloud-drive requires --cloud-account") }
            if options.values["cloud-drive-name"] != nil {
                guard options.values["cloud-account"] != nil else { throw usage("--cloud-drive-name requires --cloud-account") }
                guard options.values["cloud-drive"] == nil else { throw usage("Use --cloud-drive or --cloud-drive-name, not both") }
            }
            for flag in ["cloud-account", "cloud-drive"] {
                if let value = options.values[flag], UUID(uuidString: value) == nil || value != value.lowercased() {
                    throw usage("--\(flag) requires a lowercase identifier")
                }
            }
            if options.switches.contains("new-state-folder") {
                guard options.values["cloud-account"] != nil else { throw usage("--new-state-folder requires --cloud-account") }
                guard !options.switches.contains("replace") else { throw usage("--new-state-folder makes a new folder; --replace doesn't apply") }
            }
            command = .connect(ConnectArguments(profile: profile, values: options.values, overwrite: options.switches.contains("replace"),
                                                conflictCopies: options.switches.contains("conflict-copies"),
                                                newStateFolder: options.switches.contains("new-state-folder")))
        case "mount":
            let options = try parseOptions(commandArguments, valueNames: ["mount-point", "wait"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .mount(profile: profile, mountPoint: options.values["mount-point"], waitSeconds: try options.values["wait"].map(seconds))
        case "unmount":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .unmount(profile: profile)
        case "ls", "reveal", "pin", "unpin":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            guard commandArguments.count <= 1 else { throw usage("Too many arguments for \(name)") }
            let path = commandArguments.first ?? "/"
            if name == "ls" { command = .list(profile: profile, path: path) }
            else if name == "reveal" { command = .reveal(profile: profile, path: path) }
            else if name == "pin" { command = .pin(profile: profile, path: path) }
            else { command = .unpin(profile: profile, path: path) }
        case "status", "doctor":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let profile = try optionalProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = name == "status" ? .status(profile: profile) : .doctor(profile: profile)
        case "cache":
            let options = try parseOptions(commandArguments, valueNames: ["limit-mib"], switchNames: ["evict"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            let limit = try options.values["limit-mib"].map { try integer($0, option: "limit-mib") }
            command = .cache(profile: profile, trim: options.switches.contains("evict"), limitMiB: limit)
        case "cloud-accounts":
            try noExtraArguments(commandArguments, command: name)
            command = .cloudAccounts
        case "cloud-drives":
            let options = try parseOptions(commandArguments, valueNames: ["cloud-account"])
            try noExtraArguments(options.positionals, command: name)
            guard let account = options.values["cloud-account"] else { throw usage("Usage: paraair cloud-drives --cloud-account ID") }
            guard UUID(uuidString: account) != nil, account == account.lowercased() else { throw usage("--cloud-account requires a lowercase identifier") }
            command = .cloudDrives(account: account)
        case "cloud-sign-in":
            let options = try parseOptions(commandArguments, valueNames: ["wait"])
            try noExtraArguments(options.positionals, command: name)
            command = .cloudSignIn(waitSeconds: try options.values["wait"].map(seconds))
        case "setup-status":
            try noExtraArguments(commandArguments, command: name)
            command = .setupStatus
        case "extension-settings":
            let options = try parseOptions(commandArguments, valueNames: ["wait"])
            try noExtraArguments(options.positionals, command: name)
            command = .extensionSettings(waitSeconds: try options.values["wait"].map(seconds))
        case "trash":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .trash(profile: profile)
        case "restore":
            let options = try parseOptions(commandArguments, valueNames: ["to"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            guard commandArguments.count == 1, let node = Int64(commandArguments[0]), node > 0, node < 1 << 53 else {
                throw usage("Usage: paraair restore PROFILE NODE_ID [--to PATH]")
            }
            command = .restore(profile: profile, nodeID: node, to: options.values["to"])
        case "stored-drives":
            let options = try parseOptions(commandArguments, valueNames: ["connection", "library"])
            try noExtraArguments(options.positionals, command: name)
            guard let connection = options.values["connection"] else { throw usage("Usage: paraair stored-drives --connection ID") }
            command = .storedDrives(connection: connection, library: options.values["library"])
        case "recover":
            let options = try parseOptions(commandArguments, valueNames: ["connection", "volume", "backup", "library"], switchNames: ["take-over"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            guard let connection = options.values["connection"], let volume = options.values["volume"] else {
                throw usage("Usage: paraair recover PROFILE --connection ID --volume NAME [--backup KEY] [--take-over]")
            }
            command = .recover(profile: profile, connection: connection, volume: volume, backup: options.values["backup"],
                               takeOver: options.switches.contains("take-over"), library: options.values["library"])
        case "conflicts":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .conflicts(profile: profile)
        case "resolve":
            let options = try parseOptions(commandArguments, valueNames: ["keep-mine-as", "export-to"], switchNames: ["keep-theirs", "replace"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            let usageText = "Usage: paraair resolve PROFILE PATH (--keep-mine-as NAME | --keep-theirs | --export-to FILE [--replace])"
            guard commandArguments.count == 1 else { throw usage(usageText) }
            let chosen = [options.values["keep-mine-as"] != nil, options.switches.contains("keep-theirs"), options.values["export-to"] != nil]
            guard chosen.filter({ $0 }).count == 1 else { throw usage(usageText) }
            guard !options.switches.contains("replace") || options.values["export-to"] != nil else { throw usage("--replace applies only to --export-to") }
            let choice: CLIResolution
            if let name = options.values["keep-mine-as"] { choice = .keepMine(name: name) }
            else if let file = options.values["export-to"] { choice = .export(to: file, replace: options.switches.contains("replace")) }
            else { choice = .keepTheirs }
            command = .resolve(profile: profile, path: commandArguments[0], choice: choice)
        case "settings":
            let options = try parseOptions(commandArguments, valueNames: ["conflict-copies"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .settings(profile: profile, conflictCopies: try options.values["conflict-copies"].map { try onOff($0, option: "conflict-copies") })
        case "versions":
            let options = try parseOptions(commandArguments, valueNames: ["before", "limit"])
            commandArguments = options.positionals
            let target = try target(globals["profile"], positionals: &commandArguments, usageText: "Usage: paraair versions (PROFILE PATH | MOUNTED_PATH) [--before CURSOR] [--limit N]")
            try noExtraArguments(commandArguments, command: name)
            let before = try options.values["before"].map { value -> Int64 in
                guard let cursor = Int64(value), cursor >= 1, cursor < 1 << 53 else { throw usage("--before requires a cursor from nextBefore") }
                return cursor
            }
            let limit = try options.values["limit"].map { value -> Int in
                guard let count = Int(value), (1...1000).contains(count) else { throw usage("--limit requires 1 to 1000") }
                return count
            }
            command = .versions(target: target, before: before, limit: limit)
        case "cat-version", "restore-version":
            let restoring = name == "restore-version"
            let options = try parseOptions(commandArguments, valueNames: restoring ? ["expected-version"] : [])
            commandArguments = options.positionals
            let usageText = restoring ? "Usage: paraair restore-version (PROFILE PATH | MOUNTED_PATH) VERSION [--expected-version VERSION]"
                : "Usage: paraair cat-version (PROFILE PATH | MOUNTED_PATH) VERSION"
            let target = try target(globals["profile"], positionals: &commandArguments, usageText: usageText)
            guard commandArguments.count == 1 else { throw usage(usageText) }
            let version = try fileVersion(commandArguments[0], option: "VERSION")
            if restoring {
                let expected = try options.values["expected-version"].map { try fileVersion($0, option: "--expected-version") }
                command = .restoreVersion(target: target, version: version, expectedVersion: expected)
            } else {
                command = .catVersion(target: target, version: version)
            }
        case "conflict-info":
            let options = try parseOptions(commandArguments)
            commandArguments = options.positionals
            let target = try target(globals["profile"], positionals: &commandArguments, usageText: "Usage: paraair conflict-info (PROFILE PATH | MOUNTED_PATH)")
            try noExtraArguments(commandArguments, command: name)
            command = .conflictInfo(target: target)
        case "changes":
            let options = try parseOptions(commandArguments, valueNames: ["since", "interval"], switchNames: ["follow"])
            commandArguments = options.positionals
            let target = try target(globals["profile"], positionals: &commandArguments, pathRequired: false,
                                    usageText: "Usage: paraair changes (PROFILE [FOLDER] | MOUNTED_PATH) [--since CURSOR] [--follow [--interval SECONDS]]")
            try noExtraArguments(commandArguments, command: name)
            let since = try options.values["since"].map { value -> Int64 in
                guard let cursor = Int64(value), cursor >= 0, cursor < 1 << 53 else { throw usage("--since requires a cursor from the change feed") }
                return cursor
            }
            let interval = try options.values["interval"].map { value -> Int in
                guard let seconds = Int(value), (1...300).contains(seconds) else { throw usage("--interval requires 1 to 300 seconds") }
                return seconds
            }
            guard interval == nil || options.switches.contains("follow") else { throw usage("--interval applies only to --follow") }
            command = .changes(target: target, follow: options.switches.contains("follow"), since: since, intervalSeconds: interval)
        case "access":
            guard let verb = commandArguments.first, ["list", "set", "remove"].contains(verb) else {
                throw usage("Usage: paraair access list|set|remove (PROFILE FOLDER | MOUNTED_PATH) [(--email E | --role members|viewers | --credential ID) [--level none|read|create|write]]")
            }
            let options = try parseOptions(Array(commandArguments.dropFirst()), valueNames: ["email", "role", "credential", "level"])
            commandArguments = options.positionals
            let usageText = verb == "list" ? "Usage: paraair access list (PROFILE [FOLDER] | MOUNTED_PATH)"
                : verb == "set" ? "Usage: paraair access set (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID) --level none|read|create|write"
                : "Usage: paraair access remove (PROFILE FOLDER | MOUNTED_PATH) (--email E | --role members|viewers | --credential ID)"
            let target = try target(globals["profile"], positionals: &commandArguments, pathRequired: verb != "list", usageText: usageText)
            try noExtraArguments(commandArguments, command: "access " + verb)
            let principals = ["email", "role", "credential"].compactMap { key in options.values[key].map { (key, $0) } }
            switch verb {
            case "list":
                guard principals.isEmpty, options.values["level"] == nil else { throw usage(usageText) }
                command = .access(.list, target: target)
            default:
                guard principals.count == 1 else { throw usage(usageText) }
                let principal: ParaAirCloudAccessPrincipal
                switch principals[0] {
                case ("role", let role):
                    guard ["members", "viewers"].contains(role) else { throw usage("--role is members or viewers") }
                    principal = .role(role)
                case ("credential", let id): principal = .credential(id)
                case (_, let email):
                    guard email.contains("@"), email.utf8.count <= 320 else { throw usage("--email requires an email address") }
                    principal = .email(email)
                }
                if verb == "set" {
                    guard let raw = options.values["level"], let level = ParaAirCloudAccessLevel(rawValue: raw) else {
                        throw usage("--level requires none, read, create or write")
                    }
                    command = .access(.set(principal, level), target: target)
                } else {
                    guard options.values["level"] == nil else { throw usage(usageText) }
                    command = .access(.remove(principal), target: target)
                }
            }
        case "uploads":
            let options = try parseOptions(commandArguments, switchNames: ["retry"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .uploads(profile: profile, retry: options.switches.contains("retry"))
        default:
            throw usage("Unknown command '\(name)'. Run paraair help.")
        }
        return CLIInvocation(stateDirectory: globals["state-dir"], json: json, command: command)
    }

    private struct Options {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []
    }

    private static func parseOptions(_ arguments: [String], valueNames: Set<String> = [], switchNames: Set<String> = []) throws -> Options {
        var result = Options()
        var index = 0
        var positionalOnly = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--", !positionalOnly { positionalOnly = true }
            else if !positionalOnly, let option = matchingOption(argument, names: valueNames) {
                guard result.values[option.name] == nil else { throw usage("Duplicate --\(option.name)") }
                result.values[option.name] = try optionValue(option.inlineValue, name: option.name, arguments: arguments, index: &index)
            } else if !positionalOnly, argument.hasPrefix("--"), switchNames.contains(String(argument.dropFirst(2))) {
                let name = String(argument.dropFirst(2))
                guard result.switches.insert(name).inserted else { throw usage("Duplicate --\(name)") }
            } else if !positionalOnly, argument.hasPrefix("-") {
                throw usage("Unknown option '\(argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "")'")
            } else { result.positionals.append(argument) }
            index += 1
        }
        return result
    }

    private static func matchingOption(_ argument: String, names: Set<String>) -> (name: String, inlineValue: String?)? {
        guard argument.hasPrefix("--") else { return nil }
        let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard names.contains(name) else { return nil }
        return (name, parts.count > 1 ? String(parts[1]) : nil)
    }

    private static func optionValue(_ inline: String?, name: String, arguments: [String], index: inout Int) throws -> String {
        if let inline, !inline.isEmpty { return inline }
        guard inline == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"), !arguments[index + 1].isEmpty else {
            throw usage("--\(name) requires a value")
        }
        index += 1
        return arguments[index]
    }

    private static func requiredProfile(_ explicit: String?, positionals: inout [String]) throws -> String {
        guard let profile = try optionalProfile(explicit, positionals: &positionals) else {
            throw usage("An explicit profile is required")
        }
        return profile
    }

    private static func optionalProfile(_ explicit: String?, positionals: inout [String]) throws -> String? {
        let profile = explicit ?? (positionals.isEmpty ? nil : positionals.removeFirst())
        if let profile {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
            let initial = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            guard !profile.isEmpty, profile.utf8.count <= 64, let first = profile.unicodeScalars.first,
                  initial.contains(first), profile.unicodeScalars.allSatisfy(allowed.contains) else {
                throw usage("Invalid profile name: use 1–64 letters, digits, dots, underscores or hyphens, starting with a letter or digit")
            }
        }
        return profile
    }

    /// `PROFILE PATH`, `--profile NAME PATH`, or one path under a mounted drive. A first argument starting with "/" is a
    /// mounted path (profile names never start with "/"). Without `pathRequired`, a profile alone means the drive's root.
    private static func target(_ explicit: String?, positionals: inout [String], pathRequired: Bool = true, usageText: String) throws -> CLITarget {
        if explicit == nil, let first = positionals.first, first.hasPrefix("/") {
            positionals.removeFirst()
            return .mounted(first)
        }
        let profile = try requiredProfile(explicit, positionals: &positionals)
        guard !positionals.isEmpty || !pathRequired else { throw usage(usageText) }
        let path = positionals.isEmpty ? "/" : positionals.removeFirst()
        guard path.hasPrefix("/") else { throw usage("Drive paths start with /, as in /records/x.json") }
        return .drive(profile: profile, path: path)
    }

    /// A ParaAir Cloud file version, `pv:` and a number, as `versions` lists them.
    private static func fileVersion(_ value: String, option: String) throws -> String {
        guard value.range(of: "^pv:[1-9][0-9]{0,15}$", options: .regularExpression) != nil else {
            throw usage("\(option) requires a version such as pv:123 (see versions)")
        }
        return value
    }

    private static func onOff(_ value: String, option: String) throws -> Bool {
        switch value {
        case "on": return true
        case "off": return false
        default: throw usage("--\(option) requires on or off")
        }
    }

    private static func noExtraArguments(_ arguments: [String], command: String) throws {
        guard arguments.isEmpty else { throw usage("Too many arguments for \(command)") }
    }

    private static func integer(_ value: String, option: String, allowsZero: Bool = false) throws -> Int {
        guard let integer = Int(value), integer >= (allowsZero ? 0 : 1), integer <= Int.max / 1_048_576 else {
            throw usage("--\(option) requires a \(allowsZero ? "nonnegative" : "positive") bounded integer")
        }
        return integer
    }

    /// `--wait` values: whole seconds, 1 to 900.
    private static func seconds(_ value: String) throws -> Int {
        guard let seconds = Int(value), (1...900).contains(seconds) else { throw usage("--wait requires 1 to 900 seconds") }
        return seconds
    }

    private static func usage(_ message: String) -> CLIUsageError { CLIUsageError(message: message) }
}
