import Foundation
import XCTest
import Darwin
import StreamDriveCore
@testable import StreamDriveCLI

private final class CLIMemoryVault: ConnectionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ConnectionSecrets] = [:]
    func load(id: String) throws -> ConnectionSecrets {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[id] else { throw DriveError(EACCES, "missing") }
        return value
    }
    func save(_ secrets: ConnectionSecrets, id: String) throws { lock.lock(); values[id] = secrets; lock.unlock() }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
}

/// A few ParaAir Cloud routes for the CLI (drive details, trash, restore); the full
/// service fake lives with the core tests.
private final class CLICloudStub: URLProtocol {
    static let host = "cli-test.cloud.invalid"
    static let drive = "3f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c"
    static let workspace = "ws_0123456789ABCDEFGHJKMNPQRS"
    private static let lock = NSLock()
    private static var logged: [(path: String, body: Data)] = []
    static var requests: [(path: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return logged }
    static func reset() { lock.lock(); logged = []; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        let path = request.url!.path
        Self.lock.lock(); Self.logged.append((path, body)); Self.lock.unlock()
        let drive = "/v1/drives/" + Self.drive
        let entry = { (path: String) -> [String: Any] in
            ["id": 42, "path": path, "kind": "file", "size": 9, "mtimeNs": "1791547200123456000", "version": "pv:9001", "mode": 420]
        }
        var status = 200, object: Any
        switch path {
        case drive:
            object = ["drive": ["id": Self.drive, "workspaceId": Self.workspace, "name": "ParaAir Cloud", "role": "owner", "writable": true,
                                "chunkSize": 4_194_304, "createdAt": "2026-10-09T12:00:00.000Z"],
                      "capacity": ["quotaBytes": 1_000_000_000_000, "usedBytes": 9, "retainedBytes": 9, "reservedBytes": 0, "availableBytes": 999_999_999_991],
                      "limits": ["chunkSize": 4_194_304, "maxFileBytes": 274_877_906_944, "maxManifestChunks": 65536, "maxListPage": 5000,
                                 "maxMoveDescendants": 10000, "readTokenSeconds": 300]]
        case drive + "/trash":
            object = ["items": [["nodeId": 42, "path": "/Movies/a.mov", "size": 9, "version": "pv:9001",
                                 "deletedAt": "2026-10-09T12:00:00.000Z", "expiresAt": "2026-11-08T12:00:00.000Z"]], "nextCursor": NSNull()]
        case drive + "/trash/42/restore":
            let to = (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["to"]
            object = ["entry": entry(to ?? "/Movies/a.mov")]
        default:
            status = 404
            object = ["error": ["code": path.hasPrefix("/v1/drives/") ? "drive_not_found" : "not_found", "message": "x", "requestId": "req_TEST"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CLIApplicationTests: XCTestCase {
    private func cloudFixture() throws -> (root: URL, account: CloudAccount, dependencies: EngineOpenDependencies) {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let vault = CLIMemoryVault()
        let account = CloudAccount(issuer: "https://" + CLICloudStub.host, userID: "usr_0123456789ABCDEFGHJKMNPQRS", email: "cli@example.test")
        try CloudAccountStore(root: root).signIn(account, tokens: OAuthTokens(accessToken: "pca_test", refreshToken: "pcr_test",
                                                                              expiresAt: Date().addingTimeInterval(3600), scope: "drive offline_access"),
                                                 vault: vault)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CLICloudStub.self]
        CLICloudStub.reset()
        return (root, account, EngineOpenDependencies(cloudVault: vault, cloudConfiguration: configuration, cloudPolicy: .init(allowsLoopbackHTTP: false)))
    }

    func testConnectCloudDriveAttachesWithInjectedDependencies() throws {
        let fixture = try cloudFixture()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies)
        let result = app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive, "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        let profile = try ProfileStore(root: fixture.root).load("studio")
        XCTAssertEqual(profile.backend, .paraairCloud); XCTAssertEqual(profile.cloudDriveID, CLICloudStub.drive)
        XCTAssertEqual(profile.cloudAccountID, fixture.account.id); XCTAssertEqual(profile.cloudIssuer, fixture.account.issuer)
        XCTAssertEqual(profile.blockSize, 4_194_304)
        XCTAssertEqual(CLICloudStub.requests.map(\.path), ["/v1/drives/" + CLICloudStub.drive])
        let accounts = app.run(["cloud-accounts", "--json"])
        XCTAssertEqual(try JSONDecoder().decode([CloudAccount].self, from: Data(accounts.stdout.utf8)).map(\.id), [fixture.account.id])
        XCTAssertEqual(app.run(["cloud-accounts"]).stdout, "\(fixture.account.id)\tParaAir Cloud\tsignedIn\tcli@example.test\n")
        XCTAssertNotEqual(app.run(["connect", "other", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive]).exitCode, 0,
                          "one drive per state folder")
        let replaced = app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive, "--replace", "--cache-mib", "4096"])
        XCTAssertEqual(replaced.exitCode, 0, replaced.stderr)
        XCTAssertEqual(try ProfileStore(root: fixture.root).load("studio").cacheLimitBytes, 4096 * 1_048_576)
        let fresh = try cloudFixture()
        let missing = CLIApplication(environment: ["STREAMDRIVE_HOME": fresh.root.path], dependencies: fresh.dependencies)
            .run(["connect", "studio", "--cloud-account", fresh.account.id, "--cloud-drive", "4f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c"])
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(try ProfileStore(root: fresh.root).list().isEmpty)
    }

    func testCloudConnectRejectsBYOFlags() throws {
        let fixture = try cloudFixture()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies)
        let base = ["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive]
        for extra in [["--metadata-url", "redis://nas/1"], ["--library", "/tmp/lib.dylib"], ["--credential-id", "cred"],
                      ["--fixture-root", fixture.root.path], ["--connection", fixture.account.id], ["--block-size", "1048576"]] {
            XCTAssertEqual(app.run(base + extra).exitCode, 2, extra.joined(separator: " "))
        }
        XCTAssertEqual(app.run(["connect", "studio", "--cloud-account", fixture.account.id]).exitCode, 2)
        XCTAssertEqual(app.run(["connect", "studio", "--cloud-drive", CLICloudStub.drive]).exitCode, 2)
        XCTAssertEqual(app.run(base + ["--block-size", "4194304"]).exitCode, 0)
        XCTAssertTrue(CLICloudStub.requests.count == 1, "rejected flags never reach the service")
    }

    func testConnectionDefaultsToFourMiBBlocks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StorageConnection(provider: .customS3, name: "Test NAS", state: .storageReady,
                                           bucket: "test-bucket", endpoint: "https://storage.example.com", region: "us-east-1")
        try ConnectionStore(root: root).save(connection)
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path])
        XCTAssertEqual(app.run(["connect", "cloud", "--connection", connection.id, "--metadata-url", "sqlite3:///missing/example.db"]).exitCode, 0)
        XCTAssertEqual(try ProfileStore(root: root).load("cloud").blockSize, 4_194_304)
        XCTAssertEqual(app.run(["connect", "small", "--connection", connection.id, "--metadata-url", "sqlite3:///missing/other.db", "--block-size", "1048576"]).exitCode, 0)
        XCTAssertEqual(try ProfileStore(root: root).load("small").blockSize, 1_048_576)
        let data = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        XCTAssertEqual(app.run(["connect", "fixture", "--fixture-root", data.path, "--min-free-mib", "0"]).exitCode, 0)
        XCTAssertEqual(try ProfileStore(root: root).load("fixture").blockSize, 1_048_576)
        XCTAssertTrue(CLIHelp.text("connect").contains("4194304 with --connection"))
    }

