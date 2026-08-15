import Foundation
import Security

/// Thin wrapper over the generic-password keychain, used to store account
/// passwords (needed to derive Subsonic tokens with a fresh salt per request).
enum Keychain {
    private static let service = "com.drome.app"
    /// Shared with the iMessage extension via the App Group keychain access group.
    private static let accessGroup = "LURJ69YS93.group.drome.app"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        if !upsert(data, key: key, accessGroup: accessGroup) {
            _ = upsert(data, key: key, accessGroup: nil)
        }
    }

    static func get(_ key: String) -> String? {
        if let value = copy(key, accessGroup: accessGroup) { return value }
        if let value = copy(key, accessGroup: nil) {
            set(value, for: key)
            return value
        }
        return nil
    }

    static func delete(_ key: String) {
        delete(key, accessGroup: accessGroup)
        delete(key, accessGroup: nil)
    }

    @discardableResult
    private static func upsert(_ data: Data, key: String, accessGroup: String?) -> Bool {
        var query = baseQuery(key: key, accessGroup: accessGroup)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func copy(_ key: String, accessGroup: String?) -> String? {
        var query = baseQuery(key: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ key: String, accessGroup: String?) {
        SecItemDelete(baseQuery(key: key, accessGroup: accessGroup) as CFDictionary)
    }

    private static func baseQuery(key: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
