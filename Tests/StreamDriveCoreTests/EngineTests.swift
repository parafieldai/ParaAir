import XCTest
import Darwin
@testable import StreamDriveCore

private final class ObservedBackend: StorageBackend {
    let base: LocalDirectoryBackend
    var readBytes = 0
    var ranges: [(Int64, Int)] = []
    var offline = false
    var failAfterCommit = false
    var failBeforeCommit = false
    var onCommit: (() -> Void)?
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    func available() throws { if offline { throw DriveError(ENETDOWN, "Fixture offline") } }
    func stat(_ p: String) throws -> FileEntry { try available(); return try base.stat(p) }
    func list(_ p: String) throws -> [FileEntry] { try available(); return try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data {
        try available(); let bytes = try base.read(p, offset: offset, length: length)
        readBytes += bytes.count; ranges.append((offset, length)); return bytes
    }
    func commit(_ c: FileCommit) throws -> FileEntry {
        try available()
        onCommit?()
        if failBeforeCommit { throw DriveError(EIO, "Injected before publication") }
        let result = try base.commit(c)
        if failAfterCommit { failAfterCommit = false; throw DriveError(ECONNRESET, "Injected lost reply") }
        return result
    }
    func createDirectory(_ p: String) throws -> FileEntry { try available(); return try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { try available(); try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { try available(); try base.remove(p, directory: directory) }
}

final class EngineTests: XCTestCase {
    private var work: URL!
    private var remote: URL!
    private var state: URL!
    private var backend: ObservedBackend!
    override func setUpWithError() throws {
        work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        remote = work.appendingPathComponent("remote"); state = work.appendingPathComponent("state")
        backend = try ObservedBackend(remote)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: work) }
    private func engine(cache: Int64 = 8192, journal: Int64 = 1024 * 1024) throws -> Engine {
        try Engine(backend: backend, stateDirectory: state, cacheLimitBytes: cache, minFreeBytes: 0, blockSize: 4096, maxJournalBytes: journal)
    }
    private func seed(_ name: String, _ data: Data) throws { try data.write(to: remote.appendingPathComponent(name)) }
    private func seed(_ data: Data) throws { try seed("file", data) }

    func testPendingWritesPreserveAccessTimeAcrossRestart() throws {
        try seed(Data("initial".utf8))
        let times = [timeval(tv_sec: 200000000, tv_usec: 123456), timeval(tv_sec: 400000000, tv_usec: 654321)]
        XCTAssertEqual(times.withUnsafeBufferPointer { Darwin.utimes(remote.appendingPathComponent("file").path, $0.baseAddress) }, 0)
        var drive: Engine? = try engine()
        _ = try drive!.write("/file", offset: 0, data: Data("updated".utf8))
        drive = nil
        let reopened = try engine()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.stat("/file"))) as! [String: Any]
        XCTAssertEqual((json["accessedNanoseconds"] as? NSNumber)?.int64Value, 200000000123456000)
        let created = try reopened.create("/new", directory: false)
        let createdJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as! [String: Any]
        let initialAccess = try XCTUnwrap((createdJSON["accessedNanoseconds"] as? NSNumber)?.int64Value)
        _ = try reopened.write("/new", offset: 0, data: Data("new".utf8))
        let updatedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.stat("/new"))) as! [String: Any]
        XCTAssertEqual((updatedJSON["accessedNanoseconds"] as? NSNumber)?.int64Value, initialAccess)
    }

    func testListingIsMetadataOnlyAndDistantReadFetchesOneBlock() throws {
        let file = remote.appendingPathComponent("video")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertEqual(Darwin.ftruncate(fd, 128 * 1024 * 1024), 0)
        let drive = try engine()
        XCTAssertEqual(try drive.list("/").map(\.name), ["video"]); XCTAssertEqual(backend.readBytes, 0)
        XCTAssertEqual(try drive.read("/video", offset: 64 * 1024 * 1024 + 7, length: 17), Data(count: 17))
        XCTAssertEqual(backend.readBytes, 4096)
        _ = try drive.read("/video", offset: 64 * 1024 * 1024 + 9, length: 31)
        XCTAssertEqual(backend.readBytes, 4096)
        XCTAssertLessThan(try drive.allocatedLocalBytes("/video"), 128 * 1024 * 1024)
    }
    func testOverlappingWritesSurviveRestartAndPublish() throws {
        try seed(Data("abcdefghij".utf8))
        var drive: Engine? = try engine()
        XCTAssertEqual(try drive!.write("/file", offset: 2, data: Data("XYZ".utf8)), 3)
        XCTAssertEqual(try drive!.write("/file", offset: 4, data: Data("12".utf8)), 2)
        drive = nil; drive = try engine()
        XCTAssertEqual(try drive!.read("/file", offset: 0, length: 10), Data("abXY12ghij".utf8))
        XCTAssertEqual(try drive!.uploads().count, 1)
        XCTAssertTrue(try drive!.flushUploads().isEmpty)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("file")), Data("abXY12ghij".utf8))
        XCTAssertEqual(try drive!.status().pendingWriteBytes, 0)
    }
    func testTruncateThenExtendDoesNotResurrectBaseOrJournalBytes() throws {
        try seed(Data("abcdefghij".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 1, data: Data("1234567".utf8))
        try drive.truncate("/file", size: 4); try drive.truncate("/file", size: 10)
        let expected = Data("a123".utf8) + Data(count: 6)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 10), expected)
        try drive.fsync("/file")
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("file")), expected)
    }
    func testConcurrentRemoteEditCreatesConflictAndRetainsAcknowledgedWrite() throws {
        try seed(Data("initial".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("local!!".utf8))
        try seed(Data("remote!".utf8))
        XCTAssertThrowsError(try drive.fsync("/file")) { XCTAssertEqual(($0 as? DriveError)?.code, ESTALE) }
        XCTAssertEqual(try drive.uploads().first?.state, "conflict")
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 7), Data("local!!".utf8))
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("file")), Data("remote!".utf8))
        XCTAssertGreaterThan(try drive.status().pendingWriteBytes, 0)
    }
    func testLostRemoteAcknowledgementReplaysWithoutLosingSubsequentEdits() throws {
        try seed(Data("old".utf8))
        var drive: Engine? = try engine()
        _ = try drive!.write("/file", offset: 0, data: Data("one".utf8))
        backend.failAfterCommit = true
        XCTAssertThrowsError(try drive!.fsync("/file"))
        drive = nil; drive = try engine()
        // This must reconcile the sealed first transaction before assigning a
        // new identity, or retrying its receipt would silently discard "two".
        _ = try drive!.write("/file", offset: 0, data: Data("two".utf8))
        try drive!.fsync("/file")
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("file")), Data("two".utf8))
        XCTAssertTrue(try drive!.uploads().isEmpty)
    }
    func testFailedUploadSurvivesAndSuccessfulRetryClearsJournal() throws {
        let drive = try engine()
        _ = try drive.create("/new", directory: false)
        _ = try drive.write("/new", offset: 9000, data: Data("tail".utf8))
        backend.failBeforeCommit = true
        XCTAssertEqual(try drive.flushUploads().count, 1)
        XCTAssertEqual(try drive.read("/new", offset: 8998, length: 6), Data([0, 0]) + Data("tail".utf8))
        backend.failBeforeCommit = false
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try backend.stat("/new").size, 9004)
    }
    func testPinProtectsContentDuringEvictionAndWorksOfflineAfterRestart() throws {
        try seed("pinned", Data(repeating: 8, count: 8192)); try seed("other", Data(repeating: 1, count: 8192))
        var drive: Engine? = try engine()
        try drive!.pin("/pinned")
        _ = try drive!.read("/other", offset: 0, length: 8192)
        XCTAssertGreaterThan(try drive!.evictCache(), 0)
        XCTAssertEqual(try drive!.status().cacheBytes, 0)
        XCTAssertGreaterThan(try drive!.status().pinnedBytes, 0)
        backend.offline = true; drive = nil; drive = try engine()
        XCTAssertEqual(try drive!.read("/pinned", offset: 4090, length: 20), Data(repeating: 8, count: 20))
        try drive!.unpin("/pinned"); _ = try drive!.evictCache()
        XCTAssertThrowsError(try drive!.read("/pinned", offset: 0, length: 20))
    }
    func testCacheLimitAndEvictionNeverDiscardPendingWrites() throws {
        try seed(Data(repeating: 1, count: 32 * 1024))
        let drive = try engine(cache: 4096)
        _ = try drive.read("/file", offset: 0, length: 32 * 1024)
        XCTAssertLessThanOrEqual(try drive.status().cacheBytes, 4096)
        _ = try drive.write("/file", offset: 0, data: Data("dirty".utf8))
        let before = try drive.status().pendingWriteBytes
        _ = try drive.evictCache()
        XCTAssertEqual(try drive.status().pendingWriteBytes, before)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 5), Data("dirty".utf8))
    }
    func testRemoteChangesInvalidatePinAndRepinReleasesOldVersions() throws {
        try seed(Data(repeating: 1, count: 8192))
        let drive = try engine()
        try drive.pin("/file")
        let before = try drive.status().pinnedBytes
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
        try seed(Data(repeating: 2, count: 8192))
        _ = try drive.list("/") // refreshes metadata without downloading content
        XCTAssertFalse(try XCTUnwrap(drive.status().pins.first).complete)
        try drive.pin("/file")
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
        XCTAssertEqual(try drive.status().pinnedBytes, before)
        backend.offline = true
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 8192), Data(repeating: 2, count: 8192))
    }
    func testDirectoryRepinReleasesBlocksOfRemotelyDeletedFiles() throws {
        try seed("removed", Data(repeating: 1, count: 8192)); try seed("retained", Data(repeating: 2, count: 8192))
        let drive = try engine()
        try drive.pin("/")
        XCTAssertGreaterThan(try drive.allocatedLocalBytes("/removed"), 0)
        try backend.remove("/removed", directory: false)
        try drive.pin("/")
        XCTAssertEqual(try drive.allocatedLocalBytes("/removed"), 0)
        XCTAssertGreaterThan(try drive.allocatedLocalBytes("/retained"), 0)
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
    }
    func testJournalAdmissionRejectsBeforeAcknowledgingAndReservesOldData() throws {
        try seed(Data("original".utf8))
        let drive = try engine(journal: 4096)
        _ = try drive.write("/file", offset: 0, data: Data("first".utf8))
        XCTAssertThrowsError(try drive.write("/file", offset: 0, data: Data(repeating: 1, count: 4097))) {
            XCTAssertEqual(($0 as? DriveError)?.code, ENOSPC)
        }
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 5), Data("first".utf8))
    }
    func testTwoEngineInstancesShareJournalAndDoNotLoseEdits() throws {
        try seed(Data("abcdefgh".utf8))
        let one = try engine(), two = try engine()
        _ = try one.write("/file", offset: 0, data: Data("12".utf8))
        _ = try two.write("/file", offset: 6, data: Data("78".utf8))
        XCTAssertEqual(try one.read("/file", offset: 0, length: 8), Data("12cdef78".utf8))
        try two.fsync("/file"); XCTAssertTrue(try one.uploads().isEmpty)
    }
    func testRemoteUploadDoesNotHoldTheLocalStateLock() throws {
        try seed("upload", Data("upload".utf8)); try seed("other", Data("cached".utf8))
        let drive = try engine()
        _ = try drive.read("/other", offset: 0, length: 6)
        _ = try drive.write("/upload", offset: 0, data: Data("saved!".utf8))
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "remote publication completes")
        backend.onCommit = { started.signal(); _ = release.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            do { try drive.fsync("/upload") } catch { XCTFail("Upload failed: \(error)") }
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let begin = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(try drive.status().pendingUploads, 1)
        XCTAssertEqual(try drive.read("/other", offset: 0, length: 6), Data("cached".utf8))
        _ = try drive.write("/other", offset: 0, data: Data("local!".utf8))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9
        release.signal()
        XCTAssertLessThan(elapsed, 1, "Local cache, status and unrelated edits must not wait for remote publication")
        wait(for: [finished], timeout: 4)
    }
    func testSymlinkAndReservedPathsCannotEscapeFixture() throws {
        try FileManager.default.createSymbolicLink(at: remote.appendingPathComponent("escape"), withDestinationURL: work)
        XCTAssertThrowsError(try backend.stat("/escape"))
        XCTAssertThrowsError(try engine().create("/.streamdrive/junk", directory: false))
    }
    func testSamePathRenameSucceedsWithoutFlushingJournal() throws {
        try seed(Data("original".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("changed!".utf8))
        try drive.move("/file", to: "/file")
        XCTAssertEqual(try drive.uploads().count, 1)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("file")), Data("original".utf8))
        _ = try drive.create("/folder", directory: true)
        try drive.move("/folder", to: "/folder")
        XCTAssertEqual(try drive.stat("/folder").kind, .directory)
        XCTAssertThrowsError(try drive.move("/missing", to: "/missing")) { XCTAssertEqual(($0 as? DriveError)?.code, ENOENT) }
    }
}
