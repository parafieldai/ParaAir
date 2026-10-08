import Foundation
import Security
import LocalAuthentication

enum KeychainAccessConfiguration: Sendable {
    case legacy
    case shared(String)
    case invalid

    /// A present but malformed opt-in must never silently select legacy items.
    init(infoDictionary: [String: Any]) {
        guard let value = infoDictionary["ParaAirKeychainAccessGroup"] else { self = .legacy; return }
        guard let group = value as? String, group.utf8.count <= 255 else { self = .invalid; return }
        let components = group.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0].utf8.count == 10,
              components[0].utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              components.dropFirst().allSatisfy({ component in
                  let bytes = component.utf8
                  func alphanumeric(_ byte: UInt8) -> Bool {
                      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                  }
                  guard let first = bytes.first, let last = bytes.last,
                        alphanumeric(first), alphanumeric(last) else { return false }
                  return bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
              }) else { self = .invalid; return }
        self = .shared(group)
    }

    /// Pure query routing. Shared mode cannot search, update or delete legacy items.
    func route(_ attributes: [String: Any]) throws -> [String: Any] {
        var query = attributes
        switch self {
        case .legacy:
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            query.removeValue(forKey: kSecAttrAccessGroup as String)
        case .shared(let group):
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = group
        case .invalid:
            throw DriveError(EACCES, "This ParaAir build has invalid shared credential configuration. Reinstall a correctly signed build.")
        }
        return query
    }
}

/// Allows query routing to be tested without reading or changing real items.
protocol KeychainItemClient: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainItemClient: KeychainItemClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// ParaAir never opens a password dialog from storage or renewal operations.
/// Existing items live in the legacy file-based Keychain. Per-query modern
/// authentication settings alone do not reliably suppress its unlock/ACL UI,
/// so disable legacy interaction in this process as well. This neither unlocks
/// a Keychain nor changes any item's permissions or credentials.
enum KeychainInteractionPolicy {
    @discardableResult
    static func disableLegacyUI() -> OSStatus {
        SecKeychainSetUserInteractionAllowed(false)
    }

    static func prepare(_ attributes: [String: Any],
                        configuration: KeychainAccessConfiguration,
                        context: LAContext = LAContext()) throws -> [String: Any] {
        var query = try configuration.route(attributes)
        guard disableLegacyUI() == errSecSuccess else {
            throw DriveError(EACCES, "Credential access is paused because password dialogs could not be disabled.")
        }
        context.interactionNotAllowed = true
        guard context.interactionNotAllowed else {
            throw DriveError(EACCES, "Credential access is paused because password dialogs could not be disabled.")
        }
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
