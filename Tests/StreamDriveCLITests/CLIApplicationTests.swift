import Foundation
import XCTest
import Darwin
import CryptoKit
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
    /// The service credential the stub makes, and its token, which must reach standard output once and nowhere else.
    static let credential = "cred_01JDKQ2T5V7WXYZ0123456789A"
    static let token = "pcs_\(credential).Kq7xR2mZ9vT4wB8nL1cF6hJ3pD0sG5yA_-eUoIiNtMk"
    /// Well formed, but for another credential than the reply names: a malformed reply.
    static let otherToken = "pcs_cred_01JDKQ2T5V7WXYZ0123456789B.Zz9yX8wV7uT6sR5qP4oN3mL2kJ1iH0gF_-eDcBaQwEr"
    private static let lock = NSLock()
    private static var logged: [(path: String, body: Data, method: String)] = []
    /// What GET /v1/drives lists (names only; the drive above is the one whose details exist).
    private static var listed: [(id: String, name: String)] = [(drive, "ParaAir Cloud")]
    static var requests: [(path: String, body: Data, method: String)] { lock.lock(); defer { lock.unlock() }; return logged }
    /// The workspace's members (GET/POST /v1/workspaces/{ws}/members, PATCH/DELETE .../{userId}); 3 seats.
    static let ownerID = "usr_0123456789ABCDEFGHJKMNPQRS", adminID = "usr_1123456789ABCDEFGHJKMNPQRS"
    /// A workspace whose members the account may not manage (403), and one it isn't in (404).
    static let forbiddenWorkspace = "ws_ZZZZZZZZZZZZZZZZZZZZZZZZZZ", otherWorkspace = "ws_YYYYYYYYYYYYYYYYYYYYYYYYYY"
    private static let initialMembers: [[String: String]] = [
        ["userId": ownerID, "email": "cli@example.test", "role": "owner", "addedAt": "2026-11-23T10:00:00.000Z", "status": "active"],
        ["userId": adminID, "email": "ann@example.test", "role": "admin", "addedAt": "2026-11-23T10:00:00.000Z", "status": "invited"],
    ]
    private static var memberRows = initialMembers
    /// How the next member change (POST, PATCH or DELETE) goes wrong: applied and then answered 500, or refused because the
    /// account is no longer in the workspace.
    enum MemberFault { case appliedThen500, workspaceGone }
    private static var memberFault: MemberFault?
    static func failNextMemberChange(_ fault: MemberFault) { lock.lock(); memberFault = fault; lock.unlock() }
    /// false: answer adds like a service that predates `notify` (no `notified` field, nothing emailed).
    private static var notifySupported = true
    static func serviceKnowsNotify(_ value: Bool) { lock.lock(); notifySupported = value; lock.unlock() }
    /// Not valid UTF-8, so cat-version must pass bytes through untouched.
    static let versionBytes = Data([0x7b, 0x22, 0x76, 0x22, 0x3a, 0x31, 0x7d, 0x0a, 0x00, 0xff, 0xfe])
    static var versionHash: String { SHA256.hash(data: versionBytes).map { String(format: "%02x", $0) }.joined() }
    /// Whether the "throttled" create was already answered 429 once.
    private static var throttled = false
    static func reset() { lock.lock(); logged = []; listed = [(drive, "ParaAir Cloud")]; throttled = false; memberRows = initialMembers; memberFault = nil; notifySupported = true; lock.unlock() }
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
        Self.lock.lock(); Self.logged.append((path + (request.url!.query(percentEncoded: true).map { "?" + $0 } ?? ""), body, request.httpMethod ?? "GET")); Self.lock.unlock()
        if path.hasPrefix("/v1/w/") {
            // The one chunk of version pv:9001 (cat-version).
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["Content-Type": "application/octet-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.versionBytes)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path.hasPrefix("/v1/workspaces/"), path.contains("/members") {
            let (status, object) = Self.members(path: path, method: request.httpMethod ?? "GET", body: body)
            let data = try! JSONSerialization.data(withJSONObject: object)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
        case drive + "/versions":
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let file = items.first { $0.name == "path" }?.value ?? "/"
            let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 100, before = Int(items.first { $0.name == "before" }?.value ?? "") ?? .max
            let kept: [(id: Int, object: [String: Any])] = [
                (9001, ["version": "pv:9001", "size": Self.versionBytes.count, "createdAt": "2026-11-23T10:00:00.000Z", "current": true, "expiresAt": NSNull(),
                        "author": ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "cli@example.test"]]),
                (8000, ["version": "pv:8000", "size": 3, "createdAt": "2026-11-22T10:00:00.000Z", "current": false, "expiresAt": "2027-02-20T10:00:00.000Z",
                        "author": ["credential": "cred_relay", "name": "relay", "createdBy": ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "cli@example.test"]]])
            ].filter { $0.id < before }
            let page = Array(kept.prefix(limit))
            object = ["path": file, "versions": page.map(\.object), "nextBefore": kept.count > limit ? page.last!.id as Any : NSNull()]
        case drive + "/manifest":
            object = ["version": "pv:9001", "size": Self.versionBytes.count, "chunkSize": 4_194_304, "chunkCount": 1, "start": 0,
                      "chunks": [["index": 0, "sha256": Self.versionHash, "size": Self.versionBytes.count]], "nextStart": NSNull(),
                      "workspaceId": Self.workspace, "readToken": "prt1.test.token", "readTokenExpiresAt": "2099-01-01T00:00:00.000Z"]
        case drive + "/versions/restore":
            let fields = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
            if fields["expectedVersion"] == "pv:1" {
                status = 409; object = ["error": ["code": "version_conflict", "message": "x", "requestId": "req_TEST"]]
            } else {
                object = ["entry": entry(fields["path"] ?? "/")]
            }
        case drive + "/changes":
            let since = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
            let author: [String: Any] = ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "cli@example.test"]
            switch since {
            case nil: object = ["changes": [], "cursor": 10, "more": false, "reset": false]
            case "10":
                object = ["changes": [["cursor": 11, "change": "write", "kind": "file", "path": "/records/x.json", "version": "pv:9001",
                                       "at": "2026-11-23T10:00:00.000Z", "author": author],
                                      ["cursor": 12, "change": "move", "kind": "file", "path": "/other/y.json", "fromPath": "/elsewhere/y.json",
                                       "version": "pv:9002", "at": "2026-11-23T10:00:01.000Z", "author": author]], "cursor": 12, "more": false, "reset": false]
            case "1": object = ["changes": [], "cursor": 12, "more": false, "reset": true]
            default: object = ["changes": [], "cursor": Int(since!) ?? 0, "more": false, "reset": false]
            }
        case drive + "/access":
            switch request.httpMethod {
            case "PUT":
                let fields = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
                let principal: [String: Any] = fields["credential"].map { ["credential": $0, "name": "finance collector"] } ?? ["role": fields["role"] ?? "members"]
                object = ["rule": principal.merging(["path": fields["path"] ?? "/", "access": fields["access"] ?? "read",
                                                     "updatedAt": "2026-11-23T10:00:00.000Z"]) { $1 }]
            case "DELETE": status = 204; object = [String: Any]()
            default:
                object = ["rules": [["role": "members", "path": "/claims", "access": "create", "updatedAt": "2026-11-23T10:00:00.000Z"],
                                    ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "cli@example.test", "path": "/admin", "access": "none",
                                     "updatedAt": "2026-11-23T10:00:00.000Z"]]]
            }
        case drive + "/conflicts":
            object = ["conflict": ["path": "/records/x (conflict 2026-11-23).json", "original": "/records/x.json", "baseVersion": "pv:7",
                                   "theirsVersion": "pv:8", "createdAt": "2026-11-23T10:00:00.000Z",
                                   "author": ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "other@example.test"]]]
        case "/v1/workspaces/\(Self.workspace)/credentials":
            let made: [String: Any] = ["id": Self.credential, "name": "finance collector", "createdAt": "2026-11-24T01:00:00.000Z",
                                       "createdBy": "cli@example.test", "lastUsedAt": NSNull(), "revokedAt": NSNull()]
            guard request.httpMethod == "POST" else {
                object = ["credentials": [["id": "cred_01JD0000000000000000000000", "name": "old relay", "createdAt": "2026-11-01T01:00:00.000Z",
                                           "createdBy": NSNull(), "lastUsedAt": "2026-11-20T08:00:00.000Z", "revokedAt": "2026-11-21T08:00:00.000Z"], made]]
                break
            }
            switch (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["name"] {
            case "full":  // The service's message is never shown, even if it held a token.
                status = 409; object = ["error": ["code": "busy", "message": Self.token, "requestId": "req_TEST"]]
            case "member": status = 403; object = ["error": ["code": "forbidden", "message": "x", "requestId": "req_TEST"]]
            case "flaky": status = 500; object = ["error": ["code": "internal", "message": Self.token, "requestId": "req_TEST"]]
            case "bad reply": status = 201; object = ["credential": made, "token": Self.otherToken]
            case "expired" where request.value(forHTTPHeaderField: "Authorization") == "Bearer pca_test":
                status = 401; object = ["error": ["code": "unauthorized", "message": "x", "requestId": "req_TEST"]]
            case "throttled":
                Self.lock.lock(); let first = !Self.throttled; Self.throttled = true; Self.lock.unlock()
                if first { status = 429; object = ["error": ["code": "rate_limited", "message": "x", "requestId": "req_TEST", "retryAfterSeconds": 1]] }
                else { status = 201; object = ["credential": made, "token": Self.token] }
            default: status = 201; object = ["credential": made, "token": Self.token]
            }
        case "/oauth/token":
            object = ["access_token": "pca_renewed", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "pcr_renewed",
                      "scope": "drive offline_access"]
        case "/v1/workspaces/\(Self.workspace)/credentials/\(Self.credential)":
            status = 204; object = [String: Any]()
        default:
            status = 404
            let code = path.hasPrefix("/v1/drives/") ? "drive_not_found"
                : path.hasPrefix("/v1/workspaces/\(Self.workspace)/") ? "not_found" : path.hasPrefix("/v1/workspaces/") ? "workspace_not_found" : "not_found"
            object = ["error": ["code": code, "message": "x", "requestId": "req_TEST"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// The members routes, with the service's seat (3) and last-owner rules, and the fault set for the next change.
    private static func members(path: String, method: String, body: Data) -> (Int, Any) {
        lock.lock(); let fault = method == "GET" ? nil : memberFault; if method != "GET" { memberFault = nil }; lock.unlock()
        let failure = { (status: Int, code: String) -> (Int, Any) in (status, ["error": ["code": code, "message": "x", "requestId": "req_TEST"]]) }
        if fault == .workspaceGone { return failure(404, "workspace_not_found") }
        let result = applyMembers(path: path, method: method, body: body)
        return fault == .appliedThen500 && (200..<300).contains(result.0) ? failure(500, "internal") : result
    }

    private static func applyMembers(path: String, method: String, body: Data) -> (Int, Any) {
        func error(_ status: Int, _ code: String) -> (Int, Any) { (status, ["error": ["code": code, "message": "x", "requestId": "req_TEST"]]) }
        let base = "/v1/workspaces/\(workspace)/members"
        if path.hasPrefix("/v1/workspaces/\(forbiddenWorkspace)/") { return error(403, "forbidden") }
        guard path == base || path.hasPrefix(base + "/") else { return error(404, "workspace_not_found") }
        lock.lock(); defer { lock.unlock() }
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let fields = object.compactMapValues { $0 as? String }
        let owners = memberRows.filter { $0["role"] == "owner" }.count
        if path == base, method == "GET" {
            return (200, ["workspace": ["id": workspace, "name": "Studio", "kind": "team", "plan": "team", "seats": 3, "seatsUsed": memberRows.count] as [String: Any],
                          "members": memberRows])
        }
        if path == base, method == "POST" {
            let email = (fields["email"] ?? "").trimmingCharacters(in: .whitespaces).lowercased(), role = fields["role"] ?? "member"
            // An invitation goes out only to a newly added address, and only when asked.
            func answer(_ row: [String: String], emailed: Bool) -> [String: Any] { notifySupported ? ["member": row, "notified": emailed] : ["member": row] }
            if let existing = memberRows.first(where: { $0["email"] == email }) {
                return existing["role"] == role ? (200, answer(existing, emailed: false)) : error(409, "already_exists")
            }
            guard memberRows.count < 3 else { return error(409, "busy") }
            let row = ["userId": String(format: "usr_%026d", memberRows.count + 7), "email": email, "role": role,
                       "addedAt": "2026-11-24T10:00:00.000Z", "status": "invited"]
            memberRows.append(row)
            return (201, answer(row, emailed: object["notify"] as? Bool == true))
        }
        let userID = String(path.dropFirst(base.count + 1))
        guard let index = memberRows.firstIndex(where: { $0["userId"] == userID }) else { return error(404, "not_found") }
        let lastOwner = memberRows[index]["role"] == "owner" && owners == 1
        switch method {
        case "PATCH":
            guard !(lastOwner && fields["role"] != "owner") else { return error(409, "busy") }
            memberRows[index]["role"] = fields["role"]
            return (200, ["member": memberRows[index]])
        case "DELETE":
            guard !lastOwner else { return error(409, "busy") }
            memberRows.remove(at: index)
            return (204, [String: Any]())
        default: return error(405, "invalid_request")
        }
    }
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
    var otherCopies: [String] = []
    var settingsOpened = 0
    /// Seconds a fake FSKit query takes; the fake clock advances by it on each extensionState call.
    var queryDelay: TimeInterval = 0
    var clock = Date(timeIntervalSince1970: 2_000_000_000)
    var opened: [URL] = []
    var mounted: [MountedVolume] = []
    var sleeps = 0
    var onOpen: ((URL) -> Void)?
    var onSleep: ((Int) -> Void)?
    var system: CLISystem {
        CLISystem(appInfo: { [unowned self] _ in installed ? .init(bundleID: "dev.streamdrive.app", version: "0.2.0", build: "42") : nil },
                  isRunning: { [unowned self] _ in running },
                  extensionState: { [unowned self] _, _ in clock += queryDelay; return extensionState },
                  appStateFolders: { [unowned self] _ in folders },
                  otherAppCopies: { [unowned self] _, _ in otherCopies },
                  openExtensionSettings: { [unowned self] in settingsOpened += 1 },
                  openURL: { [unowned self] _, url in opened.append(url); onOpen?(url) },
                  mountedVolumes: { [unowned self] in mounted },
                  sleep: { [unowned self] seconds in sleeps += 1; clock += seconds; onSleep?(sleeps) },
                  now: { [unowned self] in clock })
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

    /// Integrations gate on the published contract (contract/paraair-cli-v1), so setup-status reports its version as a
    /// number whether or not the app is installed and before any account or drive exists.
    func testSetupStatusReportsTheCLIContractVersion() throws {
        let root = try temporaryDirectory(), fake = FakeSystem()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path], system: fake.system)
        let installed = try object(app.run(["setup-status", "--json"]))
        XCTAssertEqual(installed["contractVersion"] as? Int, 1)
        XCTAssertEqual((installed["accounts"] as? [[String: Any]])?.count, 0)
        fake.installed = false
        let missing = app.run(["setup-status", "--json"])
        XCTAssertEqual(missing.exitCode, 0)
        XCTAssertEqual(try object(missing)["contractVersion"] as? Int, 1)
        XCTAssertTrue(missing.stdout.contains("\"contractVersion\" : 1"), missing.stdout)
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

    func testExtensionSettingsOpensTheListThatWorksAndWaitsForTheSwitch() throws {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSystem()
        addTeardownBlock { _ = fake }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path], system: fake.system)
        // Already on: nothing opens.
        let on = app.run(["extension-settings", "--json"])
        XCTAssertEqual(on.exitCode, 0, on.stderr); XCTAssertEqual(try object(on)["state"] as? String, "enabled")
        XCTAssertEqual(try object(on)["opened"] as? Bool, false); XCTAssertEqual(fake.settingsOpened, 0)
        // Off: opens System Settings once and names the list, not the ⓘ sheet.
        fake.extensionState = "disabled"
        let opened = app.run(["extension-settings"])
        XCTAssertEqual(opened.exitCode, 0); XCTAssertEqual(fake.settingsOpened, 1)
        XCTAssertTrue(opened.stdout.contains("By Category → File System Extensions") && opened.stdout.contains("ParaAir Extensions"), opened.stdout)
        // --wait returns once the person switches it on.
        fake.onSleep = { count in if count == 3 { fake.extensionState = "enabled" } }
        let waited = app.run(["extension-settings", "--wait", "30", "--json"])
        XCTAssertEqual(waited.exitCode, 0, waited.stderr); XCTAssertEqual(try object(waited)["state"] as? String, "enabled")
        XCTAssertEqual(try object(waited)["opened"] as? Bool, true); XCTAssertEqual(fake.sleeps, 3)
        // A switch that never stays on times out with the extension_disabled outcome and the guidance.
        fake.extensionState = "disabled"; fake.onSleep = nil; fake.sleeps = 0
        let timedOut = app.run(["extension-settings", "--wait", "2", "--json"])
        XCTAssertEqual(timedOut.exitCode, 13); XCTAssertEqual(try object(timedOut)["code"] as? String, "extension_disabled")
        XCTAssertTrue((try object(timedOut)["error"] as? String)?.contains("By Category") == true)
        // A slow FSKit (5 s per answer) doesn't stretch a 10-second wait into 60.
        fake.queryDelay = 5; fake.sleeps = 0
        let slow = fake.clock
        XCTAssertEqual(app.run(["extension-settings", "--wait", "10"]).exitCode, 13)
        XCTAssertLessThanOrEqual(fake.clock.timeIntervalSince(slow), 10 + 5 + 5 + 1, "the wait is elapsed seconds, not polls")
        fake.queryDelay = 0
        XCTAssertEqual(app.run(["extension-settings", "extra"]).exitCode, 2)
        fake.installed = false
        XCTAssertEqual(app.run(["extension-settings"]).exitCode, 10)
    }

    func testSetupStatusNamesOtherCopiesAndTheSwitchToUse() throws {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSystem()
        addTeardownBlock { _ = fake }
        fake.extensionState = "disabled"
        fake.otherCopies = ["/Users/maya/Downloads/ParaAir.app"]
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": root.path], system: fake.system)
        let json = try object(app.run(["setup-status", "--json"]))
        let ext = try XCTUnwrap(json["extension"] as? [String: Any])
        XCTAssertEqual(ext["state"] as? String, "disabled")
        XCTAssertEqual(ext["otherCopies"] as? [String], ["/Users/maya/Downloads/ParaAir.app"])
        let text = app.run(["setup-status"]).stdout
        XCTAssertTrue(text.contains(ExtensionSetupGuidance.turnOn) && text.contains("Other copy of ParaAir"), text)
        fake.extensionState = "enabled"; fake.otherCopies = []
        let clean = try object(app.run(["setup-status", "--json"]))
        XCTAssertEqual((clean["extension"] as? [String: Any])?["otherCopies"] as? [String], [])
        XCTAssertFalse(app.run(["setup-status"]).stdout.contains("By Category"))
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

// MARK: Shared editing: versions, change feed, conflict copies, folder rules, mounted paths

extension CLIApplicationTests {
    /// A ParaAir Cloud profile "ParaOS" mounted at /Volumes/ParaOS, and an app that sees that mount.
    private func mountedCloud() throws -> (app: CLIApplication, root: URL, fake: FakeSystem, written: () -> Data) {
        let fixture = try cloudFixture(), fake = FakeSystem()
        let profile = DriveProfile(name: "ParaOS", backend: .paraairCloud, mountPoint: "/Volumes/ParaOS", blockSize: 4_194_304,
                                   cloudIssuer: fixture.account.issuer, cloudAccountID: fixture.account.id, cloudDriveID: CLICloudStub.drive)
        try ProfileStore(root: fixture.root).save(profile)
        fake.mounted = [MountedVolume(mountPoint: "/Volumes/ParaOS", type: "streamdrive"), MountedVolume(mountPoint: "/Volumes/Other", type: "apfs")]
        let box = OutputBox()
        addTeardownBlock { _ = fake }  // its CLISystem holds it unowned
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path, "PARAAIR_APP_PATH": "/missing/ParaAir.app"],
                                 dependencies: fixture.dependencies, system: fake.system, output: { box.append($0) })
        return (app, fixture.root, fake, { box.data })
    }
    private func lines(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testParsesCollaborationCommands() throws {
        XCTAssertEqual(try CLIParser.parse(["versions", "ParaOS", "/records/x.json", "--before", "8000"]).command,
                       .versions(target: .drive(profile: "ParaOS", path: "/records/x.json"), before: 8000, limit: nil))
        XCTAssertEqual(try CLIParser.parse(["versions", "/Volumes/ParaOS/records/x.json"]).command,
                       .versions(target: .mounted("/Volumes/ParaOS/records/x.json"), before: nil, limit: nil))
        XCTAssertEqual(try CLIParser.parse(["--profile", "ParaOS", "cat-version", "/a", "pv:12"]).command,
                       .catVersion(target: .drive(profile: "ParaOS", path: "/a"), version: "pv:12"))
        XCTAssertEqual(try CLIParser.parse(["restore-version", "ParaOS", "/a", "pv:12", "--expected-version", "pv:13"]).command,
                       .restoreVersion(target: .drive(profile: "ParaOS", path: "/a"), version: "pv:12", expectedVersion: "pv:13"))
        XCTAssertEqual(try CLIParser.parse(["changes", "ParaOS", "--follow", "--interval", "5"]).command,
                       .changes(target: .drive(profile: "ParaOS", path: "/"), follow: true, since: nil, intervalSeconds: 5))
        XCTAssertEqual(try CLIParser.parse(["access", "set", "ParaOS", "/claims", "--role", "members", "--level", "create"]).command,
                       .access(.set(.role("members"), .create), target: .drive(profile: "ParaOS", path: "/claims")))
        XCTAssertEqual(try CLIParser.parse(["access", "remove", "/Volumes/ParaOS/people/ann", "--email", "ann@example.test"]).command,
                       .access(.remove(.email("ann@example.test")), target: .mounted("/Volumes/ParaOS/people/ann")))
        XCTAssertEqual(try CLIParser.parse(["access", "list", "ParaOS"]).command, .access(.list, target: .drive(profile: "ParaOS", path: "/")))
        XCTAssertEqual(try CLIParser.parse(["settings", "ParaOS", "--conflict-copies", "on"]).command, .settings(profile: "ParaOS", conflictCopies: true))
        for bad in [["cat-version", "ParaOS", "/a", "12"], ["versions", "ParaOS"], ["versions", "ParaOS", "records"], ["changes", "ParaOS", "--interval", "5"],
                    ["access", "set", "ParaOS", "/a", "--role", "admins", "--level", "read"], ["access", "set", "ParaOS", "/a", "--role", "members"],
                    ["access", "remove", "ParaOS", "/a"], ["access", "grant", "ParaOS", "/a"], ["settings", "ParaOS", "--conflict-copies", "yes"],
                    ["versions", "ParaOS", "/a", "--limit", "0"]] {
            XCTAssertThrowsError(try CLIParser.parse(bad), bad.joined(separator: " "))
        }
    }

    func testVersionsByMountedPathAndCatVersionWritesRawBytes() throws {
        let (app, _, _, written) = try mountedCloud()
        let page = app.run(["versions", "/Volumes/ParaOS/records/x.json", "--json"])
        XCTAssertEqual(page.exitCode, 0, page.stdout + page.stderr)
        let json = try object(page)
        XCTAssertEqual(json["path"] as? String, "/records/x.json"); XCTAssertTrue(json["nextBefore"] is NSNull)
        let versions = try XCTUnwrap(json["versions"] as? [[String: Any]])
        XCTAssertEqual(versions.map { $0["version"] as? String }, ["pv:9001", "pv:8000"])
        XCTAssertEqual(versions[0]["author"] as? [String: String], ["userId": "usr_0123456789ABCDEFGHJKMNPQRS", "email": "cli@example.test"])
        XCTAssertTrue(versions[0]["expiresAt"] is NSNull)
        let credential = try XCTUnwrap(versions[1]["author"] as? [String: Any])
        XCTAssertEqual(credential["credential"] as? String, "cred_relay"); XCTAssertEqual(credential["name"] as? String, "relay")
        XCTAssertEqual(CLICloudStub.requests.last?.path, "/v1/drives/\(CLICloudStub.drive)/versions?path=/records/x.json&limit=100")
        let first = app.run(["versions", "ParaOS", "/records/x.json", "--limit", "1"]).stdout
        XCTAssertTrue(first.hasPrefix("pv:9001\t11\t2026-11-23T10:00:00.000Z\tcli@example.test\tcurrent\n"), first)
        XCTAssertTrue(first.contains("More: --before 9001"), first)
        XCTAssertEqual(try XCTUnwrap(try object(app.run(["versions", "ParaOS", "/records/x.json", "--before", "9001", "--json"]))["versions"] as? [[String: Any]])
            .map { $0["version"] as? String }, ["pv:8000"])

        let bytes = app.run(["cat-version", "/Volumes/ParaOS/records/x.json", "pv:9001"])
        XCTAssertEqual(bytes.exitCode, 0, bytes.stderr); XCTAssertEqual(bytes.stdout, "")
        XCTAssertEqual(written(), CLICloudStub.versionBytes)
        XCTAssertTrue(CLICloudStub.requests.contains { $0.path.contains("/versions?path=/records/x.json&limit=1&before=9002") })
        let other = app.run(["cat-version", "ParaOS", "/records/x.json", "pv:8001", "--json"])
        XCTAssertEqual(other.exitCode, 17, "pv:8001 isn't one of the file's versions")
        XCTAssertEqual(try object(other)["code"] as? String, "not_found")

        let outside = app.run(["versions", "/Volumes/Other/x.json", "--json"])
        XCTAssertEqual(outside.exitCode, 15); XCTAssertEqual(try object(outside)["code"] as? String, "not_mounted")
        XCTAssertEqual(app.run(["versions", "/tmp/x.json"]).exitCode, 15)
    }

    func testRestoreVersionReportsConflictsAndTheNewVersion() throws {
        let (app, _, _, _) = try mountedCloud()
        let restored = app.run(["restore-version", "ParaOS", "/records/x.json", "pv:8000", "--expected-version", "pv:9001", "--json"])
        XCTAssertEqual(restored.exitCode, 0, restored.stdout + restored.stderr)
        let json = try object(restored)
        XCTAssertEqual(json["restoredVersion"] as? String, "pv:8000"); XCTAssertEqual(json["version"] as? String, "pv:9001")
        XCTAssertEqual(json["path"] as? String, "/records/x.json")
        let body = try XCTUnwrap(CLICloudStub.requests.last { $0.path.hasSuffix("/versions/restore") }?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String],
                       ["path": "/records/x.json", "version": "pv:8000", "expectedVersion": "pv:9001"])
        let stale = app.run(["restore-version", "/Volumes/ParaOS/records/x.json", "pv:8000", "--expected-version", "pv:1", "--json"])
        XCTAssertEqual(stale.exitCode, 16); XCTAssertEqual(try object(stale)["code"] as? String, "version_conflict")
    }

    func testChangesFollowPrintsOneJSONLinePerChange() throws {
        let (app, _, _, written) = try mountedCloud()
        let start = app.run(["changes", "ParaOS", "--json"])
        XCTAssertEqual(start.exitCode, 0, start.stderr)
        XCTAssertEqual(try lines(written()).first?["cursor"] as? Int, 10)

        let (follower, _, fake, followed) = try mountedCloud()
        follower.maxFollowPolls = 2
        let result = follower.run(["changes", "/Volumes/ParaOS", "--follow", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        let printed = try lines(followed())
        XCTAssertEqual(printed.count, 3, String(decoding: followed(), as: UTF8.self))
        XCTAssertEqual(printed[0]["following"] as? Bool, true); XCTAssertEqual(printed[0]["cursor"] as? Int, 10)
        XCTAssertEqual(printed[1]["path"] as? String, "/records/x.json"); XCTAssertEqual(printed[1]["change"] as? String, "write")
        XCTAssertEqual(printed[1]["version"] as? String, "pv:9001"); XCTAssertEqual(printed[1]["cursor"] as? Int, 11)
        XCTAssertNil(printed[1]["fromPath"]); XCTAssertNil(printed[1]["rescan"])
        XCTAssertEqual(printed[2]["fromPath"] as? String, "/elsewhere/y.json")
        XCTAssertEqual((printed[1]["author"] as? [String: String])?["email"], "cli@example.test")
        XCTAssertEqual(fake.sleeps, 1)
        XCTAssertFalse(String(decoding: followed(), as: UTF8.self).contains("\n\n"))

        let (filtered, _, _, only) = try mountedCloud()
        XCTAssertEqual(filtered.run(["changes", "/Volumes/ParaOS/records", "--since", "10", "--json"]).exitCode, 0)
        XCTAssertEqual(try lines(only()).compactMap { $0["path"] as? String }, ["/records/x.json"])
        let (pruned, _, _, reset) = try mountedCloud()
        XCTAssertEqual(pruned.run(["changes", "ParaOS", "--since", "1", "--json"]).exitCode, 0)
        XCTAssertEqual(try lines(reset()).first?["reset"] as? Bool, true)
    }

    func testConflictInfoFromTheServiceAndSettings() throws {
        let (app, root, _, _) = try mountedCloud()
        let info = app.run(["conflict-info", "/Volumes/ParaOS/records/x (conflict 2026-11-23).json", "--json"])
        XCTAssertEqual(info.exitCode, 0, info.stdout + info.stderr)
        let json = try object(info)
        XCTAssertEqual(json["original"] as? String, "/records/x.json"); XCTAssertEqual(json["baseVersion"] as? String, "pv:7")
        XCTAssertEqual(json["theirsVersion"] as? String, "pv:8"); XCTAssertEqual(json["source"] as? String, "service")

        XCTAssertEqual(try ProfileStore(root: root).load("ParaOS").conflictCopies, nil)
        let on = app.run(["settings", "ParaOS", "--conflict-copies", "on", "--json"])
        XCTAssertEqual(on.exitCode, 0, on.stdout)
        XCTAssertEqual(try object(on)["conflictCopies"] as? Bool, true)
        XCTAssertEqual(try ProfileStore(root: root).load("ParaOS").conflictCopies, true)
        XCTAssertEqual(try object(app.run(["settings", "ParaOS", "--conflict-copies", "off", "--json"]))["conflictCopies"] as? Bool, false)
    }

    func testAccessRulesListSetAndRemove() throws {
        let (app, _, _, _) = try mountedCloud()
        let list = app.run(["access", "list", "/Volumes/ParaOS/claims", "--json"])
        XCTAssertEqual(list.exitCode, 0, list.stdout + list.stderr)
        let rules = try XCTUnwrap(try object(list)["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.map { $0["path"] as? String }, ["/claims"], "rules elsewhere don't decide access here")
        XCTAssertEqual(try XCTUnwrap(try object(app.run(["access", "list", "ParaOS", "--json"]))["rules"] as? [[String: Any]]).count, 2)
        let set = app.run(["access", "set", "ParaOS", "/claims", "--role", "members", "--level", "create", "--json"])
        XCTAssertEqual(set.exitCode, 0, set.stdout + set.stderr)
        XCTAssertEqual((try object(set)["rule"] as? [String: Any])?["access"] as? String, "create")
        let body = try XCTUnwrap(CLICloudStub.requests.last?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["role": "members", "path": "/claims", "access": "create"])
        let removed = app.run(["access", "remove", "ParaOS", "/people/ann", "--email", "ann@example.test", "--json"])
        XCTAssertEqual(removed.exitCode, 0, removed.stdout + removed.stderr)
        XCTAssertEqual(try object(removed)["removed"] as? Bool, true)
        XCTAssertEqual(CLICloudStub.requests.last?.path, "/v1/drives/\(CLICloudStub.drive)/access?email=ann%40example.test&path=/people/ann")
    }
}

extension CLIApplicationTests {
    func testMembersListAddRoleAndRemove() throws {
        let fixture = try cloudFixture()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies, system: FakeSystem().system)
        let base = ["--cloud-account", fixture.account.id, "--workspace", CLICloudStub.workspace]
        let route = "/v1/workspaces/\(CLICloudStub.workspace)/members"
        func last() -> (path: String, method: String, body: NSDictionary?) {
            let request = CLICloudStub.requests.last!
            return (request.path, request.method, try? JSONSerialization.jsonObject(with: request.body) as? NSDictionary)
        }

        let listed = app.run(["members", "list"] + base + ["--json"])
        XCTAssertEqual(listed.exitCode, 0, listed.stdout + listed.stderr)
        XCTAssertEqual((try object(listed)["workspace"] as? [String: Any])?["seats"] as? Int, 3)
        XCTAssertEqual((try object(listed)["members"] as? [[String: Any]])?.map { $0["email"] as? String }, ["cli@example.test", "ann@example.test"])
        XCTAssertEqual(app.run(["members", "list"] + base).stdout, """
            Studio: 2 of 3 seats used
            \(CLICloudStub.ownerID)\towner\tactive\tcli@example.test
            \(CLICloudStub.adminID)\tadmin\tinvited\tann@example.test

            """)

        // add: a new address is a member at once, with role member unless --role; a retry answers "already".
        // Without --notify nothing asks for an email, and the output says so.
        let added = app.run(["members", "add"] + base + ["--email", "New@Example.test", "--json"])
        XCTAssertEqual(added.exitCode, 0, added.stdout + added.stderr)
        XCTAssertEqual(try object(added)["added"] as? Bool, true)
        XCTAssertEqual(try object(added)["notified"] as? Bool, false)
        XCTAssertEqual((try object(added)["member"] as? [String: Any])?["status"] as? String, "invited")
        XCTAssertEqual(last().path, route); XCTAssertEqual(last().method, "POST")
        XCTAssertEqual(last().body, ["email": "New@Example.test", "role": "member"])
        XCTAssertEqual(app.run(["members", "add"] + base + ["--email", "new@example.test"]).stdout, "new@example.test is already a member (member).\n")
        let otherRole = app.run(["members", "add"] + base + ["--email", "new@example.test", "--role", "viewer"])
        XCTAssertEqual(otherRole.exitCode, 1); XCTAssertTrue(otherRole.stderr.contains("already a member with another role"), otherRole.stderr)
        let full = app.run(["members", "add"] + base + ["--email", "fourth@example.test", "--role", "admin"])
        XCTAssertEqual(full.exitCode, 1); XCTAssertTrue(full.stderr.contains("no free seat"), full.stderr)

        // role and remove find the member by email, then call by user id.
        let changed = app.run(["members", "role"] + base + ["--email", "ANN@example.test", "--role", "viewer", "--json"])
        XCTAssertEqual(changed.exitCode, 0, changed.stdout + changed.stderr)
        XCTAssertEqual((try object(changed)["member"] as? [String: Any])?["role"] as? String, "viewer")
        XCTAssertEqual(last().path, "\(route)/\(CLICloudStub.adminID)"); XCTAssertEqual(last().method, "PATCH"); XCTAssertEqual(last().body, ["role": "viewer"])
        let lastOwner = app.run(["members", "role"] + base + ["--email", "cli@example.test", "--role", "admin"])
        XCTAssertEqual(lastOwner.exitCode, 1); XCTAssertTrue(lastOwner.stderr.contains("needs an owner"), lastOwner.stderr)
        XCTAssertEqual(app.run(["members", "remove"] + base + ["--email", "cli@example.test"]).exitCode, 1)

        let removed = app.run(["members", "remove"] + base + ["--email", "new@example.test", "--json"])
        XCTAssertEqual(removed.exitCode, 0, removed.stdout + removed.stderr)
        XCTAssertEqual(try object(removed)["removed"] as? Bool, true)
        XCTAssertEqual(last().method, "DELETE"); XCTAssertTrue(last().path.hasPrefix(route + "/usr_"), last().path)
        let sent = CLICloudStub.requests.count
        let gone = app.run(["members", "remove"] + base + ["--email", "new@example.test", "--json"])
        XCTAssertEqual(gone.exitCode, 17); XCTAssertEqual(try object(gone)["code"] as? String, "not_found")
        XCTAssertEqual(CLICloudStub.requests.count, sent + 1, "only the list; nothing to delete")

        // --notify (anywhere after the verb) sends notify: true; the service emails a newly added address.
        let invited = app.run(["members", "add", "--notify"] + base + ["--email", "kim@example.test", "--role", "viewer", "--json"])
        XCTAssertEqual(invited.exitCode, 0, invited.stdout + invited.stderr)
        XCTAssertEqual(last().body, ["email": "kim@example.test", "role": "viewer", "notify": true])
        XCTAssertEqual(try object(invited)["added"] as? Bool, true); XCTAssertEqual(try object(invited)["notified"] as? Bool, true)
        XCTAssertEqual(Set(try object(invited).keys), ["member", "added", "notified"])
        XCTAssertEqual(app.run(["members", "remove"] + base + ["--email", "kim@example.test"]).exitCode, 0)
        XCTAssertEqual(app.run(["members", "add"] + base + ["--email", "kim@example.test", "--notify"]).stdout,
                       "Added kim@example.test as member. ParaAir emailed them how to start.\n")
        XCTAssertEqual(last().body, ["email": "kim@example.test", "role": "member", "notify": true])
        // A retry with --notify emails nobody: the address already was a member.
        let again = app.run(["members", "add"] + base + ["--email", "kim@example.test", "--notify", "--json"])
        XCTAssertEqual(try object(again)["added"] as? Bool, false); XCTAssertEqual(try object(again)["notified"] as? Bool, false)
        XCTAssertEqual(app.run(["members", "remove"] + base + ["--email", "kim@example.test"]).exitCode, 0)
        // A service that predates notify ignores it and omits notified: read as false, and the text says to tell them.
        CLICloudStub.serviceKnowsNotify(false)
        let older = app.run(["members", "add"] + base + ["--email", "lee@example.test", "--notify", "--json"])
        XCTAssertEqual(older.exitCode, 0, older.stdout + older.stderr)
        XCTAssertEqual(try object(older)["added"] as? Bool, true); XCTAssertEqual(try object(older)["notified"] as? Bool, false)
        XCTAssertEqual(app.run(["members", "remove"] + base + ["--email", "lee@example.test"]).exitCode, 0)
        XCTAssertEqual(app.run(["members", "add"] + base + ["--email", "lee@example.test", "--notify"]).stdout,
                       "Added lee@example.test as member. Nothing was emailed: tell them to sign in to ParaAir with this address.\n")
        XCTAssertEqual(app.run(["members", "remove"] + base + ["--email", "lee@example.test"]).exitCode, 0)
        CLICloudStub.serviceKnowsNotify(true)

        // Not an owner or admin there: 12; a workspace the account isn't in: 14; an account not signed in here: 11.
        let forbidden = app.run(["members", "list", "--cloud-account", fixture.account.id, "--workspace", CLICloudStub.forbiddenWorkspace, "--json"])
        XCTAssertEqual(forbidden.exitCode, 12); XCTAssertEqual(try object(forbidden)["code"] as? String, "forbidden")
        XCTAssertEqual(app.run(["members", "list", "--cloud-account", fixture.account.id, "--workspace", CLICloudStub.otherWorkspace]).exitCode, 14)
        XCTAssertEqual(app.run(["members", "list", "--cloud-account", "6b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e", "--workspace", CLICloudStub.workspace]).exitCode, 11)

        for usage in [["members"], ["members", "invite"] + base, ["members", "list", "--cloud-account", fixture.account.id],
                      ["members", "list", "--workspace", CLICloudStub.workspace], ["members", "list"] + base + ["--email", "a@example.test"],
                      ["members", "add"] + base, ["members", "add"] + base + ["--email", "no-at-sign"],
                      ["members", "add"] + base + ["--email", "a@example.test", "--role", "boss"],
                      ["members", "role"] + base + ["--email", "a@example.test"], ["members", "remove"] + base + ["--email", "a@example.test", "--role", "viewer"],
                      ["members", "list", "--cloud-account", fixture.account.id, "--workspace", "ws_lower"], ["members", "list"] + base + ["extra"],
                      ["members", "list"] + base + ["--notify"], ["members", "role"] + base + ["--email", "a@example.test", "--role", "viewer", "--notify"],
                      ["members", "remove"] + base + ["--email", "a@example.test", "--notify"],
                      ["members", "add"] + base + ["--email", "a@example.test", "--notify", "--notify"],
                      ["members", "add"] + base + ["--email", "a@example.test", "--notify=yes"]] {
            XCTAssertEqual(app.run(usage).exitCode, 2, usage.joined(separator: " "))
        }
        let help = app.run(["help", "members"]).stdout
        XCTAssertTrue(help.contains("paraair members add") && help.contains("--notify"), help)
    }

    /// An add or removal may go through even when its answer is lost (a 5xx, a dropped connection). Retrying would read
    /// back "already a member" or "not a member", so each is sent once and the error says to check the list. A workspace
    /// the account left between the lookup and the change keeps exit 14.
    func testMemberChangesThatMayHaveHappenedAreSentOnceAndKeepTheirExitCodes() throws {
        let fixture = try cloudFixture()
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path], dependencies: fixture.dependencies, system: FakeSystem().system)
        let base = ["--cloud-account", fixture.account.id, "--workspace", CLICloudStub.workspace]
        let route = "/v1/workspaces/\(CLICloudStub.workspace)/members"
        func sent(_ method: String) -> Int { CLICloudStub.requests.filter { $0.method == method && $0.path.hasPrefix(route) }.count }

        CLICloudStub.failNextMemberChange(.appliedThen500)
        let add = app.run(["members", "add"] + base + ["--email", "kim@example.test", "--notify", "--json"])
        XCTAssertEqual(add.exitCode, 1, add.stdout); XCTAssertEqual(sent("POST"), 1)
        XCTAssertTrue((try object(add)["error"] as? String ?? "").hasSuffix("The address may have been added: check members list"), add.stdout)
        XCTAssertTrue(app.run(["members", "list"] + base).stdout.contains("kim@example.test"), "it was added")

        CLICloudStub.failNextMemberChange(.appliedThen500)
        let remove = app.run(["members", "remove"] + base + ["--email", "kim@example.test", "--json"])
        XCTAssertEqual(remove.exitCode, 1, remove.stdout); XCTAssertEqual(sent("DELETE"), 1)
        XCTAssertTrue((try object(remove)["error"] as? String ?? "").hasSuffix("The member may have been removed: check members list"), remove.stdout)
        XCTAssertFalse(app.run(["members", "list"] + base).stdout.contains("kim@example.test"), "it was removed")

        for arguments in [["members", "role"] + base + ["--email", "ann@example.test", "--role", "viewer"],
                          ["members", "remove"] + base + ["--email", "ann@example.test"]] {
            CLICloudStub.failNextMemberChange(.workspaceGone)
            let result = app.run(arguments + ["--json"])
            XCTAssertEqual(result.exitCode, 14, arguments.joined(separator: " ") + "\n" + result.stdout)
            XCTAssertEqual(try object(result)["code"] as? String, "drive_not_found")
        }
    }

    /// The calls a client app's access reconcile makes, each with --state-dir first: their JSON shapes and
    /// exit codes are a contract with that app.
    func testParaOSReconcileCallsKeepTheirShapes() throws {
        let fixture = try cloudFixture(), fake = FakeSystem(), elsewhere = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: elsewhere); _ = fake }
        try ProfileStore(root: fixture.root).save(DriveProfile(name: "ParaOS", backend: .paraairCloud, blockSize: 4_194_304, cloudIssuer: fixture.account.issuer,
                                                               cloudAccountID: fixture.account.id, cloudDriveID: CLICloudStub.drive))
        // The environment points at another folder: --state-dir alone finds the account and the profile.
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": elsewhere.path, "PARAAIR_APP_PATH": "/missing/ParaAir.app"],
                                 dependencies: fixture.dependencies, system: fake.system)
        let members = ["--cloud-account", fixture.account.id, "--workspace", CLICloudStub.workspace]
        func run(_ arguments: [String], exitCode: Int32 = 0) throws -> [String: Any] {
            let result = app.run(["--state-dir", fixture.root.path] + arguments + ["--json"])
            XCTAssertEqual(result.exitCode, exitCode, arguments.joined(separator: " ") + "\n" + result.stdout + result.stderr)
            return try object(result)
        }
        let memberKeys: Set<String> = ["userId", "email", "role", "addedAt", "status"]

        let list = try run(["members", "list"] + members)
        XCTAssertEqual(Set(list.keys), ["workspace", "members"])
        XCTAssertEqual((list["workspace"] as? [String: Any])?["id"] as? String, CLICloudStub.workspace)
        for member in try XCTUnwrap(list["members"] as? [[String: Any]]) { XCTAssertEqual(Set(member.keys), memberKeys) }

        let added = try run(["members", "add"] + members + ["--email", "kim@example.test", "--role", "viewer", "--notify"])
        XCTAssertEqual(Set(added.keys), ["member", "added", "notified"])
        XCTAssertEqual(Set(try XCTUnwrap(added["member"] as? [String: Any]).keys), memberKeys)
        XCTAssertEqual(added["added"] as? Bool, true); XCTAssertEqual(added["notified"] as? Bool, true)

        let changed = try run(["members", "role"] + members + ["--email", "kim@example.test", "--role", "member"])
        XCTAssertEqual(Set(changed.keys), ["member"]); XCTAssertEqual((changed["member"] as? [String: Any])?["role"] as? String, "member")

        XCTAssertEqual(Set(try run(["members", "remove"] + members + ["--email", "kim@example.test"]).keys), ["userId", "email", "removed"])
        XCTAssertEqual(try run(["members", "remove"] + members + ["--email", "kim@example.test"], exitCode: 17)["code"] as? String, "not_found")

        XCTAssertEqual(Set(try run(["access", "list", "ParaOS", "/"]).keys), ["path", "rules"])
        XCTAssertEqual(Set(try run(["access", "set", "ParaOS", "/people/kim", "--email", "kim@example.test", "--level", "write"]).keys), ["rule"])
        XCTAssertEqual(Set(try run(["access", "remove", "ParaOS", "/people/kim", "--email", "kim@example.test"]).keys), ["path", "principal", "removed"])

        XCTAssertEqual(try run(["members", "list", "--cloud-account", fixture.account.id, "--workspace", CLICloudStub.forbiddenWorkspace],
                               exitCode: 12)["code"] as? String, "forbidden")
        XCTAssertEqual(try run(["members", "list"] + members + ["--role", "viewer"], exitCode: 2)["code"] as? String, "usage")
        // A ParaAir without the command answers an unknown command the same way: exit 2, code usage.
        XCTAssertEqual(try run(["no-such-command", "list"] + members, exitCode: 2)["code"] as? String, "usage")
    }

    func testASecondDriveGetsAStateFolderOfItsOwnSharingTheSignIn() throws {
        let fixture = try cloudFixture(), fake = FakeSystem()
        let home = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home); _ = fake }
        let app = CLIApplication(environment: ["STREAMDRIVE_HOME": fixture.root.path, "PARAAIR_APP_PATH": "/missing/ParaAir.app"],
                                 dependencies: fixture.dependencies, system: fake.system, home: home)
        XCTAssertEqual(app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive]).exitCode, 0)
        let full = app.run(["connect", "ParaOS", "--cloud-account", fixture.account.id, "--cloud-drive-name", "ParaAir Cloud"])
        XCTAssertEqual(full.exitCode, 1); XCTAssertTrue(full.stderr.contains("--new-state-folder"), full.stderr)

        let added = app.run(["connect", "ParaOS", "--cloud-account", fixture.account.id, "--cloud-drive-name", "ParaAir Cloud",
                             "--new-state-folder", "--conflict-copies", "--json"])
        XCTAssertEqual(added.exitCode, 0, added.stdout + added.stderr)
        let folder = try XCTUnwrap(try object(added)["stateDirectory"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: folder).deletingLastPathComponent().path,
                       CloudDriveSetup.cloudDrivesFolder(home: home).standardizedFileURL.path)
        let profile = try ProfileStore(root: URL(fileURLWithPath: folder)).load("ParaOS")
        XCTAssertEqual(profile.cloudDriveID, CLICloudStub.drive); XCTAssertEqual(profile.conflictCopies, true)
        XCTAssertEqual(try CloudAccountStore(root: URL(fileURLWithPath: folder)).load(fixture.account.id).binding, fixture.account.binding)
        XCTAssertEqual(try ProfileStore(root: fixture.root).list().map(\.name), ["studio"], "the first folder keeps its one drive")
        XCTAssertNoThrow(try CloudDriveSetup.adoptableProfile(URL(fileURLWithPath: folder), knownRoots: [fixture.root], home: home))

        // Two drives of one name would mount at the same place.
        let clash = app.run(["connect", "studio", "--cloud-account", fixture.account.id, "--cloud-drive", CLICloudStub.drive, "--new-state-folder"])
        XCTAssertEqual(clash.exitCode, 1); XCTAssertTrue(clash.stderr.contains("already saved"), clash.stderr)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: CloudDriveSetup.cloudDrivesFolder(home: home).path).count, 1)
        // A drive the service doesn't know leaves no folder behind.
        let missing = app.run(["connect", "Other", "--cloud-account", fixture.account.id, "--cloud-drive", "4f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c",
                               "--new-state-folder"])
        XCTAssertEqual(missing.exitCode, 14)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: CloudDriveSetup.cloudDrivesFolder(home: home).path).count, 1)
        XCTAssertEqual(app.run(["connect", "x", "--new-state-folder"]).exitCode, 2)
    }
}

