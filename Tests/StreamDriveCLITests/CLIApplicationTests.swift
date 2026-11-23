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
    /// What GET /v1/drives lists (names only; the drive above is the one whose details exist).
    private static var listed: [(id: String, name: String)] = [(drive, "ParaAir Cloud")]
    static var requests: [(path: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return logged }
    static func reset() { lock.lock(); logged = []; listed = [(drive, "ParaAir Cloud")]; lock.unlock() }
    static func list(_ drives: [(id: String, name: String)]) { lock.lock(); listed = drives; lock.unlock() }

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
        case "/v1/drives":
            Self.lock.lock(); let drives = Self.listed; Self.lock.unlock()
            object = ["drives": drives.map { ["id": $0.id, "workspaceId": Self.workspace, "name": $0.name, "role": "admin", "writable": true,
                                               "chunkSize": 4_194_304, "createdAt": "2026-10-09T12:00:00.000Z"] }]
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
        XCTAssertEqual(missing.exitCode, 14, "drive_not_found has its own exit code")
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

    func testConflictsListAndResolveFromTheCommandLine() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: data.appendingPathComponent("a.txt"))
        try Data("original".utf8).write(to: data.appendingPathComponent("b.txt"))
        let state = root.appendingPathComponent("state")
        let profile = DriveProfile(name: "fixture", backend: .local, localRoot: data.path, minFreeBytes: 0)
        try ProfileStore(root: state).save(profile)
        do {
            // Edits made here while another device replaced both files.
            let engine = try Engine.open(profile: profile, stateRoot: state)
            for name in ["a.txt", "b.txt"] {
                try engine.truncate("/" + name, size: 0)
                _ = try engine.write("/" + name, offset: 0, data: Data("mine".utf8))
                try Data("theirs!".utf8).write(to: data.appendingPathComponent(name))
                XCTAssertThrowsError(try engine.fsync("/" + name))
            }
        }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path])
        let listed = app.run(["conflicts", "fixture"])
        XCTAssertEqual(listed.exitCode, 0, listed.stderr)
        XCTAssertTrue(listed.stdout.contains("changed-elsewhere\t4\t") && listed.stdout.contains("/a.txt") && listed.stdout.contains("/b.txt"), listed.stdout)
        let status = app.run(["status", "fixture"])
        XCTAssertTrue(status.stdout.contains("conflicts: 2"), status.stdout)
        let kept = app.run(["resolve", "fixture", "/a.txt", "--keep-mine-as", "a mine.txt", "--json"])
        XCTAssertEqual(kept.exitCode, 0, kept.stderr)
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(kept.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(value["resolution"] as? String, "keep-mine")
        XCTAssertEqual(value["uploaded"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("a mine.txt"), encoding: .utf8), "mine")
        let exported = root.appendingPathComponent("b export.txt")
        XCTAssertEqual(app.run(["resolve", "fixture", "/b.txt", "--export-to", exported.path]).exitCode, 0)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "mine")
        XCTAssertEqual(app.run(["conflicts", "fixture"]).stdout, "No changes wait for a decision.\n")
        let missing = app.run(["resolve", "fixture", "/b.txt", "--keep-theirs"])
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.stderr.contains("no change waiting"), missing.stderr)
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

/// A stand-in for macOS in the setup commands: no app is opened and no real settings are read.
private final class FakeSystem {
    var installed = true, running = false, extensionState = "enabled"
    var folders: [String] = []
    var opened: [URL] = []
    var mounted: [MountedVolume] = []
    var sleeps = 0
    var onOpen: ((URL) -> Void)?
    var onSleep: ((Int) -> Void)?
    var system: CLISystem {
        CLISystem(appInfo: { [unowned self] _ in installed ? .init(bundleID: "dev.streamdrive.app", version: "0.2.0", build: "42") : nil },
                  isRunning: { [unowned self] _ in running },
                  extensionState: { [unowned self] _, _ in extensionState },
                  appStateFolders: { [unowned self] _ in folders },
                  openURL: { [unowned self] _, url in opened.append(url); onOpen?(url) },
                  mountedVolumes: { [unowned self] in mounted },
                  sleep: { [unowned self] _ in sleeps += 1; onSleep?(sleeps) })
    }
}

