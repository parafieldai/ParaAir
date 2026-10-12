import XCTest
import Darwin
@testable import StreamDriveCore

final class StateLockTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/state-lock-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testHeldByCurrentThreadIsReportedOnlyToTheHolder() throws {
        let lock = try StateLock(root.appendingPathComponent("state.lock"))
        XCTAssertFalse(lock.isHeldByCurrentThread)
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? lock.withLock { entered.signal(); _ = leave.wait(timeout: .now() + 5) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(lock.isHeldByCurrentThread, "Another thread's hold is not this thread's")
        XCTAssertThrowsError(try lock.withLock(timeout: 0.05) {}) { XCTAssertEqual(($0 as? DriveError)?.code, EBUSY) }
        leave.signal()
        try lock.withLock {
            XCTAssertTrue(lock.isHeldByCurrentThread)
            try lock.withLock { XCTAssertTrue(lock.isHeldByCurrentThread) }
            XCTAssertTrue(lock.isHeldByCurrentThread)
        }
        XCTAssertFalse(lock.isHeldByCurrentThread)
    }

    func testReplaceableLockFollowsTheFileAtItsPath() throws {
        let url = root.appendingPathComponent("path.lock")
        let holder = try StateLock(url, replaceable: true), cached = try StateLock(url, replaceable: true)
        try holder.withLock { holder.removeFileWhileHeld() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // `cached` still has the unlinked file open. It must exclude a new holder of
        // the file now at the path, not lock the orphan.
        let fresh = try StateLock(url, replaceable: true)
        let entered = DispatchSemaphore(value: 0), leave = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? fresh.withLock { entered.signal(); _ = leave.wait(timeout: .now() + 5) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try cached.withLock(timeout: 0.1) {}) { XCTAssertEqual(($0 as? DriveError)?.code, EBUSY) }
        leave.signal()
        try cached.withLock { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        // A plain lock never unlinks its file.
        let plain = try StateLock(root.appendingPathComponent("plain.lock"))
        try plain.withLock { plain.removeFileWhileHeld() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("plain.lock").path))
    }

    /// A replaceable lock whose reopen fails (EMFILE, a full disk, a damaged state
    /// directory) must not keep the closed descriptor number: the next open in the
    /// process reuses it, and a later acquire or deinit would lock and close that file.
    func testFailedReopenNeverTouchesAReusedDescriptor() throws {
        let directory = root.appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("path.lock")
        let holder = try StateLock(url, replaceable: true)
        var cached: StateLock? = try StateLock(url, replaceable: true)
        defer { _ = chmod(directory.path, 0o700) }
        func opensOwnFile(_ fd: Int32, _ file: URL) {
            var held = Darwin.stat(), linked = Darwin.stat()
            XCTAssertEqual(fstat(fd, &held), 0, "The descriptor was closed")
            XCTAssertEqual(lstat(file.path, &linked), 0)
            XCTAssertEqual(held.st_ino, linked.st_ino, "The descriptor now refers to another file")
        }
        for round in 0..<2 {
            try holder.withLock { holder.removeFileWhileHeld() }
            // The lock file at the path is gone and cannot be created again.
            XCTAssertEqual(chmod(directory.path, 0o500), 0)
            XCTAssertThrowsError(try cached!.withLock {}) { XCTAssertEqual(($0 as? DriveError)?.code, EACCES) }
            // Another component opens a file and gets the lowest free descriptor.
            let victimURL = root.appendingPathComponent("victim-\(round)")
            try Data("victim".utf8).write(to: victimURL)
            let victim = Darwin.open(victimURL.path, O_RDONLY)
            XCTAssertGreaterThanOrEqual(victim, 0)
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
            if round == 0 {
                // The next acquire opens the lock file again.
                try cached!.withLock { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
            } else {
                cached = nil
            }
            opensOwnFile(victim, victimURL)
            _ = Darwin.close(victim)
        }
    }

    func testSharedLockCountsHoldersAndExcludesExclusiveHolder() throws {
        let url = root.appendingPathComponent("upload.lock")
        let shared = try SharedStateLock(url), other = try SharedStateLock(url)
        let exclusive = Darwin.open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(exclusive, 0); defer { Darwin.close(exclusive) }
        try shared.withShared {
            try shared.withShared {
                try other.withShared { XCTAssertEqual(flock(exclusive, LOCK_EX | LOCK_NB), -1) }
            }
            // One holder remains in this process, so the shared flock is still held.
            XCTAssertEqual(flock(exclusive, LOCK_EX | LOCK_NB), -1)
        }
        XCTAssertEqual(flock(exclusive, LOCK_EX | LOCK_NB), 0)
        let waited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? shared.withShared {}; waited.signal() }
        XCTAssertEqual(waited.wait(timeout: .now() + 0.2), .timedOut, "A shared holder must wait for an exclusive holder")
        XCTAssertEqual(flock(exclusive, LOCK_UN), 0)
        XCTAssertEqual(waited.wait(timeout: .now() + 2), .success)
    }
}
