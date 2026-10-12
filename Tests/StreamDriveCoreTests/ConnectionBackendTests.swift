import Foundation
import XCTest
import Darwin
@testable import StreamDriveCore

/// A settable clock for credential re-check intervals.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: () -> Date { { [self] in lock.withLock { value } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

/// Stands in for one native session. A read can be held open to observe calls
/// while it is in flight; every call after close fails like a closed handle.
private final class FakeSession: ConnectionSession, @unchecked Sendable {
    let identity: String
    private let lock = NSLock()
    private var calls = 0, readBytes: Int64 = 0, reads: Int64 = 0, isClosed = false
    private var gate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    init(identity: String) { self.identity = identity }
    var callCount: Int { lock.withLock { calls } }
    var closed: Bool { lock.withLock { isClosed } }
    func holdNextRead() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let value = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        lock.withLock { gate = value }
        return value
    }
    private func call() throws {
        try lock.withLock {
            guard !isClosed else { throw DriveError(EBADF, "Fake session is closed") }
            calls += 1
        }
    }
    func volumeIdentity() throws -> String { identity }
    func stat(_ path: String) throws -> FileEntry {
        try call(); return FileEntry(id: 1, path: path, kind: .directory, size: 0, modifiedNanoseconds: 0, version: "fake")
    }
    func list(_ path: String) throws -> [FileEntry] { try call(); return [] }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try call()
        if let held = lock.withLock({ () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in defer { gate = nil }; return gate }) {
            held.entered.signal(); _ = held.release.wait(timeout: .now() + 5)
        }
        // The session must still be open when an in-flight call finishes.
        try lock.withLock {
            guard !isClosed else { throw DriveError(EBADF, "Fake session closed under an in-flight read") }
            readBytes += Int64(length); reads += 1
        }
        return Data(repeating: UInt8(truncatingIfNeeded: offset), count: length)
    }
    func commit(_ commit: FileCommit) throws -> FileEntry {
        try call(); return FileEntry(id: 2, path: commit.path, kind: .file, size: commit.finalSize, modifiedNanoseconds: 0, version: "fake")
    }
    func createDirectory(_ path: String) throws -> FileEntry { try call(); throw DriveError(ENOTSUP, "Fake session") }
    func move(_ source: String, to destination: String) throws { try call(); throw DriveError(ENOTSUP, "Fake session") }
    func remove(_ path: String, directory: Bool) throws { try call(); throw DriveError(ENOTSUP, "Fake session") }
    func transferMetrics() throws -> TransferMetrics? {
        try lock.withLock {
            guard !isClosed else { throw DriveError(EBADF, "Fake session is closed") }
            return TransferMetrics(objectReadBytes: readBytes, objectGetRequests: reads)
        }
    }
    func close() throws { lock.withLock { isClosed = true } }
}

