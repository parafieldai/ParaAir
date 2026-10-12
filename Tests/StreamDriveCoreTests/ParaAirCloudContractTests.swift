import XCTest
import CryptoKit
import Darwin
@testable import StreamDriveCore

/// Asserts that the Swift client matches `contract/paraair-cloud-v1/` exactly.
/// The service runs the same fixtures; neither side keeps its own copy.
final class ParaAirCloudContractTests: XCTestCase {
    private func contract(_ name: String) throws -> Any {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contract/paraair-cloud-v1", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("contract/paraair-cloud-v1 is absent; this check is mandatory after integration")
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    private static let errnoNames: [String: Int32] = [
        "EINVAL": EINVAL, "EACCES": EACCES, "ENAMETOOLONG": ENAMETOOLONG, "EPROTO": EPROTO, "EIO": EIO, "EFBIG": EFBIG,
        "EROFS": EROFS, "EDQUOT": EDQUOT, "ENOENT": ENOENT, "ENXIO": ENXIO, "ESTALE": ESTALE, "EEXIST": EEXIST,
        "ENOTDIR": ENOTDIR, "EISDIR": EISDIR, "ENOTEMPTY": ENOTEMPTY, "EBUSY": EBUSY, "EXDEV": EXDEV, "ECANCELED": ECANCELED,
        "EAGAIN": EAGAIN, "ENOTSUP": ENOTSUP
    ]

    func testErrorTableMatchesContract() throws {
        let table = try XCTUnwrap(try contract("errors.json") as? [String: Any])
        XCTAssertEqual(table["version"] as? Int, 1)
        let rows = try XCTUnwrap(table["errors"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["code"] as? String }), Set(ParaAirCloudErrorCode.allCases.map(\.rawValue)))
        XCTAssertEqual(rows.count, ParaAirCloudErrorCode.allCases.count, "duplicate rows")
        for row in rows {
            let name = try XCTUnwrap(row["code"] as? String)
            let code = try XCTUnwrap(ParaAirCloudErrorCode(rawValue: name), name)
            XCTAssertEqual(code.httpStatus, row["http"] as? Int, name)
            XCTAssertEqual(Int(code.errno), row["errnoValue"] as? Int, name)
            XCTAssertEqual(Self.errnoNames[row["errno"] as? String ?? ""], code.errno, name)
            XCTAssertEqual(code.fencesTransaction, row["fences"] as? Bool, name)
        }
        let unknown = try XCTUnwrap(table["unknown"] as? [[String: Any]])
        XCTAssertEqual(Set(unknown.compactMap { $0["httpClass"] as? String }), ["4xx", "5xx"])
        for row in unknown {
            let status = row["httpClass"] as? String == "4xx" ? 418 : 599
            let error = ParaAirCloudErrorMap.error(status: status, body: Data(#"{"error":{"code":"not_in_table","message":"x"}}"#.utf8),
                                                   requestID: nil, phase: .reserveOrCommit)
            XCTAssertEqual(Int(error.code), row["errnoValue"] as? Int)
            XCTAssertEqual(Self.errnoNames[row["errno"] as? String ?? ""], error.code)
            XCTAssertEqual(row["fences"] as? Bool, false)
            XCTAssertNotEqual(error.disposition, .transactionAbsent)
        }
    }

    func testCanonicalPathMatchesSwiftColumn() throws {
        let cases = try XCTUnwrap((try contract("paths.json") as? [String: Any])?["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for item in cases {
            let input = try XCTUnwrap(item["input"] as? String)
            if let expected = item["swift"] as? String {
                XCTAssertEqual(try canonicalPath(input), expected, input.debugDescription)
            } else {
                let code = try XCTUnwrap(item["swift"] as? Int, input.debugDescription)
                XCTAssertThrowsError(try canonicalPath(input), input.debugDescription) { XCTAssertEqual(Int(($0 as? DriveError)?.code ?? 0), code) }
            }
        }
    }

    func testChunkPlanReproducesManifestVectors() throws {
        let inputs = try XCTUnwrap(try contract("manifest-cases.json") as? [String: Any])
        let outputs = try XCTUnwrap(try contract("manifests.json") as? [String: Any])
        let chunkSize = try XCTUnwrap(inputs["chunkSize"] as? Int)
        XCTAssertEqual(outputs["chunkSize"] as? Int, chunkSize)
        let cases = try XCTUnwrap(inputs["cases"] as? [[String: Any]])
        let expected = Dictionary(uniqueKeysWithValues: try XCTUnwrap(outputs["cases"] as? [[String: Any]]).map { ($0["name"] as! String, $0) })
        let required = ["create-empty", "create-two-chunks", "overwrite-middle", "truncate-then-extend", "shrink-last-partial",
                        "extend-partial-last-unchanged", "overlapping-extents-later-wins", "sparse-gap-zeros"]
        XCTAssertTrue(Set(required).isSubset(of: Set(cases.compactMap { $0["name"] as? String })))
        let blobs = try cloudTestRoot(self)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let output = try XCTUnwrap(expected[name], name)
            let base = (item["base"] as? String).map { Data($0.utf8) }
            let baseRefs: [ParaAirCloudManifestPage.ChunkRef]? = (output["baseChunks"] as? [[String: Any]])?.map {
                ParaAirCloudManifestPage.ChunkRef(index: $0["index"] as! Int, sha256: $0["sha256"] as! String, size: $0["size"] as! Int)
            }
            if let base, let baseRefs {
                for ref in baseRefs {
                    let slice = base[ref.index * chunkSize..<min(base.count, (ref.index + 1) * chunkSize)]
                    XCTAssertEqual(ParaAirCloudAPI.hex(SHA256.hash(data: slice)), ref.sha256, name)
                }
            }
            var extents: [WriteExtent] = []
            for (index, extent) in (item["extents"] as? [[String: Any]] ?? []).enumerated() {
                let data = Data((extent["data"] as! String).utf8)
                let blob = blobs.appendingPathComponent("\(name)-\(index).data")
                try data.write(to: blob)
                extents.append(WriteExtent(offset: Int64(extent["offset"] as! Int), length: Int64(data.count), blobURL: blob))
            }
            let commit = FileCommit(transactionID: UUID().uuidString, path: "/f", expectedVersion: base == nil ? nil : "pv:1",
                                    finalSize: Int64(item["finalSize"] as! Int), baseVisibleSize: Int64(item["baseVisibleSize"] as! Int),
                                    extents: extents)
            let plan = try ParaAirCloudChunkPlan.make(commit, base: baseRefs, chunkSize: chunkSize)
            let chunks = try XCTUnwrap(output["chunks"] as? [[String: Any]])
            XCTAssertEqual(plan.chunks.count, chunks.count, name)
            for (chunk, vector) in zip(plan.chunks, chunks) {
                XCTAssertEqual(chunk.index, vector["index"] as? Int, name)
                XCTAssertEqual(Int(chunk.range.count), vector["size"] as? Int, name)
                let bytes = try ParaAirCloudChunkPlan.bytes(chunk) { range in
                    guard let base else { throw DriveError(EIO, "no base") }
                    return base.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
                }
                switch chunk.source {
                case .reuse(let sha):
                    XCTAssertEqual(vector["reuse"] as? Bool, true, "\(name) chunk \(chunk.index)")
                    XCTAssertEqual(sha, vector["sha256"] as? String, name)
                case .build:
                    XCTAssertEqual(vector["reuse"] as? Bool, false, "\(name) chunk \(chunk.index)")
                }
                XCTAssertEqual(ParaAirCloudAPI.hex(SHA256.hash(data: bytes)), vector["sha256"] as? String, "\(name) chunk \(chunk.index)")
            }
        }
    }
}
