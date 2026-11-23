import XCTest
import Darwin
@testable import StreamDriveCore

/// Several Macs on one ParaAir Cloud drive: conflict copies and their records, refused changes, the change feed,
/// version history and folder rules, over the real Engine and the in-memory service.
final class CollaborationTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var vault: TestConnectionVault!
    private var record: CloudAccount!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = TestConnectionVault()
        record = try fake.saveAccount(account, root: root, vault: vault)
    }

    /// One Mac: its own state folder and profile on the shared drive.
    private func mac(_ name: String, conflictCopies: Bool = true) throws -> Engine {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let saved = try fake.saveAccount(account, root: folder, vault: vault, id: record.id)
        var profile = try CloudDriveSetup.attach(driveID: account.driveID, finderName: name, name: name, accountID: saved.id,
                                                 stateRoot: folder, dependencies: fake.dependencies(vault: vault))
        profile.conflictCopies = conflictCopies
        return try Engine.open(profile: profile, stateRoot: folder, dependencies: fake.dependencies(vault: vault))
    }
    private func api() throws -> ParaAirCloudAPI {
        let session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                              policy: .init(allowsLoopbackHTTP: false))
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }
    private func save(_ engine: Engine, _ path: String, _ text: String) throws {
        if (try? engine.stat(path)) == nil { _ = try engine.create(path, directory: false) }
        try engine.truncate(path, size: 0)
        _ = try engine.write(path, offset: 0, data: Data(text.utf8))
    }
    private func text(_ path: String) -> String? { fake.contents(driveID: account.driveID, path: path).map { String(decoding: $0, as: UTF8.self) } }
    private func copyName(_ name: String) -> String { Engine.copyName(name, date: Date()) { _ in false } }

    func testAConflictKeepsTheirVersionAndUploadsThisMacsCopyBesideIt() throws {
        let a = try mac("a"), b = try mac("b")
        _ = try a.create("/records", directory: true)
        try save(a, "/records/r1.json", "{\"name\":\"base\"}")
        XCTAssertTrue(try a.flushUploads().isEmpty)
        let base = try a.stat("/records/r1.json").version
        // Both Macs edit the same record; b saves first.
        try save(b, "/records/r1.json", "{\"name\":\"theirs\"}")
        XCTAssertTrue(try b.flushUploads().isEmpty)
        let theirs = try XCTUnwrap(fake.contents(driveID: account.driveID, path: "/records/r1.json")).count
        XCTAssertGreaterThan(theirs, 0)
        try save(a, "/records/r1.json", "{\"name\":\"mine\"}")

        XCTAssertTrue(try a.flushUploads().isEmpty, "nothing waits for a decision")
        let copy = "/records/" + copyName("r1.json")
        XCTAssertEqual(text("/records/r1.json"), "{\"name\":\"theirs\"}", "storage keeps the version that won, unmerged")
        XCTAssertEqual(text(copy), "{\"name\":\"mine\"}")
        XCTAssertEqual(String(decoding: try a.read("/records/r1.json", offset: 0, length: 100), as: UTF8.self), "{\"name\":\"theirs\"}")
        XCTAssertEqual(try a.list("/records").map(\.name).sorted(), [copyName("r1.json"), "r1.json"].sorted())

        let winner = try api().stat(driveID: account.driveID, path: "/records/r1.json").version
        let info = try XCTUnwrap(try a.conflictCopyInfo(copy))
        XCTAssertEqual(info.original, "/records/r1.json"); XCTAssertEqual(info.baseVersion, base); XCTAssertEqual(info.theirsVersion, winner)
        XCTAssertEqual(info.source, "this-mac")
        // Once the copy is in storage its record is too, so another Mac can answer.
        XCTAssertEqual(fake.count("PUT /v1/drives/{d}/conflicts"), 1)
        let elsewhere = try XCTUnwrap(try b.conflictCopyInfo(copy))
        XCTAssertEqual(elsewhere.source, "service"); XCTAssertEqual(elsewhere.original, "/records/r1.json")
        XCTAssertEqual(elsewhere.baseVersion, base); XCTAssertEqual(elsewhere.theirsVersion, winner)
        XCTAssertEqual(elsewhere.author?.email, account.email)
        XCTAssertNil(try b.conflictCopyInfo("/records/r1.json"))

        // A second conflict on the same day takes the next name.
        try save(b, "/records/r1.json", "{\"name\":\"theirs again\"}")
        XCTAssertTrue(try b.flushUploads().isEmpty)
        try save(a, "/records/r1.json", "{\"name\":\"mine again\"}")
        XCTAssertTrue(try a.flushUploads().isEmpty)
        let second = "/records/" + Engine.copyName("r1.json", date: Date()) { $0 == self.copyName("r1.json") }
        XCTAssertEqual(text(second), "{\"name\":\"mine again\"}")
    }

    func testWithoutConflictCopiesAConflictStillWaitsForADecision() throws {
        let a = try mac("a", conflictCopies: false), b = try mac("b")
        try save(a, "/doc.txt", "one"); XCTAssertTrue(try a.flushUploads().isEmpty)
        try save(b, "/doc.txt", "two"); XCTAssertTrue(try b.flushUploads().isEmpty)
        try save(a, "/doc.txt", "three")
        XCTAssertEqual(try a.flushUploads().map(\.state), ["conflict"])
        XCTAssertEqual(try a.changesNeedingDecision().count, 1)
        // resolve --keep-mine-as records where the copy came from as well.
        let copy = try a.keepMine("/doc.txt", as: "doc mine.txt")
        XCTAssertEqual(try a.conflictCopyInfo(copy.path)?.original, "/doc.txt")
    }

    func testAWriteToAConflictedFileSavesTheCopyAndGoesOnTheirVersion() throws {
        let a = try mac("a"), b = try mac("b")
        try save(a, "/notes.md", "base"); XCTAssertTrue(try a.flushUploads().isEmpty)
        try save(b, "/notes.md", "theirs"); XCTAssertTrue(try b.flushUploads().isEmpty)
        try save(a, "/notes.md", "mine")
        XCTAssertThrowsError(try a.fsync("/notes.md")) { XCTAssertEqual(($0 as? DriveError)?.code, ESTALE) }
        // fsync already saved the copy and uploaded it, so the next save starts on their version.
        XCTAssertEqual(text("/" + copyName("notes.md")), "mine")
        try save(a, "/notes.md", "after")
        XCTAssertTrue(try a.flushUploads().isEmpty)
        XCTAssertEqual(text("/notes.md"), "after")
    }

    func testAChangeTheFolderRulesRefuseWaitsForADecisionAndCanBeSavedAsANewFile() throws {
        let a = try mac("a", conflictCopies: false)
        try save(a, "/claims.txt", "one")
        fake.inject(route: "POST /v1/drives/{d}/uploads", status: 403, code: "forbidden")
        let remaining = try a.flushUploads()
        XCTAssertEqual(remaining.map(\.lastErrno), [EPERM])
        XCTAssertTrue(remaining[0].needsDecision); XCTAssertFalse(remaining[0].isFailing(now: .max))
        XCTAssertEqual(try a.changesNeedingDecision().map(\.path), ["/claims.txt"])
        XCTAssertEqual(UploadFailureReason.text(EPERM, cloud: true), "your ParaAir Cloud access doesn’t allow these changes")
        let copy = try a.keepMine("/claims.txt", as: "claims mine.txt")
        XCTAssertTrue(try a.flushUploads().isEmpty)
        XCTAssertEqual(text(copy.path), "one")
    }

    func testTheChangeFeedDropsCachedMetadataAndNamesTheFoldersToRefresh() throws {
        let a = try mac("a"), b = try mac("b")
        _ = try a.create("/records", directory: true)
        try save(a, "/records/r.json", "1"); XCTAssertTrue(try a.flushUploads().isEmpty)
        let start = try XCTUnwrap(try b.followChanges(consumer: "test"))
        XCTAssertTrue(start.changes.isEmpty)
        let before = try b.stat("/records/r.json").version
        try save(a, "/records/r.json", "22"); XCTAssertTrue(try a.flushUploads().isEmpty)
        _ = try a.create("/people", directory: true)
        XCTAssertEqual(try b.stat("/records/r.json").version, before, "within the metadata lifetime the cache answers")

        let batch = try XCTUnwrap(try b.followChanges(consumer: "test"))
        XCTAssertEqual(batch.changes.map(\.path), ["/records/r.json", "/people"])
        XCTAssertEqual(batch.changes.map(\.change), ["write", "mkdir"])
        XCTAssertEqual(batch.folders, ["/records", "/", "/people"])
        XCTAssertFalse(batch.reset)
        XCTAssertNotEqual(try b.stat("/records/r.json").version, before, "the change reached this Mac at once")
        XCTAssertEqual(String(decoding: try b.read("/records/r.json", offset: 0, length: 10), as: UTF8.self), "22")
        XCTAssertTrue(try XCTUnwrap(try b.followChanges(consumer: "test")).changes.isEmpty, "the cursor moved on")

        fake.pruneChanges()
        let reset = try XCTUnwrap(try b.followChanges(consumer: "test"))
        XCTAssertTrue(reset.reset); XCTAssertEqual(reset.folders, ["/"])
        let page = try b.readChanges(since: reset.cursor)
        XCTAssertFalse(page.reset)
    }

    func testVersionHistoryRestoreAndReadingAnOldVersion() throws {
        let a = try mac("a")
        try save(a, "/doc.txt", "first"); XCTAssertTrue(try a.flushUploads().isEmpty)
        let first = try a.stat("/doc.txt").version
        try save(a, "/doc.txt", "second!"); XCTAssertTrue(try a.flushUploads().isEmpty)
        let second = try a.stat("/doc.txt").version
        let api = try api()
        let page = try api.versions(driveID: account.driveID, path: "/doc.txt", before: nil, limit: 1)
        XCTAssertEqual(page.versions.map(\.version), [second]); XCTAssertEqual(page.versions.first?.current, true)
        XCTAssertEqual(page.versions.first?.author.email, account.email)
        let older = try api.versions(driveID: account.driveID, path: "/doc.txt", before: try XCTUnwrap(page.nextBefore), limit: 10)
        XCTAssertEqual(older.versions.map(\.version), [first]); XCTAssertNil(older.nextBefore)
        XCTAssertNotNil(older.versions.first?.expiresAt)
        XCTAssertEqual(try a.readVersion("/doc.txt", version: first, offset: 0, length: 100), Data("first".utf8))

        XCTAssertThrowsError(try api.restoreVersion(driveID: account.driveID, path: "/doc.txt", version: first, expectedVersion: first, idempotencyKey: UUID())) {
            XCTAssertEqual(($0 as? DriveError)?.code, ESTALE)
        }
        XCTAssertThrowsError(try api.restoreVersion(driveID: account.driveID, path: "/doc.txt", version: "pv:999999", expectedVersion: nil, idempotencyKey: UUID())) {
            XCTAssertEqual(($0 as? DriveError)?.code, ENOENT)
        }
        let restored = try api.restoreVersion(driveID: account.driveID, path: "/doc.txt", version: first, expectedVersion: second, idempotencyKey: UUID())
        XCTAssertNotEqual(restored.version, first)
        XCTAssertEqual(text("/doc.txt"), "first")
        try a.noteStorageChanged("/doc.txt")
        XCTAssertEqual(try a.stat("/doc.txt").version, restored.version)
    }

    func testFolderRulesRoundTrip() throws {
        let api = try api()
        let rule = try api.setAccess(driveID: account.driveID, principal: .role("members"), path: "/claims", access: .create)
        XCTAssertEqual(rule.role, "members"); XCTAssertEqual(rule.access, "create"); XCTAssertEqual(rule.path, "/claims")
        _ = try api.setAccess(driveID: account.driveID, principal: .email("ann@example.test"), path: "/admin", access: ParaAirCloudAccessLevel.none)
        XCTAssertEqual(try api.accessRules(driveID: account.driveID).map(\.path), ["/admin", "/claims"])
        try api.removeAccess(driveID: account.driveID, principal: .role("members"), path: "/claims")
        XCTAssertEqual(try api.accessRules(driveID: account.driveID).map(\.path), ["/admin"])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys.map { $0 } ?? []), ["role", "path", "access", "updatedAt"])
    }
}

