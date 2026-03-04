//
//  KeychainHelper.swift
//  Olana
//
//  Generic Keychain wrapper used by TokenManager for secure OAuth token storage.
//  Phase 2 (v1.1) — not yet connected to any live code path.
//

import Foundation
import Security

enum KeychainHelper {

    // MARK: - Save

    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecValueData:        data,
            kSecAttrSynchronizable: kCFBooleanTrue!   // iCloud Keychain sync
        ]

        SecItemDelete(query as CFDictionary)   // remove old entry if present
        return SecItemAdd(query as CFDictionary, nil)
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
