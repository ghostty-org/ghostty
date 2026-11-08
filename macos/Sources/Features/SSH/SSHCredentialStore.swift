import Foundation
import Security

/// Only the signed app (including its early-entry askpass mode) reads these items.
enum SSHCredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty") + ".ssh" }

    private struct Entry: Codable {
        var value: String
        var context: SSHCredentialContext
    }

    static func read(_ id: UUID, for profile: SSHProfile) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw SSHError.message("The saved SSH credential could not be decoded.")
        }
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.context == SSHCredentialContext(profile) else {
            throw SSHError.message("This saved credential belongs to different connection settings. Enter it again to update it.")
        }
        return entry.value
    }

    /// Each edit creates a new item so a failed JSON save cannot destroy the old secret.
    static func create(_ value: String, label: String, for profile: SSHProfile) throws -> UUID {
        let id = UUID()
        var item = query(id)
        item[kSecValueData as String] = try JSONEncoder().encode(Entry(value: value, context: SSHCredentialContext(profile)))
        item[kSecAttrLabel as String] = "Ghostty SSH: \(label)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try check(SecItemAdd(item as CFDictionary, nil))
        return id
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            throw SSHError.message("Keychain: \(detail)")
        }
    }
}
