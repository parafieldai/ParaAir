import Foundation
import XCTest
import Darwin
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

    private func cloudProfile(blockSize: Int = 4_194_304) -> DriveProfile {
        DriveProfile(name: "cloud", backend: .paraairCloud, blockSize: blockSize, cloudIssuer: "https://cloud.example.test",
                     cloudAccountID: "0f8fad5b-d9cb-469f-a165-70867728950e", cloudDriveID: "3f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c")
    }

    func testCloudProfileValidation() throws {
        let valid = cloudProfile()
        XCTAssertNoThrow(try valid.validate())
        var loopback = valid; loopback.cloudIssuer = "http://127.0.0.1:8787"
        XCTAssertNoThrow(try loopback.validate())
        var broken: [DriveProfile] = []
        for change in [{ (p: inout DriveProfile) in p.cloudIssuer = nil }, { $0.cloudAccountID = nil }, { $0.cloudDriveID = nil },
                       { $0.cloudIssuer = "https://cloud.example.test/" }, { $0.cloudIssuer = "http://cloud.example.test" },
                       { $0.cloudAccountID = "0F8FAD5B-D9CB-469F-A165-70867728950E" }, { $0.cloudDriveID = "not-a-uuid" },
                       { $0.metadataURL = "redis://nas/1" }, { $0.localRoot = "/fixture" }, { $0.libraryPath = "/lib.dylib" },
                       { $0.credentialID = "cred" }, { $0.objectCredentialID = "keys" },
                       { $0.connectionID = "0f8fad5b-d9cb-469f-a165-70867728950e" }] as [(inout DriveProfile) -> Void] {
            var profile = valid; change(&profile); broken.append(profile)
        }
        var local = DriveProfile(name: "fixture", backend: .local, localRoot: "/fixture"); local.cloudDriveID = valid.cloudDriveID
        var juicefs = DriveProfile(name: "remote", metadataURL: "redis://nas/1"); juicefs.cloudIssuer = valid.cloudIssuer
        broken += [local, juicefs]
        for profile in broken { XCTAssertThrowsError(try profile.validate(), "\(profile)") }
        var otherAccount = valid; otherAccount.cloudAccountID = "1f8fad5b-d9cb-469f-a165-70867728950e"
        XCTAssertTrue(valid.targetsSameStorage(as: otherAccount), "another member's account may replace the profile")
        var otherDrive = valid; otherDrive.cloudDriveID = "4f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c"
        XCTAssertFalse(valid.targetsSameStorage(as: otherDrive))
        XCTAssertFalse(valid.targetsSameStorage(as: loopback))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        try store.save(valid)
        XCTAssertEqual(try store.load("cloud"), valid)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("volumes/cloud"), withIntermediateDirectories: true)
        XCTAssertNoThrow(try store.save(otherAccount, overwrite: true))
        XCTAssertThrowsError(try store.save(otherDrive, overwrite: true)) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
        let json = try String(contentsOf: root.appendingPathComponent("profiles/cloud.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"backend\" : \"paraairCloud\""))
    }

    func testBindingDigestUnchangedForExistingProfiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let golden: [(DriveProfile, String)] = [
            (DriveProfile(name: "redis", metadataURL: "redis://nas.example.test/1", minFreeBytes: 0),
             "ebca7d4555162550fb13bc9dbf841b54f78cfa63f3883c43eda705548cd43258"),
            (DriveProfile(name: "connected", metadataURL: "sqlite3:///tmp/x.db", minFreeBytes: 0, credentialID: "metadata-cred",
                          connectionID: "0f8fad5b-d9cb-469f-a165-70867728950e"),
             "d159b71828095f7d5a78bda7b18670b3761e263ae021c0604a99784f68d2b3ec")
        ]
        for (profile, digest) in golden {
            _ = try Engine.open(profile: profile, stateRoot: root)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("volumes/\(profile.name)/target.sha256"), encoding: .utf8), digest)
        }
        _ = try Engine.open(profile: cloudProfile(), stateRoot: root)
        let cloud = try String(contentsOf: root.appendingPathComponent("volumes/cloud/target.sha256"), encoding: .utf8)
        XCTAssertFalse(golden.map(\.1).contains(cloud))
        var renamed = cloudProfile(); renamed.cloudAccountID = "1f8fad5b-d9cb-469f-a165-70867728950e"
        _ = try Engine.open(profile: renamed, stateRoot: root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("volumes/cloud/target.sha256"), encoding: .utf8), cloud,
                       "the account id is not part of the storage binding")
        var moved = cloudProfile(); moved.cloudDriveID = "4f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c"
        XCTAssertThrowsError(try Engine.open(profile: moved, stateRoot: root)) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
    }

    func testCloudProfileRequiresFourMiBBlocks() {
        XCTAssertNoThrow(try cloudProfile().validate())
        for size in [1_048_576, 8_388_608, 4096] {
            XCTAssertThrowsError(try cloudProfile(blockSize: size).validate()) { XCTAssertEqual(($0 as? DriveError)?.code, EINVAL) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-profile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
