//
//  KeychainHelper.swift
//  Olana
//
//  Generic Keychain wrapper for the Google OAuth tokens (GoogleOAuthManager).
//
//  Items are readable after the first unlock since restart (PRD v6 §3.2), so
//  the background run can sync Google while the phone is locked. The iOS
//  default, when-unlocked, made every locked background sync skip Google.
//

import Foundation
import Security

enum KeychainHelper {

    // MARK: - Save

    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> OSStatus {
        delete(service: service, account: account)   // remove old entry if present
        let item: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        service,
            kSecAttrAccount:        account,
            kSecValueData:          data,
            kSecAttrSynchronizable: kCFBooleanTrue!,   // iCloud Keychain sync
            // Not a ThisDeviceOnly class: those can't be synchronizable.
            kSecAttrAccessible:     kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// Re-save an existing item so it picks up the current accessibility.
    /// Items saved before the change keep their old class until rewritten.
    static func upgradeAccessibility(service: String, account: String) {
        guard let data = read(service: service, account: account) else { return }
        save(data, service: service, account: account)
    }

    // MARK: - Read

    static func read(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        service,
            kSecAttrAccount:        account,
            kSecReturnData:         true,
            kSecMatchLimit:         kSecMatchLimitOne,
            kSecAttrSynchronizable: kCFBooleanTrue!
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    // MARK: - Delete

    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        service,
            kSecAttrAccount:        account,
            kSecAttrSynchronizable: kCFBooleanTrue!
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
