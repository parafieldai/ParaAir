import XCTest
import Darwin
@testable import StreamDriveCore

/// Sequential writes extend one journal payload (up to Engine.maxPayloadBytes) instead of adding one per call.
final class SequentialWriteTests: XCTestCase {
    private var work: URL!
    private var drive: Engine!
    private var journal: URL { work.appendingPathComponent("state/journal") }

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        drive = try Engine(backend: try LocalDirectoryBackend(root: work.appendingPathComponent("remote")),
                           stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 1 << 20, minFreeBytes: 0, blockSize: 4096,
                           maxJournalBytes: 1 << 30)
    }
    override func tearDownWithError() throws { drive = nil; try FileManager.default.removeItem(at: work) }

    private func payloads() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil).filter { $0.pathExtension == "data" }
    }
    private func bytes(_ count: Int, _ seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed }) }
    private func remote(_ name: String) throws -> Data { try Data(contentsOf: work.appendingPathComponent("remote/" + name)) }

    func testContiguousWritesShareOnePayload() throws {
        _ = try drive.create("/a.bin", directory: false)
        var expected = Data()
        for index in 0..<8 {
            let chunk = bytes(1000, UInt8(index))
            _ = try drive.write("/a.bin", offset: Int64(expected.count), data: chunk)
            expected += chunk
        }
        XCTAssertEqual(try payloads().count, 1)
        XCTAssertEqual(try drive.read("/a.bin", offset: 0, length: 1 << 20), expected)
        try drive.fsync("/a.bin")
        XCTAssertEqual(try remote("a.bin"), expected)
    }

    func testAGapOrAnOverwriteStartsANewPayload() throws {
        _ = try drive.create("/b.bin", directory: false)
        _ = try drive.write("/b.bin", offset: 0, data: bytes(100, 1))
        _ = try drive.write("/b.bin", offset: 200, data: bytes(100, 2))   // a gap
        _ = try drive.write("/b.bin", offset: 50, data: bytes(10, 3))     // an overwrite
        _ = try drive.write("/b.bin", offset: 60, data: bytes(10, 4))     // continues the overwrite
        XCTAssertEqual(try payloads().count, 3)
        var expected = bytes(100, 1) + Data(count: 100) + bytes(100, 2)
        expected.replaceSubrange(50..<60, with: bytes(10, 3))
        expected.replaceSubrange(60..<70, with: bytes(10, 4))
        XCTAssertEqual(try drive.read("/b.bin", offset: 0, length: 1000), expected)
        try drive.fsync("/b.bin")
        XCTAssertEqual(try remote("b.bin"), expected)
    }

    /// Bytes past a payload's recorded length (a crash between the append and the journal update) are never reused.
    func testAPayloadLongerThanItsSegmentIsNotExtended() throws {
        _ = try drive.create("/c.bin", directory: false)
        _ = try drive.write("/c.bin", offset: 0, data: bytes(100, 1))
        let payload = try XCTUnwrap(try payloads().first)
        let handle = try FileHandle(forWritingTo: payload)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 0xEE, count: 50)); try handle.close()
        _ = try drive.write("/c.bin", offset: 100, data: bytes(100, 2))
        XCTAssertEqual(try payloads().count, 2)
        XCTAssertEqual(try drive.read("/c.bin", offset: 0, length: 1000), bytes(100, 1) + bytes(100, 2))
    }

    func testATruncatedPayloadIsNotExtended() throws {
        _ = try drive.create("/d.bin", directory: false)
        _ = try drive.write("/d.bin", offset: 0, data: bytes(100, 1))
        try drive.truncate("/d.bin", size: 60)
        _ = try drive.write("/d.bin", offset: 60, data: bytes(40, 9))
        XCTAssertEqual(try drive.read("/d.bin", offset: 0, length: 1000), bytes(100, 1).prefix(60) + bytes(40, 9))
        try drive.fsync("/d.bin")
        XCTAssertEqual(try remote("d.bin"), bytes(100, 1).prefix(60) + bytes(40, 9))
    }

    func testPayloadsStopGrowingAtTheCap() throws {
        _ = try drive.create("/e.bin", directory: false)
        let chunk = Int(Engine.maxPayloadBytes / 4)
        for index in 0..<5 { _ = try drive.write("/e.bin", offset: Int64(index * chunk), data: Data(repeating: UInt8(index), count: chunk)) }
        XCTAssertEqual(try payloads().count, 2, "four writes fill the first payload; the fifth starts the next")
        XCTAssertEqual(try drive.read("/e.bin", offset: Int64(4 * chunk), length: 4), Data(repeating: 4, count: 4))
    }
}
