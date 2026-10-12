import XCTest
import Darwin
@testable import StreamDriveCore

/// Opt-in, real Swift -> C ABI -> JuiceFS -> SQLite/local objects tests.
/// No mount, account, NAS, or cloud credentials are involved.
final class NativeBackendTests: XCTestCase {
    func testNativeMetadataCarriesAccessTimeWithoutFetchingContents() throws {
        let (_, _, backend) = try fixture()
        let entry = try backend.stat("/")
        XCTAssertNotNil(entry.accessedNanoseconds)
        XCTAssertEqual(try backend.metrics().objectReadBytes, 0)
    }
    private func fixture() throws -> (URL, URL, JuiceFSBackend) {
        guard let path = ProcessInfo.processInfo.environment["STREAMDRIVE_NATIVE_LIBRARY"] else {
            throw XCTSkip("Set STREAMDRIVE_NATIVE_LIBRARY to the built native/lib/libstreamdrive.dylib")
        }
        let library = URL(fileURLWithPath: path)
        let runtime = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/native-tests")
        let root = runtime.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let backend = try JuiceFSBackend.initializeLocal(libraryURL: library, directory: root.appendingPathComponent("volume"))
        addTeardownBlock { try? backend.close() }
        return (library, root, backend)
    }

    func testNativeSparseFileListsWithoutDataAndSeeksBeforeFullDownload() throws {
        let (library, root, backend) = try fixture()
        let block = Data(repeating: 0x6f, count: 1_048_576)
        let blob = root.appendingPathComponent("write.bin")
        try block.write(to: blob)
        let first = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/large-video.bin", expectedVersion: nil,
            finalSize: 64 * 1_048_576, baseVisibleSize: 0, extents: [
                WriteExtent(offset: 0, length: Int64(block.count), blobURL: blob),
                WriteExtent(offset: 60 * 1_048_576, length: Int64(block.count), blobURL: blob)
            ]))
        XCTAssertEqual(first.size, 64 * 1_048_576)
        let cold = try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + root.appendingPathComponent("volume/metadata.sqlite3").path)
        defer { try? cold.close() }
        let listed = try cold.list("/")
        XCTAssertEqual(listed.map(\.name), ["large-video.bin"])
        XCTAssertEqual(try cold.metrics().objectReadBytes, 0)
        XCTAssertThrowsError(try cold.stat("/.streamdrive/lock"))
        XCTAssertEqual(try cold.read("/large-video.bin", offset: 60 * 1_048_576, length: 4096), block.prefix(4096))
        let metrics = try cold.metrics()
        XCTAssertGreaterThan(metrics.objectReadBytes, 0)
        XCTAssertLessThan(metrics.objectReadBytes, first.size)
        XCTAssertEqual(metrics.applicationReadBytes, 4096)
    }

    func testNativeReplayStaleVersionAndShrinkingPreserveCorrectContents() throws {
        let (_, root, backend) = try fixture()
        let blob = root.appendingPathComponent("bytes")
        try Data("0123456789".utf8).write(to: blob)
        let base = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: nil, finalSize: 10,
            extents: [WriteExtent(offset: 0, length: 10, blobURL: blob)]))
        let transaction = FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version,
            finalSize: 10, baseVisibleSize: 3, extents: [])
        let updated = try backend.commit(transaction)
        XCTAssertEqual(try backend.commit(transaction).version, updated.version)
        XCTAssertEqual(try backend.read("/file", offset: 0, length: 10), Data([48,49,50,0,0,0,0,0,0,0]))
        XCTAssertThrowsError(try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version,
            finalSize: 10, extents: []))) { error in XCTAssertEqual((error as? DriveError)?.code, ESTALE) }
        XCTAssertThrowsError(try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: nil,
            finalSize: 0, extents: [])))
    }

    func testNativeFailureLeavesOriginalAndSupportsFileOperations() throws {
        let (_, root, backend) = try fixture()
        _ = try backend.createDirectory("/folder")
        let blob = root.appendingPathComponent("blob")
        try Data("original".utf8).write(to: blob)
        let base = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/folder/file", expectedVersion: nil, finalSize: 8,
            extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]))
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try backend.commit(FileCommit(transactionID: UUID().uuidString, path: base.path, expectedVersion: base.version,
            finalSize: 8, extents: [WriteExtent(offset: 0, length: 8, blobURL: missing)])))
        XCTAssertEqual(try backend.read(base.path, offset: 0, length: 8), Data("original".utf8))
        try backend.move(base.path, to: "/folder/renamed")
        XCTAssertEqual(try backend.list("/folder").map(\.name), ["renamed"])
        try backend.remove("/folder/renamed", directory: false)
        try backend.remove("/folder", directory: true)
        XCTAssertTrue(try backend.list("/").isEmpty)
    }

    func testNativeInvalidConfigurationReturnsSanitizedError() throws {
        let (library, _, _) = try fixture()
        XCTAssertThrowsError(try JuiceFSBackend(libraryURL: library, metadataURL: "invalid://person:do-not-print@example.com")) { error in
            XCTAssertFalse(error.localizedDescription.contains("do-not-print"))
        }
    }
    func testEngineJournalSurvivesReopenAndPublishesThroughNativeBridge() throws {
        let (library, root, backend) = try fixture()
        let state = root.appendingPathComponent("client-state")
        var first: Engine? = try Engine(backend: backend, stateDirectory: state, cacheLimitBytes: 4 * 1_048_576, minFreeBytes: 0)
        _ = try first!.create("/journal.bin", directory: false)
        try first!.write("/journal.bin", offset: 0, data: Data("head".utf8))
        try first!.write("/journal.bin", offset: 64 * 1_048_576, data: Data("tail".utf8))
        XCTAssertEqual(try first!.uploads().count, 1)
        first = nil
        try backend.close()

        let reopened = try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + root.appendingPathComponent("volume/metadata.sqlite3").path)
        defer { try? reopened.close() }
        let recovered = try Engine(backend: reopened, stateDirectory: state, cacheLimitBytes: 4 * 1_048_576, minFreeBytes: 0)
        XCTAssertEqual(try recovered.read("/journal.bin", offset: 64 * 1_048_576, length: 4), Data("tail".utf8))
        XCTAssertEqual(try reopened.metrics().objectReadBytes, 0)
        XCTAssertThrowsError(try reopened.stat("/journal.bin"))
        XCTAssertTrue(try recovered.flushUploads().isEmpty)
        XCTAssertEqual(try reopened.stat("/journal.bin").size, 64 * 1_048_576 + 4)

        let reader = try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + root.appendingPathComponent("volume/metadata.sqlite3").path)
        defer { try? reader.close() }
        let engine = try Engine(backend: reader, stateDirectory: root.appendingPathComponent("reader-state"), minFreeBytes: 0)
        XCTAssertEqual(try engine.list("/").map(\.name), ["journal.bin"])
        XCTAssertEqual(try reader.metrics().objectReadBytes, 0)
        XCTAssertEqual(try engine.read("/journal.bin", offset: 64 * 1_048_576, length: 4), Data("tail".utf8))
        XCTAssertGreaterThan(try reader.metrics().objectReadBytes, 0)
        XCTAssertLessThan(try reader.metrics().objectReadBytes, 1_048_576)
        XCTAssertEqual(try engine.status().objectReadBytes, try reader.metrics().objectReadBytes)
        let repeated = try Engine(backend: reader, stateDirectory: root.appendingPathComponent("reader-state"), minFreeBytes: 0)
        XCTAssertEqual(try repeated.status().objectReadBytes, try engine.status().objectReadBytes)
    }

    func testNativeCommitRejectionCarriesDisposition() throws {
        let (_, root, backend) = try fixture()
        let blob = root.appendingPathComponent("bytes")
        try Data("original".utf8).write(to: blob)
        let base = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: nil, finalSize: 8,
            extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]))
        func disposition(_ commit: FileCommit, _ errno: Int32, file: StaticString = #filePath, line: UInt = #line) -> CommitDisposition? {
            do { _ = try backend.commit(commit); XCTFail("Commit unexpectedly succeeded", file: file, line: line); return nil }
            catch let error as DriveError { XCTAssertEqual(error.code, errno, file: file, line: line); return error.disposition }
            catch { XCTFail("Unexpected error \(error)", file: file, line: line); return nil }
        }
        // Rejected in Swift or by the bridge before the receipt check.
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version,
                                              finalSize: 4, baseVisibleSize: 8, extents: []), EINVAL), .attemptNotDispatched)
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/.streamdrive/lock", expectedVersion: nil,
                                              finalSize: 0, extents: []), EACCES), .attemptNotDispatched)
        // Fenced after the receipt check: this identity can never publish.
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: "stale-version",
                                              finalSize: 8, extents: []), ESTALE), .transactionAbsent)
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version, finalSize: 8,
                                              extents: [WriteExtent(offset: 0, length: 8, blobURL: root.appendingPathComponent("missing"))]), ENOENT),
                       .transactionAbsent)
        // Only the publishing rename failed: ambiguous.
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/missing-parent/file", expectedVersion: nil,
                                              finalSize: 8, extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]), ENOENT), .ambiguous)
        XCTAssertEqual(try backend.read("/file", offset: 0, length: 8), Data("original".utf8))
        try backend.close()
        XCTAssertEqual(disposition(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version,
                                              finalSize: 8, extents: []), EBADF), .attemptNotDispatched)
    }

    /// The bridge reports a failed publishing rename as ambiguous; the engine settles it
    /// through the commit fence, so a new file under a removed directory is a conflict.
    func testEngineMarksNewFileUnderRemovedDirectoryAsConflict() throws {
        let (_, root, backend) = try fixture()
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("client-state"), minFreeBytes: 0)
        _ = try engine.create("/d", directory: true)
        _ = try engine.create("/d/x", directory: false)
        try engine.write("/d/x", offset: 0, data: Data("hello".utf8))
        // Another client removes the directory before the file uploads.
        try backend.remove("/d", directory: true)
        XCTAssertThrowsError(try engine.fsync("/d/x")) { XCTAssertEqual(($0 as? DriveError)?.code, ENOENT) }
        let record = try XCTUnwrap(engine.uploads().first)
        XCTAssertEqual(record.state, "conflict")
        XCTAssertEqual(record.lastErrno, ENOENT)
        XCTAssertEqual(try engine.read("/d/x", offset: 0, length: 5), Data("hello".utf8))
    }

    func testNativeCommitStatus() throws {
        let (_, root, backend) = try fixture()
        let blob = root.appendingPathComponent("bytes")
        try Data("original".utf8).write(to: blob)
        let transaction = UUID().uuidString
        let base = try backend.commit(FileCommit(transactionID: transaction, path: "/file", expectedVersion: nil, finalSize: 8,
            extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]))
        XCTAssertEqual(try backend.commitStatus(transactionID: transaction, path: "/file", expectedVersion: nil), .applied(base))
        let unpublished = UUID().uuidString
        XCTAssertEqual(try backend.commitStatus(transactionID: unpublished, path: "/file", expectedVersion: base.version), .absent)
        XCTAssertEqual(try backend.commitStatus(transactionID: unpublished, path: "/new", expectedVersion: nil), .absent)
        _ = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: base.version, finalSize: 3, extents: []))
        for (path, version) in [("/file", base.version as String?), ("/file", nil), ("/new", base.version)] {
            XCTAssertThrowsError(try backend.commitStatus(transactionID: unpublished, path: path, expectedVersion: version)) {
                XCTAssertEqual(($0 as? DriveError)?.code, ESTALE)
            }
        }
        XCTAssertEqual(try backend.read("/file", offset: 0, length: 8), Data("ori".utf8))
    }

    func testNativeConcurrentReadsReturnCorrectRanges() throws {
        let (_, root, backend) = try fixture()
        // Every 4 KiB page carries its own index, so a misplaced range is visible.
        var payload = Data(capacity: 8 * 1_048_576)
        for page in 0..<(8 * 256) { payload.append(Data(repeating: UInt8(truncatingIfNeeded: page &* 31 &+ 7), count: 4096)) }
        let blob = root.appendingPathComponent("payload")
        try payload.write(to: blob)
        let entry = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/movie.bin", expectedVersion: nil,
            finalSize: Int64(payload.count), extents: [WriteExtent(offset: 0, length: Int64(payload.count), blobURL: blob)]))
        let failures = NSLock(); var problems: [String] = [], requested: Int64 = 0
        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            for round in 0..<8 {
                let offset = (worker * 524_287 + round * 1_048_573) % (payload.count - 70_000), length = 4096 + (worker * 977 + round * 131) % 65_536
                let expected = payload.subdata(in: offset..<(offset + length))
                do {
                    let plain = try backend.read("/movie.bin", offset: Int64(offset), length: length)
                    let snapshot = try backend.readSnapshot("/movie.bin", version: entry.version, offset: Int64(offset), length: length)
                    failures.withLock { requested += Int64(2 * length) }
                    if plain != expected || snapshot != expected { failures.withLock { problems.append("range \(offset)+\(length)") } }
                    _ = try backend.stat("/movie.bin")
                } catch { failures.withLock { problems.append("\(offset)+\(length): \(error)") } }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        XCTAssertEqual(try backend.metrics().applicationReadBytes, requested)
    }

    func testNativeReadSnapshotRejectsChangedVersion() throws {
        let (_, root, backend) = try fixture()
        let blob = root.appendingPathComponent("bytes")
        try Data("original".utf8).write(to: blob)
        let first = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: nil, finalSize: 8,
            extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]))
        XCTAssertEqual(try backend.readSnapshot("/file", version: first.version, offset: 2, length: 4), Data("igin".utf8))
        try Data("replaced".utf8).write(to: blob)
        let second = try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: first.version, finalSize: 8,
            extents: [WriteExtent(offset: 0, length: 8, blobURL: blob)]))
        let objectBytes = try backend.metrics().objectReadBytes
        XCTAssertThrowsError(try backend.readSnapshot("/file", version: first.version, offset: 2, length: 4)) {
            XCTAssertEqual(($0 as? DriveError)?.code, ESTALE)
        }
        XCTAssertEqual(try backend.metrics().objectReadBytes, objectBytes, "A stale snapshot fetched content")
        XCTAssertEqual(try backend.readSnapshot("/file", version: second.version, offset: 2, length: 4), Data("plac".utf8))
        XCTAssertThrowsError(try backend.readSnapshot("/missing", version: first.version, offset: 0, length: 1)) {
            XCTAssertEqual(($0 as? DriveError)?.code, ENOENT)
        }
        XCTAssertThrowsError(try backend.readSnapshot("/file", version: second.version, offset: 0, length: 8 * 1_048_576 + 1)) {
            XCTAssertEqual(($0 as? DriveError)?.code, EINVAL)
        }
        // The engine retries a changed file and returns the new version only.
        let engine = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("client-state"), minFreeBytes: 0, blockSize: 4096)
        XCTAssertEqual(try engine.read("/file", offset: 0, length: 8), Data("replaced".utf8))
    }
}
