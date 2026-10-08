import XCTest
@testable import StreamDriveCore

@MainActor
final class FinderSetupTests: XCTestCase {
    private let identifier = "dev.streamdrive.app.filesystem"
    private let path = "/fixture/ParaAir.app/Contents/Extensions/StreamDriveFS.appex"

    private func module(enabled: Bool = true, path: String? = nil) -> FinderExtensionModule {
        FinderExtensionModule(bundleIdentifier: identifier, path: path ?? self.path, isEnabled: enabled)
    }

    func testDiscoveryDistinguishesEnabledDisabledAndMissing() {
        XCTAssertEqual(resolve([module()]), .enabled)
        XCTAssertEqual(resolve([module(enabled: false)]), .disabled)
        XCTAssertEqual(resolve([]), .notDiscovered)
        XCTAssertEqual(resolve([.init(bundleIdentifier: "com.apple.example", path: "/system", isEnabled: true)]), .notDiscovered)
    }

    func testDiscoveryNeverUsesAnotherCopyOrAmbiguousRegistration() {
        XCTAssertEqual(resolve([module(path: "/other/ParaAir.app/Contents/Extensions/StreamDriveFS.appex")]), .ambiguous)
        XCTAssertEqual(resolve([module(), module(path: "/other/copy")]), .ambiguous)
        XCTAssertEqual(resolve([module(), module(enabled: false)]), .ambiguous)
    }

    func testOverlappingRefreshesWaitForOneDiscoveryAndBothSeeItsResult() async {
        let source = SuspendedFinderInventory()
        let coordinator = makeCoordinator { try await source.fetch() }
        let first = Task { await coordinator.refresh() }
        await source.waitUntilStarted()
        let secondStarted = expectation(description: "second waiter started")
        let second = Task { @MainActor in
            secondStarted.fulfill()
            return await coordinator.refresh()
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertTrue(coordinator.isRefreshing)
        await source.complete([module()])
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertEqual(firstResult, .enabled)
        XCTAssertEqual(secondResult, .enabled)
        XCTAssertEqual(coordinator.state, .enabled)
        XCTAssertFalse(coordinator.isRefreshing)
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
    }

    func testContinuationSurvivesTransientResultsAndConsumesOnlyOnceWhenReady() async {
        var responses: [[FinderExtensionModule]] = [[], [module(enabled: false)], [module(), module(path: "/other")], [module()]]
        let coordinator = makeCoordinator { responses.removeFirst() }
        coordinator.requestContinuation(for: "root/profile")
        let expectedStates: [FinderExtensionState] = [.notDiscovered, .disabled, .ambiguous]
        for expected in expectedStates {
            let state = await coordinator.refresh()
            XCTAssertEqual(state, expected)
            XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", storageReady: true, mounted: false, mounting: false))
            XCTAssertTrue(coordinator.hasPendingContinuation)
        }
        _ = await coordinator.refresh()
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", storageReady: false, mounted: false, mounting: false))
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", storageReady: true, mounted: false, mounting: true))
        XCTAssertTrue(coordinator.hasPendingContinuation)
        XCTAssertTrue(coordinator.takeContinuation(for: "root/profile", storageReady: true, mounted: false, mounting: false))
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", storageReady: true, mounted: false, mounting: false))
        XCTAssertFalse(coordinator.hasPendingContinuation)
    }

    func testFailedDiscoveryRetainsContinuationWithoutExposingErrorDetails() async {
        var fail = true
        let coordinator = makeCoordinator {
            if fail { throw NSError(domain: "private-token", code: 42, userInfo: [NSLocalizedDescriptionKey: "secret-must-not-leak"]) }
            return [self.module()]
        }
        coordinator.requestContinuation(for: "root/profile")
        let failed = await coordinator.refresh()
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(coordinator.hasPendingContinuation)
        XCTAssertFalse(coordinator.isRefreshing)
        fail = false
        let recovered = await coordinator.refresh()
        XCTAssertEqual(recovered, .enabled)
        XCTAssertTrue(coordinator.takeContinuation(for: "root/profile", storageReady: true, mounted: false, mounting: false))
    }

    func testContinuationCannotMountAnotherRootOrSurviveExplicitCancellation() async {
        let coordinator = makeCoordinator { [self.module()] }
        _ = await coordinator.refresh()
        coordinator.requestContinuation(for: "root-one/profile")
        XCTAssertFalse(coordinator.takeContinuation(for: "root-two/profile", storageReady: true, mounted: false, mounting: false))
        coordinator.cancelContinuation()
        XCTAssertFalse(coordinator.takeContinuation(for: "root-one/profile", storageReady: true, mounted: false, mounting: false))
        coordinator.requestContinuation(for: "root-one/profile")
        XCTAssertFalse(coordinator.takeContinuation(for: "root-one/profile", storageReady: true, mounted: true, mounting: false))
        XCTAssertFalse(coordinator.hasPendingContinuation)
    }

    private func resolve(_ modules: [FinderExtensionModule]) -> FinderExtensionState {
        FinderExtensionState.resolve(modules, bundleIdentifier: identifier, expectedPath: path)
    }
    private func makeCoordinator(_ fetch: @escaping @MainActor () async throws -> [FinderExtensionModule]) -> FinderSetupCoordinator {
        FinderSetupCoordinator(bundleIdentifier: identifier, expectedPath: path, fetch: fetch)
    }
}

private actor SuspendedFinderInventory {
    private var continuation: CheckedContinuation<[FinderExtensionModule], Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func fetch() async throws -> [FinderExtensionModule] {
        calls += 1
        started?.resume(); started = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ modules: [FinderExtensionModule]) { continuation?.resume(returning: modules); continuation = nil }
}
