import Foundation
import XCTest
import StreamDriveCore

final class ProfileTests: XCTestCase {
    func testFinderNameKeepsStableProfileAndStorageIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let original = DriveProfile(name: "ParaAir", backend: .local, localRoot: "/fixture")
        try store.save(original)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("volumes/ParaAir"), withIntermediateDirectories: true)
        var renamed = original
        renamed.displayName = "Studio — Video Projects"
        try store.save(renamed, overwrite: true)
        let saved = try store.load("ParaAir")
        XCTAssertEqual(saved.finderName, "Studio — Video Projects")
        XCTAssertEqual(saved.name, original.name)
        XCTAssertTrue(saved.targetsSameStorage(as: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/Studio — Video Projects.json").path))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "displayName")
        XCTAssertEqual(try JSONDecoder().decode(DriveProfile.self, from: JSONSerialization.data(withJSONObject: legacy)).finderName, "ParaAir")
    }

    func testFinderNamesRejectPathComponentsAndControlCharacters() throws {
        for name in ["", " ", ".", "..", "a/b", "a:b", "a\\b", "a\n", "a\0", String(repeating: "a", count: 256)] {
            var profile = DriveProfile(name: "ParaAir", backend: .local, localRoot: "/fixture")
            profile.displayName = name
            XCTAssertThrowsError(try profile.validate(), name)
        }
    }
    func testLocalProfileRoundTripWithoutSecretFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DriveProfile(name: "fixture", backend: .local, localRoot: root.appendingPathComponent("data").path)
        let store = ProfileStore(root: root.appendingPathComponent("state"))
        try store.save(profile)
        XCTAssertEqual(try store.load("fixture"), profile)
        let encoded = try String(contentsOf: root.appendingPathComponent("state/profiles/fixture.json"), encoding: .utf8)
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("secret"))
    }

    func testSecretMetadataURLsCannotBeSaved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        for uri in ["redis://user:password@nas:6379/1", "redis://user@nas/1", "redis://nas/1?password=hidden", "redis://nas/1#hidden"] {
            let profile = DriveProfile(name: "home", metadataURL: uri, libraryPath: "/some/library.dylib")
            XCTAssertThrowsError(try store.save(profile))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/home.json").path))
    }

    func testSavingProfileDoesNotOverwriteUnlessExplicit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let original = DriveProfile(name: "home", backend: .local, localRoot: "/one")
        let replacement = DriveProfile(name: "home", backend: .local, localRoot: "/two")
        try store.save(original)
        XCTAssertThrowsError(try store.save(replacement))
        XCTAssertEqual(try store.load("home"), original)
        try store.save(replacement, overwrite: true)
        XCTAssertEqual(try store.load("home"), replacement)
    }

    func testProfileNamesCannotEscapeStore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        for name in ["../outside", "/outside", "two/parts", ".", ""] {
            XCTAssertThrowsError(try store.save(DriveProfile(name: name, backend: .local, localRoot: "/fixture")))
            XCTAssertThrowsError(try store.load(name))
        }
    }

    func testInvalidCacheLimitsAreRejected() {
        XCTAssertThrowsError(try DriveProfile(name: "home", backend: .local, localRoot: "/fixture", cacheLimitBytes: -1).validate())
        XCTAssertThrowsError(try DriveProfile(name: "home", backend: .local, localRoot: "/fixture", blockSize: 0).validate())
        XCTAssertThrowsError(try DriveProfile(name: "home", backend: .local, localRoot: "/fixture", maxJournalBytes: 0).validate())
    }

    func testStateRootPrecedence() {
        XCTAssertEqual(ProfileStore.resolveRoot(explicit: "/explicit", environment: ["STREAMDRIVE_HOME": "/env"]).path, "/explicit")
        XCTAssertEqual(ProfileStore.resolveRoot(explicit: nil, environment: ["STREAMDRIVE_HOME": "/env"]).path, "/env")
        XCTAssertTrue(ProfileStore.resolveRoot(explicit: nil, environment: [:]).path.hasSuffix("Library/Application Support/StreamDrive"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-profile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
