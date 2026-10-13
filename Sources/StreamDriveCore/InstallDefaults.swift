import Foundation

/// Where the running ParaAir bundle lives. Classified from plain inputs so the
/// move-to-Applications and open-at-login defaults are testable without a bundle,
/// a disk image or System Settings.
public enum InstallLocation: String, Equatable, Sendable {
    /// Gatekeeper runs a quarantined download (from Downloads or a disk image) from a
    /// randomized read-only path.
    case translocated
    /// A disk image or another read-only volume.
    case readOnlyVolume
    /// /Applications or ~/Applications, or a folder inside either.
    case applications
    /// Any other writable folder, such as a developer build under .build.
    case elsewhere

    public static func classify(bundlePath: String, homeDirectory: String, volumeIsReadOnly: Bool) -> InstallLocation {
        let path = trimmed(bundlePath)
        if path.contains("/AppTranslocation/") { return .translocated }
        if volumeIsReadOnly { return .readOnlyVolume }
        let folders = ["/Applications", trimmed(homeDirectory) + "/Applications"]
        if folders.contains(where: { path.lowercased().hasPrefix($0.lowercased() + "/") }) { return .applications }
        return .elsewhere
    }

    /// Only a copy macOS runs in place from a download or a disk image moves itself.
    /// A bundle in any other writable folder (a developer build) never moves.
    public var shouldMove: Bool { self == .translocated || self == .readOnlyVolume }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Where a moved copy goes: /Applications when this user can write there, otherwise
/// ~/Applications (created when missing).
public enum InstallDestination {
    public static let bundleName = "ParaAir.app"

    public static func folder(systemApplicationsWritable: Bool, homeDirectory: String) -> String {
        if systemApplicationsWritable { return "/Applications" }
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return home + "/Applications"
    }

    public static func path(systemApplicationsWritable: Bool, homeDirectory: String) -> String {
        folder(systemApplicationsWritable: systemApplicationsWritable, homeDirectory: homeDirectory) + "/" + bundleName
    }
}

/// A bundle's CFBundleVersion and CFBundleShortVersionString.
public struct BundleVersion: Equatable, Sendable {
    public var build: String?
    public var marketing: String?

    public init(build: String?, marketing: String?) {
        self.build = build; self.marketing = marketing
    }

    public init(infoDictionary: [String: Any]) {
        self.init(build: infoDictionary["CFBundleVersion"] as? String,
                  marketing: infoDictionary["CFBundleShortVersionString"] as? String)
    }

    /// True only when this version is strictly newer: CFBundleVersion decides, and
    /// CFBundleShortVersionString breaks a tie. A missing value is older than any value.
    public func isNewer(than other: BundleVersion) -> Bool {
        switch Self.compare(build, other.build) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return Self.compare(marketing, other.marketing) == .orderedDescending
        }
    }

    /// Dot-separated numeric comparison: "1.10" is newer than "1.9" and "1.0" equals "1".
    /// Each component counts its leading digits only, so "2b3" reads as 2.
    static func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs.flatMap(components), rhs.flatMap(components)) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (left?, right?):
            for index in 0..<max(left.count, right.count) {
                let a = index < left.count ? left[index] : 0
                let b = index < right.count ? right[index] : 0
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
            return .orderedSame
        }
    }

    /// How an alert names this version beside `other`: the marketing version, with the
    /// build number added when both marketing versions match. Nil when nothing is known.
    public func label(distinctFrom other: BundleVersion) -> String? {
        let ownMarketing = Self.nonEmpty(marketing), ownBuild = Self.nonEmpty(build)
        switch (ownMarketing, ownBuild) {
        case let (version?, build?) where version == Self.nonEmpty(other.marketing): return "\(version) (\(build))"
        case let (version?, _): return version
        case let (nil, build?): return "build \(build)"
        case (nil, nil): return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func components(_ value: String) -> [Int]? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            return digits.isEmpty ? 0 : Int(digits) ?? Int.max
        }
    }
}

/// A ParaAir.app already at the destination, as found before a move.
public struct InstalledCopy: Equatable, Sendable {
    public var version: BundleVersion
    /// Its bundle identifier matches the running app. Another app named ParaAir.app is never replaced.
    public var sameIdentifier: Bool
    /// That copy is running right now.
    public var running: Bool

    public init(version: BundleVersion, sameIdentifier: Bool, running: Bool) {
        self.version = version; self.sameIdentifier = sameIdentifier; self.running = running
    }
}

/// What to do at launch about the bundle's location.
public enum InstallAction: Equatable, Sendable {
    /// Keep running from here.
    case stay
    /// Open the copy already at the destination and quit: it is newer, or it is running.
    case openInstalled
    /// Copy this bundle to the destination, moving an older copy there to the Trash first.
    case install(replacingExisting: Bool)
    /// An older copy is open at the destination. Ask before quitting it, then install as
    /// `install(replacingExisting: true)`; never fall back to the old copy without asking.
    case askToReplaceRunning
    /// Something else occupies the destination; ask the person to drag ParaAir in.
    case askToMoveManually

    public static func plan(location: InstallLocation, installed: InstalledCopy?, running: BundleVersion) -> InstallAction {
        guard location.shouldMove else { return .stay }
        guard let installed else { return .install(replacingExisting: false) }
        guard installed.sameIdentifier else { return .askToMoveManually }
        if installed.version.isNewer(than: running) { return .openInstalled }
        if installed.running {
            // The same version already open: switch to it. An older one: offer the update.
            return running.isNewer(than: installed.version) ? .askToReplaceRunning : .openInstalled
        }
        return .install(replacingExisting: true)
    }
}

/// Alert text that names versions, kept here so it is tested with the decision.
public enum InstallPrompt {
    /// "ParaAir 0.1.0 is open. Quit it and install 0.2.0?"
    public static func replaceRunning(installed: BundleVersion, running: BundleVersion) -> String {
        let new = running.label(distinctFrom: installed).map { " " + $0 } ?? ""
        guard let old = installed.label(distinctFrom: running) else {
            return "An older ParaAir is open. Quit it and install ParaAir\(new)?"
        }
        return "ParaAir \(old) is open. Quit it and install \(new.isEmpty ? "this version" : String(new.dropFirst()))?"
    }
}

/// SMAppService.Status for the main app, as plain values.
public enum LoginItemStatus: String, Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

/// The open-at-login default: applied once, the first time ParaAir runs from an
/// Applications folder. A person who turns it off later is never overridden, and a
/// bundle outside an Applications folder (a developer build) is never registered.
public enum LoginItemDefault: Equatable, Sendable {
    /// Not in an Applications folder, or the default was already applied.
    case skip
    /// Register now, then record the default as applied.
    case register
    /// Already registered (or awaiting approval): record the default without registering.
    case recordOnly

    public static let appliedKey = "loginItemDefaultApplied"

    public static func decide(location: InstallLocation, alreadyApplied: Bool, status: LoginItemStatus) -> LoginItemDefault {
        guard location == .applications, !alreadyApplied else { return .skip }
        switch status {
        case .notRegistered, .notFound: return .register
        case .enabled, .requiresApproval: return .recordOnly
        }
    }
}
