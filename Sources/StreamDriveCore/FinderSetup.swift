import Foundation

public struct FinderExtensionModule: Equatable, Sendable {
    public let bundleIdentifier: String
    public let path: String
    public let isEnabled: Bool
    public init(bundleIdentifier: String, path: String, isEnabled: Bool) {
        self.bundleIdentifier = bundleIdentifier; self.path = path; self.isEnabled = isEnabled
    }
}

public enum FinderExtensionState: Equatable, Sendable {
    case unchecked, enabled, disabled, notDiscovered, ambiguous, failed

    public static func resolve(_ modules: [FinderExtensionModule], bundleIdentifier: String,
                               expectedPath: String) -> Self {
        let matching = modules.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !matching.isEmpty else { return .notDiscovered }
        // mount selects by filesystem type, so a different copy must not be
        // treated as approval for this app, even if one copy is enabled.
        guard matching.count == 1, matching[0].path == expectedPath else { return .ambiguous }
        return matching[0].isEnabled ? .enabled : .disabled
    }
}

/// Every gate an automatic mount waits on, so the take decision and its log
/// line read one value. `description` carries no paths or identifiers.
public struct AutoMountReadiness: Equatable, Sendable, CustomStringConvertible {
    public var credentialCheckFinished: Bool
    public var storageBlocked: Bool
    public var extensionState: FinderExtensionState
    public var checkingExtension: Bool
    public var mounted: Bool
    public var mounting: Bool

    public init(credentialCheckFinished: Bool, storageBlocked: Bool, extensionState: FinderExtensionState,
                checkingExtension: Bool, mounted: Bool, mounting: Bool) {
        self.credentialCheckFinished = credentialCheckFinished; self.storageBlocked = storageBlocked
        self.extensionState = extensionState; self.checkingExtension = checkingExtension
        self.mounted = mounted; self.mounting = mounting
    }

    public var canStartMount: Bool {
        credentialCheckFinished && !storageBlocked && extensionState == .enabled && !checkingExtension && !mounted && !mounting
    }
    /// The first gate that prevents mounting, or nil when `canStartMount`.
    public var blockedGate: String? {
        if !credentialCheckFinished { return "credentials-pending" }
        if storageBlocked { return "storage-blocked" }
        if extensionState != .enabled { return "extension-\(extensionState)" }
        if checkingExtension { return "checking-extension" }
        if mounted { return "mounted" }
        if mounting { return "mounting" }
        return nil
    }
    public var description: String {
        "gate=\(blockedGate ?? "ready") credentialCheckFinished=\(credentialCheckFinished) storageBlocked=\(storageBlocked) "
            + "extension=\(extensionState) checkingExtension=\(checkingExtension) mounted=\(mounted) mounting=\(mounting)"
    }
}

/// State folders whose drive mounts at login. The selected folder always does. Signing in
/// to ParaAir Cloud switches to the cloud drive's own folder and keeps the folder it left,
/// so an existing drive never stops mounting at login (spec D5). Choose State Folder…
/// replaces the selected folder as before, except that choosing a kept folder keeps the
/// one it replaces. Paths are standardized state-folder paths.
public struct LoginMountFolders: Equatable, Sendable {
    /// Folders other than the selected one that also mount at login, oldest first.
    public private(set) var kept: [String]
    public init(kept: [String] = []) { self.kept = kept }

    /// A switch to the folder of a drive that just became ready (a ParaAir Cloud sign-in).
    public mutating func adopt(_ next: String, leaving previous: String, previousHasDrive: Bool) {
        select(next, keeping: previousHasDrive ? previous : nil)
    }
    /// A switch made with Choose State Folder….
    public mutating func choose(_ next: String, leaving previous: String, previousHasDrive: Bool) {
        select(next, keeping: previousHasDrive && kept.contains(next) ? previous : nil)
    }
    /// Folders to mount at login, the selected one first. Kept folders without a drive drop out.
    public mutating func targets(selected: String, hasDrive: (String) -> Bool) -> [String] {
        kept.removeAll { $0 == selected || !hasDrive($0) }
        return [selected] + kept
    }

    private mutating func select(_ next: String, keeping previous: String?) {
        kept.removeAll { $0 == next }
        if let previous, previous != next, !kept.contains(previous) { kept.append(previous) }
    }
}

/// Coordinates discovery and user intent without mounting or changing OS access.
@MainActor
public final class FinderSetupCoordinator {
    public private(set) var state: FinderExtensionState = .unchecked
    public var isRefreshing: Bool { inFlight != nil }
    public var hasPendingContinuation: Bool { pendingTarget != nil }
    private var pendingTarget: String?
    private var inFlight: (id: UUID, task: Task<FinderExtensionState, Never>)?
    private let bundleIdentifier: String
    private let expectedPath: String
    private let fetch: @MainActor () async throws -> [FinderExtensionModule]

    public init(bundleIdentifier: String, expectedPath: String,
                fetch: @escaping @MainActor () async throws -> [FinderExtensionModule]) {
        self.bundleIdentifier = bundleIdentifier; self.expectedPath = expectedPath; self.fetch = fetch
    }

    public func refresh() async -> FinderExtensionState {
        let operation: (id: UUID, task: Task<FinderExtensionState, Never>)
        if let inFlight { operation = inFlight }
        else {
            let task = Task { @MainActor [fetch, bundleIdentifier, expectedPath] in
                do {
                    return FinderExtensionState.resolve(try await fetch(), bundleIdentifier: bundleIdentifier,
                                                        expectedPath: expectedPath)
                } catch {
                    // Error payloads can contain local paths or opaque system data.
                    return FinderExtensionState.failed
                }
            }
            operation = (UUID(), task)
            inFlight = operation
        }
        let result = await operation.task.value
        if inFlight?.id == operation.id {
            state = result
            inFlight = nil
        }
        // An older waiter must not overwrite a newer completed refresh.
        return state
    }

    public func requestContinuation(for target: String) { pendingTarget = target }
    public func cancelContinuation() { pendingTarget = nil }
    public func takeContinuation(for target: String, readiness: AutoMountReadiness) -> Bool {
        guard pendingTarget == target else { return false }
        if readiness.mounted { pendingTarget = nil; return false }
        guard state == .enabled, !isRefreshing, readiness.canStartMount else { return false }
        pendingTarget = nil
        return true
    }
    public func takeContinuation(for target: String, storageReady: Bool, mounted: Bool, mounting: Bool) -> Bool {
        takeContinuation(for: target, readiness: AutoMountReadiness(
            credentialCheckFinished: true, storageBlocked: !storageReady, extensionState: state,
            checkingExtension: isRefreshing, mounted: mounted, mounting: mounting))
    }
}
