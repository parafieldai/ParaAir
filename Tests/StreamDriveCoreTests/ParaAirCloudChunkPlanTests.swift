import XCTest
import CryptoKit
import Darwin
@testable import StreamDriveCore

final class ParaAirCloudChunkPlanTests: XCTestCase {
    private var blobs: URL!
    override func setUpWithError() throws { blobs = try cloudTestRoot(self) }

    private func blob(_ text: String) throws -> URL {
        let url = blobs.appendingPathComponent(UUID().uuidString + ".data")
        try Data(text.utf8).write(to: url)
        return url
    }
    private func extent(_ offset: Int64, _ text: String) throws -> WriteExtent {
        WriteExtent(offset: offset, length: Int64(text.utf8.count), blobURL: try blob(text))
    }
    private func refs(_ base: String, size: Int = 8) -> [ParaAirCloudManifestPage.ChunkRef] {
        let data = Data(base.utf8)
        return stride(from: 0, to: data.count, by: size).enumerated().map { index, start in
            let slice = data[start..<min(start + size, data.count)]
            return .init(index: index, sha256: ParaAirCloudAPI.hex(SHA256.hash(data: slice)), size: slice.count)
        }
    }
    private func commit(final: Int64, visible: Int64, base: Bool = true, extents: [WriteExtent] = [], transaction: String = UUID().uuidString) -> FileCommit {
        FileCommit(transactionID: transaction, path: "/f", expectedVersion: base ? "pv:1" : nil, finalSize: final, baseVisibleSize: visible, extents: extents)
    }
    private func content(_ plan: ParaAirCloudChunkPlan, base: String) throws -> Data {
        let data = Data(base.utf8)
        return try plan.chunks.reduce(into: Data()) { output, chunk in
            output += try ParaAirCloudChunkPlan.bytes(chunk) { data.subdata(in: Int($0.lowerBound)..<Int($0.upperBound)) }
        }
    }

