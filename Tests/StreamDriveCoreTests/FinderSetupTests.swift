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

    private func readiness(credentialCheckFinished: Bool = true, storageBlocked: Bool = false, extensionState: FinderExtensionState = .enabled,
                           checkingExtension: Bool = false, mounted: Bool = false, mounting: Bool = false) -> AutoMountReadiness {
        AutoMountReadiness(credentialCheckFinished: credentialCheckFinished, storageBlocked: storageBlocked, extensionState: extensionState,
                           checkingExtension: checkingExtension, mounted: mounted, mounting: mounting)
    }

    func testReadinessGatesContinuationAndKeepsItPending() async {
        let coordinator = makeCoordinator { [self.module()] }
        _ = await coordinator.refresh()
        coordinator.requestContinuation(for: "root/profile")
        let blocked = [readiness(credentialCheckFinished: false), readiness(storageBlocked: true),
                       readiness(extensionState: .disabled), readiness(extensionState: .unchecked),
                       readiness(checkingExtension: true), readiness(mounting: true)]
        for gate in blocked {
            XCTAssertFalse(gate.canStartMount, gate.description)
            XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", readiness: gate), gate.description)
            XCTAssertTrue(coordinator.hasPendingContinuation, "A blocked gate must keep the continuation: \(gate)")
        }
        XCTAssertFalse(coordinator.takeContinuation(for: "other-root/profile", readiness: readiness()))
        XCTAssertTrue(coordinator.hasPendingContinuation)
        XCTAssertTrue(readiness().canStartMount)
        XCTAssertTrue(coordinator.takeContinuation(for: "root/profile", readiness: readiness()))
        XCTAssertFalse(coordinator.hasPendingContinuation)
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", readiness: readiness()))
    }

    func testReadinessCannotOverrideCoordinatorDiscovery() async {
        // The coordinator's own discovery result still gates a ready-looking value.
        var modules: [[FinderExtensionModule]] = [[module(enabled: false)], [module()]]
        let coordinator = makeCoordinator { modules.removeFirst() }
        _ = await coordinator.refresh()
        coordinator.requestContinuation(for: "root/profile")
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", readiness: readiness()))
        XCTAssertTrue(coordinator.hasPendingContinuation)
        _ = await coordinator.refresh()
        XCTAssertTrue(coordinator.takeContinuation(for: "root/profile", readiness: readiness()))
    }

    func testContinuationIsClearedWhenAlreadyMounted() async {
        let coordinator = makeCoordinator { [self.module(enabled: false)] }
        _ = await coordinator.refresh()
        coordinator.requestContinuation(for: "root/profile")
        // Mounted wins over every other gate: nothing remains to continue.
        let mounted = readiness(credentialCheckFinished: false, storageBlocked: true, extensionState: .disabled, mounted: true)
        XCTAssertFalse(mounted.canStartMount)
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", readiness: mounted))
        XCTAssertFalse(coordinator.hasPendingContinuation)
        XCTAssertFalse(coordinator.takeContinuation(for: "root/profile", readiness: readiness()))
    }

    func testReadinessDescriptionNamesBlockingGate() {
        let cases: [(AutoMountReadiness, String?)] = [
            (readiness(credentialCheckFinished: false, storageBlocked: true), "credentials-pending"),
            (readiness(storageBlocked: true, extensionState: .disabled), "storage-blocked"),
            (readiness(extensionState: .disabled), "extension-disabled"),
            (readiness(extensionState: .notDiscovered), "extension-notDiscovered"),
            (readiness(checkingExtension: true, mounting: true), "checking-extension"),
            (readiness(mounted: true, mounting: true), "mounted"),
            (readiness(mounting: true), "mounting"),
            (readiness(), nil),
        ]
        for (value, gate) in cases {
            XCTAssertEqual(value.blockedGate, gate)
            XCTAssertEqual(value.canStartMount, gate == nil)
            XCTAssertTrue(value.description.hasPrefix("gate=" + (gate ?? "ready") + " "), value.description)
            XCTAssertTrue(value.description.contains("storageBlocked=\(value.storageBlocked)"), value.description)
            XCTAssertFalse(value.description.contains("/"), "Readiness descriptions carry no paths")
        }
    }

    func testCloudSignInKeepsTheDriveItLeavesMountingAtLogin() {
        let byo = "/Users/u/Library/Application Support/StreamDrive"
        let cloud = "/Users/u/Library/Application Support/ParaAir/Cloud Drives/a1"
        let other = "/Users/u/state/test", empty = "/Users/u/state/empty"
        var drives: Set<String> = [byo, cloud, other]
        var login = LoginMountFolders()
        XCTAssertEqual(login.targets(selected: byo, hasDrive: drives.contains), [byo])
        // Signing in to ParaAir Cloud from the BYO folder switches to the cloud drive's own folder.
        login.adopt(cloud, leaving: byo, previousHasDrive: true)
        XCTAssertEqual(login.targets(selected: cloud, hasDrive: drives.contains), [cloud, byo],
                       "the BYO drive must still mount at the next login")
        // The setting is saved and read back as plain paths.
        login = LoginMountFolders(kept: login.kept)
        XCTAssertEqual(login.targets(selected: cloud, hasDrive: drives.contains), [cloud, byo])
        // Choosing the BYO folder again keeps the cloud drive mounting too.
        login.choose(byo, leaving: cloud, previousHasDrive: true)
        XCTAssertEqual(login.targets(selected: byo, hasDrive: drives.contains), [byo, cloud])
        // Choosing an unrelated folder replaces the selected one as before; kept drives stay.
        login.choose(other, leaving: byo, previousHasDrive: true)
        XCTAssertEqual(login.targets(selected: other, hasDrive: drives.contains), [other, cloud])
        // Adopting within the same folder, or leaving a folder without a drive, keeps nothing new.
        login.adopt(other, leaving: other, previousHasDrive: true)
        login.choose(empty, leaving: other, previousHasDrive: true)
        login.adopt(other, leaving: empty, previousHasDrive: false)
        XCTAssertEqual(login.targets(selected: other, hasDrive: drives.contains), [other, cloud])
        // A kept folder whose drive is gone drops out.
        drives.remove(cloud)
        XCTAssertEqual(login.targets(selected: other, hasDrive: drives.contains), [other])
        XCTAssertEqual(login.kept, [])
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
