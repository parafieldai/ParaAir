import XCTest
import Darwin
@testable import StreamDriveCore

final class TestConnectionVault: ConnectionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ConnectionSecrets] = [:]
    var failRemoval = false
    func load(id: String) throws -> ConnectionSecrets {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[id] else { throw DriveError(EACCES, "Test vault entry is missing") }
        return value
    }
    func save(_ secrets: ConnectionSecrets, id: String) throws { lock.lock(); values[id] = secrets; lock.unlock() }
    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemoval { throw DriveError(EACCES, "Test vault is locked") }
        values[id] = nil
    }
}

final class ConnectionStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/connection-tests/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func record() -> StorageConnection {
        StorageConnection(provider: .customS3, name: "Test storage", state: .storageReady,
                          accountID: "test-account", bucket: "test-bucket", endpoint: "https://s3.example.test", region: "test-1")
    }
    private func secrets(_ record: StorageConnection, expiry: Date? = nil) throws -> ConnectionSecrets {
        ConnectionSecrets(binding: record.credentialBinding, oauth: OAuthTokens(accessToken: "test-private-oauth", refreshToken: "test-private-refresh"),
                          s3: try S3Credentials(accessKey: "test-private-access", secretKey: "test-private-secret", sessionToken: "test-private-session"),
                          storageExpiresAt: expiry, providerSession: Data("test-private-device-registration".utf8))
    }
    private func expect(_ code: Int32, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? DriveError)?.code, code, file: file, line: line) }
    }

    func testPublicRecordsNeverPersistVaultSecretsAndUsePrivatePermissions() throws {
        let root = try fixture(), store = ConnectionStore(root: root), record = record(), vault = TestConnectionVault()
        try store.save(record); try vault.save(secrets(record), id: record.id)
        let file = root.appendingPathComponent("connections/\(record.id).json")
        let text = try String(contentsOf: file, encoding: .utf8)
        for value in ["test-private-oauth", "test-private-refresh", "test-private-access", "test-private-secret", "test-private-session", "test-private-device-registration", "accessToken", "secretKey"] {
            XCTAssertFalse(text.contains(value))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(try store.load(record.id), record)
        XCTAssertEqual(try store.list().count, 1)
    }

    func testRejectsTraversalAndCredentialBearingPublicAddresses() throws {
        let store = ConnectionStore(root: try fixture())
        for id in ["../secret", "a/b", "", UUID().uuidString.uppercased()] { expect(EINVAL) { _ = try store.load(id) } }
        for endpoint in ["https://user:password@example.test", "https://example.test?token=secret", "https://example.test/#secret", "http://example.test"] {
            var record = record(); record.endpoint = endpoint
            expect(EINVAL) { try store.save(record) }
        }
    }

    func testDirectoryAndFileSymlinksAreRejected() throws {
        let root = try fixture(), target = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("connections"), withDestinationURL: target)
        expect(EACCES) { try ConnectionStore(root: root).save(self.record()) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("connections"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("connections"), withIntermediateDirectories: false)
        let record = record(), source = target.appendingPathComponent("public.json")
        try JSONEncoder().encode(record).write(to: source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("connections/\(record.id).json"), withDestinationURL: source)
        let store = ConnectionStore(root: root)
        expect(EACCES) { _ = try store.load(record.id) }
        expect(EACCES) { try store.save(record) }
    }

    func testPublicJSONCannotRetargetExistingCredentials() throws {
        let root = try fixture(), store = ConnectionStore(root: root), vault = TestConnectionVault()
        var record = record(); try store.save(record); try vault.save(secrets(record), id: record.id)
        record.bucket = "different-bucket"
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("connections/\(record.id).json"))
        expect(EXDEV) { _ = try store.credentials(record.id, vault: vault) }
    }

    func testExpiredAndDisconnectedCredentialsAreRejected() throws {
        let store = ConnectionStore(root: try fixture()), record = record(), vault = TestConnectionVault()
        try store.save(record)
        try vault.save(secrets(record, expiry: Date().addingTimeInterval(-1)), id: record.id)
        expect(EACCES) { _ = try store.credentials(record.id, vault: vault) }
        try vault.save(secrets(record, expiry: Date().addingTimeInterval(600)), id: record.id)
        XCTAssertEqual(try store.credentials(record.id, vault: vault).0.id, record.id)
        try store.disconnect(record.id, vault: vault)
        XCTAssertEqual(try store.load(record.id).state, .disconnected)
        expect(ENOTCONN) { _ = try store.credentials(record.id, vault: vault) }
        expect(EACCES) { _ = try vault.load(id: record.id) }
    }

    func testDisconnectBlocksAccessEvenWhenVaultDeletionFailsAndPreservesFiles() throws {
        let root = try fixture(), store = ConnectionStore(root: root), record = record(), vault = TestConnectionVault()
        let pending = root.appendingPathComponent("pending-data")
        try Data("acknowledged-local-write".utf8).write(to: pending)
        try store.save(record); try vault.save(secrets(record), id: record.id); vault.failRemoval = true
        expect(EACCES) { try store.disconnect(record.id, vault: vault) }
        expect(ENOTCONN) { _ = try store.credentials(record.id, vault: vault) }
        XCTAssertEqual(try Data(contentsOf: pending), Data("acknowledged-local-write".utf8))
    }

    func testTargetRemainsImmutableAfterDisconnectButDisplayNameCanChange() throws {
        let store = ConnectionStore(root: try fixture()), vault = TestConnectionVault()
        var record = record(); try store.save(record); try vault.save(secrets(record), id: record.id)
        var renamed = record; renamed.name = "Renamed storage"; try store.save(renamed)
        try store.disconnect(record.id, vault: vault)
        record = try store.load(record.id)
        var changed = record; changed.bucket = "different-bucket"
        expect(EXDEV) { try store.save(changed) }
        changed = record; changed.provider = .awsS3
        expect(EXDEV) { try store.save(changed) }
        changed = record; changed.endpoint = "https://different.example.test"
        expect(EXDEV) { try store.save(changed) }
        XCTAssertEqual(try store.load(record.id).bucket, record.bucket)
    }

    func testOversizedOrMismatchedRecordsFailClosed() throws {
        let root = try fixture(), store = ConnectionStore(root: root), record = record()
        try store.save(record)
        let file = root.appendingPathComponent("connections/\(record.id).json")
        try Data(repeating: 0x20, count: 65537).write(to: file)
        expect(EINVAL) { _ = try store.load(record.id) }
        var altered = record; altered.id = UUID().uuidString.lowercased()
        try JSONEncoder().encode(altered).write(to: file)
        expect(ENOENT) { _ = try store.load(record.id) }
    }
}
