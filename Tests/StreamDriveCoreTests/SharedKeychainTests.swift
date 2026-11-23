import XCTest
import Security
import LocalAuthentication
@testable import StreamDriveCore

final class SharedKeychainTests: XCTestCase {
    private let group = "3LHSL95J9H.dev.paraair.credentials"
    private let connectionID = "12345678-1234-1234-1234-123456789abc"

    private var configured: [String: Any] { ["ParaAirKeychainAccessGroup": group] }
    private let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    override func setUp() { KeychainInteractionPolicy.resetMigrationsForTesting() }

    func testMissingConfigurationPreservesLegacyKeychain() throws {
        let query = try KeychainInteractionPolicy.prepare([:], configuration: .init(infoDictionary: [:]))
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        assertNoInteraction(query)
    }

    func testSharedConfigurationSelectsDataProtectionKeychainAndExactGroup() throws {
        let query = try KeychainInteractionPolicy.prepare([:], configuration: .init(infoDictionary: configured))
        assertShared(query)
    }

    func testRejectedNoInteractionSettingFailsBeforeReturningAQuery() {
        XCTAssertThrowsError(try KeychainInteractionPolicy.prepare([:],
            configuration: .init(infoDictionary: configured), context: InteractionUnavailableContext())) { error in
            XCTAssertEqual((error as? DriveError)?.code, EACCES)
            XCTAssertEqual((error as? DriveError)?.message,
                "Credential access is paused because password dialogs could not be disabled.")
        }
    }

    func testInvalidConfigurationFailsClosedWithoutEchoingInput() {
        let invalid: [Any] = [true, 12, NSNull(), "", "dev.paraair.credentials", "SHORT.dev.paraair",
            "3LHSL95J9H", "3lhsl95j9h.dev.paraair", "3LHSL95J9H.*", "3LHSL95J9H..paraair",
            "3LHSL95J9H.dev paraair", "3LHSL95J9H.dev.paraair\n", "3LHSL95J9H.dev/paraair",
            "3LHSL95J9H.dev.-paraair", "3LHSL95J9H.dev.paraair-", "3LHSL95J9H." + String(repeating: "a", count: 256)]
        for value in invalid {
            XCTAssertThrowsError(try KeychainInteractionPolicy.prepare([:], configuration: .init(
                infoDictionary: ["ParaAirKeychainAccessGroup": value]))) { error in
                let failure = error as? DriveError
                XCTAssertEqual(failure?.code, EACCES)
                XCTAssertEqual(failure?.message, "This ParaAir build has invalid shared credential configuration. Reinstall a correctly signed build.")
            }
        }
    }

    func testConnectionVaultRoutesEveryOperationToSharedStore() throws {
        let secrets = ConnectionSecrets(binding: "test-fixture-binding")
        let client = RecordingKeychainClient(data: try JSONEncoder().encode(secrets))
        let vault = KeychainConnectionVault(infoDictionary: configured, client: client)
        XCTAssertEqual(try vault.load(id: connectionID).binding, secrets.binding)
        try vault.save(secrets, id: connectionID)
        try vault.remove(id: connectionID)
        XCTAssertEqual(client.operations.map(\.name), ["load", "update", "add", "update", "delete"], "the read moves the item to after-first-unlock")
        for operation in client.operations {
            assertShared(operation.query)
            XCTAssertEqual(operation.query[kSecAttrService as String] as? String, "dev.streamdrive.connections")
        }
    }

