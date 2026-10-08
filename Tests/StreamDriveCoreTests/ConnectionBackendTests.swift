import Foundation
import XCTest
import Darwin
@testable import StreamDriveCore

final class ConnectionBackendTests: XCTestCase {
    private func record() -> StorageConnection {
        StorageConnection(provider: .customS3, name: "Fixture", state: .storageReady, bucket: "fixture-bucket", endpoint: "https://127.0.0.1:1", region: "us-east-1")
    }
    private func secrets(_ connection: StorageConnection, suffix: String = "one") throws -> ConnectionSecrets {
        ConnectionSecrets(binding: connection.credentialBinding,
                          s3: try S3Credentials(accessKey: "fixture-access-" + suffix, secretKey: "fixture-secret-" + suffix))
    }
    func testNativeS3ConfigurationBindsEndpointAndRegionWithoutMutatingPublicRecord() throws {
        let connection = record(), credentials = try secrets(connection)
        let config = try connection.nativeConfiguration(secrets: credentials)
        XCTAssertEqual(config["expectedBucketURL"] as? String, "https://127.0.0.1:1/fixture-bucket")
        XCTAssertEqual(config["s3Region"] as? String, "us-east-1")
        XCTAssertEqual((config["objectCredentials"] as? [String: String])?["accessKey"], "fixture-access-one")
        XCTAssertNil(config["cloudflareToken"])
        let publicJSON = String(data: try JSONEncoder().encode(connection), encoding: .utf8)!
        XCTAssertFalse(publicJSON.contains("fixture-access-one"))
        XCTAssertFalse(publicJSON.contains("fixture-secret-one"))
    }
    func testNativeCloudflareConfigurationRequiresExactAccountAndBucket() throws {
        let account = "0123456789abcdef0123456789abcdef"
        let endpoint = try CloudflareR2Provider.bucketEndpoint(accountID: account, bucketName: "fixture-bucket").absoluteString
        var connection = StorageConnection(provider: .cloudflareR2, name: "Fixture R2", state: .storageReady,
                                            accountID: account, bucket: "fixture-bucket", endpoint: endpoint)
        let credentials = ConnectionSecrets(binding: connection.credentialBinding,
            oauth: OAuthTokens(accessToken: "fixture-oauth", expiresAt: Date().addingTimeInterval(3600)))
        let config = try connection.nativeConfiguration(secrets: credentials)
        XCTAssertEqual(config["expectedBucketURL"] as? String, endpoint)
        XCTAssertEqual(config["cloudflareToken"] as? String, "fixture-oauth")
        XCTAssertNil(config["objectCredentials"])
        connection.accountID = "22222222222222222222222222222222"
        XCTAssertThrowsError(try connection.nativeBucketURL())
        XCTAssertThrowsError(try connection.nativeConfiguration(secrets: credentials)) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
    }
    func testChangedTargetCannotUseCredentialsBoundToOriginal() throws {
        let original = record(), credentials = try secrets(original)
        for field in 0..<4 {
            var changed = original
            switch field {
            case 0: changed.bucket = "other-bucket"
            case 1: changed.endpoint = "https://elsewhere.invalid"
            case 2: changed.region = "us-west-2"
            default: changed.provider = .backblazeB2
            }
            XCTAssertThrowsError(try changed.nativeConfiguration(secrets: credentials)) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
        }
    }
    func testCredentialBearingPublicTargetsAndIncompleteStateFailBeforeNativeLoad() throws {
        for endpoint in ["https://person:password@127.0.0.1", "https://127.0.0.1?token=private", "https://127.0.0.1/other-bucket", "http://127.0.0.1"] {
            var connection = record(); connection.endpoint = endpoint
            XCTAssertThrowsError(try connection.nativeConfiguration(secrets: secrets(connection)))
        }
        var connection = record(); connection.state = .authorized
        XCTAssertThrowsError(try connection.nativeConfiguration(secrets: secrets(connection)))
    }
    /// Initializes only local SQLite and stat/list metadata; no server exists at this loopback endpoint.
    /// No object operation, credential-provider fallback, or real cloud target is used.
    func testNativeCredentialRotationReopensSameVolumeAndRejectsRetargeting() throws {
        guard let path = ProcessInfo.processInfo.environment["STREAMDRIVE_NATIVE_LIBRARY"] else { throw XCTSkip("Native bridge not selected") }
        let library = URL(fileURLWithPath: path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/connection-backend-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("metadata.sqlite3"), connection = record()
        let initialSecrets = try secrets(connection)
        let initialized = try JuiceFSBackend.initializeCloud(libraryURL: library, metadataURL: metadata, connection: connection, secrets: initialSecrets)
        let identity = try initialized.volumeIdentity()
        XCTAssertEqual(try initialized.metrics().objectGetRequests, 0)
        try initialized.close()
        XCTAssertThrowsError(try JuiceFSBackend.initializeCloud(libraryURL: library, metadataURL: metadata, connection: connection, secrets: initialSecrets)) {
            XCTAssertEqual(($0 as? DriveError)?.code, EEXIST)
        }
        let store = ConnectionStore(root: root), vault = TestConnectionVault()
        try store.authorize(connection, secrets: initialSecrets, vault: vault)
        var boundIdentities: [String] = []
        let backend = try ConnectionBackend(libraryURL: library, metadataURL: "sqlite3://" + metadata.path,
            connectionID: connection.id, store: store, vault: vault, bindVolume: { value in
                guard value == identity else { throw DriveError(EXDEV, "Fixture volume changed") }
                boundIdentities.append(value)
            })
        defer { try? backend.close() }
        XCTAssertTrue(try backend.list("/").isEmpty)
        XCTAssertEqual(boundIdentities.count, 1)
        let rotated = try secrets(connection, suffix: "two")
        try vault.save(rotated, id: connection.id)
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(boundIdentities, [identity, identity])
        XCTAssertEqual(try backend.transferMetrics()?.objectReadBytes, 0)
        var wrongBinding = rotated; wrongBinding.binding = "different-target"
        try vault.save(wrongBinding, id: connection.id)
        XCTAssertThrowsError(try backend.stat("/")) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
        try vault.save(rotated, id: connection.id)
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(boundIdentities.count, 2)
        var other = connection; other.bucket = "other-bucket"
        XCTAssertThrowsError(try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + metadata.path, connection: other, secrets: secrets(other))) {
            XCTAssertEqual(($0 as? DriveError)?.code, EXDEV)
        }
        // Only inspect the known fake-key fixture, never an operator's existing database.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("metadata.sqlite3") {
            let data = try Data(contentsOf: file)
            XCTAssertNil(data.range(of: Data("fixture-secret-one".utf8)))
            XCTAssertNil(data.range(of: Data("fixture-secret-two".utf8)))
        }
    }
}
