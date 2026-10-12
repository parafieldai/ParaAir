import XCTest
import Darwin
@testable import StreamDriveCore

final class CloudAccountStoreTests: XCTestCase {
    private let issuer = "https://cloud.example.test"
    private func user() -> String { "usr_" + FakeParaAirCloud.base32() }
    private func tokens(_ suffix: String = "1") -> OAuthTokens {
        OAuthTokens(accessToken: "pca_access-" + suffix, refreshToken: "pcr_refresh-" + suffix, expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                    scope: "drive offline_access")
    }

    func testSignInWritesRecordAfterVault() throws {
        let root = try cloudTestRoot(self), store = CloudAccountStore(root: root)
        let account = CloudAccount(issuer: issuer, userID: user(), email: "person@example.test")
        let locked = CountingVault(); locked.failSaves = true
        expectDriveError(EACCES) { try store.signIn(account, tokens: self.tokens(), vault: locked) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud-accounts/\(account.id).json").path))
        let vault = TestConnectionVault()
        try store.signIn(account, tokens: tokens(), vault: vault)
        let saved = try store.load(account.id)
        XCTAssertEqual(saved.state, .signedIn); XCTAssertEqual(saved.binding, account.binding)
        XCTAssertEqual(try vault.load(id: account.id).binding, account.binding)
        let (record, stored) = try store.credentials(account.id, vault: vault)
        XCTAssertEqual(record.id, account.id); XCTAssertEqual(stored, tokens())
        let file = root.appendingPathComponent("cloud-accounts/\(account.id).json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("pca_access")); XCTAssertFalse(text.contains("pcr_refresh"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
        expectDriveError(EINVAL) { try store.signIn(account, tokens: OAuthTokens(accessToken: "pca_x"), vault: vault) }
        var other = account; other.userID = self.user(); other.binding = CloudAccount.binding(id: other.id, issuer: other.issuer, userID: other.userID)
        expectDriveError(EXDEV) { try store.signIn(other, tokens: self.tokens(), vault: vault) }
        var forged = account; forged.issuer = "https://evil.example.test"
        expectDriveError(EINVAL) { try store.signIn(forged, tokens: self.tokens(), vault: vault) }
    }

    func testSignOutCapturesTokensAndBlocksCredentials() throws {
        let root = try cloudTestRoot(self), store = CloudAccountStore(root: root), vault = TestConnectionVault()
        let account = CloudAccount(issuer: issuer, userID: user(), email: "person@example.test")
        try store.signIn(account, tokens: tokens(), vault: vault)
        XCTAssertEqual(try store.signOut(account.id, vault: vault), tokens())
        XCTAssertEqual(try store.load(account.id).state, .signedOut)
        expectDriveError(EACCES) { _ = try vault.load(id: account.id) }
        expectDriveError(EACCES) { _ = try store.credentials(account.id, vault: vault) }
        let stubborn = TestConnectionVault()
        try store.signIn(account, tokens: tokens("2"), vault: stubborn)
        stubborn.failRemoval = true
        expectDriveError(EACCES) { _ = try store.signOut(account.id, vault: stubborn) }
        XCTAssertEqual(try store.load(account.id).state, .signedOut, "the record blocks use even when the vault keeps the tokens")
        expectDriveError(EACCES) { _ = try store.credentials(account.id, vault: stubborn) }
        try vault.save(ConnectionSecrets(binding: "other", oauth: tokens()), id: account.id)
        try store.signIn(account, tokens: tokens("3"), vault: vault)
        try vault.save(ConnectionSecrets(binding: "other", oauth: tokens()), id: account.id)
        expectDriveError(EXDEV) { _ = try store.credentials(account.id, vault: vault) }
        try vault.save(ConnectionSecrets(binding: account.binding, oauth: OAuthTokens(accessToken: "pca_only")), id: account.id)
        expectDriveError(EACCES) { _ = try store.credentials(account.id, vault: vault) }
    }

    func testUnreadableRecordDoesNotHideOthers() throws {
        let root = try cloudTestRoot(self), store = CloudAccountStore(root: root), vault = TestConnectionVault()
        let good = CloudAccount(issuer: issuer, userID: user(), email: "good@example.test")
        let bad = CloudAccount(issuer: issuer, userID: user(), email: "bad@example.test")
        try store.signIn(good, tokens: tokens(), vault: vault); try store.signIn(bad, tokens: tokens(), vault: vault)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("cloud-accounts/\(bad.id).json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("cloud-accounts/not-a-uuid.json"))
        let listed = store.list()
        XCTAssertEqual(listed.accounts.map(\.id), [good.id])
        XCTAssertEqual(Set(listed.unreadable), [bad.id, "not-a-uuid"])
        expectDriveError(EINVAL) { _ = try store.load(bad.id) }
        expectDriveError(ENOENT) { _ = try store.load(UUID().uuidString.lowercased()) }
        expectDriveError(EINVAL) { _ = try store.load("../escape") }
        XCTAssertEqual(CloudAccountStore(root: try cloudTestRoot(self)).list().accounts, [])
    }

    func testSymlinksRejected() throws {
        let root = try cloudTestRoot(self), vault = TestConnectionVault()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cloud-accounts"), withDestinationURL: elsewhere)
        let store = CloudAccountStore(root: root)
        let account = CloudAccount(issuer: issuer, userID: user(), email: "person@example.test")
        expectDriveError(EACCES) { try store.signIn(account, tokens: self.tokens(), vault: vault) }
        expectDriveError(EACCES) { _ = try store.load(account.id) }
        XCTAssertEqual(store.list().unreadable, ["cloud-accounts"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("cloud-accounts"))
        try store.signIn(account, tokens: tokens(), vault: vault)
        let file = root.appendingPathComponent("cloud-accounts/\(account.id).json")
        let copy = elsewhere.appendingPathComponent("copy.json")
        try FileManager.default.moveItem(at: file, to: copy)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: copy)
        expectDriveError(EACCES) { _ = try store.load(account.id) }
        XCTAssertEqual(store.list().unreadable, [account.id])
    }

    func testExistingAccountReusedForSameIssuerAndUser() throws {
        let root = try cloudTestRoot(self), store = CloudAccountStore(root: root), vault = TestConnectionVault()
        let userID = user()
        let account = CloudAccount(issuer: issuer, userID: userID, email: "person@example.test")
        try store.signIn(account, tokens: tokens(), vault: vault)
        XCTAssertEqual(store.existing(issuer: issuer, userID: userID)?.id, account.id)
        XCTAssertNil(store.existing(issuer: "https://other.example.test", userID: userID))
        XCTAssertNil(store.existing(issuer: issuer, userID: user()))
        let home = try cloudTestRoot(self)
        let reused = try ParaAirCloudSignIn.chooseRoot(issuer: issuer, userID: userID, current: root, home: home)
        XCTAssertEqual(reused.root, root); XCTAssertEqual(reused.accountID, account.id); XCTAssertFalse(reused.created)
        let empty = try cloudTestRoot(self)
        let fresh = try ParaAirCloudSignIn.chooseRoot(issuer: issuer, userID: user(), current: empty, home: home)
        XCTAssertEqual(fresh.root, empty); XCTAssertFalse(fresh.created)
        let other = try ParaAirCloudSignIn.chooseRoot(issuer: issuer, userID: user(), current: root, home: home)
        XCTAssertTrue(other.created)
        XCTAssertEqual(other.root, CloudDriveSetup.defaultStateRoot(accountID: other.accountID, home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.root.path))
    }
}
