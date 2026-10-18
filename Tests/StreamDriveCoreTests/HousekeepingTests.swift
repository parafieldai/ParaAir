import XCTest
import Darwin
@testable import StreamDriveCore

/// Local fixture storage that records every path the engine sends it.
private final class RecordingBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    private let lock = NSLock()
    private var seen: [String] = []
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    private func saw(_ paths: String...) { lock.lock(); seen.append(contentsOf: paths); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    func stat(_ p: String) throws -> FileEntry { saw(p); return try base.stat(p) }
    func list(_ p: String) throws -> [FileEntry] { saw(p); return try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data { saw(p); return try base.read(p, offset: offset, length: length) }
    func commit(_ c: FileCommit) throws -> FileEntry { saw(c.path); return try base.commit(c) }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        saw(path); return try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func createDirectory(_ p: String) throws -> FileEntry { saw(p); return try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { saw(p, d); try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { saw(p); try base.remove(p, directory: directory) }
}

final class HousekeepingTests: XCTestCase {
    private var work: URL!
    private var remote: URL!
    private var backend: RecordingBackend!
    private var drive: Engine!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        remote = work.appendingPathComponent("remote")
        backend = try RecordingBackend(remote)
        drive = try Engine(backend: backend, stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 1 << 20,
                           minFreeBytes: 0, blockSize: 4096, maxJournalBytes: 1 << 20)
    }
    override func tearDownWithError() throws { drive = nil; try FileManager.default.removeItem(at: work) }

    private func seed(_ path: String, _ text: String = "remote") throws {
        let url = remote.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func remoteExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: remote.appendingPathComponent(path).path) }
    private func names(_ path: String) throws -> [String] { try drive.list(path).map(\.name) }
    private func save(_ path: String, _ text: String) throws {
        _ = try drive.create(path, directory: false)
        _ = try drive.write(path, offset: 0, data: Data(text.utf8))
    }
    private func expectError(_ code: Int32, _ action: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? DriveError)?.code, code, file: file, line: line) }
    }
    /// No housekeeping path ever reached storage.
    private func assertStorageNeverSawHousekeeping(file: StaticString = #filePath, line: UInt = #line) {
        let leaked = backend.paths.filter { Housekeeping.staysLocal($0) }
        XCTAssertEqual(leaked, [], "sent to storage", file: file, line: line)
    }

    func testClassification() {
        for path in ["/.DS_Store", "/a/._b", "/a/b/._", "/x/" + Housekeeping.refreshName] { XCTAssertTrue(Housekeeping.isLocalOnly(path), path) }
        for path in ["/.fseventsd", "/.fseventsd/0000", "/.Spotlight-V100/Store-V2"] { XCTAssertTrue(Housekeeping.isRefused(path), path) }
        for path in ["/", "/a", "/a/.hidden", "/sub/.fseventsd", "/a/_b", "/.Trashes/501/x", "/.TemporaryItems/folders.501/f"] {
            XCTAssertFalse(Housekeeping.staysLocal(path), path)
        }
    }

    func testHousekeepingFilesStayOnThisMac() throws {
        try save("/.DS_Store", "view settings")
        try save("/._photo.jpg", "tags")
        _ = try drive.flushUploads(policy: .immediate)
        XCTAssertEqual(try drive.read("/.DS_Store", offset: 0, length: 64), Data("view settings".utf8))
        XCTAssertEqual(try drive.stat("/._photo.jpg").size, 4)
        XCTAssertEqual(try names("/"), ["._photo.jpg", ".DS_Store"].sorted())
        XCTAssertEqual(try drive.uploads().count, 0)
        let status = try drive.status()
        XCTAssertEqual(status.pendingUploads, 0)
        XCTAssertEqual(status.pendingWriteBytes, 0)
        XCTAssertFalse(remoteExists(".DS_Store")); XCTAssertFalse(remoteExists("._photo.jpg"))
        assertStorageNeverSawHousekeeping()
    }

    func testStoredCopiesAreHidden() throws {
        try seed("keep.txt"); try seed(".DS_Store"); try seed("._keep.txt"); try seed(".fseventsd/0000000001")
        try seed(".Spotlight-V100/Store-V2/x")
        XCTAssertEqual(try names("/"), ["keep.txt"])
        expectError(ENOENT, try self.drive.stat("/.DS_Store"))
        expectError(ENOENT, try self.drive.stat("/.fseventsd"))
        expectError(ENOENT, try self.drive.list("/.fseventsd"))
        expectError(ENOENT, try self.drive.read("/._keep.txt", offset: 0, length: 4))
        assertStorageNeverSawHousekeeping()
    }

    func testSystemFoldersAreRefused() throws {
        expectError(EACCES, try self.drive.create("/.fseventsd", directory: true))
        expectError(EACCES, try self.drive.create("/.Spotlight-V100", directory: true))
        expectError(EACCES, try self.drive.create("/.fseventsd/0000", directory: false))
        expectError(EACCES, try self.drive.create("/._folder", directory: true))
        // Only the root folders macOS uses are refused; Trash and safe-save folders still sync.
        _ = try drive.create("/sub", directory: true)
        _ = try drive.create("/sub/.fseventsd", directory: true)
        _ = try drive.create("/.Trashes", directory: true)
        XCTAssertTrue(remoteExists("sub/.fseventsd")); XCTAssertTrue(remoteExists(".Trashes"))
        assertStorageNeverSawHousekeeping()
    }

    func testAppleDoubleCompanionsFollowRenames() throws {
        try save("/doc.pages", "document")
        try save("/._doc.pages", "quarantine")
        try drive.move("/doc.pages", to: "/report.pages")
        try drive.move("/._doc.pages", to: "/._report.pages")
        XCTAssertEqual(try names("/"), ["._report.pages", "report.pages"])
        XCTAssertEqual(try drive.read("/._report.pages", offset: 0, length: 64), Data("quarantine".utf8))
        expectError(ENOENT, try self.drive.stat("/._doc.pages"))
        // A rename between local and synced names would move bytes in or out of storage.
        expectError(EACCES, try self.drive.move("/._report.pages", to: "/notes.txt"))
        expectError(EACCES, try self.drive.move("/report.pages", to: "/._report2"))
        XCTAssertTrue(remoteExists("report.pages"))
        assertStorageNeverSawHousekeeping()
    }

    func testLocalFilesReplaceOnRename() throws {
        try save("/._a", "new")
        try save("/._b", "old")
        try drive.move("/._a", to: "/._b")
        XCTAssertEqual(try drive.read("/._b", offset: 0, length: 8), Data("new".utf8))
        expectError(ENOENT, try self.drive.stat("/._a"))
        expectError(ENOENT, try self.drive.move("/._missing", to: "/._c"))
        expectError(ENOENT, try self.drive.move("/._b", to: "/absent/._b"))
    }

    func testFolderMovesAndRemovalsCarryLocalFiles() throws {
        _ = try drive.create("/dir", directory: true)
        try save("/dir/a.txt", "a")
        _ = try drive.flushUploads(policy: .immediate)
        try save("/dir/.DS_Store", "layout")
        try drive.move("/dir", to: "/moved")
        XCTAssertEqual(try drive.read("/moved/.DS_Store", offset: 0, length: 16), Data("layout".utf8))
        expectError(ENOENT, try self.drive.stat("/dir/.DS_Store"))
        try drive.remove("/moved/a.txt", directory: false)
        try drive.remove("/moved", directory: true)
        expectError(ENOENT, try self.drive.stat("/moved/.DS_Store"))
        XCTAssertFalse(remoteExists("moved"))
        XCTAssertEqual(try drive.status().pendingWriteBytes, 0)
        assertStorageNeverSawHousekeeping()
    }

    func testFolderHoldingOnlyStoredHousekeepingCanBeRemoved() throws {
        try seed("old/._photo.jpg"); try seed("old/.DS_Store")
        XCTAssertEqual(try names("/old"), [])
        try drive.remove("/old", directory: true)
        XCTAssertFalse(remoteExists("old"))
        // A folder with real files is still refused.
        try seed("full/._x"); try seed("full/x")
        expectError(ENOTEMPTY, try self.drive.remove("/full", directory: true))
        XCTAssertTrue(remoteExists("full/x"))
    }

    func testRefreshNameNeverReachesStorage() throws {
        _ = try drive.create("/" + Housekeeping.refreshName, directory: false)
        try drive.remove("/" + Housekeeping.refreshName, directory: false)
        expectError(ENOENT, try self.drive.stat("/" + Housekeeping.refreshName))
        expectError(ENOENT, try self.drive.remove("/" + Housekeeping.refreshName, directory: false))
        assertStorageNeverSawHousekeeping()
    }

    func testPinsIgnoreHousekeeping() throws {
        try seed("pinned/song.flac", "audio")
        try drive.pin("/pinned")
        try save("/pinned/.DS_Store", "layout")
        XCTAssertEqual(try drive.status().pins.first?.complete, true)
        try drive.pin("/pinned")
        XCTAssertEqual(try drive.status().pins.first?.fileCount, 1)
        assertStorageNeverSawHousekeeping()
    }
}
