import Foundation
import XCTest
import StreamDriveCore
@testable import StreamDriveCLI

final class CLIApplicationTests: XCTestCase {
    func testParaAirHelpRetainsLegacyStateAndCommandGuidance() {
        let result = CLIApplication(environment: [:]).run(["help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("ParaAir — streamed files in Finder"))
        XCTAssertTrue(result.stdout.contains("Usage: paraair "))
        XCTAssertTrue(result.stdout.contains("streamdrive command remains available"))
        XCTAssertTrue(result.stdout.contains("Library/Application Support/StreamDrive"))
        XCTAssertTrue(result.stdout.contains("PARAAIR_APP_PATH"))
        XCTAssertTrue(CLIApplication(environment: [:]).run(["unknown"]).stderr.hasPrefix("paraair: "))
    }

    func testDoctorPrefersParaAirAndRetainsLegacyAppLookup() {
        let home = URL(fileURLWithPath: "/test-user")
        let newer = "/Applications/ParaAir.app", legacy = "/Applications/StreamDrive.app"
        let userNewer = "/test-user/Applications/ParaAir.app", userLegacy = "/test-user/Applications/StreamDrive.app"
        func selected(_ installed: Set<String>, environment: [String: String] = [:]) -> String {
            CLIApplication.applicationPath(environment: environment, homeDirectory: home, fileExists: installed.contains)
        }
        XCTAssertEqual(selected([newer, legacy, userNewer]), newer)
        XCTAssertEqual(selected([userNewer, legacy]), userNewer)
        XCTAssertEqual(selected([legacy, userLegacy]), legacy)
        XCTAssertEqual(selected([userLegacy]), userLegacy)
        XCTAssertEqual(selected([]), newer)
        XCTAssertEqual(selected([newer], environment: ["STREAMDRIVE_APP_PATH": "/legacy-override"]), "/legacy-override")
        XCTAssertEqual(selected([newer], environment: ["PARAAIR_APP_PATH": "/new-override", "STREAMDRIVE_APP_PATH": "/legacy-override"]), "/new-override")
    }

    func testSavedConnectionReferencesNeedNoCLICredentialsOrNetwork() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StorageConnection(provider: .customS3, name: "Test NAS", state: .storageReady,
                                           bucket: "test-bucket", endpoint: "https://storage.example.com", region: "us-east-1")
        try ConnectionStore(root: root).save(connection)
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path])
        let list = app.run(["connections", "--json"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertEqual(try JSONDecoder().decode([StorageConnection].self, from: Data(list.stdout.utf8)), [connection])
        let saved = app.run(["connect", "cloud", "--connection", connection.id, "--metadata-url", "sqlite3:///missing/example.db"])
        XCTAssertEqual(saved.exitCode, 0, saved.stderr)
        XCTAssertEqual(try ProfileStore(root: root).load("cloud").connectionID, connection.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("volumes/cloud").path))
        XCTAssertNotEqual(app.run(["connect", "bad", "--connection", "../elsewhere", "--metadata-url", "sqlite3:///missing/example.db"]).exitCode, 0)
    }

    func testConnectCreatesExplicitFixtureProfileWithoutHydratingFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: data.appendingPathComponent("hello.txt"))
        let state = root.appendingPathComponent("state")
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path])
        let connected = app.run(["connect", "fixture", "--fixture-root", data.path, "--min-free-mib", "0"])
        XCTAssertEqual(connected.exitCode, 0, connected.stderr)
        XCTAssertEqual(try ProfileStore(root: state).load("fixture").backend, .local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("volumes/fixture/cache").path))
        let status = app.run(["status", "fixture", "--json"])
        XCTAssertEqual(status.exitCode, 0, status.stderr)
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any])
        let drive = try XCTUnwrap(value["drive"] as? [String: Any])
        XCTAssertEqual((drive["cacheBytes"] as? NSNumber)?.intValue, 0)
    }

    func testJSONListingReturnsFinderRelevantEntries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: data.appendingPathComponent("a file.txt"))
        let state = root.appendingPathComponent("state")
        try ProfileStore(root: state).save(DriveProfile(name: "fixture", backend: .local, localRoot: data.path, minFreeBytes: 0))
        let result = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path]).run(["ls", "fixture", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let entries = try JSONDecoder().decode([FileEntry].self, from: Data(result.stdout.utf8))
        XCTAssertEqual(entries.map(\.path), ["/a file.txt"])
        XCTAssertEqual(entries.first?.size, 5)
    }

    func testStatusIsAvailableWithoutRemoteCredentialsOrLibrary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProfileStore(root: root).save(DriveProfile(name: "remote", libraryPath: "/missing/libstreamdrive.dylib", minFreeBytes: 0, credentialID: "missing-test-credential"))
        let result = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path]).run(["status", "remote", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("cacheBytes"))
        XCTAssertFalse(result.stdout.contains("missing-test-credential"))
    }

    func testSecretValuedUnknownFlagsAreNotEchoed() {
        let result = CLIApplication(environment: [:]).run(["connect", "home", "--password=DO_NOT_ECHO"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse((result.stdout + result.stderr).contains("DO_NOT_ECHO"))
    }

    func testConnectDoesNotOverwriteWithoutReplace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.appendingPathComponent("state").path])
        let arguments = ["connect", "fixture", "--fixture-root", data.path, "--min-free-mib", "0"]
        XCTAssertEqual(app.run(arguments).exitCode, 0)
        XCTAssertNotEqual(app.run(arguments).exitCode, 0)
        XCTAssertEqual(app.run(arguments + ["--replace"]).exitCode, 0)
    }

    func testFixtureRootCannotContainStateDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.appendingPathComponent("state").path])
        XCTAssertNotEqual(app.run(["connect", "fixture", "--fixture-root", root.path]).exitCode, 0)
    }

    func testReplacementCannotRetargetExistingState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state"), app = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path])
        XCTAssertEqual(app.run(["connect", "fixture", "--fixture-root", first.path, "--min-free-mib", "0"]).exitCode, 0)
        XCTAssertEqual(app.run(["status", "fixture"]).exitCode, 0)
        XCTAssertNotEqual(app.run(["connect", "fixture", "--fixture-root", second.path, "--replace"]).exitCode, 0)
        XCTAssertEqual(try ProfileStore(root: state).load("fixture").localRoot, first.path)
    }

    private func temporaryDirectory() throws -> URL {
        let root = testWorkspaceRoot().appendingPathComponent("streamdrive-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
