//
//  KeychainStore.swift
//  PrintParty
//
//  Minimal Keychain wrapper for secrets that must never live in SwiftData.
//  Today the only secret stored here is the Bambu LAN access code.
//
//  Items are scoped to the app's bundle (kSecAttrService = bundle id) and
//  accessible only when the device is unlocked (kSecAttrAccessibleWhenUnlocked).
//

import Foundation
import Security

enum KeychainStore {

    private static let service = "com.clengineering.PrintParty"

    enum KeychainError: Error {
        case unhandled(OSStatus)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item before inserting (idempotent upsert).
        let deleteQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String:    data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Conventions

    /// Account key for a Bambu printer's LAN access code.
    static func bambuAccessCodeAccount(printerId: UUID) -> String {
        "bambu.\(printerId.uuidString).accessCode"
    }

    /// Account key for a paired gateway's shared symmetric key (raw 32-byte
    /// HKDF output, base64-encoded for storage).
    static func gatewaySharedKeyAccount(gatewayId: String) -> String {
        "gateway.\(gatewayId).sharedKey"
    }
}