    func testReplaceKeepsStoredBlockSize() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.appendingPathComponent("state").path])
        let base = ["connect", "fixture", "--fixture-root", data.path, "--min-free-mib", "0"]
        XCTAssertEqual(app.run(base + ["--block-size", "65536"]).exitCode, 0)
        XCTAssertEqual(app.run(base + ["--replace", "--cache-mib", "64"]).exitCode, 0)
        let kept = try ProfileStore(root: root.appendingPathComponent("state")).load("fixture")
        XCTAssertEqual(kept.blockSize, 65536); XCTAssertEqual(kept.cacheLimitBytes, 64 * 1_048_576)
        XCTAssertEqual(app.run(base + ["--replace", "--block-size", "131072"]).exitCode, 0)
        XCTAssertEqual(try ProfileStore(root: root.appendingPathComponent("state")).load("fixture").blockSize, 131072)
    }

    func testTrashAndRestoreJSON() throws {
        let fixture = try cloudFixture()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies)
        XCTAssertEqual(app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive]).exitCode, 0)
        let trash = app.run(["--json", "trash", "studio"])
        XCTAssertEqual(trash.exitCode, 0, trash.stdout + trash.stderr)
        let items = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(trash.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.first?["nodeId"] as? Int, 42); XCTAssertEqual(items.first?["path"] as? String, "/Movies/a.mov")
        XCTAssertEqual(app.run(["trash", "studio"]).stdout, "42\t9\t/Movies/a.mov\n")
        let restored = app.run(["--json", "restore", "studio", "42"])
        XCTAssertEqual(restored.exitCode, 0, restored.stdout + restored.stderr)
        XCTAssertEqual(try JSONDecoder().decode(FileEntry.self, from: Data(restored.stdout.utf8)).path, "/Movies/a.mov")
        let moved = app.run(["--json", "restore", "studio", "42", "--to", "//Movies//b.mov"])
        XCTAssertEqual(try JSONDecoder().decode(FileEntry.self, from: Data(moved.stdout.utf8)).path, "/Movies/b.mov")
        let body = try XCTUnwrap(CLICloudStub.requests.last?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["to": "/Movies/b.mov"])
        XCTAssertEqual(app.run(["restore", "studio", "0"]).exitCode, 2)
        XCTAssertEqual(app.run(["restore", "studio", "abc"]).exitCode, 2)
        let data = fixture.root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: local) }
        try ProfileStore(root: local).save(DriveProfile(name: "fixture", backend: .local, localRoot: data.path, minFreeBytes: 0))
        let byo = CLIApplication(environment: ["STREAMDRIVE_HOME": local.path], dependencies: fixture.dependencies)
        XCTAssertEqual(byo.run(["trash", "fixture"]).exitCode, 2)
        XCTAssertEqual(byo.run(["restore", "fixture", "42"]).exitCode, 2)
    }

    func testDoctorReportsCloudProfile() throws {
        let fixture = try cloudFixture()
        let profile = DriveProfile(name: "studio", backend: .paraairCloud, blockSize: 4_194_304, cloudIssuer: fixture.account.issuer,
                                   cloudAccountID: fixture.account.id, cloudDriveID: CLICloudStub.drive)
        try ProfileStore(root: fixture.root).save(profile)
        let result = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path, "PARAAIR_APP_PATH": "/missing/ParaAir.app"],
                                    dependencies: fixture.dependencies).run(["doctor", "studio", "--json"])
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let checks = try XCTUnwrap(value["checks"] as? [[String: String]])
        let check = try XCTUnwrap(checks.first { $0["name"] == "profile:studio" })
        XCTAssertEqual(check["state"], "pass")
        XCTAssertEqual(check["detail"], "ParaAir Cloud drive \(CLICloudStub.drive) at \(fixture.account.issuer); service and Keychain access were not probed")
        XCTAssertFalse(checks.contains { $0["name"] == "library:studio" })
        XCTAssertTrue(CLICloudStub.requests.isEmpty, "doctor never contacts the service")
    }

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
