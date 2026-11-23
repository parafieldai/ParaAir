import XCTest
import Darwin
@testable import StreamDriveCore

/// A second drive in a state folder of its own, sharing a sign-in made in another folder (paraair connect
/// --new-state-folder), and the checks the app makes before it learns such a folder.
final class SharedSignInTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var home: URL!
    private var vault: TestConnectionVault!
    private var record: CloudAccount!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = TestConnectionVault()
        home = root.appendingPathComponent("home", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        record = try fake.saveAccount(account, root: first, vault: vault)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var first: URL { root.appendingPathComponent("first", isDirectory: true).standardizedFileURL }
    private func session(_ folder: URL) throws -> ParaAirCloudSession {
        try ParaAirCloudSession(root: folder, accountID: record.id, vault: vault, configuration: fake.configuration,
                                policy: .init(allowsLoopbackHTTP: false))
    }
    private func expectError(_ code: Int32, _ action: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? DriveError)?.code, code, file: file, line: line) }
    }

    func testFoldersSharingASignInRefreshInTurnWithoutEndingIt() throws {
        let second = try CloudDriveSetup.newStateRoot(sharing: record, vault: vault, home: home)
        XCTAssertEqual(second.deletingLastPathComponent().path, CloudDriveSetup.cloudDrivesFolder(home: home).standardizedFileURL.path)
        XCTAssertEqual(try CloudAccountStore(root: second).load(record.id).binding, record.binding)
        let a = try session(first), b = try session(second)
        for _ in 0..<3 {
            fake.expireAccessTokens()
            XCTAssertTrue(try a.refreshIfDue(within: 7200))
            XCTAssertTrue(try b.refreshIfDue(within: 7200), "b starts from the tokens a saved, never from its own stale ones")
            XCTAssertEqual(try ParaAirCloudAPI(http: try a.http(), tokens: a).me().user.email, account.email)
            XCTAssertEqual(try ParaAirCloudAPI(http: try b.http(), tokens: b).me().user.email, account.email)
        }
        // Signing out in one folder signs out the shared sign-in everywhere.
        try CloudAccountStore(root: first).signOut(record.id, vault: vault)
        fake.expireAccessTokens()
        XCTAssertThrowsError(try b.refreshIfDue(within: 7200))
    }

    func testSharingNeedsTheSameSignInInTheVault() throws {
        let other = CloudAccount(issuer: record.issuer, userID: record.userID, email: record.email)
        let folder = root.appendingPathComponent("other", isDirectory: true)
        expectError(EACCES, try CloudAccountStore(root: folder).share(other, vault: vault))
        var signedOut = record!; signedOut.state = .signedOut
        expectError(EACCES, try CloudAccountStore(root: folder).share(signedOut, vault: vault))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CloudDriveSetup.cloudDrivesFolder(home: home).path) == false)
        expectError(EACCES, try CloudDriveSetup.newStateRoot(sharing: other, vault: vault, home: home))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: CloudDriveSetup.cloudDrivesFolder(home: home).path), [],
                       "a refused folder is removed again")
    }

    func testTheAppLearnsOnlyAVettedFolderInCloudDrives() throws {
        let second = try CloudDriveSetup.newStateRoot(sharing: record, vault: vault, home: home)
        let attached = try CloudDriveSetup.attach(driveID: account.driveID, finderName: "ParaOS", accountID: record.id, stateRoot: second,
                                                  dependencies: fake.dependencies(vault: vault))
        XCTAssertEqual(try CloudDriveSetup.adoptableProfile(second, knownRoots: [first], home: home), attached)

        expectError(EACCES, try CloudDriveSetup.adoptableProfile(second, knownRoots: [], home: home))  // no known folder has the sign-in
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(second, knownRoots: [second], home: home))
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(second, knownRoots: [first], home: root))  // outside Cloud Drives
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(first, knownRoots: [first], home: home))
        let link = CloudDriveSetup.cloudDrivesFolder(home: home).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(link, knownRoots: [first], home: home))
        let nested = second.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(nested, knownRoots: [first], home: home))

        // A second drive in the folder, or a different sign-in, is refused too.
        var extra = attached; extra.name = "Extra"
        try ProfileStore(root: second).save(extra)
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(second, knownRoots: [first], home: home))
        try FileManager.default.removeItem(at: second.appendingPathComponent("profiles/Extra.json"))
        XCTAssertNoThrow(try CloudDriveSetup.adoptableProfile(second, knownRoots: [first], home: home))
        try CloudAccountStore(root: first).signOut(record.id, vault: vault)
        expectError(EACCES, try CloudDriveSetup.adoptableProfile(second, knownRoots: [first], home: home))
    }

    func testAFolderAskedToMountIsKeptForLogin() {
        var folders = LoginMountFolders(kept: ["/a"])
        folders.keep("/b", selected: "/s"); folders.keep("/b", selected: "/s"); folders.keep("/s", selected: "/s")
        XCTAssertEqual(folders.kept, ["/a", "/b"])
    }

    /// A vault that runs `beforeLoad` once, at the first load after the fake has answered more token requests than
    /// `after`: inside another folder's refresh, after its exchange and before it saves.
    private final class HookVault: ConnectionVault, @unchecked Sendable {
        let inner = TestConnectionVault()
        var trigger: (() -> Bool)?
        var beforeLoad: (() -> Void)?
        func load(id: String) throws -> ConnectionSecrets {
            if let trigger, trigger(), let hook = beforeLoad { beforeLoad = nil; self.trigger = nil; hook() }
            return try inner.load(id: id)
        }
        func save(_ secrets: ConnectionSecrets, id: String) throws { try inner.save(secrets, id: id) }
        func remove(id: String) throws { try inner.remove(id: id) }
    }

    private func sharedFolders(_ hook: HookVault) throws -> (a: ParaAirCloudSession, b: ParaAirCloudSession) {
        let first = root.appendingPathComponent("hooked", isDirectory: true)
        record = try fake.saveAccount(account, root: first, vault: hook)
        let second = try CloudDriveSetup.newStateRoot(sharing: record, vault: hook, home: home)
        let make = { (folder: URL) in
            try ParaAirCloudSession(root: folder, accountID: self.record.id, vault: hook, configuration: self.fake.configuration,
                                    policy: .init(allowsLoopbackHTTP: false))
        }
        return (try make(first), try make(second))
    }

    func testARefreshNeverSavesOlderTokensOverOnesAnotherFolderSavedMeanwhile() throws {
        let vault = HookVault()
        let (a, b) = try sharedFolders(vault)
        fake.expireAccessTokens()
        let before = fake.count("POST /oauth/token")
        var newest: String?
        vault.trigger = { self.fake.count("POST /oauth/token") > before }
        vault.beforeLoad = {
            // While b's exchange was in flight, the other folder rotated twice and saved.
            _ = try? a.refreshIfDue(within: 7200); _ = try? a.refreshIfDue(within: 7200)
            newest = try? vault.inner.load(id: self.record.id).oauth?.refreshToken
        }
        XCTAssertTrue(try b.refreshIfDue(within: 7200))
        XCTAssertNotNil(newest)
        XCTAssertEqual(try vault.inner.load(id: record.id).oauth?.refreshToken, newest, "b kept its older tokens out of the vault")
        XCTAssertEqual(try ParaAirCloudAPI(http: try a.http(), tokens: a).me().user.email, account.email)
        XCTAssertEqual(try ParaAirCloudAPI(http: try b.http(), tokens: b).me().user.email, account.email)
        fake.expireAccessTokens()
        XCTAssertTrue(try b.refreshIfDue(within: 7200), "b goes on from the newest tokens; the sign-in still works")
    }

    func testARefreshNeverBringsBackASignInAnotherFolderRemoved() throws {
        let vault = HookVault()
        let (_, b) = try sharedFolders(vault)
        fake.expireAccessTokens()
        let before = fake.count("POST /oauth/token")
        vault.trigger = { self.fake.count("POST /oauth/token") > before }
        vault.beforeLoad = { _ = try? CloudAccountStore(root: self.root.appendingPathComponent("hooked")).signOut(self.record.id, vault: vault) }
        _ = try? b.refreshIfDue(within: 7200)
        XCTAssertThrowsError(try vault.inner.load(id: record.id), "the removed Keychain item stays removed")
        _ = try? b.accessToken()
        XCTAssertThrowsError(try vault.inner.load(id: record.id))
    }
}

