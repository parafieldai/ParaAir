import XCTest
import Darwin
@testable import StreamDriveCore

final class FileEntryMetadataTests: XCTestCase {
    func testAccessTimeRoundTripsAndLegacyMetadataStillDecodes() throws {
        let legacy = Data(#"{"id":3,"path":"/file","kind":"file","size":0,"modifiedNanoseconds":400000000123456789,"version":"v1","mode":420}"#.utf8)
        let old = try JSONDecoder().decode(FileEntry.self, from: legacy)
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertNil(oldJSON["accessedNanoseconds"])
        var currentJSON = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        currentJSON["accessedNanoseconds"] = Int64(200000000987654321)
        let current = try JSONDecoder().decode(FileEntry.self, from: JSONSerialization.data(withJSONObject: currentJSON))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        XCTAssertEqual((encoded["accessedNanoseconds"] as? NSNumber)?.int64Value, 200000000987654321)
    }

    func testLocalMetadataPreservesAccessTimeSeparatelyFromModification() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".runtime/tests/" + UUID().uuidString)
        let backend = try LocalDirectoryBackend(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try Data().write(to: url)
        let times = [timeval(tv_sec: 200000000, tv_usec: 123456), timeval(tv_sec: 400000000, tv_usec: 654321)]
        XCTAssertEqual(times.withUnsafeBufferPointer { Darwin.utimes(url.path, $0.baseAddress) }, 0)
        let entry = try backend.stat("/file")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        XCTAssertEqual((json["accessedNanoseconds"] as? NSNumber)?.int64Value, 200000000123456000)
        XCTAssertEqual(entry.modifiedNanoseconds, 400000000654321000)
    }
}