    func testReuseRequiresFullChunkBelowBaseVisibleSize() throws {
        let base = "0123456789abcdefghijklmn"
        let plan = try ParaAirCloudChunkPlan.make(commit(final: 24, visible: 12), base: refs(base), chunkSize: 8)
        XCTAssertEqual(plan.chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(plan.chunks[0].source, .reuse(sha256: refs(base)[0].sha256))
        XCTAssertEqual(plan.chunks[1].source, .build(baseBytes: 8..<12, overlays: []))
        XCTAssertEqual(plan.chunks[2].source, .build(baseBytes: nil, overlays: []))
        XCTAssertEqual(try content(plan, base: base), Data("0123456789ab".utf8) + Data(count: 12))
    }

    func testTruncateThenExtendDoesNotResurrect() throws {
        let base = "ABCDEFGHIJKLMNOPQRST"
        let plan = try ParaAirCloudChunkPlan.make(commit(final: 20, visible: 5, extents: [try extent(18, "yz")]), base: refs(base), chunkSize: 8)
        XCTAssertEqual(try content(plan, base: base), Data("ABCDE".utf8) + Data(count: 13) + Data("yz".utf8))
        XCTAssertFalse(plan.chunks.contains { if case .reuse = $0.source { return true }; return false })
    }

    func testLaterExtentOverridesEarlier() throws {
        let base = "0123456789abcdef"
        let plan = try ParaAirCloudChunkPlan.make(commit(final: 16, visible: 16, extents: [try extent(2, "aaaaaaaa"), try extent(4, "BB"), try extent(6, "c")]),
                                                  base: refs(base), chunkSize: 8)
        XCTAssertEqual(try content(plan, base: base), Data("01aaBBcaaa abcdef".replacingOccurrences(of: " ", with: "").utf8))
        // Bytes 0..<2 of chunk 0 are not overwritten, so its visible base range is fetched.
        if case .build(let baseBytes, let overlays) = plan.chunks[0].source {
            XCTAssertEqual(baseBytes, 0..<8); XCTAssertEqual(overlays.count, 3)
        } else { XCTFail("Chunk 0 must be rebuilt") }
    }

    func testPartialLastChunkIsRebuiltWhenLengthChanges() throws {
        let base = "0123456789ab"
        let grown = try ParaAirCloudChunkPlan.make(commit(final: 14, visible: 12), base: refs(base), chunkSize: 8)
        XCTAssertEqual(grown.chunks[0].source, .reuse(sha256: refs(base)[0].sha256))
        XCTAssertEqual(grown.chunks[1].source, .build(baseBytes: 8..<12, overlays: []))
        XCTAssertEqual(try content(grown, base: base), Data("0123456789ab".utf8) + Data(count: 2))
        let shrunk = try ParaAirCloudChunkPlan.make(commit(final: 10, visible: 10), base: refs(base), chunkSize: 8)
        XCTAssertEqual(shrunk.chunks[1].source, .build(baseBytes: 8..<10, overlays: []))
        XCTAssertEqual(try content(shrunk, base: base), Data("0123456789".utf8))
    }

    func testSparseGapIsZeroFilled() throws {
        let plan = try ParaAirCloudChunkPlan.make(commit(final: 30, visible: 0, base: false, extents: [try extent(0, "head"), try extent(26, "tail")]),
                                                  base: nil, chunkSize: 8)
        XCTAssertEqual(plan.chunks.count, 4)
        XCTAssertEqual(plan.chunks[1].source, .build(baseBytes: nil, overlays: []))
        XCTAssertEqual(try content(plan, base: ""), Data("head".utf8) + Data(count: 22) + Data("tail".utf8))
    }

    func testRejectsInvalidSizesExtentsAndTransactionID() throws {
        let base = refs("0123456789")
        let blob = try self.blob("x")
        let invalid: [(FileCommit, [ParaAirCloudManifestPage.ChunkRef]?)] = [
            (commit(final: -1, visible: 0, base: false), nil),
            (commit(final: 4, visible: 5), base),
            (commit(final: 10, visible: 10, extents: [WriteExtent(offset: 10, length: 1, blobURL: blob)]), base),
            (commit(final: 10, visible: 10, extents: [WriteExtent(offset: -1, length: 1, blobURL: blob)]), base),
            (commit(final: 10, visible: 10, extents: [WriteExtent(offset: 0, length: 1, blobURL: URL(string: "https://example.test/x")!)]), base),
            (commit(final: 10, visible: 10, transaction: "not-a-uuid"), base),
            (commit(final: 10, visible: 3, base: false), nil),
            (commit(final: 20, visible: 20), base)
        ]
        for (value, refs) in invalid {
            expectDriveError(EINVAL, disposition: .attemptNotDispatched) { _ = try ParaAirCloudChunkPlan.make(value, base: refs, chunkSize: 8) }
        }
    }

    func testMoreThan65536ChunksIsEFBIG() throws {
        XCTAssertEqual(try ParaAirCloudChunkPlan.make(commit(final: 8 * 65536, visible: 0, base: false), base: nil, chunkSize: 8).chunks.count, 65536)
        expectDriveError(EFBIG, disposition: .attemptNotDispatched) {
            _ = try ParaAirCloudChunkPlan.make(self.commit(final: 8 * 65536 + 1, visible: 0, base: false), base: nil, chunkSize: 8)
        }
    }

    func testShortBlobIsEIO() throws {
        let short = WriteExtent(offset: 0, length: 6, blobURL: try blob("abc"))
        let plan = try ParaAirCloudChunkPlan.make(commit(final: 6, visible: 0, base: false, extents: [short]), base: nil, chunkSize: 8)
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try ParaAirCloudChunkPlan.bytes(plan.chunks[0]) { _ in Data() } }
        let link = blobs.appendingPathComponent("link.data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try blob("abcdef"))
        let linked = try ParaAirCloudChunkPlan.make(commit(final: 6, visible: 0, base: false, extents: [WriteExtent(offset: 0, length: 6, blobURL: link)]),
                                                    base: nil, chunkSize: 8)
        XCTAssertThrowsError(try ParaAirCloudChunkPlan.bytes(linked.chunks[0]) { _ in Data() })
    }
}
