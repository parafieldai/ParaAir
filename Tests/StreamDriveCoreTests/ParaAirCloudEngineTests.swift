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

    private func open(_ options: ParaAirCloudSession.Options = .init(), backend: ParaAirCloudBackend.Options = .init()) throws -> Engine {
        var dependencies = fake.dependencies(vault: vault, options: options)
        dependencies.cloudBackendOptions = backend
        return try Engine.open(profile: profile, stateRoot: root, dependencies: dependencies)
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
        // Within the listing lifetime the saved listing answers and no request is made, so the drive isn't offline.
        XCTAssertEqual(try opened.list("/").map(\.name), ["doc.txt"])
        XCTAssertFalse(try opened.status().offline)
        // Once a change drops it, the listing is fetched again; offline, the last saved one isn't there to fall back on,
        // so a drive without a listing lifetime (below) covers the offline fallback.
        // A zero metadata lifetime sends every stat to the service, so the offline path is exercised.
        var options = ParaAirCloudBackend.Options(); options.capacityLifetime = 0
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        let backend = try ParaAirCloudBackend(driveID: account.driveID, options: options, bindVolume: { _ in }, api: {
            let api = ParaAirCloudAPI(http: try session.http(), tokens: session); api.retryDelays = [0.01]; return api
        })
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("volumes/direct"), minFreeBytes: 0,
                                blockSize: chunk, tuning: EngineTuning(metadataLifetimeNanoseconds: 0))
        XCTAssertEqual(try engine.list("/").map(\.name), ["doc.txt"])
        let online = try engine.stat("/doc.txt")
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8))
        try session.http().offlineBackoffInterval = 60
        fake.injectTransport(.notConnectedToInternet, route: "GET /v1/drives/{d}/stat")
        XCTAssertEqual(try engine.stat("/doc.txt"), online)
        XCTAssertTrue(try engine.status().offline)
        XCTAssertEqual(try engine.read("/doc.txt", offset: 0, length: 6), Data("cached".utf8), "cached content is served offline")
        fake.injectTransport(.notConnectedToInternet, route: "GET /v1/drives/{d}/list", times: 3)
        XCTAssertEqual(try engine.list("/").map(\.name), ["doc.txt"], "offline, the saved listing answers")
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
        // A chunk whose PUT was cut off may go again after 50 ms, never within the attempt that lost it.
        var pacing = ParaAirCloudBackend.Options(); pacing.cutOffChunkWait = 0.05; pacing.longestChunkWait = 0
        let engine = try open(backend: pacing)
        _ = try engine.create("/video.mov", directory: false)
        _ = try engine.write("/video.mov", offset: 0, data: seededBytes(4 << 20, seed: 9))
        for _ in 1...3 {
            let before = try XCTUnwrap(try engine.uploads().first?.transactionID)
            fake.injectTransport(.networkConnectionLost, route: "PUT /v1/drives/{d}/chunks/{sha}")
            Thread.sleep(forTimeInterval: 0.06)
            XCTAssertEqual(try engine.flushUploads().first?.lastErrno, ECONNRESET)
            XCTAssertNotEqual(try engine.uploads().first?.transactionID, before)
            XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
        }
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
        XCTAssertEqual(fake.usedBytes(workspaceID: account.workspaceID), 4 << 20)
    }

    // MARK: A slow or refusing service (docs/speed.md, Bottlenecks 2)

    private let reserveRoute = "POST /v1/drives/{d}/uploads"
    private let putRoute = "PUT /v1/drives/{d}/chunks/{sha}"

    /// Waits until a chunk PUT reached the fake, which holds it (`hang`).
    private func waitForPut() {
        let deadline = Date().addingTimeInterval(5)
        while fake.requests(putRoute).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// Deleting a new file whose upload keeps failing drops its change: the delete doesn't wait for an upload that
    /// can't land, and nothing is uploaded for a file that is going anyway.
    func testDeletingNewFileWhoseUploadFailsDropsIt() throws {
        let engine = try open()
        _ = try engine.create("/draft.bin", directory: false)
        _ = try engine.write("/draft.bin", offset: 0, data: seededBytes(1000, seed: 50))
        fake.inject(route: reserveRoute, status: 503, code: "unavailable", times: 3)
        XCTAssertEqual(try engine.flushUploads().first?.lastErrno, EIO)
        fake.inject(route: reserveRoute, status: 503, code: "unavailable", times: 3)
        fake.clearLog()
        try engine.remove("/draft.bin", directory: false)
        XCTAssertEqual(fake.requests(reserveRoute).count, 0)
        XCTAssertEqual(fake.requests(putRoute).count, 0)
        XCTAssertLessThanOrEqual(fake.requests("POST /v1/drives/{d}/transactions/{tx}/fence").count, 1,
                                 "at most the commit fence, which proves the earlier attempt can't publish later")
        XCTAssertTrue(try engine.uploads().isEmpty)
        expectDriveError(ENOENT) { _ = try engine.stat("/draft.bin") }
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/draft.bin"))
        XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
    }

    /// Deleting a new file stops its upload in flight instead of waiting for it.
    func testDeletingNewFileStopsItsUploadInFlight() throws {
        let engine = try open()
        _ = try engine.create("/inflight.bin", directory: false)
        _ = try engine.write("/inflight.bin", offset: 0, data: seededBytes(1000, seed: 51))
        fake.hang(route: putRoute)
        let flushed = expectation(description: "upload pass ended")
        DispatchQueue.global().async { _ = try? engine.flushUploads(); flushed.fulfill() }
        waitForPut()
        let started = Date()
        try engine.remove("/inflight.bin", directory: false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        wait(for: [flushed], timeout: 2)
        XCTAssertTrue(try engine.uploads().isEmpty)
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/inflight.bin"))
        XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0)
        // The drive goes on uploading other files.
        _ = try engine.create("/next.bin", directory: false)
        _ = try engine.write("/next.bin", offset: 0, data: Data("next".utf8))
        XCTAssertTrue(try engine.flushUploads().isEmpty)
    }

    /// An fsync that waits for the file's upload lock while a delete holds it and drops the change fails with ECANCELED
    /// after the delete ends: it never reports as published data that was discarded. (Getting the lock before the delete
    /// does, it fails the same way: `removing`.)
    func testFsyncWaitingWhileADeleteDropsTheFileFails() throws {
        let engine = try open()
        _ = try engine.create("/raced.bin", directory: false)
        _ = try engine.write("/raced.bin", offset: 0, data: seededBytes(1000, seed: 60))
        // The commit's reply is lost, so the delete asks the commit fence while it holds the file's upload lock.
        fake.injectTransport(.timedOut, route: "POST /v1/drives/{d}/uploads/{u}/commit", times: 3)
        XCTAssertEqual(try engine.flushUploads().first?.lastErrno, ETIMEDOUT)
        fake.delay(route: "POST /v1/drives/{d}/transactions/{tx}/fence", seconds: 0.6)
        let removed = expectation(description: "delete returned")
        let removal = NSMutableArray()
        DispatchQueue.global().async {
            do { try engine.remove("/raced.bin", directory: false); removal.add("removed") } catch { removal.add(error) }
            removed.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while fake.requests("POST /v1/drives/{d}/transactions/{tx}/fence").isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let synced = expectation(description: "fsync returned")
        let outcome = NSMutableArray()
        DispatchQueue.global().async {
            do { try engine.fsync("/raced.bin"); outcome.add("published") } catch { outcome.add(error) }
            synced.fulfill()
        }
        wait(for: [removed, synced], timeout: 5)
        XCTAssertEqual(removal.firstObject as? String, "removed")
        XCTAssertEqual((outcome.firstObject as? DriveError)?.code, ECANCELED, "\(outcome)")
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/raced.bin"))
        XCTAssertTrue(try engine.uploads().isEmpty)
    }

    /// A file that was published keeps the usual delete: storage removes it.
    func testDeletingPublishedFileStillRemovesItInStorage() throws {
        let engine = try open()
        _ = try engine.create("/kept.bin", directory: false)
        _ = try engine.write("/kept.bin", offset: 0, data: Data("kept".utf8))
        XCTAssertTrue(try engine.flushUploads().isEmpty)
        _ = try engine.write("/kept.bin", offset: 4, data: Data(" more".utf8))
        try engine.remove("/kept.bin", directory: false)
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/kept.bin"))
        XCTAssertTrue(try engine.uploads().isEmpty)
    }

    /// Closing the engine (unmount) stops an upload in flight; the change stays for the next mount and the stop isn't
    /// counted as a failed upload.
    func testCloseStopsTheUploadInFlightWithoutCountingAFailure() throws {
        let engine = try open()
        _ = try engine.create("/unmount.bin", directory: false)
        _ = try engine.write("/unmount.bin", offset: 0, data: seededBytes(1000, seed: 52))
        fake.hang(route: putRoute)
        let flushed = expectation(description: "upload pass ended")
        DispatchQueue.global().async { _ = try? engine.flushUploads(); flushed.fulfill() }
        waitForPut()
        engine.close()
        wait(for: [flushed], timeout: 2)
        let record = try XCTUnwrap(try engine.uploads().first)
        XCTAssertEqual(record.path, "/unmount.bin")
        XCTAssertEqual(record.failures, 0); XCTAssertNil(record.lastErrno)
        let reopened = try open()
        XCTAssertTrue(try reopened.flushUploads().isEmpty)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/unmount.bin"), seededBytes(1000, seed: 52))
        XCTAssertEqual(fake.reservedBytes(workspaceID: account.workspaceID), 0,
                       "the next mount resumed the stopped upload instead of reserving the file again")
    }

    /// A delete of a file whose earlier upload may have landed asks the commit fence: landed, it is removed in storage.
    func testDeletingNewFileWhoseUploadLandedRemovesItInStorage() throws {
        let engine = try open()
        _ = try engine.create("/landed.bin", directory: false)
        _ = try engine.write("/landed.bin", offset: 0, data: Data("landed".utf8))
        fake.injectTransport(.networkConnectionLost, route: "POST /v1/drives/{d}/uploads/{u}/commit", times: 3, afterProcessing: true)
        XCTAssertEqual(try engine.flushUploads().first?.lastErrno, ECONNRESET)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/landed.bin"), Data("landed".utf8))
        fake.clearLog()
        try engine.remove("/landed.bin", directory: false)
        XCTAssertEqual(fake.requests("POST /v1/drives/{d}/transactions/{tx}/fence").count, 1)
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/landed.bin"))
        XCTAssertTrue(try engine.uploads().isEmpty)
    }

    /// When the fence can't answer, the change is kept and the delete goes the usual way; if that upload fails too, the
    /// delete fails and the data stays. A later delete, once the fence answers, drops it.
    func testDeletingNewFileKeepsItWhileItsOutcomeIsUnknown() throws {
        let engine = try open()
        _ = try engine.create("/unsure.bin", directory: false)
        _ = try engine.write("/unsure.bin", offset: 0, data: Data("unsure".utf8))
        fake.injectTransport(.timedOut, route: "POST /v1/drives/{d}/uploads/{u}/commit", times: 3)
        XCTAssertEqual(try engine.flushUploads().first?.lastErrno, ETIMEDOUT)
        fake.inject(route: "POST /v1/drives/{d}/transactions/{tx}/fence", status: 503, code: "unavailable", times: 3)
        fake.inject(route: reserveRoute, status: 503, code: "unavailable", times: 3)
        expectDriveError(EIO) { try engine.remove("/unsure.bin", directory: false) }
        XCTAssertEqual(try engine.uploads().map(\.path), ["/unsure.bin"])
        XCTAssertEqual(try engine.read("/unsure.bin", offset: 0, length: 6), Data("unsure".utf8))
        try engine.remove("/unsure.bin", directory: false)
        XCTAssertTrue(try engine.uploads().isEmpty)
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/unsure.bin"))
    }

    /// A volume sync (which macOS also sends on its own) uploads new changes at once but leaves a file whose upload
    /// just failed to its retry time, so syncs don't turn the retry backoff into a storm.
    func testSyncPolicyWaitsForAFailingFilesRetry() throws {
        let engine = try open()
        _ = try engine.create("/failing.bin", directory: false)
        _ = try engine.write("/failing.bin", offset: 0, data: Data("failing".utf8))
        fake.inject(route: reserveRoute, status: 503, code: "unavailable", times: 3)
        XCTAssertEqual(try engine.flushUploads(policy: .sync).first?.lastErrno, EIO)
        _ = try engine.create("/fresh.bin", directory: false)
        _ = try engine.write("/fresh.bin", offset: 0, data: Data("fresh".utf8))
        fake.clearLog()
        XCTAssertEqual(try engine.flushUploads(policy: .sync).map(\.path), ["/failing.bin"])
        XCTAssertEqual(fake.requests(reserveRoute).count, 1, "only the new file was sent")
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/fresh.bin"), Data("fresh".utf8))
        XCTAssertTrue(try engine.flushUploads(policy: .immediate).isEmpty, "an explicit retry still goes at once")
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

    // 2026-11-26 production review: a commit that applied but whose reply was lost, followed by a throttled retry and a
    // throttled fence, was reported as never sent. The engine started the file's upload over, so the user's own file
    // came back as a conflict; deleting it instead left the published copy in storage.
    func testAppliedCommitWhoseRetryIsThrottledSettlesAsPublished() throws {
        let commit = "POST /v1/drives/{d}/uploads/{u}/commit", fence = "POST /v1/drives/{d}/transactions/{tx}/fence"
        let engine = try open()
        let data = seededBytes(1000, seed: 901)
        _ = try engine.create("/applied.bin", directory: false)
        _ = try engine.write("/applied.bin", offset: 0, data: data)
        fake.injectTransport(.timedOut, route: commit, afterProcessing: true)
        fake.inject(route: commit, status: 429, code: "rate_limited", retryAfter: 60)
        fake.inject(route: fence, status: 429, code: "rate_limited", retryAfter: 60)
        _ = try engine.flushUploads()
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/applied.bin"), data)
        let second = try engine.flushUploads()
        XCTAssertTrue(second.isEmpty, "our own applied upload must settle, not become a pending conflict: \(second.map { "\($0.path) \($0.state)" })")
    }

    func testDeletingAFileWhoseCommitMayHaveAppliedRemovesItFromStorage() throws {
        let commit = "POST /v1/drives/{d}/uploads/{u}/commit", fence = "POST /v1/drives/{d}/transactions/{tx}/fence"
        let engine = try open()
        let data = seededBytes(1000, seed: 904)
        _ = try engine.create("/zombie.bin", directory: false)
        _ = try engine.write("/zombie.bin", offset: 0, data: data)
        fake.injectTransport(.timedOut, route: commit, afterProcessing: true)
        fake.inject(route: commit, status: 429, code: "rate_limited", retryAfter: 10)
        fake.inject(route: fence, status: 429, code: "rate_limited", retryAfter: 10)
        _ = try engine.flushUploads()
        try engine.remove("/zombie.bin", directory: false)
        XCTAssertNil(fake.contents(driveID: account.driveID, path: "/zombie.bin"), "a file the user deleted must not stay in storage")
    }
}
