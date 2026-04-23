import Foundation
import Security

/// Thin wrapper over `Security.framework` for storing MCP source API keys in
/// the macOS Keychain. Keys live under the shared service
/// `com.seansmithdesign.ghostties.mcp` with the MCP source id (slug) as the
/// account. Non-secret config (name, transport, endpoint) stays in
/// `.ghostties/mcp-sources.json`; credentials never land on disk in cleartext.
///
/// Intentionally narrow surface: set / get / delete. Anything more (iCloud
/// sync, access groups, biometric prompts) lives outside this helper.
enum Keychain {
    /// Shared Keychain service identifier for all MCP source credentials.
    static let mcpService = "com.seansmithdesign.ghostties.mcp"

    /// Store `value` under `account` in the `mcpService` service. Overwrites
    /// any existing entry for the same account. Returns `true` on success.
    @discardableResult
    static func set(account: String, value: String, service: String = mcpService) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Try update first — if the item already exists, `SecItemAdd` would
        // fail with errSecDuplicateItem.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addAttrs = query
        addAttrs[kSecValueData as String] = data
        // Don't sync to iCloud — MCP credentials are per-device.
        addAttrs[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Fetch the value stored under `account`, or `nil` if no entry exists.
    static func get(account: String, service: String = mcpService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the entry for `account`. Returns `true` if an entry existed and
    /// was removed, `false` if it didn't exist or the remove failed.
    @discardableResult
    static func delete(account: String, service: String = mcpService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
