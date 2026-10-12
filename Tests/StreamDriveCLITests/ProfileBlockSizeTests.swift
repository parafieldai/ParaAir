import Foundation
import XCTest
import StreamDriveCore

/// Engine-lane coverage kept out of ProfileTests.swift, which the client lane owns.
final class ProfileBlockSizeTests: XCTestCase {
    func testStoredBlockSizeIsPreservedOnLoad() throws {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-block-size-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        // A connected drive made before 4 MiB blocks keeps the size its cache was cut at.
        let legacy = DriveProfile(name: "Legacy", metadataURL: "sqlite3:///fixture/Legacy.sqlite3", connectionID: UUID().uuidString.lowercased())
        XCTAssertEqual(legacy.blockSize, 1_048_576)
        try store.save(legacy)
        XCTAssertEqual(try store.load("Legacy").blockSize, 1_048_576)
        // JSON written by an older build decodes its explicit size unchanged.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["blockSize"] = 2_097_152
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("profiles/Legacy.json"))
        XCTAssertEqual(try store.load("Legacy").blockSize, 2_097_152)
        XCTAssertEqual(try store.list().map(\.blockSize), [2_097_152])
        // New connected drives get 4 MiB, and a saved profile round-trips it.
        let current = ConnectedDrive.profile(name: "Current", connectionID: UUID().uuidString.lowercased(),
                                             metadata: root.appendingPathComponent("metadata/Current.sqlite3"),
                                             libraryURL: URL(fileURLWithPath: "/fixture/libstreamdrive.dylib"), stateRoot: root)
        try store.save(current)
        XCTAssertEqual(try store.load("Current").blockSize, 4_194_304)
        XCTAssertEqual(try store.load("Legacy").blockSize, 2_097_152)
    }
}