final class ConnectionBackendTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/connection-backend-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    /// A connection over fake sessions; `sessions` lists every session opened, in order.
    private func fakeConnection(_ root: URL, clock: TestClock) throws
        -> (ConnectionBackend, StorageConnection, ConnectionStore, TestConnectionVault, () -> [FakeSession]) {
        let connection = record(), store = ConnectionStore(root: root), vault = TestConnectionVault()
        try store.authorize(connection, secrets: secrets(connection), vault: vault)
        let opened = NSLock(); var sessions: [FakeSession] = []
        let backend = try ConnectionBackend(connectionID: connection.id, store: store, vault: vault, bindVolume: { _ in },
            openSession: { _, _ in
                let session = FakeSession(identity: "fixture-volume")
                opened.withLock { sessions.append(session) }
                return session
            }, now: clock.now)
        return (backend, connection, store, vault, { opened.withLock { sessions } })
    }
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() { if Date() > deadline { return false }; Thread.sleep(forTimeInterval: 0.01) }
        return true
    }

    func testRotationDoesNotBlockReadsOnOldHandle() throws {
        let clock = TestClock()
        let (backend, connection, _, vault, sessions) = try fakeConnection(try workspace(), clock: clock)
        defer { try? backend.close() }
        XCTAssertEqual(try backend.read("/movie", offset: 1, length: 10), Data(repeating: 1, count: 10))
        let old = try XCTUnwrap(sessions().first), held = old.holdNextRead()
        let inFlight = expectation(description: "read on the old session completes")
        DispatchQueue.global().async {
            do {
                let bytes = try backend.read("/movie", offset: 7, length: 4096)
                XCTAssertEqual(bytes, Data(repeating: 7, count: 4096))
            } catch { XCTFail("In-flight read failed across rotation: \(error)") }
            inFlight.fulfill()
        }
        XCTAssertEqual(held.entered.wait(timeout: .now() + 2), .success)
        // Renewal rotates the credentials while the old session is mid-read.
        try vault.save(secrets(connection, suffix: "two"), id: connection.id)
        clock.advance(16)
        let started = DispatchTime.now()
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(try backend.read("/other", offset: 2, length: 100), Data(repeating: 2, count: 100))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(elapsed, 1, "Rotation and new calls must not wait for the old session's read")
        XCTAssertEqual(sessions().count, 2)
        let replacement = sessions()[1]
        XCTAssertEqual(replacement.callCount, 2)
        XCTAssertFalse(old.closed, "The old session closed under an in-flight read")
        // Totals stay monotonic while the old session drains.
        let during = try XCTUnwrap(backend.transferMetrics())
        XCTAssertGreaterThanOrEqual(during.objectReadBytes, 110)
        held.release.signal()
        wait(for: [inFlight], timeout: 5)
        XCTAssertTrue(eventually { old.closed }, "The replaced session was never closed")
        let after = try XCTUnwrap(backend.transferMetrics())
        XCTAssertEqual(after.objectReadBytes, 10 + 4096 + 100, "Bytes read by the in-flight call are counted once")
        XCTAssertEqual(after.objectGetRequests, 3)
        XCTAssertGreaterThanOrEqual(after.objectReadBytes, during.objectReadBytes)
        XCTAssertEqual(old.callCount, 2, "No call reached the old session after rotation")
    }

    func testDisconnectStopsNativeIOWithinOneCall() throws {
        let clock = TestClock(), root = try workspace()
        let (backend, connection, store, vault, sessions) = try fakeConnection(root, clock: clock)
        defer { try? backend.close() }
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        let session = try XCTUnwrap(sessions().first), calls = session.callCount
        try store.disconnect(connection.id, vault: vault)
        // No clock advance: the rewritten record alone forces the re-check.
        XCTAssertThrowsError(try backend.stat("/")) { XCTAssertEqual(($0 as? DriveError)?.code, ENOTCONN) }
        XCTAssertThrowsError(try backend.read("/movie", offset: 0, length: 1))
        XCTAssertThrowsError(try backend.commit(FileCommit(transactionID: UUID().uuidString, path: "/file", expectedVersion: nil,
                                                           finalSize: 0, extents: []))) {
            XCTAssertEqual(($0 as? DriveError)?.code, ENOTCONN)
            XCTAssertEqual(($0 as? DriveError)?.disposition, .attemptNotDispatched)
        }
        XCTAssertEqual(session.callCount, calls, "A disconnected connection reached storage")
        XCTAssertTrue(eventually { session.closed }, "Disconnect left the session open")
        XCTAssertEqual(sessions().count, 1)

        // The same through the native bridge, when it is built.
        guard let path = ProcessInfo.processInfo.environment["STREAMDRIVE_NATIVE_LIBRARY"] else { return }
        let library = URL(fileURLWithPath: path), nativeRoot = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
        let metadata = nativeRoot.appendingPathComponent("metadata.sqlite3"), nativeConnection = record()
        let nativeSecrets = try secrets(nativeConnection)
        try JuiceFSBackend.initializeCloud(libraryURL: library, metadataURL: metadata, connection: nativeConnection, secrets: nativeSecrets).close()
        let nativeStore = ConnectionStore(root: nativeRoot), nativeVault = TestConnectionVault()
        try nativeStore.authorize(nativeConnection, secrets: nativeSecrets, vault: nativeVault)
        let native = try ConnectionBackend(libraryURL: library, metadataURL: "sqlite3://" + metadata.path, connectionID: nativeConnection.id,
                                           store: nativeStore, vault: nativeVault, bindVolume: { _ in })
        defer { try? native.close() }
        XCTAssertTrue(try native.list("/").isEmpty)
        try nativeStore.disconnect(nativeConnection.id, vault: nativeVault)
        XCTAssertThrowsError(try native.list("/")) { XCTAssertEqual(($0 as? DriveError)?.code, ENOTCONN) }
        XCTAssertThrowsError(try native.transferMetrics()) { XCTAssertEqual(($0 as? DriveError)?.code, ENOTCONN) }
    }

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
    func testConnectedDriveProfileUsesFourMiBBlocks() throws {
        let stateRoot = URL(fileURLWithPath: "/fixture/state", isDirectory: true), connectionID = UUID().uuidString.lowercased()
        let profile = ConnectedDrive.profile(name: "ParaAir", connectionID: connectionID,
                                             metadata: stateRoot.appendingPathComponent("metadata/ParaAir.sqlite3"),
                                             libraryURL: URL(fileURLWithPath: "/fixture/libstreamdrive.dylib"), stateRoot: stateRoot)
        XCTAssertEqual(profile.blockSize, 4_194_304)
        XCTAssertEqual(profile.backend, .juicefs)
        XCTAssertEqual(profile.connectionID, connectionID)
        XCTAssertEqual(profile.metadataURL, "sqlite3:///fixture/state/metadata/ParaAir.sqlite3")
        XCTAssertEqual(profile.mountPoint, "/fixture/ParaAir-ParaAir-" + String(connectionID.prefix(8)))
        XCTAssertNoThrow(try profile.validate())
        // Only the block size differs from the generic defaults.
        let defaults = DriveProfile(name: "ParaAir")
        XCTAssertEqual(profile.cacheLimitBytes, defaults.cacheLimitBytes)
        XCTAssertEqual(profile.maxJournalBytes, defaults.maxJournalBytes)
        XCTAssertEqual(defaults.blockSize, 1_048_576)
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
        let clock = TestClock()
        let backend = try ConnectionBackend(connectionID: connection.id, store: store, vault: vault, bindVolume: { value in
                guard value == identity else { throw DriveError(EXDEV, "Fixture volume changed") }
                boundIdentities.append(value)
            }, openSession: { record, secrets in
                try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + metadata.path, connection: record, secrets: secrets)
            }, now: clock.now)
        defer { try? backend.close() }
        XCTAssertTrue(try backend.list("/").isEmpty)
        XCTAssertEqual(boundIdentities.count, 1)
        // Renewal replaces only the vault entry; the next periodic check picks it up.
        let rotated = try secrets(connection, suffix: "two")
        try vault.save(rotated, id: connection.id)
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(boundIdentities.count, 1, "Credentials are not re-read on every call")
        clock.advance(16)
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(boundIdentities, [identity, identity])
        XCTAssertEqual(try backend.transferMetrics()?.objectReadBytes, 0)
        var wrongBinding = rotated; wrongBinding.binding = "different-target"
        try vault.save(wrongBinding, id: connection.id)
        clock.advance(16)
        XCTAssertThrowsError(try backend.stat("/")) { XCTAssertEqual(($0 as? DriveError)?.code, EXDEV) }
        // A failed check closed the session; restored credentials bind a fresh one to the same volume.
        try vault.save(rotated, id: connection.id)
        XCTAssertEqual(try backend.stat("/").kind, .directory)
        XCTAssertEqual(boundIdentities, [identity, identity, identity])
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