    func testMetadataAndObjectStoresRouteEveryOperationToSharedStore() throws {
        let metadataClient = RecordingKeychainClient(data: Data("sqlite3:///fixture.db".utf8))
        let metadata = KeychainSecretStore(infoDictionary: configured, client: metadataClient)
        XCTAssertEqual(try metadata.metadataURL(for: "fixture"), "sqlite3:///fixture.db")
        try metadata.storeMetadataURL("sqlite3:///fixture.db", identifier: "fixture")

        let keys = try S3Credentials(accessKey: "fixture-access", secretKey: "fixture-secret")
        let objectClient = RecordingKeychainClient(data: try JSONEncoder().encode(keys))
        let objects = KeychainSecretStore(infoDictionary: configured, client: objectClient)
        XCTAssertEqual(try objects.objectCredentials(for: "fixture").accessKey, keys.accessKey)
        try objects.storeObjectCredentials(keys, identifier: "fixture")

        for (client, service) in [(metadataClient, "dev.streamdrive.metadata"), (objectClient, "dev.streamdrive.metadata.s3")] {
            XCTAssertEqual(client.operations.map(\.name), ["load", "update", "add", "update"])
            for operation in client.operations {
                assertShared(operation.query)
                XCTAssertEqual(operation.query[kSecAttrService as String] as? String, service)
            }
        }
    }

    func testInvalidStoreConfigurationMakesNoSecurityCalls() {
        let client = RecordingKeychainClient(data: Data())
        let info: [String: Any] = ["ParaAirKeychainAccessGroup": false]
        let connections = KeychainConnectionVault(infoDictionary: info, client: client)
        let profiles = KeychainSecretStore(infoDictionary: info, client: client)
        XCTAssertThrowsError(try connections.load(id: connectionID))
        XCTAssertThrowsError(try connections.save(.init(binding: "fixture"), id: connectionID))
        XCTAssertThrowsError(try connections.remove(id: connectionID))
        XCTAssertThrowsError(try profiles.metadataURL(for: "fixture"))
        XCTAssertThrowsError(try profiles.storeMetadataURL("sqlite3:///fixture.db", identifier: "fixture"))
        XCTAssertThrowsError(try profiles.objectCredentials(for: "fixture"))
        XCTAssertThrowsError(try profiles.storeObjectCredentials(.init(accessKey: "fixture-access", secretKey: "fixture-secret"), identifier: "fixture"))
        XCTAssertTrue(client.operations.isEmpty)
    }

    func testSharedReadFailureNeverFallsBackToLegacy() {
        let client = RecordingKeychainClient(data: nil, readStatus: errSecMissingEntitlement)
        let connections = KeychainConnectionVault(infoDictionary: configured, client: client)
        let profiles = KeychainSecretStore(infoDictionary: configured, client: client)
        XCTAssertThrowsError(try connections.load(id: connectionID))
        XCTAssertThrowsError(try profiles.metadataURL(for: "fixture"))
        XCTAssertThrowsError(try profiles.objectCredentials(for: "fixture"))
        XCTAssertEqual(client.operations.count, 3)
        for operation in client.operations { assertShared(operation.query) }
    }

    func testEverySavedItemStaysReadableWhileTheMacIsLocked() throws {
        let client = RecordingKeychainClient(data: nil)
        try KeychainConnectionVault(infoDictionary: configured, client: client).save(.init(binding: "fixture"), id: connectionID)
        let profiles = KeychainSecretStore(infoDictionary: configured, client: client)
        try profiles.storeMetadataURL("sqlite3:///fixture.db", identifier: "fixture")
        try profiles.storeObjectCredentials(.init(accessKey: "fixture-access", secretKey: "fixture-secret"), identifier: "fixture")
        XCTAssertEqual(client.operations.map(\.name), ["add", "update", "add", "update", "add", "update"])
        for operation in client.operations {
            let accessibility = (operation.name == "add" ? operation.query : operation.attributes)[kSecAttrAccessible as String] as? String
            XCTAssertEqual(accessibility, afterFirstUnlock, operation.name)
        }
    }

