import XCTest
import Darwin
@testable import StreamDriveCore

/// Local fixture storage with injected failures. State is locked because uploads,
/// writers and background flushes call it from several threads.
private final class ObservedBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    private struct Values {
        var readBytes = 0
        var ranges: [(Int64, Int)] = []
        var reads: [(path: String, offset: Int64)] = []
        var offline = false
        var failAfterCommit = false
        var lostReplyErrno = ECONNRESET
        var failBeforeCommit = false
        var failNotDispatched: Int32?
        var failAbsent: Int32?
        var statusUnknown = false
        var commits = 0
        var committedPaths: [String] = []
        var statusCalls = 0
        var stats = 0
        var capacity: VolumeCapacity?
        var onCommit: (() -> Void)?
        var onCommitOf: ((String) -> Void)?
    }
    private let lock = NSLock()
    private var values = Values()
    private func with<T>(_ body: (inout Values) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&values) }
    var readBytes: Int { with { $0.readBytes } }
    /// Blocks read from storage at `path`, as block indexes of `size` bytes.
    func fetchedBlocks(_ path: String, size: Int64 = 4096) -> [Int64] { with { $0.reads.filter { $0.path == path }.map { $0.offset / size } } }
    var commits: Int { with { $0.commits } }
    var committedPaths: [String] { with { $0.committedPaths } }
    var statusCalls: Int { with { $0.statusCalls } }
    var stats: Int { with { $0.stats } }
    var offline: Bool { get { with { $0.offline } } set { with { $0.offline = newValue } } }
    var failAfterCommit: Bool { get { with { $0.failAfterCommit } } set { with { $0.failAfterCommit = newValue } } }
    /// The errno of the injected lost reply.
    var lostReplyErrno: Int32 { get { with { $0.lostReplyErrno } } set { with { $0.lostReplyErrno = newValue } } }
    var failBeforeCommit: Bool { get { with { $0.failBeforeCommit } } set { with { $0.failBeforeCommit = newValue } } }
    /// Rejects commits before anything is sent, like a failed sign-in or no network.
    var failNotDispatched: Int32? { get { with { $0.failNotDispatched } } set { with { $0.failNotDispatched = newValue } } }
    /// Rejects commits with a fenced error, like quota_exceeded or parent_not_found.
    var failAbsent: Int32? { get { with { $0.failAbsent } } set { with { $0.failAbsent = newValue } } }
    var statusUnknown: Bool { get { with { $0.statusUnknown } } set { with { $0.statusUnknown = newValue } } }
    var capacityValue: VolumeCapacity? { get { with { $0.capacity } } set { with { $0.capacity = newValue } } }
    var onCommit: (() -> Void)? { get { with { $0.onCommit } } set { with { $0.onCommit = newValue } } }
    var onCommitOf: ((String) -> Void)? { get { with { $0.onCommitOf } } set { with { $0.onCommitOf = newValue } } }
    init(_ root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    func available() throws { if offline { throw DriveError(ENETDOWN, "Fixture offline") } }
    func stat(_ p: String) throws -> FileEntry { with { $0.stats += 1 }; try available(); return try base.stat(p) }
    func list(_ p: String) throws -> [FileEntry] { try available(); return try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data {
        try available(); let bytes = try base.read(p, offset: offset, length: length)
        with { $0.readBytes += bytes.count; $0.ranges.append((offset, length)); $0.reads.append((p, offset)) }; return bytes
    }
    func commit(_ c: FileCommit) throws -> FileEntry {
        with { $0.commits += 1 }
        do { try available() } catch let error as DriveError { throw error.with(.attemptNotDispatched) }
        let injected = with { $0 }
        injected.onCommit?()
        injected.onCommitOf?(c.path)
        if let code = injected.failNotDispatched { throw DriveError(code, "Injected rejection before dispatch", disposition: .attemptNotDispatched) }
        if let code = injected.failAbsent { throw DriveError(code, "Injected fenced rejection", disposition: .transactionAbsent) }
        if injected.failBeforeCommit { throw DriveError(EIO, "Injected before publication") }
        let result = try base.commit(c)
        with { $0.committedPaths.append(c.path) }
        if with({ values -> Bool in defer { values.failAfterCommit = false }; return values.failAfterCommit }) {
            throw DriveError(lostReplyErrno, "Injected lost reply")
        }
        return result
    }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        with { $0.statusCalls += 1 }
        try available()
        if statusUnknown { return .unknown }
        return try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func capacity() throws -> VolumeCapacity? { try available(); return try capacityValue ?? base.capacity() }
    func createDirectory(_ p: String) throws -> FileEntry { try available(); return try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { try available(); try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { try available(); try base.remove(p, directory: directory) }
}

/// Wraps `ObservedBackend` and holds chosen calls open, to observe the engine while
/// a fetch, refresh, listing or rename is in flight. A gate catches the next
/// matching call only. `.before` holds the call before it runs; `.after` runs it
/// first, so it returns what storage said before the release.
private final class GatedBackend: StorageBackend, @unchecked Sendable {
    enum Operation: String { case stat, list, read, readSnapshot, move }
    enum Timing { case before, after }
    final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        fileprivate let timing: Timing, offset: Int64?, failure: DriveError?
        fileprivate init(timing: Timing, offset: Int64?, failure: DriveError?) { self.timing = timing; self.offset = offset; self.failure = failure }
    }
    let base: ObservedBackend
    private let lock = NSLock()
    private var gates: [String: [Gate]] = [:]
    private var snapshots: [String: Int] = [:]
    private var duplicates = false
    init(_ base: ObservedBackend) { self.base = base }
    @discardableResult
    func hold(_ operation: Operation, _ path: String, offset: Int64? = nil, timing: Timing = .before, failing failure: DriveError? = nil) -> Gate {
        let gate = Gate(timing: timing, offset: offset, failure: failure)
        lock.withLock { gates[operation.rawValue + " " + path, default: []].append(gate) }
        return gate
    }
    /// `readSnapshot` calls for `path`, held or not.
    func snapshotReads(_ path: String) -> Int { lock.withLock { snapshots[path] ?? 0 } }
    /// Lists every entry twice, like a backend that pages inconsistently.
    var duplicateListings: Bool { get { lock.withLock { duplicates } } set { lock.withLock { duplicates = newValue } } }
    private func pass<T>(_ operation: Operation, _ path: String, offset: Int64? = nil, _ body: () throws -> T) throws -> T {
        let gate = lock.withLock { () -> Gate? in
            let key = operation.rawValue + " " + path
            guard let index = gates[key]?.firstIndex(where: { $0.offset == nil || $0.offset == offset }) else { return nil }
            return gates[key]?.remove(at: index)
        }
        guard let gate else { return try body() }
        let result = gate.timing == .after ? Result { try body() } : nil
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 10)
        if let failure = gate.failure { throw failure }
        return try result?.get() ?? body()
    }
    func stat(_ path: String) throws -> FileEntry { try pass(.stat, path) { try base.stat(path) } }
    func list(_ path: String) throws -> [FileEntry] {
        try pass(.list, path) { let entries = try base.list(path); return duplicateListings ? entries + entries : entries }
    }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try pass(.read, path, offset: offset) { try base.read(path, offset: offset, length: length) }
    }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        lock.withLock { snapshots[path, default: 0] += 1 }
        return try pass(.readSnapshot, path, offset: offset) { try base.readSnapshot(path, version: version, offset: offset, length: length) }
    }
    func move(_ source: String, to destination: String) throws { try pass(.move, source) { try base.move(source, to: destination) } }
    func commit(_ commit: FileCommit) throws -> FileEntry { try base.commit(commit) }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func capacity() throws -> VolumeCapacity? { try base.capacity() }
    func createDirectory(_ path: String) throws -> FileEntry { try base.createDirectory(path) }
    func remove(_ path: String, directory: Bool) throws { try base.remove(path, directory: directory) }
}