// MARK: Service credentials: create, grant one folder, list, revoke

extension CLIApplicationTests {
    func testParsesCredentialCommands() throws {
        let account = "7d4c2b1a-0e9f-4a8b-9c7d-6e5f4a3b2c1d", ws = CLICloudStub.workspace, id = CLICloudStub.credential
        let base = ["--cloud-account", account, "--workspace", ws]
        XCTAssertEqual(try CLIParser.parse(["credentials", "create"] + base + ["--name", "  finance collector "]).command,
                       .credentials(.create(name: "finance collector"), account: account, workspace: ws))
        XCTAssertEqual(try CLIParser.parse(["credentials", "list"] + base + ["--json"]).command, .credentials(.list, account: account, workspace: ws))
        XCTAssertEqual(try CLIParser.parse(["credentials", "revoke"] + base + ["--id", id]).command,
                       .credentials(.revoke(id: id), account: account, workspace: ws))
        XCTAssertEqual(try CLIParser.parse(["access", "set", "ParaOS", "/admin/finance", "--credential", id, "--level", "write"]).command,
                       .access(.set(.credential(id), .write), target: .drive(profile: "ParaOS", path: "/admin/finance")))
        for bad in [["credentials"], ["credentials", "rotate"] + base, ["credentials", "list", "--cloud-account", account],
                    ["credentials", "list", "--workspace", ws], ["credentials", "list"] + base + ["--name", "x"],
                    ["credentials", "list", "--cloud-account", account.uppercased(), "--workspace", ws],
                    ["credentials", "list", "--cloud-account", account, "--workspace", "ws_short"],
                    ["credentials", "create"] + base, ["credentials", "create"] + base + ["--name", "   "],
                    ["credentials", "create"] + base + ["--name", "bell\u{7}"], ["credentials", "create"] + base + ["--name", String(repeating: "n", count: 101)],
                    ["credentials", "create"] + base + ["--name", "x", "--id", id], ["credentials", "revoke"] + base,
                    ["credentials", "revoke"] + base + ["--id", "cred_relay"], ["credentials", "list"] + base + ["extra"],
                    ["credentials", "revoke"] + base + ["--id", id + "\n"], ["credentials", "revoke"] + base + ["--id", id + "\r\n"],
                    ["credentials", "list", "--cloud-account", account, "--workspace", ws + "\n"],
                    ["access", "set", "ParaOS", "/a", "--credential", id + "\n", "--level", "read"],
                    ["access", "set", "ParaOS", "/a", "--credential", "relay", "--level", "read"]] {
            XCTAssertThrowsError(try CLIParser.parse(bad), bad.joined(separator: " "))
        }
    }

