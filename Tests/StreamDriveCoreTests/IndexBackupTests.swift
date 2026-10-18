import XCTest
import Darwin
@testable import StreamDriveCore

/// Local fixture storage standing in for a drive whose index lives on this Mac.
private final class IndexedBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    private let lock = NSLock()
    private var count = 0
    /// nil: the index is not local. A thrown error: the upload failed.
    var outcome: () throws -> String? = { "meta/dump" }
    private(set) var replaced: [String?] = []
    var duringBackup: (() -> Void)?
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    var backups: Int { lock.lock(); defer { lock.unlock() }; return count }
    func backupIndex(replacing previous: String?) throws -> String? {
        lock.lock(); count += 1; replaced.append(previous); lock.unlock()
        duringBackup?()
        return try outcome()
    }
    func stat(_ p: String) throws -> FileEntry { try base.stat(p) }
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

final class IndexBackupTests: XCTestCase {
    private var work: URL!
    private var backend: IndexedBackend!
    private var drive: Engine!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        backend = try IndexedBackend(work.appendingPathComponent("remote"))
        drive = try Engine(backend: backend, stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 1 << 20,
                           minFreeBytes: 0, blockSize: 4096, maxJournalBytes: 1 << 20)
    }
    override func tearDownWithError() throws { drive = nil; try FileManager.default.removeItem(at: work) }

    private func publish(_ path: String) throws {
        _ = try drive.create(path, directory: false)
        _ = try drive.write(path, offset: 0, data: Data("content".utf8))
        _ = try drive.flushUploads(policy: .immediate)
    }
    private let hourly = IndexBackupPolicy(quietNanoseconds: 0, maxDelayNanoseconds: 0, retryNanoseconds: 3_600_000_000_000)

    func testNothingToBackUpWithoutChanges() throws {
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertEqual(backend.backups, 0)
        XCTAssertNil(try drive.status().indexBackup)
    }

    func testBacksUpOnceChangesReachStorage() throws {
        _ = try drive.create("/draft", directory: false)
        _ = try drive.write("/draft", offset: 0, data: Data("local only".utf8))
        // An unpublished write is not in the index yet.
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        _ = try drive.flushUploads(policy: .immediate)
        // The standard policy waits for changes to go quiet.
        XCTAssertFalse(try drive.backupIndexIfDue())
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertEqual(backend.backups, 1)
        let status = try XCTUnwrap(try drive.status().indexBackup)
        XCTAssertNotNil(status.lastBackupNanoseconds)
        XCTAssertNil(status.pendingSinceNanoseconds)
        XCTAssertNil(status.lastError)
    }

    func testNamespaceChangesNeedABackup() throws {
        _ = try drive.create("/folder", directory: true)
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        try publish("/folder/a")
        try drive.move("/folder/a", to: "/folder/b")
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        try drive.remove("/folder/b", directory: false)
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        // Housekeeping never reaches storage, so it never needs a backup.
        _ = try drive.create("/folder/.DS_Store", directory: false)
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertEqual(backend.backups, 3)
        // Each backup names the one before it, for storage that cannot rotate.
        XCTAssertEqual(backend.replaced, [nil, "meta/dump", "meta/dump"])
    }

    func testFailuresAreReportedAndRetriedAfterBackoff() throws {
        try publish("/file")
        backend.outcome = { throw DriveError(ENETDOWN, "offline") }
        XCTAssertThrowsError(try drive.backupIndexIfDue(policy: .immediate))
        let failed = try XCTUnwrap(try drive.status().indexBackup)
        XCTAssertEqual(failed.lastError, "offline")
        XCTAssertNotNil(failed.pendingSinceNanoseconds)
        backend.outcome = { "meta/dump" }
        XCTAssertFalse(try drive.backupIndexIfDue(policy: hourly), "retried inside the backoff")
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertNil(try drive.status().indexBackup?.lastError)
        XCTAssertEqual(backend.backups, 2)
    }

    func testDrivesWithoutALocalIndexStopTracking() throws {
        backend.outcome = { nil }
        try publish("/file")
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        try publish("/other")
        XCTAssertFalse(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertEqual(backend.backups, 1)
        XCTAssertNil(try drive.status().indexBackup)
    }

    func testAChangeDuringTheBackupStaysPending() throws {
        try publish("/file")
        backend.duringBackup = { [unowned self] in
            backend.duringBackup = nil
            _ = try? drive.create("/made-during-backup", directory: true)
        }
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertNotNil(try drive.status().indexBackup?.pendingSinceNanoseconds)
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
        XCTAssertNil(try drive.status().indexBackup?.pendingSinceNanoseconds)
    }

    func testPendingChangesSurviveRestart() throws {
        try publish("/file")
        drive = nil
        drive = try Engine(backend: backend, stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 1 << 20,
                           minFreeBytes: 0, blockSize: 4096, maxJournalBytes: 1 << 20)
        XCTAssertTrue(try drive.backupIndexIfDue(policy: .immediate))
    }
}