/// Runs one engine call on another thread.
private final class Background<T>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<T, Error>?
    init(_ body: @escaping () throws -> T) {
        DispatchQueue.global().async { [self] in
            let result = Result { try body() }
            lock.withLock { outcome = result }
            done.signal()
        }
    }
    var finished: Bool { lock.withLock { outcome != nil } }
    func result(timeout: TimeInterval = 10) throws -> T {
        guard done.wait(timeout: .now() + timeout) == .success else { throw DriveError(ETIMEDOUT, "Background call did not finish") }
        done.signal()
        return try lock.withLock { outcome! }.get()
    }
}

/// The persisted journal fields that `UploadRecord` does not expose.
private struct JournalProbe: Decodable {
    var transactionID: String
    var sealed: Bool
    var state: String
    var mayHaveApplied: Bool?
    var failures: Int?
    var nextAttemptAt: Int64?
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
    private func remoteData(_ name: String = "file") throws -> Data { try Data(contentsOf: remote.appendingPathComponent(name)) }
    private func journal(_ path: String) throws -> JournalProbe? {
        try Database(state.appendingPathComponent("state.sqlite3")).get("journal", path)
    }
    private func transaction(_ drive: Engine, _ path: String = "/file") throws -> String {
        try XCTUnwrap(drive.uploads().first { $0.path == path }).transactionID
    }
    private func expectError(_ code: Int32, _ action: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? DriveError)?.code, code, file: file, line: line) }
    }
    private func nanoseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }

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

    // MARK: E2: block size

    func testBlockSizeChangeInvalidatesPinsAndReclaimsBlocks() throws {
        try seed("pinned", Data(repeating: 7, count: 16384)); try seed("other", Data(repeating: 3, count: 8192))
        func open(_ size: Int) throws -> Engine {
            try Engine(backend: backend, stateDirectory: state, cacheLimitBytes: 65536, minFreeBytes: 0, blockSize: size, maxJournalBytes: 1 << 20)
        }
        let marker = state.appendingPathComponent("block.size"), cacheFiles = state.appendingPathComponent("cache")
        var drive: Engine? = try open(4096)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "4096")
        try drive!.pin("/pinned")
        _ = try drive!.read("/other", offset: 0, length: 8192)
        XCTAssertGreaterThan(try drive!.status().pinnedBytes, 0)
        XCTAssertGreaterThan(try drive!.status().cacheBytes, 0)
        // The same size, or a state folder from before the marker existed, keeps everything.
        drive = nil; drive = try open(4096)
        XCTAssertTrue(try XCTUnwrap(drive!.status().pins.first).complete)
        drive = nil; try FileManager.default.removeItem(at: marker); drive = try open(4096)
        XCTAssertTrue(try XCTUnwrap(drive!.status().pins.first).complete)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "4096")
        // A new size releases every block and cache file; the pin must be refreshed.
        drive = nil; drive = try open(8192)
        let pin = try XCTUnwrap(drive!.status().pins.first)
        XCTAssertFalse(pin.complete)
        XCTAssertEqual(pin.lastError, "Block size changed; pin again to refresh the offline snapshot")
        XCTAssertEqual(try drive!.status().pinnedBytes, 0)
        XCTAssertEqual(try drive!.status().cacheBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cacheFiles.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "8192")
        try drive!.pin("/pinned")
        XCTAssertTrue(try XCTUnwrap(drive!.status().pins.first).complete)
        backend.offline = true
        XCTAssertEqual(try drive!.read("/pinned", offset: 8190, length: 4), Data(repeating: 7, count: 4))
    }

    // MARK: E3: failed uploads and the commit fence

    func testAbsentFailureRotatesTransactionAndAllowsOfflineWrites() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("one".utf8))
        let before = try transaction(drive)
        backend.failAbsent = EDQUOT
        expectError(EDQUOT, try drive.fsync("/file"))
        let record = try XCTUnwrap(drive.uploads().first)
        XCTAssertNotEqual(record.transactionID, before, "A fenced rejection must rotate the identity")
        XCTAssertEqual(record.state, "pending")
        XCTAssertEqual(record.lastErrno, EDQUOT)
        let probe = try XCTUnwrap(journal("/file"))
        XCTAssertFalse(probe.sealed)
        XCTAssertEqual(probe.mayHaveApplied, false)
        // Unsealed again: later writes stay local, even offline, and never reach storage.
        backend.offline = true
        let commits = backend.commits, statuses = backend.statusCalls
        XCTAssertEqual(try drive.write("/file", offset: 3, data: Data("two".utf8)), 3)
        XCTAssertEqual(backend.commits, commits)
        XCTAssertEqual(backend.statusCalls, statuses)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 6), Data("onetwo".utf8))
        backend.offline = false; backend.failAbsent = nil
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try remoteData(), Data("onetwo".utf8))
    }

    func testNotDispatchedFailureRotatesOnlyWithoutPriorAmbiguousAttempt() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("one".utf8))
        let first = try transaction(drive)
        backend.failNotDispatched = EAGAIN
        expectError(EAGAIN, try drive.fsync("/file"))
        let rotated = try transaction(drive)
        XCTAssertNotEqual(rotated, first)
        XCTAssertFalse(try XCTUnwrap(journal("/file")).sealed)
        // An ambiguous attempt makes the identity sticky...
        backend.failNotDispatched = nil; backend.failBeforeCommit = true
        expectError(EIO, try drive.fsync("/file"))
        XCTAssertEqual(try transaction(drive), rotated)
        XCTAssertTrue(try XCTUnwrap(journal("/file")).sealed)
        // ...so a later failure before dispatch keeps it sealed under the same identity.
        backend.failBeforeCommit = false; backend.failNotDispatched = EAGAIN
        expectError(EAGAIN, try drive.fsync("/file"))
        let probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.transactionID, rotated)
        XCTAssertTrue(probe.sealed)
        XCTAssertEqual(probe.mayHaveApplied, true)
        backend.failNotDispatched = nil
        try drive.fsync("/file")
        XCTAssertTrue(try drive.uploads().isEmpty)
        XCTAssertEqual(try remoteData(), Data("one".utf8))
    }

    func testPreDispatchFailureAfterLostAcknowledgementDoesNotRotateIdentity() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("one".utf8))
        let identity = try transaction(drive)
        backend.failAfterCommit = true
        expectError(ECONNRESET, try drive.fsync("/file"))
        XCTAssertEqual(try remoteData(), Data("one".utf8), "The lost reply hid a successful publication")
        backend.failNotDispatched = ENETDOWN
        expectError(ENETDOWN, try drive.fsync("/file"))
        let probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.transactionID, identity, "Rotating now would turn the published attempt into a false conflict")
        XCTAssertTrue(probe.sealed)
        XCTAssertEqual(probe.mayHaveApplied, true)
        backend.failNotDispatched = nil
        try drive.fsync("/file")
        XCTAssertTrue(try drive.uploads().isEmpty, "The replay must hit the receipt, not conflict")
        XCTAssertEqual(try remoteData(), Data("one".utf8))
    }

    func testWriterResolvesSealedJournalWithCommitStatusWithoutUploading() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("one".utf8))
        backend.failAfterCommit = true
        expectError(ECONNRESET, try drive.fsync("/file"))
        // Applied: the writer settles the sealed journal and starts a new one on top.
        var commits = backend.commits
        XCTAssertEqual(try drive.write("/file", offset: 0, data: Data("two".utf8)), 3)
        XCTAssertEqual(backend.commits, commits, "A writer must never upload")
        XCTAssertEqual(backend.statusCalls, 1)
        var probe = try XCTUnwrap(journal("/file"))
        XCTAssertFalse(probe.sealed)
        XCTAssertEqual(probe.mayHaveApplied, false)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 3), Data("two".utf8))
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data("two".utf8))
        // Absent: a sealed attempt that never published is rotated, not uploaded.
        _ = try drive.write("/file", offset: 0, data: Data("3".utf8))
        backend.failBeforeCommit = true
        expectError(EIO, try drive.fsync("/file"))
        backend.failBeforeCommit = false
        let sealed = try transaction(drive)
        commits = backend.commits
        XCTAssertEqual(try drive.write("/file", offset: 1, data: Data("4".utf8)), 1)
        XCTAssertEqual(backend.commits, commits)
        XCTAssertEqual(backend.statusCalls, 2)
        probe = try XCTUnwrap(journal("/file"))
        XCTAssertNotEqual(probe.transactionID, sealed)
        XCTAssertFalse(probe.sealed)
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data("34o".utf8))
    }

    func testWriterGetsEIOWhenOutcomeUnknownAndMayHaveApplied() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("one".utf8))
        backend.failAfterCommit = true
        expectError(ECONNRESET, try drive.fsync("/file"))
        let identity = try transaction(drive), commits = backend.commits
        let message = "The previous upload of this file has an unknown outcome. Your changes are kept and will upload when the connection returns."
        backend.statusUnknown = true
        XCTAssertThrowsError(try drive.write("/file", offset: 0, data: Data("two".utf8))) {
            XCTAssertEqual(($0 as? DriveError)?.code, EIO)
            XCTAssertEqual(($0 as? DriveError)?.message, message)
        }
        // An unreachable fence is just as unknown.
        backend.statusUnknown = false; backend.offline = true
        expectError(EIO, try drive.write("/file", offset: 0, data: Data("two".utf8)))
        expectError(EIO, try drive.truncate("/file", size: 1))
        XCTAssertEqual(backend.commits, commits)
        XCTAssertTrue(try drive.status().offline)
        // Acknowledged data stays readable, and the identity is unchanged.
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 3), Data("one".utf8))
        let probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.transactionID, identity)
        XCTAssertTrue(probe.sealed)
        backend.offline = false
        XCTAssertEqual(try drive.write("/file", offset: 0, data: Data("two".utf8)), 3)
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data("two".utf8))
    }

    func testNamespaceRejectionBecomesConflict() throws {
        let drive = try engine()
        for code in [ENOENT, ENOTDIR, EISDIR] {
            let path = "/file-\(code)"
            _ = try drive.create(path, directory: false)
            _ = try drive.write(path, offset: 0, data: Data("kept".utf8))
            backend.failAbsent = code
            expectError(code, try drive.fsync(path))
            backend.failAbsent = nil
            let record = try XCTUnwrap(drive.uploads().first { $0.path == path })
            XCTAssertEqual(record.state, "conflict", "errno \(code)")
            XCTAssertEqual(record.lastErrno, code)
            expectError(ESTALE, try drive.write(path, offset: 0, data: Data("more".utf8)))
            expectError(ESTALE, try drive.fsync(path))
            XCTAssertEqual(try drive.read(path, offset: 0, length: 4), Data("kept".utf8))
        }
        // The same errno without the fence is not a namespace change.
        _ = try drive.create("/plain", directory: false)
        backend.failNotDispatched = ENOENT
        expectError(ENOENT, try drive.fsync("/plain"))
        backend.failNotDispatched = nil
        XCTAssertEqual(try XCTUnwrap(drive.uploads().first { $0.path == "/plain" }).state, "pending")
        try drive.fsync("/plain")
        XCTAssertEqual(try drive.uploads().filter { $0.state == "conflict" }.count, 3)
    }

    func testBackoffPersistsNextAttempt() throws {
        try seed(Data("old".utf8))
        let quick = UploadPolicy(closedIdleNanoseconds: 0, openIdleNanoseconds: 0, pressureFraction: 1, respectsBackoff: true)
        var drive: Engine? = try engine()
        _ = try drive!.write("/file", offset: 0, data: Data("one".utf8))
        backend.failNotDispatched = EAGAIN
        var start = nanoseconds()
        XCTAssertEqual(try drive!.flushUploads(policy: quick).first?.lastErrno, EAGAIN)
        var probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.failures, 1)
        var next = try XCTUnwrap(probe.nextAttemptAt)
        XCTAssertGreaterThanOrEqual(next, start + 2_000_000_000)
        XCTAssertLessThanOrEqual(next, nanoseconds() + 2_000_000_000)
        // The schedule survives a restart: background passes leave the file alone.
        drive = nil; drive = try engine()
        XCTAssertEqual(try drive!.flushUploads(policy: quick).count, 1)
        XCTAssertEqual(backend.commits, 1)
        // An explicit flush retries; each failure doubles the delay.
        start = nanoseconds()
        XCTAssertEqual(try drive!.flushUploads().count, 1)
        XCTAssertEqual(backend.commits, 2)
        probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.failures, 2)
        next = try XCTUnwrap(probe.nextAttemptAt)
        XCTAssertGreaterThanOrEqual(next, start + 4_000_000_000)
        XCTAssertLessThanOrEqual(next, nanoseconds() + 4_000_000_000)
        for _ in 0..<10 { _ = try drive!.flushUploads() }
        probe = try XCTUnwrap(journal("/file"))
        XCTAssertEqual(probe.failures, 12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(probe.nextAttemptAt), nanoseconds() + 900_000_000_000, "The delay is capped at 15 minutes")
        XCTAssertGreaterThan(try XCTUnwrap(probe.nextAttemptAt), nanoseconds() + 800_000_000_000)
        backend.failNotDispatched = nil
        XCTAssertTrue(try drive!.flushUploads().isEmpty)
        XCTAssertNil(try journal("/file"))
    }

    func testMixedVersionLegacyLockExcludesOldBinary() throws {
        try seed(Data("old".utf8)); try seed("other", Data("other".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("new".utf8))
        // An older binary holds upload.lock exclusively for its whole upload.
        let legacy = Darwin.open(state.appendingPathComponent("upload.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(legacy, 0); defer { Darwin.close(legacy) }
        XCTAssertEqual(flock(legacy, LOCK_EX), 0)
        let waited = expectation(description: "upload waits for the older binary")
        DispatchQueue.global().async {
            do { try drive.fsync("/file") } catch { XCTFail("Upload failed: \(error)") }
            waited.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(backend.commits, 0, "No upload may start while an older binary uploads")
        XCTAssertEqual(flock(legacy, LOCK_UN), 0)
        wait(for: [waited], timeout: 5)
        XCTAssertEqual(try remoteData(), Data("new".utf8))
        // While a new binary uploads, an older one cannot start, but other new uploads can.
        _ = try drive.write("/file", offset: 0, data: Data("two".utf8))
        _ = try drive.write("/other", offset: 0, data: Data("OTHER".utf8))
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        backend.onCommitOf = { path in if path == "/file" { started.signal(); _ = release.wait(timeout: .now() + 5) } }
        let gated = expectation(description: "gated upload finishes")
        DispatchQueue.global().async {
            do { try drive.fsync("/file") } catch { XCTFail("Upload failed: \(error)") }
            gated.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(flock(legacy, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        try drive.fsync("/other")
        XCTAssertEqual(try remoteData("other"), Data("OTHER".utf8))
        release.signal()
        wait(for: [gated], timeout: 5)
        XCTAssertEqual(flock(legacy, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(legacy, LOCK_UN), 0)
        XCTAssertEqual(try remoteData(), Data("two".utf8))
        // Published files leave no per-path lock files behind.
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("uploads").path).isEmpty)
    }

    // MARK: E4: upload only closed or idle files

    func testBackgroundPolicySkipsRecentWritesAndOpenFiles() throws {
        let drive = try engine()
        for name in ["/closed", "/open"] {
            _ = try drive.create(name, directory: false)
            _ = try drive.write(name, offset: 0, data: Data(name.utf8))
        }
        XCTAssertEqual(try drive.flushUploads(policy: .background) { _ in false }.count, 2)
        XCTAssertEqual(backend.commits, 0, "Files written moments ago are not idle yet")
        let policy = UploadPolicy(closedIdleNanoseconds: 50_000_000, openIdleNanoseconds: 60_000_000_000, pressureFraction: 0.5, respectsBackoff: true)
        Thread.sleep(forTimeInterval: 0.1)
        var asked: [String] = []
        let remaining = try drive.flushUploads(policy: policy) { asked.append($0); return $0 == "/open" }
        XCTAssertEqual(remaining.map(\.path), ["/open"])
        XCTAssertEqual(backend.committedPaths, ["/closed"])
        XCTAssertEqual(Set(asked), ["/closed", "/open"])
        XCTAssertEqual(try remoteData("closed"), Data("/closed".utf8))
        // Once closed, the idle file uploads.
        XCTAssertTrue(try drive.flushUploads(policy: policy) { _ in false }.isEmpty)
        // An immediate flush ignores idleness and open files.
        _ = try drive.write("/open", offset: 0, data: Data("again".utf8))
        XCTAssertTrue(try drive.flushUploads(policy: .immediate) { _ in true }.isEmpty)
        XCTAssertEqual(try remoteData("open"), Data("again".utf8))
    }

    func testJournalPressureMakesOpenFilesEligible() throws {
        let drive = try engine(journal: 64 * 1024)
        for (name, count) in [("/small", 4096), ("/large", 32 * 1024)] {
            _ = try drive.create(name, directory: false)
            if name == "/small" {
                _ = try drive.write(name, offset: 0, data: Data(repeating: 1, count: count))
                XCTAssertEqual(try drive.flushUploads(policy: .background) { _ in true }.count, 1, "Below pressure, open files wait")
            } else { _ = try drive.write(name, offset: 0, data: Data(repeating: 2, count: count)) }
        }
        // Half the journal is used: open, recent files upload too, largest first.
        XCTAssertTrue(try drive.flushUploads(policy: .background) { _ in true }.isEmpty)
        XCTAssertEqual(backend.committedPaths, ["/large", "/small"])
        XCTAssertEqual(try drive.status().pendingWriteBytes, 0)
    }

    func testWriteAtJournalLimitDrainsThenContinues() throws {
        let drive = try engine(journal: 3 * 4096)
        for name in ["/a", "/b", "/c"] {
            _ = try drive.create(name, directory: false)
            _ = try drive.write(name, offset: 0, data: Data(repeating: UInt8(name.utf8.last!), count: 4096))
        }
        XCTAssertEqual(backend.commits, 0)
        // Full: this write drains the journal through uploads, then lands locally.
        XCTAssertEqual(try drive.write("/c", offset: 4096, data: Data(repeating: 9, count: 4096)), 4096)
        XCTAssertEqual(Set(backend.committedPaths), ["/a", "/b", "/c"])
        XCTAssertEqual(try remoteData("a"), Data(repeating: UInt8(ascii: "a"), count: 4096))
        XCTAssertEqual(try drive.uploads().map(\.path), ["/c"])
        XCTAssertEqual(try drive.read("/c", offset: 4094, length: 4), Data([UInt8(ascii: "c"), UInt8(ascii: "c"), 9, 9]))
        try drive.fsync("/c")
        XCTAssertEqual(try remoteData("c"), Data(repeating: UInt8(ascii: "c"), count: 4096) + Data(repeating: 9, count: 4096))
        // A write that can never fit fails at once without uploading anything.
        let commits = backend.commits
        expectError(ENOSPC, try drive.write("/a", offset: 0, data: Data(count: 4 * 4096)))
        XCTAssertEqual(backend.commits, commits)
    }

    func testDrainAtLimitIsSkippedOffline() throws {
        let drive = try engine(journal: 2 * 4096)
        for name in ["/a", "/b"] {
            _ = try drive.create(name, directory: false)
            _ = try drive.write(name, offset: 0, data: Data(repeating: 1, count: 4096))
        }
        backend.failNotDispatched = ENETDOWN
        expectError(ENETDOWN, try drive.fsync("/a"))
        backend.failNotDispatched = nil
        XCTAssertTrue(try drive.status().offline)
        let commits = backend.commits
        expectError(ENOSPC, try drive.write("/b", offset: 4096, data: Data(repeating: 2, count: 4096)))
        XCTAssertEqual(backend.commits, commits, "Offline, a full journal fails at once instead of draining")
        XCTAssertEqual(try drive.uploads().count, 2)
        // Back online, uploads clear the offline state and the write succeeds.
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try drive.write("/b", offset: 4096, data: Data(repeating: 2, count: 4096)), 4096)
    }

    func testWriterAtLimitAndBackgroundFlushDoNotDeadlock() throws {
        let drive = try engine(journal: 4 * 4096)
        let names = ["/f0", "/f1", "/f2", "/f3"], rounds = 16
        for name in names { _ = try drive.create(name, directory: false) }
        let quick = UploadPolicy(closedIdleNanoseconds: 0, openIdleNanoseconds: 0, pressureFraction: 0.5, respectsBackoff: true)
        let finished = DispatchGroup(), stop = DispatchSemaphore(value: 0)
        let failure = NSLock(); var errors: [Error] = []
        DispatchQueue.global().async(group: finished) {
            do {
                for round in 0..<rounds {
                    for name in names { _ = try drive.write(name, offset: Int64(round * 4096), data: Data(repeating: UInt8(round), count: 4096)) }
                }
            } catch { failure.lock(); errors.append(error); failure.unlock() }
            stop.signal()
        }
        DispatchQueue.global().async(group: finished) {
            while stop.wait(timeout: .now()) == .timedOut {
                do { _ = try drive.flushUploads(policy: quick) } catch { failure.lock(); errors.append(error); failure.unlock(); return }
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "A writer at the limit and a background flush deadlocked")
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        for name in names {
            let data = try remoteData(String(name.dropFirst()))
            XCTAssertEqual(data.count, rounds * 4096)
            for round in 0..<rounds { XCTAssertEqual(data[round * 4096], UInt8(round)) }
        }
    }

    func testFailedBackgroundUploadBacksOffButExplicitFlushRetries() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("new".utf8))
        let quick = UploadPolicy(closedIdleNanoseconds: 0, openIdleNanoseconds: 0, pressureFraction: 1, respectsBackoff: true)
        backend.failNotDispatched = EAGAIN
        XCTAssertEqual(try drive.flushUploads(policy: quick).first?.lastErrno, EAGAIN)
        XCTAssertEqual(backend.commits, 1)
        backend.failNotDispatched = nil
        // Backed off: background passes leave the file alone although it is closed and idle.
        XCTAssertEqual(try drive.flushUploads(policy: quick).count, 1)
        XCTAssertEqual(backend.commits, 1)
        // An explicit flush (sync, the CLI, a drain) retries at once.
        XCTAssertTrue(try drive.flushUploads(policy: .immediate).isEmpty)
        XCTAssertEqual(backend.commits, 2)
        XCTAssertEqual(try remoteData(), Data("new".utf8))
        // Offline, background passes do nothing and probe storage at most every 15 s.
        _ = try drive.write("/file", offset: 0, data: Data("off".utf8))
        backend.failNotDispatched = ENETDOWN
        _ = try drive.flushUploads()
        backend.failNotDispatched = nil; backend.offline = true
        let stats = backend.stats, commits = backend.commits
        XCTAssertEqual(try drive.flushUploads(policy: quick).count, 1)
        XCTAssertEqual(backend.stats, stats + 1, "One reachability probe")
        XCTAssertEqual(try drive.flushUploads(policy: quick).count, 1)
        XCTAssertEqual(backend.stats, stats + 1, "No second probe within 15 s")
        XCTAssertEqual(backend.commits, commits)
    }

    func testCapacityExcludesPendingJournal() throws {
        let drive = try engine()
        XCTAssertNil(try drive.capacity())
        backend.capacityValue = VolumeCapacity(totalBytes: 1 << 20, availableBytes: 1 << 20)
        XCTAssertEqual(try drive.capacity(), VolumeCapacity(totalBytes: 1 << 20, availableBytes: 1 << 20))
        _ = try drive.create("/new", directory: false)
        _ = try drive.write("/new", offset: 0, data: Data(repeating: 1, count: 4096))
        XCTAssertEqual(try drive.capacity(), VolumeCapacity(totalBytes: 1 << 20, availableBytes: (1 << 20) - 4096))
        backend.capacityValue = VolumeCapacity(totalBytes: 1 << 20, availableBytes: 1024)
        XCTAssertEqual(try drive.capacity()?.availableBytes, 0)
    }

    // MARK: E6: the state lock is never held across network calls

    private func gatedEngine(_ gated: GatedBackend, cache: Int64 = 65536, lifetime: Int64 = 60_000_000_000,
                             readahead: ReadaheadPolicy = .disabled) throws -> Engine {
        try Engine(backend: gated, stateDirectory: state, cacheLimitBytes: cache, minFreeBytes: 0, blockSize: 4096, maxJournalBytes: 1 << 20,
                   tuning: EngineTuning(readahead: readahead, metadataLifetimeNanoseconds: lifetime))
    }
    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    func testColdFetchDoesNotHoldStateLock() throws {
        try seed("cold", Data(repeating: 5, count: 8192)); try seed("cached", Data(repeating: 6, count: 4096)); try seed("other", Data("other".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        XCTAssertEqual(try drive.read("/cached", offset: 0, length: 4096), Data(repeating: 6, count: 4096))
        let gate = gated.hold(.readSnapshot, "/cold")
        let cold = Background { try drive.read("/cold", offset: 4090, length: 100) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let elapsed = try seconds {
            XCTAssertEqual(try drive.read("/cached", offset: 10, length: 10), Data(repeating: 6, count: 10))
            XCTAssertEqual(try drive.stat("/other").size, 5)
            XCTAssertEqual(try drive.write("/other", offset: 0, data: Data("OTHER".utf8)), 5)
            XCTAssertEqual(try drive.status().pendingUploads, 1)
            XCTAssertEqual(try drive.list("/").map(\.name), ["cached", "cold", "other"])
            XCTAssertGreaterThan(try drive.allocatedLocalBytes("/cached"), 0)
        }
        XCTAssertLessThan(elapsed, 1, "Local work waited for a cold fetch")
        XCTAssertFalse(cold.finished)
        gate.release.signal()
        XCTAssertEqual(try cold.result(), Data(repeating: 5, count: 100))
    }

    func testCachedReadCompletesWhileStatIsGated() throws {
        try seed("cached", Data(repeating: 6, count: 4096)); try seed("slow", Data("slow".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        XCTAssertEqual(try drive.read("/cached", offset: 0, length: 4096), Data(repeating: 6, count: 4096))
        let gate = gated.hold(.stat, "/slow")
        let slow = Background { try drive.stat("/slow") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let elapsed = try seconds {
            XCTAssertEqual(try drive.read("/cached", offset: 100, length: 50), Data(repeating: 6, count: 50))
            XCTAssertEqual(try drive.stat("/cached").size, 4096)
        }
        XCTAssertLessThan(elapsed, 1, "A cached read waited for a metadata refresh of another file")
        gate.release.signal()
        XCTAssertEqual(try slow.result().size, 4)
    }

    func testConcurrentReadersOfOneBlockShareOneFetch() throws {
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        try seed(content)
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        _ = try drive.stat("/file")
        let gate = gated.hold(.readSnapshot, "/file")
        let first = Background { try drive.read("/file", offset: 0, length: 100) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let second = Background { try drive.read("/file", offset: 50, length: 100) }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(second.finished, "The second reader fetched on its own instead of joining the fetch in flight")
        gate.release.signal()
        XCTAssertEqual(try first.result(), content.subdata(in: 0..<100))
        XCTAssertEqual(try second.result(), content.subdata(in: 50..<150))
        XCTAssertEqual(gated.snapshotReads("/file"), 1)
        XCTAssertEqual(backend.readBytes, 4096)
    }

    func testReadRetriesWhenRemoteChangesDuringFetch() throws {
        try seed(Data(repeating: 1, count: 4096))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        _ = try drive.stat("/file")
        let gate = gated.hold(.readSnapshot, "/file")
        let reader = Background { try drive.read("/file", offset: 0, length: 4096) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        try seed(Data(repeating: 2, count: 4096))
        gate.release.signal()
        XCTAssertEqual(try reader.result(), Data(repeating: 2, count: 4096))
        XCTAssertEqual(gated.snapshotReads("/file"), 2, "One stale attempt, then one fetch of the new version")
        XCTAssertEqual(try drive.stat("/file").version, try backend.stat("/file").version)
    }

    func testReadAcrossConcurrentPublicationNeverMixesVersions() throws {
        try seed(Data(repeating: 1, count: 8192))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 4096), Data(repeating: 1, count: 4096))
        // The first block is cached at the old version; the second is fetched while a new version publishes.
        let gate = gated.hold(.readSnapshot, "/file", offset: 4096)
        let reader = Background { try drive.read("/file", offset: 0, length: 8192) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try drive.write("/file", offset: 0, data: Data(repeating: 2, count: 8192)), 8192)
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data(repeating: 2, count: 8192))
        gate.release.signal()
        XCTAssertEqual(try reader.result(), Data(repeating: 2, count: 8192), "A read mixed blocks of two versions")
    }

    func testSlowListCannotRegressMetadataAfterPublication() throws {
        try seed(Data("old!".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        let before = try drive.stat("/file")
        let gate = gated.hold(.list, "/", timing: .after)
        let lister = Background { try drive.list("/") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        _ = try drive.write("/file", offset: 0, data: Data("new!".utf8))
        try drive.fsync("/file")
        let published = try backend.stat("/file")
        gate.release.signal()
        XCTAssertEqual(try lister.result().map(\.version), [before.version], "The listing reports what storage said when it ran")
        XCTAssertEqual(try drive.stat("/file").version, published.version, "A slow listing regressed metadata recorded by a publication")
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 4), Data("new!".utf8))
    }

    func testConcurrentRefreshDoesNotInvalidatePin() throws {
        try seed(Data(repeating: 1, count: 4096))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, lifetime: 0)
        _ = try drive.stat("/file")
        // Storage answers this refresh with the first version; the answer arrives late.
        let gate = gated.hold(.stat, "/file", timing: .after)
        let refresher = Background { try drive.stat("/file") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        try seed(Data(repeating: 2, count: 4096))
        try drive.pin("/file")
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
        gate.release.signal()
        _ = try refresher.result()
        let pin = try XCTUnwrap(drive.status().pins.first)
        XCTAssertTrue(pin.complete, "A refresh that started before the pin invalidated it with older metadata")
        XCTAssertNil(pin.lastError)
        backend.offline = true
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 4096), Data(repeating: 2, count: 4096))
    }

    func testPinDoesNotBlockOtherReadsAndRejectsEditsDuringPin() throws {
        try seed("big", Data(repeating: 3, count: 3 * 4096)); try seed("other", Data(repeating: 4, count: 4096))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        let gate = gated.hold(.readSnapshot, "/big", offset: 4096)
        let pinning = Background { try drive.pin("/big") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let elapsed = try seconds {
            XCTAssertEqual(try drive.read("/other", offset: 0, length: 4096), Data(repeating: 4, count: 4096))
            XCTAssertEqual(try drive.read("/big", offset: 0, length: 10), Data(repeating: 3, count: 10))
            XCTAssertEqual(try drive.write("/big", offset: 0, data: Data("edit".utf8)), 4)
        }
        XCTAssertLessThan(elapsed, 1, "Reads and edits waited for a pin")
        gate.release.signal()
        XCTAssertThrowsError(try pinning.result()) { XCTAssertEqual(($0 as? DriveError)?.code, EBUSY) }
        let pin = try XCTUnwrap(drive.status().pins.first)
        XCTAssertFalse(pin.complete)
        XCTAssertNotNil(pin.lastError)
        XCTAssertEqual(try drive.read("/big", offset: 0, length: 6), Data("edit".utf8) + Data(repeating: 3, count: 2))
        // Once the edit uploads, pinning again completes.
        try drive.fsync("/big")
        try drive.pin("/big")
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
    }

    func testSupersededVersionIsNotPersistedIntoPinnedSpace() throws {
        try seed(Data(repeating: 1, count: 8192))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, lifetime: 0)
        try drive.pin("/file")
        let pinned = try drive.status().pinnedBytes
        XCTAssertGreaterThan(pinned, 0)
        try seed(Data(repeating: 2, count: 8192))
        // Storage returns the second version's block, then a third version is recorded before it lands.
        let gate = gated.hold(.readSnapshot, "/file", offset: 0, timing: .after)
        let reader = Background { try drive.read("/file", offset: 0, length: 4096) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        try seed(Data(repeating: 3, count: 8192))
        XCTAssertEqual(try drive.stat("/file").version, try backend.stat("/file").version)
        gate.release.signal()
        XCTAssertEqual(try reader.result(), Data(repeating: 2, count: 4096), "The read returns one consistent version")
        XCTAssertEqual(try drive.status().pinnedBytes, pinned, "A superseded block took pinned space")
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 4096), Data(repeating: 3, count: 4096))
    }

    func testDuplicatePathsInListingDoNotTrap() throws {
        try seed("a", Data("a".utf8)); try seed("b", Data("b".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated)
        gated.duplicateListings = true
        XCTAssertEqual(try drive.list("/").map(\.name), ["a", "b"])
        _ = try drive.create("/c", directory: false)
        XCTAssertEqual(try drive.list("/").map(\.name), ["a", "b", "c"])
        backend.offline = true
        XCTAssertEqual(try drive.list("/").map(\.name), ["a", "b", "c"])
    }

    // MARK: E8: sequential readahead, cloud tuning only

    private func movie(_ name: String = "movie", blocks: Int = 32) throws -> Data {
        let content = Data((0..<(blocks * 4096)).map { UInt8(truncatingIfNeeded: ($0 / 4096) &* 37 &+ $0 % 7) })
        try seed(name, content)
        return content
    }
    private func blockOf(_ content: Data, _ index: Int) -> Data { content.subdata(in: (index * 4096)..<((index + 1) * 4096)) }
    private func cloud(maxConcurrent: Int) -> ReadaheadPolicy { ReadaheadPolicy(maxBlocks: 8, maxConcurrent: maxConcurrent) }

    func testSequentialReadsPrefetchWithinCacheBudget() throws {
        let movie = try self.movie(), second = try self.movie("second"), third = try self.movie("third")
        // A 64 KiB cache of 4 KiB blocks: each window is at most min(8, 16 / 4) = 4
        // blocks, and all windows together at most 8 (half the cache).
        let drive = try gatedEngine(GatedBackend(backend), readahead: cloud(maxConcurrent: 2))
        for index in 0..<12 {
            XCTAssertEqual(try drive.read("/movie", offset: Int64(index * 4096), length: 4096), blockOf(movie, index))
            drive.waitForReadahead()
            let furthest = try XCTUnwrap(backend.fetchedBlocks("/movie").max())
            XCTAssertLessThanOrEqual(furthest, Int64(index + 4), "Readahead ran past its window")
            if index >= 1 { XCTAssertGreaterThan(furthest, Int64(index), "Sequential reads did not prefetch") }
            XCTAssertLessThanOrEqual(drive.readaheadWindows()["/movie"] ?? 0, 4)
        }
        let fetched = backend.fetchedBlocks("/movie")
        XCTAssertEqual(fetched.count, Set(fetched).count, "A prefetched block was fetched again")
        // Three streams at once share the budget.
        for index in 12..<20 {
            for (name, content) in [("movie", movie), ("second", second), ("third", third)] {
                let at = name == "movie" ? index : index - 12
                XCTAssertEqual(try drive.read("/" + name, offset: Int64(at * 4096), length: 4096), blockOf(content, at))
            }
            drive.waitForReadahead()
            let windows = drive.readaheadWindows()
            XCTAssertLessThanOrEqual(windows.values.reduce(0, +), 8, "Readahead windows exceed half the cache: \(windows)")
            XCTAssertTrue(windows.values.allSatisfy { $0 <= 4 }, "\(windows)")
        }
        XCTAssertLessThanOrEqual(try drive.status().cacheBytes, 65536)
    }

    func testRandomReadsDoNotPrefetch() throws {
        let movie = try self.movie()
        let drive = try gatedEngine(GatedBackend(backend), readahead: cloud(maxConcurrent: 2))
        let order = [9, 2, 14, 5, 11, 0, 7, 20, 3]
        for index in order {
            XCTAssertEqual(try drive.read("/movie", offset: Int64(index * 4096), length: 4096), blockOf(movie, index))
            drive.waitForReadahead()
        }
        XCTAssertEqual(Set(backend.fetchedBlocks("/movie")), Set(order.map(Int64.init)))
        XCTAssertTrue(drive.readaheadWindows().isEmpty)
    }

    func testSeekCancelsQueuedPrefetch() throws {
        let movie = try self.movie()
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, readahead: cloud(maxConcurrent: 1))
        let gate = gated.hold(.readSnapshot, "/movie", offset: 2 * 4096)
        XCTAssertEqual(try drive.read("/movie", offset: 0, length: 4096), blockOf(movie, 0))
        XCTAssertEqual(try drive.read("/movie", offset: 4096, length: 4096), blockOf(movie, 1))
        // Blocks 2 and 3 are queued; block 2 is in flight, block 3 waits behind it.
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try drive.read("/movie", offset: 20 * 4096, length: 4096), blockOf(movie, 20))
        gate.release.signal()
        drive.waitForReadahead()
        XCTAssertEqual(Set(backend.fetchedBlocks("/movie")), [0, 1, 2, 20], "A seek did not cancel queued readahead")
        XCTAssertNil(drive.readaheadWindows()["/movie"])
    }

    func testPrefetchSkipsFilesWithPendingWrites() throws {
        let movie = try self.movie()
        let drive = try gatedEngine(GatedBackend(backend), readahead: cloud(maxConcurrent: 2))
        XCTAssertEqual(try drive.write("/movie", offset: 0, data: Data("edit".utf8)), 4)
        for index in 0..<6 {
            let expected = index == 0 ? Data("edit".utf8) + blockOf(movie, 0).dropFirst(4) : blockOf(movie, index)
            XCTAssertEqual(try drive.read("/movie", offset: Int64(index * 4096), length: 4096), expected)
            drive.waitForReadahead()
        }
        XCTAssertEqual(Set(backend.fetchedBlocks("/movie")), Set(0..<6), "A file with local edits was prefetched")
        XCTAssertTrue(drive.readaheadWindows().isEmpty)
    }

    func testPrefetchStopsOnStaleVersion() throws {
        let movie = try self.movie()
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, readahead: cloud(maxConcurrent: 1))
        let gate = gated.hold(.readSnapshot, "/movie", offset: 2 * 4096)
        XCTAssertEqual(try drive.read("/movie", offset: 0, length: 4096), blockOf(movie, 0))
        XCTAssertEqual(try drive.read("/movie", offset: 4096, length: 4096), blockOf(movie, 1))
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let replaced = Data(repeating: 9, count: 32 * 4096)
        try seed("movie", replaced)
        gate.release.signal()
        drive.waitForReadahead()
        XCTAssertEqual(gated.snapshotReads("/movie"), 3, "Readahead continued after the file changed")
        XCTAssertNil(drive.readaheadWindows()["/movie"])
        XCTAssertEqual(try drive.read("/movie", offset: 2 * 4096, length: 4096), blockOf(replaced, 2))
    }

    func testPrefetchErrorDoesNotFailForegroundReader() throws {
        let movie = try self.movie()
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, readahead: cloud(maxConcurrent: 1))
        let gate = gated.hold(.readSnapshot, "/movie", offset: 2 * 4096, failing: DriveError(ECONNRESET, "Injected prefetch failure"))
        XCTAssertEqual(try drive.read("/movie", offset: 0, length: 4096), blockOf(movie, 0))
        XCTAssertEqual(try drive.read("/movie", offset: 4096, length: 4096), blockOf(movie, 1))
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        // The reader joins the failing prefetch's fetch.
        let reader = Background { try drive.read("/movie", offset: 2 * 4096, length: 4096) }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(reader.finished, "The reader did not wait for the prefetch in flight")
        gate.release.signal()
        XCTAssertEqual(try reader.result(), blockOf(movie, 2))
        drive.waitForReadahead()
        XCTAssertFalse(try drive.status().offline, "A failed prefetch marked the drive offline")
    }

    func testReadaheadDisabledForBYOTuning() throws {
        XCTAssertEqual(EngineTuning.byo.readahead, .disabled)
        XCTAssertEqual(EngineTuning.paraairCloud.readahead, .standard)
        let movie = try self.movie()
        let drive = try engine(cache: 65536)
        for index in 0..<8 {
            XCTAssertEqual(try drive.read("/movie", offset: Int64(index * 4096), length: 4096), blockOf(movie, index))
        }
        drive.waitForReadahead()
        XCTAssertEqual(backend.fetchedBlocks("/movie"), (0..<8).map(Int64.init))
        XCTAssertTrue(drive.readaheadWindows().isEmpty)
    }

    // MARK: Review fixes (2026-10-12)

    /// Another device publishes a second version; while this engine refreshes it, an
    /// unrelated file is created here. The refresh still counts.
    func testWriterRefreshOverlappingAnotherCreateBasesJournalOnFetchedVersion() throws {
        try seed(Data("aaaa".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, lifetime: 0)
        XCTAssertEqual(try drive.stat("/file").size, 4)
        try seed(Data("bbbbbbbb".utf8))
        let gate = gated.hold(.stat, "/file", timing: .after)
        let writer = Background { try drive.write("/file", offset: 0, data: Data("X".utf8)) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        _ = try drive.create("/other", directory: false)
        gate.release.signal()
        XCTAssertEqual(try writer.result(), 1)
        XCTAssertEqual(try drive.stat("/file").size, 8, "The journal is based on the version recorded before the refresh")
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 8), Data("Xbbbbbbb".utf8))
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data("Xbbbbbbb".utf8))
    }

    func testStatRefreshOverlappingAnotherCreateReturnsFetchedVersion() throws {
        try seed(Data("aaaa".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, lifetime: 0)
        XCTAssertEqual(try drive.stat("/file").size, 4)
        try seed(Data("bbbbbbbb".utf8))
        var gate = gated.hold(.stat, "/file", timing: .after)
        let changed = Background { try drive.stat("/file") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        _ = try drive.create("/other", directory: false)
        gate.release.signal()
        XCTAssertEqual(try changed.result().size, 8)
        // A removal seen across another change is recorded too: offline, the file is not reported.
        try FileManager.default.removeItem(at: remote.appendingPathComponent("file"))
        gate = gated.hold(.stat, "/file", timing: .after)
        let removed = Background { try drive.stat("/file") }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        _ = try drive.create("/another", directory: false)
        gate.release.signal()
        XCTAssertThrowsError(try removed.result()) { XCTAssertEqual(($0 as? DriveError)?.code, ENOENT) }
        backend.offline = true
        XCTAssertThrowsError(try drive.stat("/file"), "Offline, the removed file's old metadata answered") {
            XCTAssertEqual(($0 as? DriveError)?.code, ENETDOWN)
        }
    }

    func testReadWhoseRefreshesOverlapOtherChangesReturnsNewVersion() throws {
        try seed(Data("aaaa".utf8))
        let gated = GatedBackend(backend), drive = try gatedEngine(gated, lifetime: 0)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 4), Data("aaaa".utf8))
        try seed(Data("bbbbbbbb".utf8))
        let gates = (0..<3).map { _ in gated.hold(.stat, "/file", timing: .after) }
        let reader = Background { try drive.read("/file", offset: 0, length: 8) }
        // Every refresh of /file the read makes overlaps a create elsewhere.
        for (index, gate) in gates.enumerated() {
            var entered = false
            while !entered && !reader.finished { entered = gate.entered.wait(timeout: .now() + 0.05) == .success }
            guard entered else { break }
            _ = try drive.create("/other-\(index)", directory: false)
            gate.release.signal()
        }
        for gate in gates { gate.release.signal() }
        XCTAssertEqual(try reader.result(), Data("bbbbbbbb".utf8))
    }

    private func cacheFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("cache").path).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testBlockWhoseCacheFileWasDeletedIsCachedAgain() throws {
        let content = Data((0..<10_000).map { UInt8($0 % 251) })
        try seed(content)
        let drive = try engine(cache: 65536)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 10_000), content)
        let names = try cacheFiles()
        XCTAssertEqual(names.count, 3)
        for name in names { try FileManager.default.removeItem(at: state.appendingPathComponent("cache/" + name)) }
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 10_000), content)
        XCTAssertEqual(try cacheFiles(), names, "Blocks whose cache files were deleted are fetched but never cached again")
        let fetched = backend.readBytes
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 10_000), content)
        XCTAssertEqual(backend.readBytes, fetched)
        backend.offline = true
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 10_000), content)
    }

    func testRepinAfterLostCacheFilesRestoresOfflineData() throws {
        let content = Data((0..<8192).map { UInt8($0 % 241) })
        try seed(content)
        let drive = try engine(cache: 65536)
        try drive.pin("/file")
        let names = try cacheFiles()
        XCTAssertEqual(names.count, 2)
        for name in names { try FileManager.default.removeItem(at: state.appendingPathComponent("cache/" + name)) }
        try drive.pin("/file")
        XCTAssertTrue(try XCTUnwrap(drive.status().pins.first).complete)
        XCTAssertEqual(try cacheFiles(), names, "A pin reported complete without its offline data")
        XCTAssertGreaterThan(try drive.status().pinnedBytes, 0)
        backend.offline = true
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 8192), content)
    }

    func testCleanupFailureAfterPublicationDoesNotFailTheUpload() throws {
        try seed(Data("old".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("first".utf8))
        // An orphan payload that cannot be deleted makes the cleanup after publication fail.
        let orphan = state.appendingPathComponent("journal/" + UUID().uuidString + ".data")
        try Data("x".utf8).write(to: orphan)
        XCTAssertEqual(chflags(orphan.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(orphan.path, 0) }
        XCTAssertNoThrow(try drive.fsync("/file"), "A published upload was reported as failed")
        XCTAssertEqual(try remoteData(), Data("first".utf8))
        XCTAssertTrue(try drive.uploads().isEmpty)
        _ = try drive.write("/file", offset: 5, data: Data("-second".utf8))
        try drive.fsync("/file")
        XCTAssertEqual(try remoteData(), Data("first-second".utf8))
    }

    /// While an upload is in flight its journal leaves the table and a writer starts a
    /// new transaction, as after a publication. The failed upload must not put its
    /// sealed snapshot back over the writer's journal.
    func testFailedUploadNeverOverwritesAnotherTransactionsJournal() throws {
        try seed(Data("base".utf8))
        let drive = try engine()
        _ = try drive.write("/file", offset: 0, data: Data("first".utf8))
        let sealed = try transaction(drive)
        let database = state.appendingPathComponent("state.sqlite3")
        var written: Int?
        backend.failBeforeCommit = true
        backend.onCommitOf = { [weak backend] _ in
            backend?.onCommitOf = nil
            try? Database(database).delete("journal", "/file")
            written = try? Background { try drive.write("/file", offset: 0, data: Data("second".utf8)) }.result()
        }
        expectError(EIO, try drive.fsync("/file"))
        XCTAssertEqual(written, 6)
        let probe = try XCTUnwrap(journal("/file"))
        XCTAssertNotEqual(probe.transactionID, sealed, "The failed upload put its journal back over a newer one")
        XCTAssertFalse(probe.sealed)
        XCTAssertEqual(try drive.read("/file", offset: 0, length: 6), Data("second".utf8))
        backend.failBeforeCommit = false
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try remoteData(), Data("second".utf8))
    }

    func testNewFileUnderRemotelyRemovedDirectoryBecomesConflict() throws {
        let drive = try engine()
        _ = try drive.create("/d", directory: true)
        _ = try drive.create("/d/x", directory: false)
        _ = try drive.write("/d/x", offset: 0, data: Data("hello".utf8))
        // Another device removes the directory before the file uploads.
        try FileManager.default.removeItem(at: remote.appendingPathComponent("d"))
        expectError(ENOENT, try drive.fsync("/d/x"))
        let record = try XCTUnwrap(drive.uploads().first)
        XCTAssertEqual(record.state, "conflict", "A publishing rename that failed for a missing parent kept retrying")
        XCTAssertEqual(record.lastErrno, ENOENT)
        let commits = backend.commits
        XCTAssertEqual(try drive.flushUploads().count, 1)
        XCTAssertEqual(backend.commits, commits, "A conflict is not uploaded again")
        XCTAssertEqual(try drive.read("/d/x", offset: 0, length: 5), Data("hello".utf8))
        expectError(ESTALE, try drive.write("/d/x", offset: 5, data: Data("!".utf8)))
    }

    /// A namespace errno from a commit that did publish (a retried storage transaction)
    /// is not a conflict: the fence finds the receipt and the replay settles it.
    func testNamespaceErrnoAfterPublicationIsNotAConflict() throws {
        let drive = try engine()
        _ = try drive.create("/new", directory: false)
        _ = try drive.write("/new", offset: 0, data: Data("data".utf8))
        backend.lostReplyErrno = ENOENT
        backend.failAfterCommit = true
        expectError(ENOENT, try drive.fsync("/new"))
        XCTAssertEqual(try remoteData("new"), Data("data".utf8))
        let probe = try XCTUnwrap(journal("/new"))
        XCTAssertEqual(probe.state, "pending")
        XCTAssertTrue(probe.sealed)
        XCTAssertTrue(try drive.flushUploads().isEmpty)
        XCTAssertEqual(try remoteData("new"), Data("data".utf8))
    }
}
