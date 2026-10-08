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

}
