//
//  GoogleOAuthManager.swift
//  Olana
//
//  Multi-account Google OAuth 2.0 with PKCE.
//  Uses ASWebAuthenticationSession (no GIDSignIn dependency) so multiple
//  Google accounts can be connected independently.
//
//  Tokens are stored in iCloud Keychain per account ID so they survive
//  device restores and are available on all the user's devices.
//

import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import FirebaseCore
import UIKit

// MARK: - Connected Account Model

struct GoogleOAuthAccount: Codable, Identifiable, Equatable {
    let id: String              // Google user ID ("sub" from userinfo endpoint)
    let email: String
    var displayName: String?
    let connectedAt: Date
}

// MARK: - GoogleOAuthManager

@MainActor
final class GoogleOAuthManager: NSObject, ObservableObject,
                                 ASWebAuthenticationPresentationContextProviding {

    static let shared = GoogleOAuthManager()

    @Published private(set) var connectedAccounts: [GoogleOAuthAccount] = []
    @Published private(set) var isConnecting = false

    private let keychainService = "com.olana.google-oauth"
    private let accountsKey     = "connectedGoogleAccounts_v1"
    /// Strong reference so the session isn't deallocated before its callback fires.
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        loadAccounts()
    }

    // MARK: - Add Account

    /// Opens the Google OAuth consent screen. Stores tokens on success.
    func addAccount() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw GoogleOAuthError.missingClientID
        }
        let scheme      = reversedScheme(from: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        isConnecting = true
        defer { isConnecting = false }

        let verifier  = makeCodeVerifier()
        let challenge = makeCodeChallenge(from: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",            value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid email profile https://www.googleapis.com/auth/calendar.readonly"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "select_account"),
        ]
        guard let authURL = comps.url else { throw GoogleOAuthError.invalidURL }

        // Present OAuth browser and wait for callback.
        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme
            ) { url, error in
                if let url        { cont.resume(returning: url) }
                else if let error { cont.resume(throwing: error) }
                else              { cont.resume(throwing: GoogleOAuthError.cancelled) }
            }
            session.presentationContextProvider    = self
            session.prefersEphemeralWebBrowserSession = false  // show existing Google sessions
            authSession = session
            session.start()
        }
        authSession = nil

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw GoogleOAuthError.missingAuthCode }

        let tokens   = try await exchangeCode(code, verifier: verifier,
                                              clientID: clientID, redirectURI: redirectURI)
        let userInfo = try await fetchUserInfo(accessToken: tokens.accessToken)

        // Silently skip if this account is already connected.
        guard !connectedAccounts.contains(where: { $0.id == userInfo.sub }) else { return }

        persistTokens(access: tokens.accessToken,
                      expiry: Date().addingTimeInterval(Double(tokens.expiresIn - 60)),
                      refresh: tokens.refreshToken ?? "",
                      for: userInfo.sub)

        connectedAccounts.append(GoogleOAuthAccount(
            id: userInfo.sub,
            email: userInfo.email,
            displayName: userInfo.name,
            connectedAt: Date()
        ))
        saveAccounts()
    }

    // MARK: - Remove Account

    func removeAccount(id: String) {
        connectedAccounts.removeAll { $0.id == id }
        saveAccounts()
        KeychainHelper.delete(service: keychainService, account: "\(id).access")
        KeychainHelper.delete(service: keychainService, account: "\(id).expiry")
        KeychainHelper.delete(service: keychainService, account: "\(id).refresh")
    }

    // MARK: - Valid Access Token (with auto-refresh)

    func validAccessToken(for accountId: String) async throws -> String {
        // Return cached token if it hasn't expired yet.
        if let token  = cachedToken(for: accountId),
           let expiry = cachedExpiry(for: accountId),
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        // Refresh using the stored refresh token.
        guard let refresh = storedRefresh(for: accountId), !refresh.isEmpty else {
            throw GoogleOAuthError.unauthorized
        }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw GoogleOAuthError.missingClientID
        }
        let fresh = try await doRefresh(refreshToken: refresh, clientID: clientID)
        persistTokens(access: fresh.accessToken,
                      expiry: Date().addingTimeInterval(Double(fresh.expiresIn - 60)),
                      refresh: refresh,   // Google refresh tokens don't rotate
                      for: accountId)
        return fresh.accessToken
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Called on the main thread by the system; safe to assume isolation.
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first ?? ASPresentationAnchor()
        }
    }

    // MARK: - Private: Network

    private struct TokenResponse: Decodable {
        let access_token:  String
        let expires_in:    Int
        let refresh_token: String?
        var accessToken:   String  { access_token }
        var expiresIn:     Int     { expires_in }
        var refreshToken:  String? { refresh_token }
    }

    private struct UserInfoResponse: Decodable {
        let sub:   String
        let email: String
        let name:  String?
    }

    private func exchangeCode(_ code: String, verifier: String,
                              clientID: String, redirectURI: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "code": code, "client_id": clientID,
            "redirect_uri": redirectURI, "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleOAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func doRefresh(refreshToken: String, clientID: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "refresh_token": refreshToken, "client_id": clientID,
            "grant_type": "refresh_token",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleOAuthError.unauthorized }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfoResponse {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    // MARK: - Private: PKCE

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeCodeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reverses dot-separated components: `foo.bar.baz` → `baz.bar.foo`
    private func reversedScheme(from clientID: String) -> String {
        clientID.components(separatedBy: ".").reversed().joined(separator: ".")
    }

    private func formEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&").data(using: .utf8)
    }

    // MARK: - Private: Keychain

    private func persistTokens(access: String, expiry: Date, refresh: String, for id: String) {
        if let d = access.data(using: .utf8)         { KeychainHelper.save(d, service: keychainService, account: "\(id).access") }
        if let d = try? JSONEncoder().encode(expiry)  { KeychainHelper.save(d, service: keychainService, account: "\(id).expiry") }
        if !refresh.isEmpty, let d = refresh.data(using: .utf8) {
            KeychainHelper.save(d, service: keychainService, account: "\(id).refresh")
        }
    }

    private func cachedToken(for id: String) -> String? {
        KeychainHelper.read(service: keychainService, account: "\(id).access")
            .flatMap { String(data: $0, encoding: .utf8) }
    }
    private func cachedExpiry(for id: String) -> Date? {
        KeychainHelper.read(service: keychainService, account: "\(id).expiry")
            .flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    }
    private func storedRefresh(for id: String) -> String? {
        KeychainHelper.read(service: keychainService, account: "\(id).refresh")
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Private: Persistence

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(connectedAccounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }
    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let list = try? JSONDecoder().decode([GoogleOAuthAccount].self, from: data)
        else { return }
        connectedAccounts = list
    }
}

// MARK: - Errors

enum GoogleOAuthError: LocalizedError {
    case missingClientID, invalidURL, cancelled, missingAuthCode, tokenExchangeFailed, unauthorized

    var errorDescription: String? {
        switch self {
        case .missingClientID:     return "Google client ID is not configured."
        case .invalidURL:          return "Could not build the authorization URL."
        case .cancelled:           return "Sign-in was cancelled."
        case .missingAuthCode:     return "Authorization code was not received."
        case .tokenExchangeFailed: return "Could not complete sign-in. Try again."
        case .unauthorized:        return "Session expired. Please reconnect this account."
        }
    }
}
