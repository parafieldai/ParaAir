import XCTest
import Darwin
@testable import StreamDriveCore

final class CloudDriveSetupTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var vault: TestConnectionVault!
    private var record: CloudAccount!
    private let drivesRoute = "POST /v1/drives"

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = TestConnectionVault()
        record = try fake.saveAccount(account, root: root, vault: vault)
    }
    private var dependencies: EngineOpenDependencies { fake.dependencies(vault: vault) }

    func testCreatePersistsIdempotencyKeyAndSavesProfile() throws {
        let profile = try CloudDriveSetup.create(workspaceID: account.workspaceID, name: "Projects", finderName: "Projects",
                                                 accountID: record.id, stateRoot: root, dependencies: dependencies)
        XCTAssertEqual(try ProfileStore(root: root).load(profile.name), profile)
        XCTAssertEqual(profile.backend, .paraairCloud); XCTAssertEqual(profile.cloudIssuer, fake.issuerString)
        XCTAssertEqual(profile.cloudAccountID, record.id)
        XCTAssertEqual(fake.liveDriveCount(workspaceID: account.workspaceID), 2)
        let request = try XCTUnwrap(fake.requests(drivesRoute).first)
        XCTAssertNotNil(request.headers["idempotency-key"].flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud-pending-drive.json").path))
        let drives = try ParaAirCloudAPI(http: try ParaAirCloudHTTP(baseURL: fake.issuer, policy: .init(allowsLoopbackHTTP: false),
                                                                   configuration: fake.configuration),
                                         tokens: StaticAccessToken(vault.load(id: record.id).oauth!.accessToken)).drives()
        XCTAssertTrue(drives.contains { $0.id == profile.cloudDriveID && $0.name == "Projects" })
    }

    func testCreateRetryAfterCrashReusesKey() throws {
        fake.injectTransport(.networkConnectionLost, route: drivesRoute, times: 3, afterProcessing: true)
        expectDriveError(ECONNRESET) {
            _ = try CloudDriveSetup.create(workspaceID: self.account.workspaceID, name: "Projects", finderName: "Projects",
                                           accountID: self.record.id, stateRoot: self.root, dependencies: self.dependencies)
        }
        let pending = root.appendingPathComponent("cloud-pending-drive.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(try ProfileStore(root: root).list().isEmpty)
        let profile = try CloudDriveSetup.create(workspaceID: account.workspaceID, name: "Projects", finderName: "Projects",
                                                 accountID: record.id, stateRoot: root, dependencies: dependencies)
        let keys = Set(fake.requests(drivesRoute).compactMap { $0.headers["idempotency-key"] })
        XCTAssertEqual(keys.count, 1, "every attempt reuses the persisted key")
        XCTAssertEqual(fake.requests(drivesRoute).count, 4)
        XCTAssertEqual(fake.liveDriveCount(workspaceID: account.workspaceID), 2, "the lost reply did not create a second drive")
        XCTAssertNotNil(profile.cloudDriveID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testAttachVerifiesDriveID() throws {
        expectDriveError(ENXIO) {
            _ = try CloudDriveSetup.attach(driveID: UUID().uuidString.lowercased(), finderName: "ParaAir Cloud", accountID: self.record.id,
                                           stateRoot: self.root, dependencies: self.dependencies)
        }
        expectDriveError(ENXIO) {
            _ = try CloudDriveSetup.attach(driveID: "not-a-drive", finderName: "ParaAir Cloud", accountID: self.record.id,
                                           stateRoot: self.root, dependencies: self.dependencies)
        }
        fake.injectRaw(route: "GET /v1/drives/{d}", status: 200, body: try JSONSerialization.data(withJSONObject: [
            "drive": ["id": UUID().uuidString.lowercased(), "workspaceId": account.workspaceID, "name": "Other", "role": "owner", "writable": true,
                      "chunkSize": 4_194_304, "createdAt": "2026-10-09T12:00:00.000Z"],
            "capacity": ["quotaBytes": 1, "usedBytes": 0, "retainedBytes": 0, "reservedBytes": 0, "availableBytes": 1],
            "limits": ["chunkSize": 4_194_304, "maxFileBytes": 1, "maxManifestChunks": 1, "maxListPage": 1, "maxMoveDescendants": 1, "readTokenSeconds": 300]]))
        XCTAssertThrowsError(try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id,
                                                        stateRoot: root, dependencies: dependencies))
        XCTAssertTrue(try ProfileStore(root: root).list().isEmpty)
        let profile = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id,
                                                 stateRoot: root, dependencies: dependencies)
        XCTAssertEqual(profile.cloudDriveID, account.driveID); XCTAssertEqual(profile.name, "ParaAir-Cloud")
        XCTAssertEqual(profile.finderName, "ParaAir Cloud")
        try CloudAccountStore(root: root).signOut(record.id, vault: vault)
        let signedOut = try cloudTestRoot(self)
        try FileManager.default.copyItem(at: root.appendingPathComponent("cloud-accounts"), to: signedOut.appendingPathComponent("cloud-accounts"))
        expectDriveError(EACCES) {
            _ = try CloudDriveSetup.attach(driveID: self.account.driveID, finderName: "X", accountID: self.record.id, stateRoot: signedOut,
                                           dependencies: self.dependencies)
        }
    }

    func testRefusesSecondProfileInFolder() throws {
        let first = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id,
                                               stateRoot: root, dependencies: dependencies)
        expectDriveError(EEXIST) {
            _ = try CloudDriveSetup.attach(driveID: self.account.driveID, finderName: "Again", accountID: self.record.id,
                                           stateRoot: self.root, dependencies: self.dependencies)
        }
        expectDriveError(EEXIST) {
            _ = try CloudDriveSetup.create(workspaceID: self.account.workspaceID, name: "Two", finderName: "Two", accountID: self.record.id,
                                           stateRoot: self.root, dependencies: self.dependencies)
        }
        XCTAssertEqual(fake.liveDriveCount(workspaceID: account.workspaceID), 1)
        let replaced = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "Renamed", name: first.name, accountID: record.id,
                                                  stateRoot: root, replace: true, dependencies: dependencies)
        XCTAssertEqual(replaced.name, first.name); XCTAssertEqual(replaced.finderName, "Renamed")
    }

    func testProfileUsesFourMiBBlocksAndScaledLimits() throws {
        let gib: Int64 = 1 << 30
        let id = UUID().uuidString.lowercased(), drive = UUID().uuidString.lowercased()
        func make(_ free: Int64, finder: String = "ParaAir Cloud") -> DriveProfile {
            CloudDriveSetup.profile(issuer: "https://cloud.example.test", accountID: id, driveID: drive, finderName: finder, stateRoot: root, freeBytes: free)
        }
        let mid = make(100 * gib)
        XCTAssertEqual(mid.blockSize, 4_194_304); XCTAssertEqual(mid.cacheLimitBytes, 10 * gib); XCTAssertEqual(mid.maxJournalBytes, 20 * gib)
        XCTAssertEqual(mid.minFreeBytes, 5 * gib); XCTAssertNil(mid.mountPoint); XCTAssertEqual(mid.backend, .paraairCloud)
        XCTAssertNil(mid.metadataURL); XCTAssertNil(mid.libraryPath); XCTAssertNil(mid.connectionID)
        XCTAssertEqual(make(1 * gib).cacheLimitBytes, 2 * gib); XCTAssertEqual(make(1 * gib).maxJournalBytes, 4 * gib)
        XCTAssertEqual(make(2000 * gib).cacheLimitBytes, 20 * gib); XCTAssertEqual(make(2000 * gib).maxJournalBytes, 50 * gib)
        XCTAssertEqual(mid.name, "ParaAir-Cloud"); XCTAssertEqual(mid.displayName, "ParaAir Cloud")
        XCTAssertNil(make(gib, finder: "Studio").displayName)
        XCTAssertEqual(CloudDriveSetup.profileName(for: "  Été Video / Projects  "), "t-Video-Projects")
        XCTAssertEqual(CloudDriveSetup.profileName(for: "日本"), "ParaAir")
        XCTAssertNoThrow(try mid.validate())
    }

    func testDefaultStateRootLayout() {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(CloudDriveSetup.defaultStateRoot(accountID: id, home: URL(fileURLWithPath: "/Users/tester")).path,
                       "/Users/tester/Library/Application Support/ParaAir/Cloud Drives/" + id)
        XCTAssertTrue(CloudDriveSetup.defaultStateRoot(accountID: id).path.hasSuffix("Library/Application Support/ParaAir/Cloud Drives/" + id))
        XCTAssertEqual(CloudDriveSetup.blockSize, 4_194_304)
        XCTAssertEqual(CloudDriveSetup.defaultFinderName, "ParaAir Cloud")
    }

    // MARK: Sign-in (6.8), driven by the headless dev browser against the fake service

    private func signIn(email: String, current: URL, home: URL, decision: String = "allow",
                        vault: any ConnectionVault) async throws -> ParaAirCloudSignIn.Result {
        let browser = HeadlessDevBrowser(admin: fake.adminToken, email: email, configuration: fake.configuration, decision: decision)
        browser.outboxWait = 0.5 // the fake writes its outbox before answering
        return try await ParaAirCloudSignIn.run(issuer: fake.issuer, currentStateRoot: current, policy: .init(allowsLoopbackHTTP: false),
                                                vault: vault, configuration: fake.configuration, minimumValidity: 5, home: home,
                                                openAuthorizationURL: { try await browser.open($0) })
    }

    func testSignInWithHeadlessBrowserCreatesAccountAndListsDrives() async throws {
        let current = try cloudTestRoot(self), home = try cloudTestRoot(self), vault = TestConnectionVault()
        fake.invite("New.Person@Example.test")
        let result = try await signIn(email: "new.person@example.test", current: current, home: home, vault: vault)
        XCTAssertEqual(result.stateRoot, current); XCTAssertFalse(result.createdStateRoot)
        XCTAssertEqual(result.account.issuer, fake.issuerString); XCTAssertEqual(result.account.email, "new.person@example.test")
        XCTAssertEqual(result.account.state, .signedIn); XCTAssertEqual(result.me.user.id, result.account.userID)
        XCTAssertEqual(result.drives.map(\.name), ["ParaAir Cloud"])
        XCTAssertEqual(try CloudAccountStore(root: current).load(result.account.id), result.account)
        let tokens = try XCTUnwrap(try vault.load(id: result.account.id).oauth)
        XCTAssertTrue(tokens.accessToken.hasPrefix("pca_")); XCTAssertTrue(tokens.refreshToken?.hasPrefix("pcr_") == true)
        XCTAssertEqual(fake.tokenRequests, 1)
        // Signing in again reuses the record for the same issuer and user.
        let again = try await signIn(email: "new.person@example.test", current: current, home: home, vault: vault)
        XCTAssertEqual(again.account.id, result.account.id)
        XCTAssertEqual(CloudAccountStore(root: current).list().accounts.count, 1)
    }

    func testDeniedAndUninvitedSignInsSaveNothing() async throws {
        let current = try cloudTestRoot(self), home = try cloudTestRoot(self), vault = TestConnectionVault()
        do {
            _ = try await signIn(email: account.email, current: current, home: home, decision: "deny", vault: vault)
            XCTFail("Expected the denied consent to fail")
        } catch { XCTAssertEqual(error as? OAuthError, .authorizationDenied) }
        do {
            _ = try await signIn(email: "stranger@example.test", current: current, home: home, vault: vault)
            XCTFail("Expected an uninvited email to get no code")
        } catch { XCTAssertEqual(error as? OAuthError, .requestFailed) }
        XCTAssertTrue(CloudAccountStore(root: current).list().accounts.isEmpty)
        XCTAssertTrue(fake.outbox.filter { $0.to == "stranger@example.test" }.isEmpty)
    }

    func testCancelUnfinishedSignsOutRevokesAndRemovesCreatedRoot() async throws {
        let home = try cloudTestRoot(self), vault = TestConnectionVault()
        _ = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaAir Cloud", accountID: record.id, stateRoot: root,
                                       dependencies: dependencies)
        let second = fake.createAccount(email: "second@example.test")
        let result = try await signIn(email: second.email, current: root, home: home, vault: vault)
        XCTAssertTrue(result.createdStateRoot, "a folder that already has a drive is left alone")
        XCTAssertEqual(result.stateRoot, CloudDriveSetup.defaultStateRoot(accountID: result.account.id, home: home))
        let tokens = try XCTUnwrap(try vault.load(id: result.account.id).oauth)
        await ParaAirCloudSignIn.cancelUnfinished(result, vault: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.stateRoot.path))
        expectDriveError(EACCES) { _ = try vault.load(id: result.account.id) }
        XCTAssertEqual(fake.requests("DELETE /v1/sessions/current").count, 1)
        let http = try ParaAirCloudHTTP(baseURL: fake.issuer, policy: .init(allowsLoopbackHTTP: false), configuration: fake.configuration)
        expectDriveError(EACCES) { _ = try ParaAirCloudAPI(http: http, tokens: StaticAccessToken(tokens.accessToken)).me() }
    }

    func testHeadlessBrowserReadsFormFieldsInAnyAttributeStyle() {
        for html in [#"<form><input type="hidden" name="ar" value="ar_1"></form>"#, #"<INPUT value='ar_1' NAME='ar'/>"#,
                     "<input\nname=ar\tvalue=ar_1>", #"<input name="email"><input name="ar" value="ar_1">"#] {
            XCTAssertEqual(HeadlessDevBrowser.inputValue("ar", in: html), "ar_1", html)
        }
        XCTAssertEqual(HeadlessDevBrowser.inputValue("ar", in: #"<input name="ar" value="a&amp;b">"#), "a&b")
        XCTAssertNil(HeadlessDevBrowser.inputValue("ar", in: #"<input name="code" value="1"><p name="ar" value="x">"#))
    }
}
