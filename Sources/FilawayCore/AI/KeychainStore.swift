import Foundation
import Security

/// Something the Keychain refused to do.
public enum KeychainError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    case notUTF8

    public var description: String {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .notUTF8:
            return "The stored secret is not valid UTF-8."
        }
    }
}

/// The real Keychain (`kSecClassGenericPassword`), service
/// `com.tejaspanse.filaway`, account `anthropic-api-key` (FR-6.1, NFR-4).
///
/// Nothing in `FilawayCore` reaches for this type directly — callers take a
/// ``SecretStore`` — because a Keychain query from an unsigned `swift test`
/// binary can prompt the user or fail with `errSecMissingEntitlement`. The
/// suite covering this file is gated on `FILAWAY_TEST_KEYCHAIN=1` and uses a
/// throwaway service name.
public struct KeychainStore: SecretStore {
    /// Bundle id and OSLog subsystem, reused as the Keychain service.
    public static let defaultService = FilawayCore.subsystem
    /// Account name for the Claude API key.
    public static let apiKeyAccount = "anthropic-api-key"

    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.notUTF8 }
            guard let text = String(data: data, encoding: .utf8) else { throw KeychainError.notUTF8 }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The key is needed by background organize runs, so it must survive
            // a locked screen — but never leave the device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query(for: account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query(for: account)
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
