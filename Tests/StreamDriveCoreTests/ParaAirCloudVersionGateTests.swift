import Foundation
import XCTest
import Darwin
@testable import StreamDriveCore

/// ParaAir Cloud's 426 `client_too_old` (incident 2026-11-27): one refusal stops the calls it covers until the gate lets
/// one ask again, a mounted drive serves what this Mac has read-only, and the app, CLI and engine can tell it apart.
final class ParaAirCloudVersionGateTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }
    private let service = URL(string: "https://cloud.example.test")!

    override func tearDown() {
        ParaAirCloudConfiguration.VersionInfo.replace(nil)
        super.tearDown()
    }

    // MARK: The gate alone

    func testScopesFollowTheServicesVersionChecks() {
        XCTAssertEqual(ParaAirCloudVersionGate.scope(of: "/v1/me"), .service)
        XCTAssertEqual(ParaAirCloudVersionGate.scope(of: "/v1/drives/d/stat"), .service)
        XCTAssertEqual(ParaAirCloudVersionGate.scope(of: "/v1/w/ws/chunks/abc"), .service)
        XCTAssertEqual(ParaAirCloudVersionGate.scope(of: "/v1/billing/offer"), .billing)
        XCTAssertEqual(ParaAirCloudVersionGate.scope(of: "/v1/billing/portal"), .billing)
        XCTAssertNil(ParaAirCloudVersionGate.scope(of: "/v1/health"), "health answers older apps and reports the floor")
        XCTAssertNil(ParaAirCloudVersionGate.scope(of: "/oauth/token"), "sign-in and token renewal aren't refused by version")
        XCTAssertNil(ParaAirCloudVersionGate.scope(of: "/account"))
        XCTAssertEqual(ParaAirCloudVersionGate.origin(URL(string: "wss://Cloud.Example.test/v1/drives/x/changes/stream")!),
                       ParaAirCloudVersionGate.origin(URL(string: "https://cloud.example.test")!), "the change stream shares the service's answer")
        XCTAssertNotEqual(ParaAirCloudVersionGate.origin(URL(string: "https://cloud.example.test:8443")!),
                          ParaAirCloudVersionGate.origin(service))
    }

    func testARefusalStopsCallsUntilOneAsksAgainAfterTheInterval() {
        let clock = Clock(), gate = ParaAirCloudVersionGate(now: { clock.now })
        gate.recheckInterval = 900
        XCTAssertTrue(gate.admits(service, path: "/v1/me"))
        gate.answered(service, path: "/v1/me", status: 426)
        XCTAssertEqual(gate.refusal(for: service), .service)
        XCTAssertEqual(gate.refusal(), .service)
        XCTAssertNil(gate.refusal(for: URL(string: "https://other.example.test")!), "another service hasn't refused")
        XCTAssertFalse(gate.admits(service, path: "/v1/drives/d/stat"))
        XCTAssertFalse(gate.admits(service, path: "/v1/billing/offer"), "the service's floor covers billing")
        XCTAssertTrue(gate.admits(service, path: "/v1/health"))
        XCTAssertTrue(gate.admits(service, path: "/oauth/token"))
        clock.advance(899)
        XCTAssertFalse(gate.admits(service, path: "/v1/me"))
        clock.advance(1)
        XCTAssertTrue(gate.admits(service, path: "/v1/me"), "one call asks again")
        XCTAssertFalse(gate.admits(service, path: "/v1/me"), "the rest wait for its answer, or the next interval")
        gate.answered(service, path: "/v1/me", status: 426)
        XCTAssertEqual(gate.refusal(for: service), .service, "still refused")
        // Answers given before the service's version check say nothing about it.
        gate.answered(service, path: "/v1/me", status: 429)
        gate.answered(service, path: "/v1/me", status: 503)
        XCTAssertEqual(gate.refusal(for: service), .service)
        clock.advance(900)
        XCTAssertTrue(gate.admits(service, path: "/v1/drives/d/list"))
        gate.answered(service, path: "/v1/drives/d/list", status: 404)
        XCTAssertNil(gate.refusal(for: service), "the floor went down: past the check, any answer lets calls through")
        XCTAssertTrue(gate.admits(service, path: "/v1/me")); XCTAssertTrue(gate.admits(service, path: "/v1/me"))
    }

    func testABillingFloorStopsBillingCallsOnly() {
        let clock = Clock(), gate = ParaAirCloudVersionGate(now: { clock.now })
        gate.answered(service, path: "/v1/billing/offer", status: 426)
        XCTAssertEqual(gate.refusal(for: service), .billing)
        XCTAssertFalse(gate.admits(service, path: "/v1/billing/checkout"))
        XCTAssertTrue(gate.admits(service, path: "/v1/drives/d/stat"), "files keep working")
        gate.answered(service, path: "/v1/drives/d/stat", status: 200)
        XCTAssertEqual(gate.refusal(for: service), .billing, "a file call passing says nothing about the billing floor")
        clock.advance(gate.recheckInterval)
        XCTAssertTrue(gate.admits(service, path: "/v1/billing/offer"))
        gate.answered(service, path: "/v1/billing/offer", status: 200)
        XCTAssertNil(gate.refusal(for: service))
        // A billing call that passes passes both floors.
        gate.answered(service, path: "/v1/me", status: 426)
        clock.advance(gate.recheckInterval)
        XCTAssertTrue(gate.admits(service, path: "/v1/billing/offer"))
        gate.answered(service, path: "/v1/billing/offer", status: 200)
        XCTAssertNil(gate.refusal(for: service))
    }

    func testOnlyChangesAreAnnounced() {
        let gate = ParaAirCloudVersionGate()
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: ParaAirCloudVersionGate.didChange, object: gate, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        gate.answered(service, path: "/v1/me", status: 426)
        gate.answered(service, path: "/v1/drives/d/stat", status: 426)
        gate.answered(service, path: "/v1/me", status: 200)
        gate.answered(service, path: "/v1/me", status: 200)
        gate.answered(service, path: "/v1/health", status: 426)
        XCTAssertEqual(posted, 2, "refused once, accepted once")
    }

    // MARK: Through the HTTP client and the fake service

    private func signedIn() throws -> (FakeParaAirCloud, ParaAirCloudAPI, ParaAirCloudHTTP, Clock, ParaAirCloudVersionGate) {
        let fake = FakeParaAirCloud(), account = fake.createAccount()
        let http = try ParaAirCloudHTTP(baseURL: fake.issuer, policy: .init(allowsLoopbackHTTP: false), configuration: fake.configuration)
        let clock = Clock(), gate = ParaAirCloudVersionGate(now: { clock.now })
        http.versionGate = gate
        let api = ParaAirCloudAPI(http: http, tokens: StaticAccessToken(fake.issueTokens(for: account).accessToken))
        // Build 84 of 0.1.x, as alpha 12 sent it.
        ParaAirCloudConfiguration.VersionInfo.replace(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "84"])
        return (fake, api, http, clock, gate)
    }

    func testOneRefusedRequestThenNoneUntilTheGateAsksAgain() throws {
        let (fake, api, _, clock, gate) = try signedIn()
        _ = try api.me()
        fake.minimumClientVersion = "0.1.88"
        fake.clearLog()
        for _ in 0..<5 {
            do { _ = try api.me(); XCTFail("refused") } catch let error as DriveError {
                XCTAssertEqual(error.code, ENOTSUP)
                XCTAssertEqual(ParaAirCloudOutcome.of(error), .updateRequired, error.message)
                XCTAssertEqual(error.disposition, .attemptNotDispatched)
            }
        }
        XCTAssertEqual(fake.requests("GET /v1/me").count, 1, "the service was asked once; the gate answered the rest")
        XCTAssertEqual(fake.requests("GET /v1/me").first?.headers["x-paraair-client"], "mac/0.1.84")
        XCTAssertEqual(gate.refusal(for: fake.issuer), .service)
        // The floor goes back down (paraair-cloud#45); the next call after the interval asks and gets through.
        fake.minimumClientVersion = "0.0.0"
        XCTAssertThrowsError(try api.me(), "not before the interval")
        clock.advance(gate.recheckInterval)
        XCTAssertNoThrow(try api.me())
        XCTAssertNil(gate.refusal(for: fake.issuer))
        XCTAssertEqual(fake.requests("GET /v1/me").count, 2)
    }

    func testABillingOnlyFloorKeepsFilesAndTheAccountWorking() throws {
        let (fake, api, _, _, gate) = try signedIn()
        fake.billingProvider = "stripe"
        fake.minimumBillingClientVersion = "0.1.88"
        XCTAssertNoThrow(try api.me())
        XCTAssertThrowsError(try api.billingOffer()) { error in
            XCTAssertEqual(ParaAirCloudOutcome.of(error), .updateRequired)
        }
        XCTAssertEqual(gate.refusal(for: fake.issuer), .billing)
        fake.clearLog()
        XCTAssertThrowsError(try api.billingOffer())
        XCTAssertNoThrow(try api.me())
        XCTAssertEqual(fake.requests.map(\.route), ["GET /v1/me"], "billing waits for the interval; the account call went out")
        // A newer build passes both floors.
        ParaAirCloudConfiguration.VersionInfo.replace(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "88"])
        fake.minimumClientVersion = "0.1.88"
        XCTAssertNoThrow(try api.me())
    }

    // MARK: A mounted drive

    func testARefusedDriveServesWhatThisMacHasReadOnlyAndKeepsEarlierChanges() throws {
        let fake = FakeParaAirCloud(), account = fake.createAccount(), root = try cloudTestRoot(self), vault = TestConnectionVault()
        let record = try fake.saveAccount(account, root: root, vault: vault)
        fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("cached".utf8))
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        let clock = Clock(), gate = ParaAirCloudVersionGate(now: { clock.now })
        try session.http().versionGate = gate
        let backend = try ParaAirCloudBackend(driveID: account.driveID, bindVolume: { _ in }, api: {
            let api = ParaAirCloudAPI(http: try session.http(), tokens: session); api.retryDelays = [0.01]; return api
        })
        // A zero metadata lifetime sends every stat to the service, as an expired entry would.
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("volumes/direct"), minFreeBytes: 0,
                                blockSize: 4_194_304, tuning: EngineTuning(metadataLifetimeNanoseconds: 0, listingLifetimeNanoseconds: 0))
        ParaAirCloudConfiguration.VersionInfo.replace(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "84"])
        XCTAssertEqual(try engine.list("/").map(\.name), ["doc.txt"])
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8))
        // A change made before the floor rose: written here, not uploaded yet.
        _ = try engine.create("/draft.txt", directory: false)
        XCTAssertEqual(try engine.write("/draft.txt", offset: 0, data: Data("mine".utf8)), 4)

        fake.minimumClientVersion = "0.1.88"
        fake.clearLog()
        XCTAssertFalse(backend.updateRequired(), "nothing refused yet")
        XCTAssertEqual(try engine.stat("/doc.txt").size, 6, "cached metadata answers")
        XCTAssertTrue(backend.updateRequired())
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8), "cached content opens")
        XCTAssertEqual(Set(try engine.list("/").map(\.name)), ["doc.txt", "draft.txt"], "the saved listing answers")
        XCTAssertTrue(try engine.status().offline)
        // Changes are refused, in words the CLI maps to update_required.
        for change in [{ _ = try engine.create("/new.txt", directory: false) },
                       { _ = try engine.write("/doc.txt", offset: 0, data: Data("x".utf8)) },
                       { try engine.remove("/doc.txt", directory: false) },
                       { try engine.move("/doc.txt", to: "/moved.txt") },
                       { _ = try engine.create("/Folder", directory: true) }] as [() throws -> Void] {
            XCTAssertThrowsError(try change()) { error in
                XCTAssertEqual((error as? DriveError)?.code, EROFS)
                XCTAssertEqual(ParaAirCloudOutcome.of(error), .updateRequired)
            }
        }
        // Finder's housekeeping files stay on this Mac and are never refused.
        XCTAssertNoThrow(try engine.create("/.DS_Store", directory: false))
        // Background uploads wait; the earlier change is kept for after the update.
        _ = try engine.flushUploads(policy: .background)
        XCTAssertEqual(try engine.uploads().map(\.path), ["/draft.txt"])
        XCTAssertEqual(fake.requests.filter { $0.path.hasPrefix("/v1/") }.count, 1, "one refused request; the rest never left this Mac")

        // The floor goes down; once the gate lets a call ask, the drive is writable again and the change uploads.
        fake.minimumClientVersion = nil
        clock.advance(gate.recheckInterval)
        XCTAssertEqual(try engine.stat("/doc.txt").size, 6)
        XCTAssertFalse(backend.updateRequired())
        XCTAssertEqual(try engine.flushUploads().count, 0)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/draft.txt"), Data("mine".utf8))
        XCTAssertNoThrow(try engine.create("/new.txt", directory: false))
    }

    /// Copilot on ParaAir#86: a change that passes the first check can learn of the refusal from its own metadata
    /// refresh, which the cached fallback then hides; it must still be refused before the journal changes.
    func testAChangeThatLearnsOfTheRefusalOnTheWayIsRefusedBeforeItIsWritten() throws {
        let fake = FakeParaAirCloud(), account = fake.createAccount(), root = try cloudTestRoot(self), vault = TestConnectionVault()
        let record = try fake.saveAccount(account, root: root, vault: vault)
        fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("cached".utf8))
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        let clock = Clock(), gate = ParaAirCloudVersionGate(now: { clock.now })
        try session.http().versionGate = gate
        let backend = try ParaAirCloudBackend(driveID: account.driveID, bindVolume: { _ in }, api: {
            let api = ParaAirCloudAPI(http: try session.http(), tokens: session); api.retryDelays = [0.01]; return api
        })
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("volumes/direct"), minFreeBytes: 0,
                                blockSize: 4_194_304, tuning: EngineTuning(metadataLifetimeNanoseconds: 0, listingLifetimeNanoseconds: 0))
        ParaAirCloudConfiguration.VersionInfo.replace(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "84"])
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8))
        fake.minimumClientVersion = "0.1.88"
        func refused(_ change: () throws -> Void, _ name: String) {
            XCTAssertThrowsError(try change(), name) { error in
                XCTAssertEqual((error as? DriveError)?.code, EROFS, name)
                XCTAssertEqual(ParaAirCloudOutcome.of(error), .updateRequired, name)
            }
        }
        // The first check passes (nothing refused yet); the refresh on the way hears the 426.
        XCTAssertFalse(backend.updateRequired())
        refused({ _ = try engine.write("/doc.txt", offset: 0, data: Data("x".utf8)) }, "write")
        XCTAssertTrue(backend.updateRequired())
        XCTAssertTrue(try engine.uploads().isEmpty, "nothing was journaled")
        // The same with the refusal learned by a create's lookups, which have nothing cached to fall back on.
        gate.reset()
        refused({ _ = try engine.create("/new.txt", directory: false) }, "create")
        gate.reset()
        refused({ try engine.truncate("/doc.txt", size: 0) }, "truncate")
        XCTAssertTrue(try engine.uploads().isEmpty)
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8))
    }

    /// Copilot on ParaAir#86: an engine opened after another drive of this process heard the refusal must refuse
    /// changes before its backend connects (a change to a file with a pending journal never asks storage).
    func testADriveThatHasNotConnectedYetKnowsTheRefusal() throws {
        let fake = FakeParaAirCloud(), account = fake.createAccount(), root = try cloudTestRoot(self), vault = TestConnectionVault()
        let record = try fake.saveAccount(account, root: root, vault: vault)
        let profile = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id,
                                                 stateRoot: root, dependencies: fake.dependencies(vault: vault))
        let first = try Engine.open(profile: profile, stateRoot: root, dependencies: fake.dependencies(vault: vault))
        _ = try first.create("/draft.txt", directory: false)
        XCTAssertEqual(try first.write("/draft.txt", offset: 0, data: Data("mine".utf8)), 4)
        first.close()

        // Another drive of the same service heard the 426 (the shared gate, as in the app and its extension).
        ParaAirCloudVersionGate.shared.answered(fake.issuer, path: "/v1/me", status: 426)
        defer { ParaAirCloudVersionGate.shared.answered(fake.issuer, path: "/v1/me", status: 200) }
        fake.clearLog()
        let engine = try Engine.open(profile: profile, stateRoot: root, dependencies: fake.dependencies(vault: vault))
        defer { engine.close() }
        XCTAssertThrowsError(try engine.write("/draft.txt", offset: 4, data: Data(" more".utf8))) { error in
            XCTAssertEqual((error as? DriveError)?.code, EROFS)
        }
        XCTAssertEqual(try engine.read("/draft.txt", offset: 0, length: 4), Data("mine".utf8), "the earlier change is kept")
        XCTAssertTrue(fake.requests.isEmpty, "decided without connecting")
        // ParaAirCloudBackend itself, before its first call.
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        XCTAssertTrue(try ParaAirCloudBackend(driveID: account.driveID, session: session, issuer: fake.issuer, bindVolume: { _ in }).updateRequired())
    }
}