    func testItemsFromEarlierBuildsMoveToAfterFirstUnlockOnceWhenRead() throws {
        let client = RecordingKeychainClient(data: try JSONEncoder().encode(ConnectionSecrets(binding: "fixture")))
        let vault = KeychainConnectionVault(infoDictionary: configured, client: client)
        _ = try vault.load(id: connectionID); _ = try vault.load(id: connectionID)
        XCTAssertEqual(client.operations.map(\.name), ["load", "update", "load"], "once per process")
        let update = client.operations[1]
        XCTAssertEqual(update.attributes as? [String: String], [kSecAttrAccessible as String: afterFirstUnlock])
        XCTAssertNil(update.query[kSecReturnData as String]); XCTAssertNil(update.query[kSecMatchLimit as String])
        assertShared(update.query)
        // The file-based Keychain doesn't lock with the screen; its items are left as they are.
        let legacy = RecordingKeychainClient(data: try JSONEncoder().encode(ConnectionSecrets(binding: "fixture")))
        _ = try KeychainConnectionVault(infoDictionary: [:], client: legacy).load(id: "abcdef01-1234-1234-1234-123456789abc")
        XCTAssertEqual(legacy.operations.map(\.name), ["load"])
    }

    func testALockedMacIsNamedInsteadOfAGenericFailure() {
        let locked = RecordingKeychainClient(data: nil, readStatus: errSecInteractionNotAllowed, addStatus: errSecInteractionNotAllowed)
        let vault = KeychainConnectionVault(infoDictionary: configured, client: locked)
        XCTAssertThrowsError(try vault.save(.init(binding: "fixture"), id: connectionID)) {
            XCTAssertEqual(($0 as? DriveError)?.code, EACCES)
            XCTAssertEqual(($0 as? DriveError)?.message, "This Mac is locked, so ParaAir can’t save to the Keychain. Unlock it and try again.")
        }
        XCTAssertThrowsError(try vault.load(id: connectionID)) {
            XCTAssertEqual(($0 as? DriveError)?.code, EACCES)
            XCTAssertEqual(($0 as? DriveError)?.message, "This Mac is locked, so ParaAir can’t read its saved credentials. Unlock it to continue.")
        }
        XCTAssertThrowsError(try KeychainSecretStore(infoDictionary: configured, client: locked).metadataURL(for: "fixture")) {
            XCTAssertEqual(($0 as? DriveError)?.message, "This Mac is locked, so ParaAir can’t read its saved credentials. Unlock it to continue.")
        }
        let other = RecordingKeychainClient(data: nil, readStatus: errSecMissingEntitlement, addStatus: errSecMissingEntitlement)
        XCTAssertThrowsError(try KeychainConnectionVault(infoDictionary: configured, client: other).save(.init(binding: "fixture"), id: connectionID)) {
            XCTAssertEqual(($0 as? DriveError)?.message, "Cannot save connection credentials in Keychain")
        }
    }

    private func assertShared(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group, file: file, line: line)
        assertNoInteraction(query, file: file, line: line)
    }

    private func assertNoInteraction(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertNotNil(context, file: file, line: line)
        XCTAssertTrue(context?.interactionNotAllowed == true, file: file, line: line)
    }
}

private final class InteractionUnavailableContext: LAContext {
    override var interactionNotAllowed: Bool {
        get { false }
        set { }
    }
}

/// Captures synthetic inputs only. Never calls Security.framework item APIs.
private final class RecordingKeychainClient: KeychainItemClient, @unchecked Sendable {
    struct Operation { let name: String; let query: [String: Any]; var attributes: [String: Any] = [:] }
    private(set) var operations: [Operation] = []
    let data: Data?
    let readStatus: OSStatus
    let addStatus: OSStatus
    init(data: Data?, readStatus: OSStatus = errSecSuccess, addStatus: OSStatus = errSecDuplicateItem) {
        self.data = data; self.readStatus = readStatus; self.addStatus = addStatus
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        operations.append(.init(name: "load", query: query)); return (readStatus, data)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        operations.append(.init(name: "add", query: query)); return addStatus
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        operations.append(.init(name: "update", query: query, attributes: attributes)); return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        operations.append(.init(name: "delete", query: query)); return errSecSuccess
    }
}
