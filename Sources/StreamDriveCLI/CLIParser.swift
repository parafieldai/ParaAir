import Foundation

struct CLIInvocation: Equatable {
    var stateDirectory: String?
    var json: Bool
    var command: CLICommand
}

struct ConnectArguments: Equatable {
    var profile: String
    var values: [String: String]
    var overwrite: Bool
}

enum CLICommand: Equatable {
    case help(String?)
    case connect(ConnectArguments)
    case connections
    case mount(profile: String, mountPoint: String?)
    case unmount(profile: String)
    case list(profile: String, path: String)
    case reveal(profile: String, path: String)
    case status(profile: String?)
    case cache(profile: String, trim: Bool, limitMiB: Int?)
    case pin(profile: String, path: String)
    case unpin(profile: String, path: String)
    case uploads(profile: String, retry: Bool)
    case doctor(profile: String?)
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
            let options = try parseOptions(commandArguments, valueNames: ["metadata-url", "library", "mount-point", "fixture-root", "credential-id", "connection", "cache-mib", "min-free-mib", "block-size", "journal-mib"], switchNames: ["replace"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            for flag in ["cache-mib", "min-free-mib", "block-size", "journal-mib"] {
                if let value = options.values[flag] { _ = try integer(value, option: flag, allowsZero: flag == "min-free-mib") }
            }
            command = .connect(ConnectArguments(profile: profile, values: options.values, overwrite: options.switches.contains("replace")))
        case "mount":
            let options = try parseOptions(commandArguments, valueNames: ["mount-point"])
            commandArguments = options.positionals
            let profile = try requiredProfile(globals["profile"], positionals: &commandArguments)
            try noExtraArguments(commandArguments, command: name)
            command = .mount(profile: profile, mountPoint: options.values["mount-point"])
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

    private static func noExtraArguments(_ arguments: [String], command: String) throws {
        guard arguments.isEmpty else { throw usage("Too many arguments for \(command)") }
    }

    private static func integer(_ value: String, option: String, allowsZero: Bool = false) throws -> Int {
        guard let integer = Int(value), integer >= (allowsZero ? 0 : 1), integer <= Int.max / 1_048_576 else {
            throw usage("--\(option) requires a \(allowsZero ? "nonnegative" : "positive") bounded integer")
        }
        return integer
    }

    private static func usage(_ message: String) -> CLIUsageError { CLIUsageError(message: message) }
}
