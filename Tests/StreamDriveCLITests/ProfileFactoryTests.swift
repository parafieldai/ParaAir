import Foundation
import XCTest
import StreamDriveCore

final class ProfileFactoryTests: XCTestCase {
    func testStatusDoesNotLoadNativeLibraryOrFetchCredentials() throws {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-lazy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DriveProfile(name: "unavailable", libraryPath: "/missing/libstreamdrive.dylib", minFreeBytes: 0, credentialID: "unavailable-test-identifier")
        let engine = try Engine.open(profile: profile, stateRoot: root)
        XCTAssertEqual(try engine.status().cacheBytes, 0)
        XCTAssertEqual(try engine.uploads().count, 0)
    }

    func testLibraryIsRequiredWhenStorageIsAccessed() throws {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-lazy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DriveProfile(name: "unavailable", metadataURL: "redis://unavailable.invalid/0", libraryPath: "/missing/libstreamdrive.dylib", minFreeBytes: 0)
        let engine = try Engine.open(profile: profile, stateRoot: root)
        XCTAssertThrowsError(try engine.list("/"))
    }

    func testPersistentStateCannotBeReboundToAnotherTarget() throws {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-binding-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state")
        let original = DriveProfile(name: "fixture", backend: .local, localRoot: first.path, minFreeBytes: 0)
        _ = try Engine.open(profile: original, stateRoot: state).status()
        let replacement = DriveProfile(name: "fixture", backend: .local, localRoot: second.path, minFreeBytes: 0)
        XCTAssertThrowsError(try Engine.open(profile: replacement, stateRoot: state))
        _ = try Engine.open(profile: original, stateRoot: state).status()
    }
}
