//
//  TokenManager.swift
//  Olana
//
//  Keychain-backed storage for Google OAuth tokens.
//  Phase 2 (v1.1) — not yet connected to any live code path.
//
//  Tokens are stored with kSecAttrSynchronizable = true so they transfer
//  automatically when the user restores to a new device via iCloud Keychain.
//

import Foundation

enum TokenManager {

    private static let service = "com.olana.google-calendar"

    // MARK: - Access Token

    static var accessToken: String? {
        get {
            KeychainHelper.read(service: service, account: "access_token")
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            if let token = newValue, let data = token.data(using: .utf8) {
                KeychainHelper.save(data, service: service, account: "access_token")
            } else {
                KeychainHelper.delete(service: service, account: "access_token")
            }
        }
    }

    // MARK: - Refresh Token

    static var refreshToken: String? {
        get {
            KeychainHelper.read(service: service, account: "refresh_token")
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            if let token = newValue, let data = token.data(using: .utf8) {
                KeychainHelper.save(data, service: service, account: "refresh_token")
            } else {
                KeychainHelper.delete(service: service, account: "refresh_token")
            }
        }
    }

    // MARK: - Token Expiry

    static var accessTokenExpiry: Date? {
        get {
            KeychainHelper.read(service: service, account: "access_token_expiry")
                .flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
        }
        set {
            if let date = newValue, let data = try? JSONEncoder().encode(date) {
                KeychainHelper.save(data, service: service, account: "access_token_expiry")
            } else {
                KeychainHelper.delete(service: service, account: "access_token_expiry")
            }
        }
    }

    // MARK: - Helpers

    /// True if the access token exists and expires more than 5 minutes from now.
    static var isAccessTokenValid: Bool {
        guard accessToken != nil, let expiry = accessTokenExpiry else { return false }
        return expiry.timeIntervalSinceNow > 300
    }

    static func clearAll() {
        accessToken        = nil
        refreshToken       = nil
        accessTokenExpiry  = nil
    }
}
