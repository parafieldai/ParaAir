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
    public func takeContinuation(for target: String, storageReady: Bool, mounted: Bool, mounting: Bool) -> Bool {
        guard pendingTarget == target else { return false }
        if mounted { pendingTarget = nil; return false }
        guard state == .enabled, !isRefreshing, storageReady, !mounting else { return false }
        pendingTarget = nil
        return true
    }
}