extension CLIApplicationTests {
    private func object(_ result: CLIExecution) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], result.stdout + result.stderr)
    }

    func testSetupStatusReportsAppExtensionAccountsAndDrives() throws {
        let fixture = try cloudFixture(), fake = FakeSystem()
        fake.running = true
        fake.folders = ["/nonexistent-app-folder"] // ignored: STREAMDRIVE_HOME names the only folder
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies, system: fake.system)
        XCTAssertEqual(app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive]).exitCode, 0)
        let result = app.run(["setup-status", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stdout)
        let value = try object(result)
        let appInfo = try XCTUnwrap(value["app"] as? [String: Any])
        XCTAssertEqual(appInfo["installed"] as? Bool, true); XCTAssertEqual(appInfo["running"] as? Bool, true)
        XCTAssertEqual(appInfo["version"] as? String, "0.2.0"); XCTAssertEqual(appInfo["build"] as? String, "42"); XCTAssertNotNil(appInfo["path"])
        XCTAssertEqual((value["extension"] as? [String: Any])?["state"] as? String, "enabled")
        let accounts = try XCTUnwrap(value["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0]["id"] as? String, fixture.account.id)
        XCTAssertEqual(accounts[0]["state"] as? String, "signedIn")
        XCTAssertEqual(accounts[0]["email"] as? String, "cli@example.test")
        XCTAssertEqual(accounts[0]["stateDirectory"] as? String, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(accounts[0]["workspaceIds"] as? [String], [CLICloudStub.workspace])
        let profiles = try XCTUnwrap(value["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["profile"] as? String, "studio")
        XCTAssertEqual(profiles[0]["cloudDriveId"] as? String, CLICloudStub.drive)
        XCTAssertEqual(profiles[0]["cloudAccountId"] as? String, fixture.account.id)
        XCTAssertEqual(profiles[0]["workspaceId"] as? String, CLICloudStub.workspace)
        XCTAssertEqual(profiles[0]["mounted"] as? Bool, false); XCTAssertEqual(profiles[0]["healthy"] as? Bool, false)

        fake.installed = false
        let missing = try object(app.run(["setup-status", "--json"]))
        XCTAssertEqual((missing["app"] as? [String: Any])?["installed"] as? Bool, false)
        XCTAssertNil((missing["app"] as? [String: Any])?["path"])
        XCTAssertEqual((missing["extension"] as? [String: Any])?["state"] as? String, "notDiscovered")
        XCTAssertTrue(fake.opened.isEmpty, "setup-status never opens the app")
    }

    func testCloudSignInOpensTheAppAndWaitsForAnAccount() throws {
        let fixture = try cloudFixture(), fake = FakeSystem()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies, system: fake.system)
        // Already signed in: answered at once, nothing opened.
        let already = app.run(["cloud-sign-in", "--json"])
        XCTAssertEqual(already.exitCode, 0); XCTAssertEqual(try object(already)["id"] as? String, fixture.account.id)
        XCTAssertTrue(fake.opened.isEmpty)

        let store = CloudAccountStore(root: fixture.root)
        _ = try store.signOut(fixture.account.id, vault: fixture.dependencies.cloudVault)
        let opened = app.run(["cloud-sign-in", "--json"])
        XCTAssertEqual(opened.exitCode, 0); XCTAssertEqual(try object(opened)["opened"] as? Bool, true)
        XCTAssertEqual(fake.opened, [URL(string: "paraair://cloud/sign-in")!])

        fake.onSleep = { count in
            guard count == 2 else { return }
            try? store.signIn(fixture.account, tokens: OAuthTokens(accessToken: "pca_again", refreshToken: "pcr_again",
                                                                   expiresAt: Date().addingTimeInterval(3600), scope: "drive offline_access"),
                              vault: fixture.dependencies.cloudVault)
        }
        let waited = app.run(["cloud-sign-in", "--wait", "30", "--json"])
        XCTAssertEqual(waited.exitCode, 0, waited.stdout)
        XCTAssertEqual(try object(waited)["id"] as? String, fixture.account.id)
        XCTAssertEqual(fake.sleeps, 2)

        _ = try store.signOut(fixture.account.id, vault: fixture.dependencies.cloudVault)
        fake.onSleep = nil; fake.sleeps = 0
        let timedOut = app.run(["cloud-sign-in", "--wait", "3", "--json"])
        XCTAssertEqual(timedOut.exitCode, 11)
        XCTAssertEqual(try object(timedOut)["code"] as? String, "not_signed_in")
        XCTAssertEqual(fake.sleeps, 3)

        fake.installed = false
        let notInstalled = app.run(["cloud-sign-in", "--json"])
        XCTAssertEqual(notInstalled.exitCode, 10)
        XCTAssertEqual(try object(notInstalled)["code"] as? String, "app_not_installed")
    }

    func testCloudDrivesAndConnectByName() throws {
        let fixture = try cloudFixture(), fake = FakeSystem()
        CLICloudStub.list([(CLICloudStub.drive, "ParaOS"), ("5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "Archive")])
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies, system: fake.system)
        let listed = app.run(["cloud-drives", "--cloud-account", fixture.account.id, "--json"])
        XCTAssertEqual(listed.exitCode, 0, listed.stdout)
        let drives = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(drives.map { $0["name"] as? String }, ["ParaOS", "Archive"])
        XCTAssertEqual(Set(drives[0].keys), ["id", "workspaceId", "name", "role", "writable"])

        let connected = app.run(["connect", "ParaOS", "--cloud-account", fixture.account.id, "--cloud-drive-name", "ParaOS", "--json"])
        XCTAssertEqual(connected.exitCode, 0, connected.stdout)
        XCTAssertEqual(try ProfileStore(root: fixture.root).load("ParaOS").cloudDriveID, CLICloudStub.drive)

        let fresh = try cloudFixture()
        let other = CLIApplication(environment: ["STREAMDRIVE_HOME": fresh.root.path], dependencies: fresh.dependencies, system: fake.system)
        CLICloudStub.list([(CLICloudStub.drive, "Dup"), ("5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "Dup")])
        for name in ["Missing", "Dup"] {
            let result = other.run(["connect", "x", "--cloud-account", fresh.account.id, "--cloud-drive-name", name, "--json"])
            XCTAssertEqual(result.exitCode, 14, name)
            XCTAssertEqual(try object(result)["code"] as? String, "drive_not_found")
        }
        XCTAssertTrue(try ProfileStore(root: fresh.root).list().isEmpty)
        let unknown = other.run(["cloud-drives", "--cloud-account", "6b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e", "--json"])
        XCTAssertEqual(unknown.exitCode, 11)
        XCTAssertEqual(other.run(["connect", "x", "--cloud-drive-name", "ParaOS"]).exitCode, 2)
    }

    func testMountWithoutAMountPointAsksTheAppAndWaitsForVolumes() throws {
        let root = try temporaryDirectory(), data = root.appendingPathComponent("data")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state")
        let fake = FakeSystem()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path], system: fake.system)
        XCTAssertEqual(app.run(["connect", "fixture", "--fixture-root", data.path]).exitCode, 0)

        // Like the app: mount, then save the mount point to the profile.
        let store = ProfileStore(root: state)
        fake.onOpen = { _ in
            fake.mounted = [MountedVolume(mountPoint: "/Volumes/fixture", type: "streamdrive")]
            if var profile = try? store.load("fixture") { profile.mountPoint = "/Volumes/fixture"; try? store.save(profile, overwrite: true) }
        }
        let mounted = app.run(["mount", "fixture", "--json"])
        XCTAssertEqual(mounted.exitCode, 0, mounted.stdout)
        XCTAssertEqual(try object(mounted)["mountPoint"] as? String, "/Volumes/fixture")
        let url = try XCTUnwrap(fake.opened.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual([components.scheme, components.host, components.path], ["paraair", "drive", "/mount"])
        XCTAssertEqual(components.queryItems?.first { $0.name == "profile" }?.value, "fixture")
        XCTAssertEqual(components.queryItems?.first { $0.name == "folder" }?.value, state.standardizedFileURL.path)

        fake.mounted = []; fake.onOpen = nil
        let timedOut = app.run(["mount", "fixture", "--wait", "2", "--json"])
        XCTAssertEqual(timedOut.exitCode, 1); XCTAssertEqual(try object(timedOut)["code"] as? String, "failed")
        XCTAssertEqual(fake.sleeps, 2)
        // Another folder's drive with the same name appearing is not this drive: the profile never got that mount point.
        if var profile = try? store.load("fixture") { profile.mountPoint = nil; try store.save(profile, overwrite: true) }
        fake.onOpen = { _ in fake.mounted = [MountedVolume(mountPoint: "/Volumes/fixture", type: "streamdrive")] }
        XCTAssertEqual(app.run(["mount", "fixture", "--wait", "2"]).exitCode, 1)
        // And a volume already at that point refuses the request before asking the app.
        fake.opened = []
        XCTAssertEqual(app.run(["mount", "fixture", "--wait", "2"]).exitCode, 1)
        XCTAssertTrue(fake.opened.isEmpty)
        fake.mounted = []; fake.onOpen = nil
        XCTAssertEqual(app.run(["mount", "fixture", "--mount-point", "/Volumes/other"]).exitCode, 2)
        // The app's own mount helper never asks the app back (they would loop): without a mount point it is a usage error.
        let helper = CLIApplication(environment: ["STREAMDRIVE_HOME": state.path, "PARAAIR_MOUNT_ROUTE": "direct"], system: fake.system)
        fake.opened = []
        XCTAssertEqual(helper.run(["mount", "fixture"]).exitCode, 2)
        XCTAssertTrue(fake.opened.isEmpty)
        fake.extensionState = "disabled"
        XCTAssertEqual(app.run(["mount", "fixture"]).exitCode, 13)
        fake.installed = false
        XCTAssertEqual(app.run(["mount", "fixture"]).exitCode, 10)
    }

    func testJSONErrorsCarryAStableCode() throws {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path], system: FakeSystem().system)
        let failed = app.run(["status", "missing", "--json"])
        XCTAssertEqual(failed.exitCode, 1); XCTAssertEqual(try object(failed)["code"] as? String, "failed")
        let usage = app.run(["mount", "--json"])
        XCTAssertEqual(usage.exitCode, 2); XCTAssertEqual(try object(usage)["code"] as? String, "usage")
    }
}
