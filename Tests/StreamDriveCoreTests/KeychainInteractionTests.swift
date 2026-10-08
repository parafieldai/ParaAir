import XCTest
import Security
@testable import StreamDriveCore

final class KeychainInteractionTests: XCTestCase {
    // This changes only the test process's interaction flag. No Keychain item
    // is read, created, updated or deleted, and no authentication is attempted.
    func testConnectionVaultDisablesLegacyPasswordDialogsBeforeUse() {
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
        _ = KeychainConnectionVault()
        var allowed = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
        _ = SecKeychainSetUserInteractionAllowed(false)
    }

    func testMetadataVaultDisablesLegacyPasswordDialogsBeforeUse() {
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
        _ = KeychainSecretStore()
        var allowed = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
        _ = SecKeychainSetUserInteractionAllowed(false)
    }
}
