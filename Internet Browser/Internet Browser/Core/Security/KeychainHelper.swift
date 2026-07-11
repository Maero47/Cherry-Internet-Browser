//
//  KeychainHelper.swift
//  Cherry Browser
//

import Foundation
import Security

enum KeychainHelper {
    private static let serviceName = "com.cherry.browser.passwords"

    @discardableResult
    static func save(password: String, for id: UUID) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // Add first and fall back to update on duplicate. Never delete before
        // adding: retrieve() re-saves on every read, and a delete followed by
        // a failed SecItemAdd (locked keychain, denied access) would destroy
        // the only stored copy of the password.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: id.uuidString,
            ]
            let attributes: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        }
        if status != errSecSuccess {
            print("[Keychain] save failed: \(status)")
        }
        return status == errSecSuccess
    }

    static func retrieve(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status != errSecSuccess {
            print("[Keychain] retrieve failed: \(status)")
            return nil
        }

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }

        // Re-save to update the Keychain ACL to the current app signature,
        // so future reads won't prompt for Keychain access
        save(password: password, for: id)

        return password
    }

    @discardableResult
    static func update(password: String, for id: UUID) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            return save(password: password, for: id)
        }

        return status == errSecSuccess
    }

    @discardableResult
    static func delete(for id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