/// Local storage whose stat can be held after it has read the file, to stand for a request in flight in another process.
private final class HeldStatBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    private let lock = NSLock()
    private var holdNext = false
    let fetched = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    func holdNextStat() { lock.withLock { holdNext = true } }
    func stat(_ p: String) throws -> FileEntry {
        let entry = try base.stat(p)
        if lock.withLock({ defer { holdNext = false }; return holdNext }) { fetched.signal(); release.wait() }
        return entry
    }
    func list(_ p: String) throws -> [FileEntry] { try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data { try base.read(p, offset: offset, length: length) }
    func commit(_ c: FileCommit) throws -> FileEntry { try base.commit(c) }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func createDirectory(_ p: String) throws -> FileEntry { try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { try base.remove(p, directory: directory) }
}

final class RemoteInvalidationTests: XCTestCase {
    func testAStatInFlightInAnotherProcessDoesNotRecordWhatTheFeedInvalidated() throws {
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let remote = work.appendingPathComponent("remote"), state = work.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: remote.appendingPathComponent("r.json"))
        let held = try HeldStatBackend(remote)
        let tuning = EngineTuning(metadataLifetimeNanoseconds: 60_000_000_000)
        // The mounted drive's engine, and the app's, which follows the feed: one state, two instances.
        let mount = try Engine(backend: held, stateDirectory: state, minFreeBytes: 0, blockSize: 4096, tuning: tuning)
        let follower = try Engine(backend: try LocalDirectoryBackend(root: remote), stateDirectory: state, minFreeBytes: 0, blockSize: 4096, tuning: tuning)
        held.holdNextStat()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? mount.stat("/r.json"); done.signal() }
        held.fetched.wait()
        // The file changes, and the feed says so, while that stat is still on its way back with v1.
        try Data("v2-new".utf8).write(to: remote.appendingPathComponent("r.json"))
        try follower.applyRemoteChanges([ParaAirCloudChange(cursor: 1, change: "write", kind: "file", path: "/r.json", at: "", author: ParaAirCloudAuthor())])
        held.release.signal(); done.wait()
        XCTAssertEqual(try mount.stat("/r.json").size, 6, "the late answer wasn't recorded, so the next stat asks storage")
    }
}

