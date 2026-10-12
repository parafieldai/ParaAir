import XCTest
import CryptoKit
import Darwin
@testable import StreamDriveCore

/// The real Engine over `ParaAirCloudBackend` over the in-memory service.
final class ParaAirCloudEngineTests: XCTestCase {
    private let chunk = 4_194_304
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var vault: TestConnectionVault!
    private var record: CloudAccount!
    private var profile: DriveProfile!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = TestConnectionVault()
        record = try fake.saveAccount(account, root: root, vault: vault)
        profile = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id,
                                             stateRoot: root, dependencies: fake.dependencies(vault: vault))
    }

    private func open(_ options: ParaAirCloudSession.Options = .init()) throws -> Engine {
        try Engine.open(profile: profile, stateRoot: root, dependencies: fake.dependencies(vault: vault, options: options))
    }
    private func api() throws -> ParaAirCloudAPI {
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }
    private func sha(_ data: Data) -> String { ParaAirCloudAPI.hex(SHA256.hash(data: data)) }

    func testWriteFlushEvictReadRoundTrip() throws {
        let engine = try open()
        XCTAssertEqual(try engine.create("/Movies", directory: true).kind, .directory)
        _ = try engine.create("/Movies/a+b.mov", directory: false)
        let data = seededBytes(9 * 1024 * 1024, seed: 11)
        for offset in stride(from: 0, to: data.count, by: 1 << 20) {
            XCTAssertEqual(try engine.write("/Movies/a+b.mov", offset: Int64(offset), data: data.subdata(in: offset..<offset + (1 << 20))), 1 << 20)
        }
        XCTAssertEqual(try engine.flushUploads().count, 0)
        XCTAssertTrue(try engine.uploads().isEmpty)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/Movies/a+b.mov"), data)
        XCTAssertEqual(try api().stat(driveID: account.driveID, path: "/Movies/a+b.mov").size, 9_437_184)
        XCTAssertEqual(fake.storedChunkCount(workspaceID: account.workspaceID), 3)
        _ = try engine.evictCache()
        let before = try engine.status().objectGetRequests
        XCTAssertEqual(try engine.read("/Movies/a+b.mov", offset: 4_194_300, length: 11), data.subdata(in: 4_194_300..<4_194_311))
        var whole = Data()
        for offset in stride(from: 0, to: data.count, by: 1 << 20) { whole += try engine.read("/Movies/a+b.mov", offset: Int64(offset), length: 1 << 20) }
        XCTAssertEqual(sha(whole), sha(data))
        XCTAssertEqual(try engine.status().objectGetRequests - before, 3, "one chunk GET per 4 MiB block")
        XCTAssertEqual(try engine.list("/Movies").map(\.name), ["a+b.mov"])
        XCTAssertEqual(try engine.stat("/Movies/a+b.mov").version.hasPrefix("pv:"), true)
    }

    func testOfflineStatServesCachedMetadata() throws {
        fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("cached".utf8))
        let opened = try open()
        XCTAssertEqual(try opened.list("/").map(\.name), ["doc.txt"])
        fake.injectTransport(.notConnectedToInternet, route: "GET /v1/drives/{d}/list", times: 3)
        XCTAssertEqual(try opened.list("/").map(\.name), ["doc.txt"])
        XCTAssertTrue(try opened.status().offline)
        // A zero metadata lifetime sends every stat to the service, so the offline path is exercised.
        var options = ParaAirCloudBackend.Options(); options.capacityLifetime = 0
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        let backend = try ParaAirCloudBackend(driveID: account.driveID, options: options, bindVolume: { _ in }, api: {
            let api = ParaAirCloudAPI(http: try session.http(), tokens: session); api.retryDelays = [0.01]; return api
        })
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("volumes/direct"), minFreeBytes: 0,
                                blockSize: chunk, tuning: EngineTuning(metadataLifetimeNanoseconds: 0))
        let online = try engine.stat("/doc.txt")
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8))
        try session.http().offlineBackoffInterval = 60
        fake.injectTransport(.notConnectedToInternet, route: "GET /v1/drives/{d}/stat")
        XCTAssertEqual(try engine.stat("/doc.txt"), online)
        XCTAssertTrue(try engine.status().offline)
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8), "cached content is served offline")
    }

    func testConflictRetainsJournal() throws {
        let engine = try open()
        _ = try engine.create("/doc.txt", directory: false)
        _ = try engine.write("/doc.txt", offset: 0, data: Data("v1".utf8))
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 2), Data("v1".utf8))
        fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("A2".utf8))
        _ = try engine.write("/doc.txt", offset: 0, data: Data("B".utf8))
        let remaining = try engine.flushUploads()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.state, "conflict")
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 2), Data("B1".utf8))
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/doc.txt"), Data("A2".utf8))
        XCTAssertGreaterThan(try engine.status().pendingWriteBytes, 0)
    }

    /// Depends on the engine lane's E3 (rotate a transaction the service fenced): until it
    /// lands, the sealed journal keeps its transaction id and the next write fails.
    func testQuotaExceededRotatesTransactionAndAllowsFurtherWrites() throws {
        var engine: Engine? = try open()
        let used = fake.usedBytes(workspaceID: account.workspaceID)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: used + 1_048_576)
        _ = try engine!.create("/big.bin", directory: false)
        _ = try engine!.write("/big.bin", offset: 0, data: seededBytes(8 << 20, seed: 12))
        let before = try XCTUnwrap(try engine!.uploads().first?.transactionID)
        let pending = try engine!.flushUploads()
        XCTAssertEqual(pending.first?.lastErrno, EDQUOT)
        XCTAssertEqual(pending.first?.state, "pending")
        XCTAssertNotEqual(pending.first?.transactionID, before, "a fenced transaction is rotated, so the journal is unsealed")
        XCTAssertNoThrow(try engine!.write("/big.bin", offset: 0, data: Data("more".utf8)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(try engine!.capacity()).availableBytes, 1_048_576)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: nil)
        engine = nil
        // A new engine has no client-side quota cooldown.
        engine = try open()
        XCTAssertTrue(try engine!.flushUploads().isEmpty)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/big.bin")?.prefix(4), Data("more".utf8))
    }

    /// Spec 6.10 step 9: a successful remove clears the quota cooldown that a rejected upload started.
    func testRemoveThroughEngineClearsUploadQuotaCooldown() throws {
        fake.seedFile(driveID: account.driveID, path: "/old.bin", data: seededBytes(2 << 20, seed: 3))
        let engine = try open()
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: fake.usedBytes(workspaceID: account.workspaceID) + 1_048_576)
        _ = try engine.create("/new.bin", directory: false)
        _ = try engine.write("/new.bin", offset: 0, data: seededBytes(2 << 20, seed: 4))
        XCTAssertEqual(try engine.flushUploads().first?.lastErrno, EDQUOT)
        try engine.remove("/old.bin", directory: false)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: nil)
        fake.clearLog()
        XCTAssertTrue(try engine.flushUploads().isEmpty, "the upload proceeds once a remove freed space")
        XCTAssertEqual(fake.requests("POST /v1/drives/{d}/uploads").count, 1)
    }

    /// A commit reply carries fresh capacity; the volume's next capacity read reflects the upload.
    func testCapacityReflectsCommittedUpload() throws {
        let engine = try open()
        let before = try XCTUnwrap(try engine.capacity())
        _ = try engine.create("/f.bin", directory: false)
        _ = try engine.write("/f.bin", offset: 0, data: seededBytes(8 << 20, seed: 5))
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        XCTAssertEqual(try XCTUnwrap(try engine.capacity()).availableBytes, before.availableBytes - (8 << 20))
    }

    /// Interrupted uploads must not accumulate quota reservations: each failed attempt after
    /// reserve releases its upload, although the engine retries under a new transaction id.
    func testFailedUploadAttemptsDoNotAccumulateReservations() throws {
        let engine = try open()
        _ = try engine.create("/video.mov", directory: false)
        _ = try engine.write("/video.mov", offset: 0, data: seededBytes(4 << 20, seed: 9))
        for _ in 1...3 {
            let before = try XCTUnwrap(try engine.uploads().first?.transactionID)
            fake.injectTransport(.networkConnectionLost, route: "PUT /v1/drives/{d}/chunks/{sha}", times: 3)
            XCTAssertEqual(try engine.flushUploads().first?.lastErrno, ECONNRESET)
            XCTAssertNotEqual(try engine.uploads().first?.transactionID, before)
            XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
        }
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
        XCTAssertEqual(fake.usedBytes(workspaceID: account.workspaceID), 4 << 20)
    }

    func testExpiredAccessTokenRefreshedThroughEngineOpen() throws {
        let engine = try open()
        XCTAssertEqual(try engine.list("/").count, 0)
        let before = try vault.load(id: record.id).oauth
        fake.expireAccessTokens()
        _ = try engine.create("/after-401", directory: true)
        XCTAssertEqual(fake.tokenRequests, 1)
        XCTAssertNotEqual(try vault.load(id: record.id).oauth?.accessToken, before?.accessToken)
        let soon = try vault.load(id: record.id).oauth!
        try vault.save(ConnectionSecrets(binding: record.binding, oauth: OAuthTokens(accessToken: soon.accessToken, refreshToken: soon.refreshToken,
                                                                                     expiresAt: Date().addingTimeInterval(10), scope: soon.scope)),
                       id: record.id)
        var options = ParaAirCloudSession.Options(); options.minimumValidity = 30
        options.reloadInterval = 1
        let reopened = try open(options)
        XCTAssertEqual(try reopened.list("/").map(\.name), ["after-401"])
        XCTAssertEqual(fake.tokenRequests, 2, "a token within minimumValidity is refreshed before use")
    }

    func testEngineOpenRejectsIssuerMismatch() throws {
        var foreign = profile!
        foreign.name = "Foreign"; foreign.cloudIssuer = "https://other.cloud.invalid"
        expectDriveError(EXDEV) { _ = try Engine.open(profile: foreign, stateRoot: self.root, dependencies: self.fake.dependencies(vault: self.vault)) }
        var missing = profile!
        missing.name = "Missing"; missing.cloudAccountID = UUID().uuidString.lowercased()
        let engine = try Engine.open(profile: missing, stateRoot: root, dependencies: fake.dependencies(vault: vault))
        XCTAssertThrowsError(try engine.list("/"))
        XCTAssertTrue(fake.requests.filter { $0.route != "GET /v1/drives/{d}" }.isEmpty, "nothing is sent without a usable account")
    }

    func testTrashRestoreThroughAPIIsVisibleToEngine() throws {
        let engine = try open()
        _ = try engine.create("/a.txt", directory: false)
        let data = Data("restore me".utf8)
        _ = try engine.write("/a.txt", offset: 0, data: data)
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        try engine.remove("/a.txt", directory: false)
        expectDriveError(ENOENT) { _ = try engine.stat("/a.txt") }
        let api = try api()
        let trash = try api.trash(driveID: account.driveID, cursor: nil, limit: 100)
        let item = try XCTUnwrap(trash.items.first { $0.path == "/a.txt" })
        XCTAssertEqual(item.size, Int64(data.count))
        XCTAssertEqual(item.expiresAt.timeIntervalSince(item.deletedAt), 30 * 86400, accuracy: 5)
        let restored = try api.restore(driveID: account.driveID, nodeID: item.nodeId, to: nil, idempotencyKey: UUID())
        XCTAssertEqual(restored.path, "/a.txt")
        XCTAssertEqual(try engine.stat("/a.txt").size, Int64(data.count))
        _ = try engine.evictCache()
        XCTAssertEqual(try engine.read("/a.txt", offset: 0, length: data.count), data)
        XCTAssertTrue(try api.trash(driveID: account.driveID, cursor: nil, limit: 100).items.isEmpty)
    }
}