    func testCredentialRecipeCreateGrantListRevoke() throws {
        let (app, root, _, _) = try mountedCloud()
        let account = try XCTUnwrap(CloudAccountStore(root: root).list().accounts.first?.id)
        let base = ["--cloud-account", account, "--workspace", CLICloudStub.workspace]
        let token = CLICloudStub.token, id = CLICloudStub.credential
        func count(_ text: String) -> Int { text.components(separatedBy: token).count - 1 }

        let made = app.run(["credentials", "create"] + base + ["--name", "finance collector"])
        XCTAssertEqual(made.exitCode, 0, made.stdout + made.stderr)
        XCTAssertEqual(count(made.stdout), 1, "the token is printed exactly once"); XCTAssertEqual(made.stderr, "")
        XCTAssertTrue(made.stdout.contains("\n" + token + "\n"), "on a line of its own")
        XCTAssertTrue(made.stdout.contains("can't be shown again"), made.stdout)
        XCTAssertTrue(made.stdout.contains("access set PROFILE /admin/finance --credential \(id) --level write"), made.stdout)
        let posted = try XCTUnwrap(CLICloudStub.requests.last)
        XCTAssertEqual(posted.path, "/v1/workspaces/\(CLICloudStub.workspace)/credentials")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: posted.body) as? [String: String], ["name": "finance collector"])

        let json = app.run(["credentials", "create"] + base + ["--name", "finance collector", "--json"])
        XCTAssertEqual(json.exitCode, 0, json.stdout + json.stderr); XCTAssertEqual(count(json.stdout), 1); XCTAssertEqual(json.stderr, "")
        let created = try object(json)
        XCTAssertEqual(created["token"] as? String, token); XCTAssertEqual(created["workspaceId"] as? String, CLICloudStub.workspace)
        let credential = try XCTUnwrap(created["credential"] as? [String: Any])
        XCTAssertEqual(credential["id"] as? String, id); XCTAssertEqual(credential["name"] as? String, "finance collector")
        XCTAssertTrue(credential["revokedAt"] is NSNull); XCTAssertTrue(credential["lastUsedAt"] is NSNull)

        // Nothing on this Mac keeps the token: no file in the state folder holds it.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(token.utf8)), file.path)
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(token.split(separator: ".")[1].utf8)), file.path)
        }

        // Grant one folder, write or create, through the existing folder rules.
        for level in ["write", "create"] {
            let grant = app.run(["access", "set", "ParaOS", "/admin/finance", "--credential", id, "--level", level, "--json"])
            XCTAssertEqual(grant.exitCode, 0, grant.stdout + grant.stderr)
            let rule = try XCTUnwrap(try object(grant)["rule"] as? [String: Any])
            XCTAssertEqual(rule["credential"] as? String, id); XCTAssertEqual(rule["access"] as? String, level)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(CLICloudStub.requests.last?.body)) as? [String: String],
                           ["credential": id, "path": "/admin/finance", "access": level])
        }
        let granted = app.run(["access", "set", "/Volumes/ParaOS/admin/finance", "--credential", id, "--level", "write"])
        XCTAssertEqual(granted.stdout, "credential:\(id) (finance collector) now has write access at /admin/finance.\n")

        let list = app.run(["credentials", "list"] + base + ["--json"])
        XCTAssertEqual(list.exitCode, 0, list.stdout + list.stderr); XCTAssertEqual(count(list.stdout), 0)
        let listed = try XCTUnwrap(try object(list)["credentials"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, ["cred_01JD0000000000000000000000", id])
        XCTAssertNil(listed[1]["token"]); XCTAssertEqual(listed[0]["revokedAt"] as? String, "2026-11-21T08:00:00.000Z")
        XCTAssertEqual(app.run(["credentials", "list"] + base).stdout,
                       "cred_01JD0000000000000000000000\trevoked 2026-11-21T08:00:00.000Z\tlast used 2026-11-20T08:00:00.000Z\told relay\n"
                       + "\(id)\tactive\tnever used\tfinance collector\n")

        let revoked = app.run(["credentials", "revoke"] + base + ["--id", id, "--json"])
        XCTAssertEqual(revoked.exitCode, 0, revoked.stdout + revoked.stderr)
        XCTAssertEqual(try object(revoked)["revoked"] as? Bool, true); XCTAssertEqual(try object(revoked)["id"] as? String, id)
        XCTAssertEqual(CLICloudStub.requests.last?.path, "/v1/workspaces/\(CLICloudStub.workspace)/credentials/\(id)")
        XCTAssertEqual(app.run(["credentials", "revoke"] + base + ["--id", id]).stdout,
                       "Revoked \(id). Its token no longer works and its folder rules are deleted.\n")
    }

    func testCredentialFailuresNeverShowTheToken() throws {
        let (app, root, _, _) = try mountedCloud()
        let account = try XCTUnwrap(CloudAccountStore(root: root).list().accounts.first?.id)
        let base = ["--cloud-account", account, "--workspace", CLICloudStub.workspace]
        func create(_ name: String, json: Bool = false) -> CLIExecution {
            app.run(["credentials", "create"] + base + ["--name", name] + (json ? ["--json"] : []))
        }
        func clean(_ result: CLIExecution, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
            for token in [CLICloudStub.token, CLICloudStub.otherToken] {
                XCTAssertFalse((result.stdout + result.stderr).contains(token), label, file: file, line: line)
                XCTAssertFalse((result.stdout + result.stderr).contains(String(token.split(separator: ".")[1])), label, file: file, line: line)
            }
        }
        // The service's own message (here holding a token) is never shown; the limit has its own text.
        for json in [false, true] {
            let full = create("full", json: json)
            XCTAssertEqual(full.exitCode, 1); clean(full, "busy")
            XCTAssertTrue((full.stdout + full.stderr).contains("20 active service credentials"), full.stdout + full.stderr)
        }
        // A reply whose token doesn't belong to its credential is refused, and the token isn't repeated.
        let malformed = create("bad reply", json: true)
        XCTAssertEqual(malformed.exitCode, 1); clean(malformed, "malformed")
        XCTAssertEqual(try object(malformed)["code"] as? String, "failed")
        XCTAssertTrue((try object(malformed)["error"] as? String ?? "").hasPrefix("ParaAir Cloud returned a malformed response"), malformed.stdout)
        // Sent once: no retry that could make a second credential, and the error says to check the list.
        let before = CLICloudStub.requests.count
        let flaky = create("flaky")
        XCTAssertEqual(flaky.exitCode, 1); clean(flaky, "unavailable")
        XCTAssertEqual(CLICloudStub.requests.count, before + 1)
        XCTAssertTrue(flaky.stderr.contains("may have been made: run credentials list"), flaky.stderr)

        XCTAssertEqual(create("member").exitCode, 12)
        let elsewhere = app.run(["credentials", "list", "--cloud-account", account, "--workspace", "ws_ZZZZZZZZZZZZZZZZZZZZZZZZZZ", "--json"])
        XCTAssertEqual(elsewhere.exitCode, 14); XCTAssertEqual(try object(elsewhere)["code"] as? String, "drive_not_found")
        let unknown = app.run(["credentials", "revoke"] + base + ["--id", "cred_01JDKQ2T5V7WXYZ0123456789B", "--json"])
        XCTAssertEqual(unknown.exitCode, 17); XCTAssertEqual(try object(unknown)["code"] as? String, "not_found")
        let notSignedIn = app.run(["credentials", "list", "--cloud-account", "7d4c2b1a-0e9f-4a8b-9c7d-6e5f4a3b2c1d", "--workspace", CLICloudStub.workspace])
        XCTAssertEqual(notSignedIn.exitCode, 11)

        // A token pasted where an id or name belongs is refused without repeating it.
        let requests = CLICloudStub.requests.count
        for arguments in [["access", "set", "ParaOS", "/admin/finance", "--credential", CLICloudStub.token, "--level", "write"],
                          ["access", "remove", "ParaOS", "/admin/finance", "--credential", CLICloudStub.token, "--json"],
                          ["credentials", "revoke"] + base + ["--id", CLICloudStub.token],
                          ["credentials", "list"] + base + [CLICloudStub.token],
                          ["credentials", "create"] + base + ["--name", "x", "--token=" + CLICloudStub.token],
                          ["credentials", "create"] + base + ["--name", CLICloudStub.token],
                          ["credentials", "create"] + base + ["--name", "relay " + CLICloudStub.token, "--json"]] {
            let result = app.run(arguments)
            XCTAssertEqual(result.exitCode, 2, arguments.joined(separator: " ")); clean(result, arguments[0] + " " + arguments[1])
        }
        XCTAssertEqual(CLICloudStub.requests.count, requests, "refused before reaching the service")
    }

    /// Create is sent again only after answers the service gives before making anything: 401 (with a renewed sign-in)
    /// and 429. After a 5xx it is not, since the credential may exist.
    func testCredentialCreateIsSentAgainOnlyAfterAnswersThatMadeNothing() throws {
        let (app, root, _, _) = try mountedCloud()
        let account = try XCTUnwrap(CloudAccountStore(root: root).list().accounts.first?.id)
        let base = ["--cloud-account", account, "--workspace", CLICloudStub.workspace]
        func posts(_ name: String) -> Int {
            CLICloudStub.requests.filter {
                $0.path == "/v1/workspaces/\(CLICloudStub.workspace)/credentials"
                    && (try? JSONSerialization.jsonObject(with: $0.body) as? [String: String])?["name"] == name
            }.count
        }
        for (name, sent) in [("expired", 2), ("throttled", 2), ("flaky", 1)] {
            let result = app.run(["credentials", "create"] + base + ["--name", name, "--json"])
            XCTAssertEqual(posts(name), sent, name)
            if sent == 2 {
                XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
                XCTAssertEqual(result.stdout.components(separatedBy: CLICloudStub.token).count - 1, 1, name)
            } else {
                XCTAssertEqual(result.exitCode, 1); XCTAssertFalse(result.stdout.contains(CLICloudStub.token))
            }
        }
        XCTAssertEqual(CLICloudStub.requests.filter { $0.path == "/oauth/token" }.count, 1, "the 401 renewed the sign-in once")
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ bytes: Data) { lock.lock(); stored.append(bytes); lock.unlock() }
}
