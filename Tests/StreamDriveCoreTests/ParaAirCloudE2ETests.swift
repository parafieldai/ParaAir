import XCTest
import CryptoKit
import Darwin
@testable import StreamDriveCore
@testable import StreamDriveCLI

/// End-to-end run against a local `wrangler dev` (spec section 9). Skipped unless
/// `PARAAIR_E2E_BASE_URL` is set; `scripts/cloud-e2e.sh` starts the service and sets
/// `PARAAIR_E2E_ADMIN_TOKEN` and `PARAAIR_E2E_EMAIL`. No Keychain, no real browser.
final class ParaAirCloudE2ETests: XCTestCase {
    private var issuer: URL!
    private var admin = ""
    private var email = ""
    private let policy = ParaAirCloudTransportPolicy(allowsLoopbackHTTP: true)
    private let configuration = URLSessionConfiguration.ephemeral

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["PARAAIR_E2E_BASE_URL"], !base.isEmpty else {
            throw XCTSkip("Set PARAAIR_E2E_BASE_URL (scripts/cloud-e2e.sh does) to run the end-to-end flow")
        }
        issuer = try ParaAirCloudIssuer.validate(base)
        admin = environment["PARAAIR_E2E_ADMIN_TOKEN"] ?? ""
        email = environment["PARAAIR_E2E_EMAIL"] ?? ""
    }

    private func dependencies(_ vault: any ConnectionVault, minimumValidity: TimeInterval = 5) -> EngineOpenDependencies {
        var options = ParaAirCloudSession.Options(); options.minimumValidity = minimumValidity
        return EngineOpenDependencies(cloudVault: vault, cloudConfiguration: configuration, cloudPolicy: policy, cloudSessionOptions: options)
    }
    private func root(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/tests/e2e-\(name)-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func signIn(_ root: URL, vault: any ConnectionVault) async throws -> ParaAirCloudSignIn.Result {
        let browser = HeadlessDevBrowser(admin: admin, email: email)
        return try await ParaAirCloudSignIn.run(issuer: issuer, currentStateRoot: root, policy: policy, vault: vault, configuration: configuration,
                                                minimumValidity: 5, openAuthorizationURL: { try await browser.open($0) })
    }
    private func api(_ root: URL, _ account: CloudAccount, _ vault: any ConnectionVault) throws -> ParaAirCloudAPI {
        let session = try ParaAirCloudSession.shared(root: root, accountID: account.id, vault: vault, configuration: configuration, policy: policy,
                                                     options: dependencies(vault).cloudSessionOptions)
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }
    private func adminRequest(_ method: String, _ path: String, _ body: [String: Any?]) throws -> Int {
        var request = URLRequest(url: issuer.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + admin, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        return try blockingStatus(request).0
    }
    private func blockingStatus(_ request: URLRequest) throws -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data) = (0, Data())
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 60) == .success else { throw DriveError(ETIMEDOUT, "Request timed out") }
        return result
    }
    private func sha(_ data: Data) -> String { ParaAirCloudAPI.hex(SHA256.hash(data: data)) }
    private func readAll(_ engine: Engine, _ path: String, size: Int) throws -> Data {
        var data = Data()
        while data.count < size { data += try engine.read(path, offset: Int64(data.count), length: min(1 << 20, size - data.count)) }
        return data
    }

    func testE2E01LoopbackHTTPReachable() throws {
        let http = try ParaAirCloudHTTP(baseURL: issuer, policy: policy, configuration: configuration)
        defer { http.invalidate() }
        let response = try http.sendSync(.init(method: "GET", path: "/v1/health", route: "GET /v1/health"), bearer: nil)
        XCTAssertEqual(response.status, 200, "ATS or the dev service blocked loopback HTTP")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(body["apiVersion"] as? Int, 1)
    }

    /// Activities must run on the main actor; the blocking engine calls may (only the app forbids that).
    @MainActor
    func testE2E02FullFlow() async throws {
        XCTAssertFalse(admin.isEmpty); XCTAssertFalse(email.isEmpty)
        let vault = TestConnectionVault()
        let rootA = try root("a"), rootB = try root("b"), rootTwo = try root("two")

        // 1. Sign in, scripted.
        let signedIn = try await signIn(rootA, vault: vault)
        let firstDrive = try XCTContext.runActivity(named: "Sign in") { _ -> ParaAirCloudDrive in
            XCTAssertEqual(signedIn.account.issuer, issuer.absoluteString)
            XCTAssertEqual(signedIn.account.state, .signedIn)
            XCTAssertEqual(signedIn.stateRoot.standardizedFileURL, rootA.standardizedFileURL)
            let stored = try XCTUnwrap(try vault.load(id: signedIn.account.id).oauth)
            XCTAssertTrue((stored.scope ?? "").split(separator: " ").contains("drive"))
            return try XCTUnwrap(signedIn.drives.first)
        }
        let workspace = firstDrive.workspaceId

        // 2. Attach the personal drive and create a second one in its own folder.
        let profile = try XCTContext.runActivity(named: "Create the drive") { _ -> DriveProfile in
            let profile = try CloudDriveSetup.attach(driveID: firstDrive.id, finderName: "ParaAir Cloud", accountID: signedIn.account.id,
                                                     stateRoot: rootA, dependencies: dependencies(vault))
            XCTAssertEqual(profile.blockSize, 4_194_304)
            try FileManager.default.copyItem(at: rootA.appendingPathComponent("cloud-accounts"), to: rootTwo.appendingPathComponent("cloud-accounts"))
            let second = try CloudDriveSetup.create(workspaceID: workspace, name: "E2E Two", finderName: "E2E Two", accountID: signedIn.account.id,
                                                    stateRoot: rootTwo, dependencies: dependencies(vault))
            XCTAssertEqual(second.blockSize, 4_194_304)
            XCTAssertNotEqual(second.cloudDriveID, profile.cloudDriveID)
            return profile
        }
        var engine = try Engine.open(profile: profile, stateRoot: rootA, dependencies: dependencies(vault))
        _ = try engine.stat("/")
        XCTAssertEqual(try String(contentsOf: rootA.appendingPathComponent("volumes/\(profile.name)/volume.identity"), encoding: .utf8),
                       "paraair-cloud:v1:" + firstDrive.id)
        let api = try self.api(rootA, signedIn.account, vault)

        // 3. Write a file.
        let data = seededBytes(9 * 1024 * 1024, seed: 2026)
        try XCTContext.runActivity(named: "Write a file") { _ in
            _ = try engine.create("/Movies", directory: true)
            _ = try engine.create("/Movies/a+b.mov", directory: false)
            for offset in stride(from: 0, to: data.count, by: 1 << 20) {
                _ = try engine.write("/Movies/a+b.mov", offset: Int64(offset), data: data.subdata(in: offset..<offset + (1 << 20)))
            }
            _ = try engine.flushUploads()
            XCTAssertTrue(try engine.uploads().isEmpty)
            XCTAssertEqual(try api.stat(driveID: firstDrive.id, path: "/Movies/a+b.mov").size, 9_437_184)
        }

        // 4. Read a range, then the whole file.
        try XCTContext.runActivity(named: "Read a range") { _ in
            _ = try engine.evictCache()
            let before = try engine.status().objectGetRequests
            XCTAssertEqual(try engine.read("/Movies/a+b.mov", offset: 4_194_300, length: 11), data.subdata(in: 4_194_300..<4_194_311))
            XCTAssertEqual(sha(try readAll(engine, "/Movies/a+b.mov", size: data.count)), sha(data))
            XCTAssertEqual(try engine.status().objectGetRequests - before, 3)
        }

        // 5. Partial overwrite uploads one chunk.
        try XCTContext.runActivity(named: "Partial overwrite") { _ in
            let before = try XCTUnwrap(try api.me().workspaces.first { $0.id == workspace }?.usage?.uploadedBytes)
            _ = try engine.write("/Movies/a+b.mov", offset: 5 * 1024 * 1024, data: seededBytes(4096, seed: 7))
            _ = try engine.flushUploads()
            XCTAssertTrue(try engine.uploads().isEmpty)
            let after = try XCTUnwrap(try api.me().workspaces.first { $0.id == workspace }?.usage?.uploadedBytes)
            XCTAssertEqual(after - before, 4_194_304)
        }

        // 6. Conflict between two Macs.
        let deviceB = try await signIn(rootB, vault: vault)
        try XCTContext.runActivity(named: "Conflict") { _ in
            _ = try engine.create("/doc.txt", directory: false)
            _ = try engine.write("/doc.txt", offset: 0, data: Data("v1".utf8))
            _ = try engine.flushUploads()
            let profileB = try CloudDriveSetup.attach(driveID: firstDrive.id, finderName: "ParaAir Cloud", accountID: deviceB.account.id,
                                                      stateRoot: rootB, dependencies: dependencies(vault))
            let engineB = try Engine.open(profile: profileB, stateRoot: rootB, dependencies: dependencies(vault))
            XCTAssertEqual(try engineB.read("/doc.txt", offset: 0, length: 2), Data("v1".utf8))
            _ = try engineB.write("/doc.txt", offset: 0, data: Data("B".utf8))
            _ = try engine.write("/doc.txt", offset: 0, data: Data("A2".utf8))
            _ = try engine.flushUploads()
            let remaining = try engineB.flushUploads()
            XCTAssertEqual(remaining.first?.state, "conflict")
            XCTAssertEqual(try engineB.read("/doc.txt", offset: 0, length: 1), Data("B".utf8))
            XCTAssertEqual(try api.stat(driveID: firstDrive.id, path: "/doc.txt").size, 2)
            XCTAssertGreaterThan(try engineB.status().pendingWriteBytes, 0)
        }

        // 7. Quota exceeded (needs the engine's E3 rotation).
        try XCTContext.runActivity(named: "Quota exceeded") { _ in
            let used = try XCTUnwrap(try api.drive(firstDrive.id).capacity.usedBytes)
            XCTAssertEqual(try adminRequest("PATCH", "admin/v1/workspaces/\(workspace)", ["quotaOverrideBytes": used + 1_048_576]), 200)
            _ = try engine.create("/big.bin", directory: false)
            _ = try engine.write("/big.bin", offset: 0, data: seededBytes(8 << 20, seed: 8))
            let before = try XCTUnwrap(try engine.uploads().first { $0.path == "/big.bin" }?.transactionID)
            let pending = try XCTUnwrap(try engine.flushUploads().first { $0.path == "/big.bin" })
            XCTAssertEqual(pending.lastErrno, EDQUOT); XCTAssertEqual(pending.state, "pending")
            XCTAssertNotEqual(pending.transactionID, before)
            XCTAssertNoThrow(try engine.write("/big.bin", offset: 0, data: Data("more".utf8)))
            XCTAssertLessThanOrEqual(try XCTUnwrap(try engine.capacity()).availableBytes, 1_048_576)
            XCTAssertEqual(try adminRequest("PATCH", "admin/v1/workspaces/\(workspace)", ["quotaOverrideBytes": nil]), 200)
            // A fresh engine has no client-side quota cooldown.
            engine = try Engine.open(profile: profile, stateRoot: rootA, dependencies: dependencies(vault))
            XCTAssertTrue(try engine.flushUploads().filter { $0.path != "/doc.txt" }.isEmpty)
        }

        // 8. Delete and restore from trash.
        try XCTContext.runActivity(named: "Trash and restore") { _ in
            try engine.remove("/Movies/a+b.mov", directory: false)
            let item = try XCTUnwrap(try api.trash(driveID: firstDrive.id, cursor: nil, limit: 100).items.first { $0.path == "/Movies/a+b.mov" })
            XCTAssertEqual(item.expiresAt.timeIntervalSinceNow, 30 * 86400, accuracy: 3600)
            // Restore through the CLI, in process, with the same injected vault and transport.
            let cli = CLIApplication(environment: [:], dependencies: dependencies(vault))
                .run(["--state-dir", rootA.path, "--json", "restore", profile.name, String(item.nodeId)])
            XCTAssertEqual(cli.exitCode, 0, cli.stdout + cli.stderr)
            let restored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
            XCTAssertEqual(restored["path"] as? String, "/Movies/a+b.mov")
            let size = Int(try engine.stat("/Movies/a+b.mov").size)
            var expected = data
            expected.replaceSubrange(5 * 1024 * 1024..<5 * 1024 * 1024 + 4096, with: seededBytes(4096, seed: 7))
            XCTAssertEqual(sha(try readAll(engine, "/Movies/a+b.mov", size: size)), sha(expected))
        }

        // 9. Token refresh and replay of the previous refresh token.
        try XCTContext.runActivity(named: "Token refresh") { _ in
            let old = try XCTUnwrap(try vault.load(id: signedIn.account.id).oauth)
            Thread.sleep(forTimeInterval: 6)
            let refreshing = try Engine.open(profile: profile, stateRoot: rootA, dependencies: dependencies(vault, minimumValidity: 115))
            _ = try refreshing.stat("/")
            let renewed = try XCTUnwrap(try vault.load(id: signedIn.account.id).oauth)
            XCTAssertNotEqual(renewed.refreshToken, old.refreshToken)
            var request = URLRequest(url: issuer.appendingPathComponent("oauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = oauthFormBody(["grant_type": "refresh_token", "refresh_token": old.refreshToken!, "client_id": "paraair-macos"])
            let (status, body) = try blockingStatus(request)
            XCTAssertEqual(status, 200)
            let replay = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(replay["refresh_token"] as? String, renewed.refreshToken)
        }

        // 10. Sign out and revoke.
        let tokens = try XCTUnwrap(try CloudAccountStore(root: rootA).signOut(signedIn.account.id, vault: vault))
        await ParaAirCloudSignIn.revoke(tokens, issuer: issuer, policy: policy, configuration: configuration)
        try XCTContext.runActivity(named: "Sign out") { _ in
            var me = URLRequest(url: issuer.appendingPathComponent("v1/me"))
            me.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
            me.setValue("mac/dev", forHTTPHeaderField: "X-ParaAir-Client")
            XCTAssertEqual(try blockingStatus(me).0, 401)
            let fresh = try Engine.open(profile: profile, stateRoot: rootA, dependencies: dependencies(vault, minimumValidity: 6))
            expectDriveError(EACCES) { _ = try fresh.stat("/never-cached") }
            expectDriveError(EACCES) { _ = try fresh.list("/") }
        }
    }
}
