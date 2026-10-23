import XCTest
import Darwin
@testable import StreamDriveCore

/// Local fixture storage that can refuse commits and report another Mac as the owner.
private final class RefusingBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    private let lock = NSLock()
    private var refusal: DriveError?
    private var currentOwner: StorageOwnership?
    /// Thrown by every commit until cleared.
    var commitError: DriveError? { get { lock.withLock { refusal } } set { lock.withLock { refusal = newValue } } }
    var owner: StorageOwnership? { get { lock.withLock { currentOwner } } set { lock.withLock { currentOwner = newValue } } }
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    func ownership(refresh: Bool) throws -> StorageOwnership? { owner }
    func stat(_ p: String) throws -> FileEntry { try base.stat(p) }
    func list(_ p: String) throws -> [FileEntry] { try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data { try base.read(p, offset: offset, length: length) }
    func commit(_ c: FileCommit) throws -> FileEntry {
        if let error = commitError { throw error }
        return try base.commit(c)
    }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func createDirectory(_ p: String) throws -> FileEntry { try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { try base.remove(p, directory: directory) }
}

final class DecisionTests: XCTestCase {
    private var work: URL!
    private var remote: URL!
    private var backend: RefusingBackend!
    private var drive: Engine!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        remote = work.appendingPathComponent("remote")
        backend = try RefusingBackend(remote)
        drive = try Engine(backend: backend, stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 1 << 20,
                           minFreeBytes: 0, blockSize: 4096, maxJournalBytes: 1 << 20)
    }
    override func tearDownWithError() throws { drive = nil; try FileManager.default.removeItem(at: work) }

    private func seed(_ name: String, _ text: String) throws {
        let url = remote.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func remoteText(_ name: String) throws -> String { String(decoding: try Data(contentsOf: remote.appendingPathComponent(name)), as: UTF8.self) }
    private func text(_ path: String) throws -> String { String(decoding: try drive.read(path, offset: 0, length: 1 << 20), as: UTF8.self) }
    private func expectError(_ code: Int32, _ action: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? DriveError)?.code, code, file: file, line: line) }
    }
    private var clock: Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }
    /// A local edit of `path` made while another device replaced the file in storage. Without
    /// an offset the edit replaces the whole file; with one it changes only those bytes.
    private func conflict(_ path: String, local: String, at offset: Int64? = nil, remoteText: String) throws {
        if offset == nil { try drive.truncate(path, size: 0) }
        _ = try drive.write(path, offset: offset ?? 0, data: Data(local.utf8))
        try seed(String(path.dropFirst()), remoteText)
        expectError(ESTALE, try drive.fsync(path))
        XCTAssertEqual(try drive.uploads().first { $0.path == path }?.state, "conflict")
    }

    // MARK: Failing uploads

    func testUploadsThatKeepFailingCrossThePolicy() throws {
        let started = clock
        _ = try drive.create("/new.txt", directory: false)
        _ = try drive.write("/new.txt", offset: 0, data: Data("hello".utf8))
        backend.commitError = DriveError(EACCES, "Access denied", disposition: .attemptNotDispatched)
        for attempt in 1...4 {
            let record = try XCTUnwrap(try drive.flushUploads().first)
            XCTAssertEqual(record.failures, attempt)
            XCTAssertEqual(record.lastErrno, EACCES)
            XCTAssertEqual(record.isFailing(now: clock), attempt >= 4, "after \(attempt) failures")
        }
        let record = try XCTUnwrap(try drive.uploads().first)
        let since = try XCTUnwrap(record.failingSinceNanoseconds)
        XCTAssertGreaterThanOrEqual(since, started)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(record.pendingSinceNanoseconds), started)
        XCTAssertLessThanOrEqual(try XCTUnwrap(record.pendingSinceNanoseconds), since, "the change came before its first failure")
        let status = try XCTUnwrap(try drive.status().failingUploads)
        XCTAssertEqual(status, UploadFailureSummary(count: 1, errno: EACCES, oldestChangeNanoseconds: record.pendingSinceNanoseconds!))
        // Uploading again ends the run of failures.
        backend.commitError = nil
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertNil(try drive.status().failingUploads)
    }

    func testOneFailureCountsOnceItHasLastedLongEnough() throws {
        _ = try drive.create("/new.txt", directory: false)
        backend.commitError = DriveError(ENETDOWN, "Offline", disposition: .attemptNotDispatched)
        let record = try XCTUnwrap(try drive.flushUploads().first)
        let since = try XCTUnwrap(record.failingSinceNanoseconds)
        let quarterHour = UploadFailurePolicy(minFailures: 100, minDurationNanoseconds: 900_000_000_000)
        XCTAssertFalse(record.isFailing(now: since + 899_000_000_000, policy: quarterHour))
        XCTAssertTrue(record.isFailing(now: since + 900_000_000_000, policy: quarterHour))
        // A clock that went back never makes a file look failing.
        XCTAssertFalse(record.isFailing(now: since - 1, policy: UploadFailurePolicy(minFailures: 100, minDurationNanoseconds: 0)))
    }

    func testSummaryNamesTheMostCommonCauseAndTheOldestChange() {
        func record(_ path: String, _ code: Int32?, since: Int64, state: String = "pending") -> UploadRecord {
            UploadRecord(transactionID: UUID().uuidString, path: path, logicalSize: 1, pendingBytes: 1, state: state, lastError: nil,
                         lastErrno: code, failures: 9, failingSinceNanoseconds: since, pendingSinceNanoseconds: since, modifiedNanoseconds: since)
        }
        let uploads = [record("/a", EIO, since: 300), record("/b", ENETDOWN, since: 100), record("/c", ENETDOWN, since: 200),
                       record("/d", nil, since: 50), record("/e", EROFS, since: 10), record("/f", ESTALE, since: 20, state: "conflict")]
        let summary = UploadFailureSummary.make(uploads, now: 1_000)
        XCTAssertEqual(summary, UploadFailureSummary(count: 3, errno: ENETDOWN, oldestChangeNanoseconds: 100),
                       "Waiting files and changes that need a decision aren't failures")
        XCTAssertEqual(UploadFailureSummary.make(uploads, now: 1_000, excluding: { $0.lastErrno == ENETDOWN })?.errno, EIO)
        XCTAssertNil(UploadFailureSummary.make([record("/d", nil, since: 50)], now: 1_000))
        // A tie goes to the lower errno, so the cause doesn't flicker between polls.
        XCTAssertEqual(UploadFailureSummary.make([record("/a", EIO, since: 1), record("/b", ETIMEDOUT, since: 1)], now: 9)?.errno, EIO)
    }

    func testReasonsAreInPlainWords() {
        XCTAssertEqual(UploadFailureReason.text(ETIMEDOUT, cloud: false), "your storage can’t be reached")
        XCTAssertEqual(UploadFailureReason.text(ETIMEDOUT, cloud: true), "ParaAir Cloud can’t be reached")
        XCTAssertEqual(UploadFailureReason.text(EACCES, cloud: false), "your storage refused access; its key may have been revoked")
        XCTAssertEqual(UploadFailureReason.text(ENOENT, cloud: false), "the bucket, or the drive’s folder in it, is missing")
        XCTAssertEqual(UploadFailureReason.text(EDQUOT, cloud: false), "your storage is full")
        XCTAssertEqual(UploadFailureReason.text(EIO, cloud: false), "your storage didn’t accept the upload")
        XCTAssertEqual(UploadFailureReason.text(EPROTONOSUPPORT, cloud: false), "the upload failed (error \(EPROTONOSUPPORT))")
    }

    // MARK: Changes that need a decision

    func testConflictsAndRefusedChangesNeedADecisionAndAreNotFailures() throws {
        try seed("shared.txt", "original")
        try conflict("/shared.txt", local: "mine", remoteText: "theirs!!")
        _ = try drive.create("/refused.txt", directory: false)
        backend.commitError = DriveError(EROFS, "Read-only", disposition: .attemptNotDispatched)
        for _ in 1...5 { _ = try drive.flushUploads() }
        let decisions = try drive.changesNeedingDecision()
        XCTAssertEqual(Set(decisions.map(\.path)), ["/shared.txt", "/refused.txt"])
        XCTAssertFalse(decisions.contains { $0.isFailing(now: clock) })
        XCTAssertNil(try drive.status().failingUploads)
    }

    func testKeepMineSavesTheCopyBesideTheOriginal() throws {
        try seed("doc.txt", "original")
        try conflict("/doc.txt", local: "my edit", remoteText: "their edit")
        let name = try drive.suggestedCopyName(for: "/doc.txt", date: Date(timeIntervalSince1970: 907_200))
        XCTAssertEqual(name, "doc (conflict 1970-01-11).txt")
        let copy = try drive.keepMine("/doc.txt", as: name)
        XCTAssertEqual(copy.path, "/" + name)
        XCTAssertEqual(try text("/doc.txt"), "their edit", "the original shows the version in storage")
        XCTAssertEqual(try text("/" + name), "my edit")
        XCTAssertTrue(try drive.flushUploads().isEmpty, "the copy uploads like any new file")
        XCTAssertEqual(try remoteText(name), "my edit")
        XCTAssertEqual(try remoteText("doc.txt"), "their edit")
        XCTAssertTrue(try drive.changesNeedingDecision().isEmpty)
    }

    func testKeepMineCarriesThePartsSharedWithTheEarlierVersion() throws {
        try seed("clip.bin", "abcdefghij")
        XCTAssertEqual(try text("/clip.bin"), "abcdefghij") // the earlier version is now cached
        try conflict("/clip.bin", local: "XY", at: 2, remoteText: "0123456789")
        _ = try drive.keepMine("/clip.bin", as: "clip mine.bin")
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try remoteText("clip mine.bin"), "abXYefghij")
        XCTAssertEqual(try remoteText("clip.bin"), "0123456789")
    }

    func testKeepMineChangesNothingWhenTheEarlierVersionIsGone() throws {
        try seed("clip.bin", "abcdefghij")
        _ = try drive.stat("/clip.bin") // known, but none of its blocks cached
        try conflict("/clip.bin", local: "XY", at: 2, remoteText: "0123456789")
        let before = try XCTUnwrap(try drive.uploads().first)
        expectError(ESTALE, try drive.keepMine("/clip.bin", as: "clip mine.bin"))
        let after = try XCTUnwrap(try drive.uploads().first)
        XCTAssertEqual(after.path, "/clip.bin"); XCTAssertEqual(after.transactionID, before.transactionID)
        XCTAssertEqual(after.state, "conflict")
        expectError(ENOENT, try drive.stat("/clip mine.bin"))
        // Only the version in storage can be kept now.
        try drive.keepTheirs("/clip.bin")
        XCTAssertEqual(try text("/clip.bin"), "0123456789")
    }

    func testKeepMineRefusesTakenAndInvalidNames() throws {
        try seed("doc.txt", "original"); try seed("other.txt", "x")
        try conflict("/doc.txt", local: "mine", remoteText: "theirs")
        expectError(EEXIST, try drive.keepMine("/doc.txt", as: "other.txt"))
        expectError(EINVAL, try drive.keepMine("/doc.txt", as: "a/b"))
        expectError(EINVAL, try drive.keepMine("/doc.txt", as: "doc.txt"))
        expectError(EINVAL, try drive.keepMine("/doc.txt", as: ".DS_Store"))
        XCTAssertEqual(try drive.uploads().first?.state, "conflict", "nothing changed")
        // Noon UTC on 11 January 1970 is that date in every time zone.
        let day = Date(timeIntervalSince1970: 907_200)
        XCTAssertEqual(Engine.copyName("doc.txt", date: day) { $0 == "doc (conflict 1970-01-11).txt" }, "doc (conflict 1970-01-11 2).txt")
        XCTAssertEqual(Engine.copyName("a.tar.gz", date: day) { _ in false }, "a.tar (conflict 1970-01-11).gz")
        XCTAssertEqual(Engine.copyName(".env", date: day) { _ in false }, ".env (conflict 1970-01-11)")
    }

    func testKeepTheirsDropsOnlyThisMacsCopy() throws {
        try seed("doc.txt", "original")
        try conflict("/doc.txt", local: "mine", remoteText: "theirs")
        _ = try drive.create("/waiting.txt", directory: false)
        try drive.keepTheirs("/doc.txt")
        XCTAssertEqual(try text("/doc.txt"), "theirs")
        XCTAssertEqual(try drive.uploads().map(\.path), ["/waiting.txt"])
        // A change that can still upload is never discarded here.
        expectError(ENOENT, try drive.keepTheirs("/waiting.txt"))
        expectError(ENOENT, try drive.keepMine("/waiting.txt", as: "copy.txt"))
        XCTAssertEqual(try drive.uploads().map(\.path), ["/waiting.txt"])
    }

    func testFolderRenamesAndRemovalsWorkOnceResolved() throws {
        try seed("folder/a.txt", "original"); try seed("folder/b.txt", "original")
        try conflict("/folder/a.txt", local: "mine", remoteText: "theirs")
        try conflict("/folder/b.txt", local: "mine too", remoteText: "theirs too")
        expectError(ESTALE, try drive.move("/folder", to: "/renamed"))
        _ = try drive.keepMine("/folder/a.txt", as: "a mine.txt")
        try drive.keepTheirs("/folder/b.txt")
        try drive.move("/folder", to: "/renamed")
        XCTAssertEqual(try remoteText("renamed/a mine.txt"), "mine")
        XCTAssertEqual(try remoteText("renamed/a.txt"), "theirs")
        XCTAssertEqual(try remoteText("renamed/b.txt"), "theirs too")
        for name in ["a mine.txt", "a.txt", "b.txt"] { try drive.remove("/renamed/" + name, directory: false) }
        try drive.remove("/renamed", directory: true)
        XCTAssertTrue(try drive.uploads().isEmpty)
    }

    func testRefusedChangesExportOutsideTheDrive() throws {
        try seed("report.txt", "original")
        _ = try drive.write("/report.txt", offset: 0, data: Data("edited here".utf8))
        // Another Mac took over: storage refuses the upload, and the drive refuses new files.
        backend.owner = StorageOwnership(ownedElsewhere: true, ownerName: "Laptop")
        backend.commitError = DriveError(EROFS, "Read-only", disposition: .attemptNotDispatched)
        _ = try drive.flushUploads()
        XCTAssertEqual(try drive.changesNeedingDecision().first?.lastErrno, EROFS)
        expectError(EROFS, try drive.keepMine("/report.txt", as: "report mine.txt"))
        let exports = work.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let taken = exports.appendingPathComponent("report.txt")
        try Data("keep me".utf8).write(to: taken)
        expectError(EEXIST, try drive.exportChange("/report.txt", to: taken))
        XCTAssertEqual(try Data(contentsOf: taken), Data("keep me".utf8), "an existing file stays unless replacing")
        XCTAssertEqual(try drive.changesNeedingDecision().count, 1, "a failed export keeps the change")
        try drive.exportChange("/report.txt", to: taken, replacing: true)
        XCTAssertEqual(try Data(contentsOf: taken), Data("edited here".utf8))
        XCTAssertTrue(try drive.uploads().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exports.path), ["report.txt"], "no staged file is left behind")
        XCTAssertEqual(try text("/report.txt"), "original")
    }

    func testConflictsExportToo() throws {
        try seed("notes.txt", "original")
        try conflict("/notes.txt", local: "local notes", remoteText: "remote notes")
        let destination = work.appendingPathComponent("notes copy.txt")
        try drive.exportChange("/notes.txt", to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "local notes")
        XCTAssertEqual(try text("/notes.txt"), "remote notes")
        XCTAssertTrue(try drive.changesNeedingDecision().isEmpty)
    }
}
