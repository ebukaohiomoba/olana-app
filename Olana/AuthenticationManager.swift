//
//  AuthenticationManager.swift
//  Olana
//
//  Manages Firebase Auth state, Google Sign-In, and Apple Sign-In.
//

import SwiftUI
import Combine
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import AuthenticationServices
import CryptoKit

@MainActor
final class AuthenticationManager: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var currentUser: FirebaseAuth.User?
    @Published var appUser: AppUser?
    @Published var isLoading: Bool = false

    // MARK: - Private
    private var stateListener: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    // MARK: - Init
    override init() {
        super.init()
        stateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentUser = user
                if let user {
                    await self.fetchOrCreateAppUser(for: user)
                } else {
                    self.appUser = nil
                    self.isLoading = false
                }
            }
        }
    }

    deinit {
        if let stateListener {
            Auth.auth().removeStateDidChangeListener(stateListener)
        }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.missingClientID
        }
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        guard let rootVC = UIApplication.shared.topViewController else {
            throw AuthError.missingPresenter
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingToken
        }
        let accessToken = result.user.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        try await Auth.auth().signIn(with: credential)
        OlanaAnalytics.login(method: .google)
    }

    // MARK: - Apple Sign-In
    //
    // Two-step pattern that works with SignInWithAppleButton:
    //   1. Call prepareAppleSignIn() in the button's request closure to get the
    //      nonce hash that Apple embeds in the identity token.
    //   2. Call handleAppleSignIn(_:) in onCompletion with the raw result.

    /// Generates and caches a nonce, returns its SHA-256 hash for the Apple request.
    func prepareAppleSignIn() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }

    /// Processes the result from SignInWithAppleButton's onCompletion closure.
    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .success(let authorization):
            guard
                let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let nonce = currentNonce,
                let appleIDToken = appleIDCredential.identityToken,
                let idTokenString = String(data: appleIDToken, encoding: .utf8)
            else {
                throw AuthError.missingToken
            }
            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )
            try await Auth.auth().signIn(with: credential)
            currentNonce = nil
            OlanaAnalytics.login(method: .apple)

        case .failure(let error):
            throw error
        }
    }

    // MARK: - Username Setup

    func updateUsername(_ username: String) async throws {
        guard let uid = currentUser?.uid else {
            throw AuthError.missingToken
        }
        let lower = username.lowercased()
        try await FirestoreService.shared.updateUsername(uid: uid, username: lower)
        // Update local state. If appUser was nil (e.g. fetchOrCreateAppUser failed
        // at sign-in), re-fetch so the auth gate can transition to ContentView.
        if appUser != nil {
            appUser?.username = lower
        } else {
            appUser = try await FirestoreService.shared.fetchUser(uid: uid)
        }
    }

    // MARK: - Sign Out

    func signOut() throws {
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
    }

    // MARK: - Firestore User Management

    private func fetchOrCreateAppUser(for firebaseUser: FirebaseAuth.User) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let existing = try await FirestoreService.shared.fetchUser(uid: firebaseUser.uid) {
                self.appUser = existing
                // Returning user — pull their Firestore stats into XPManager
                XPManager.shared.configure(uid: firebaseUser.uid, loadExisting: true)
            } else {
                // New user — seed the Firestore doc with whatever local progress they have
                var displayName = firebaseUser.displayName ?? ""
                if displayName.isEmpty { displayName = "New User" }

                let xp = XPManager.shared
                let newUser = AppUser(
                    id: firebaseUser.uid,
                    username: "",
                    displayName: displayName,
                    email: firebaseUser.email ?? "",
                    profileEmoji: "👤",
                    streakDays: xp.streakDays,
                    graceTokens: xp.graceTokens,
                    totalXP: xp.totalXP,
                    joinedAt: Date(),
                    lastActiveAt: Date()
                )
                try await FirestoreService.shared.createUser(newUser)
                self.appUser = newUser
                // Push full stats (extra fields beyond AppUser) to Firestore
                XPManager.shared.configure(uid: firebaseUser.uid, loadExisting: false)
            }
        } catch {
            print("AuthenticationManager: error fetching/creating AppUser — \(error)")
        }
    }

    // MARK: - Nonce Helpers

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let hashedData = SHA256.hash(data: Data(input.utf8))
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case missingClientID
    case missingToken
    case missingPresenter

    var errorDescription: String? {
        switch self {
        case .missingClientID:  return "Firebase client ID is not configured."
        case .missingToken:     return "Authentication token is missing."
        case .missingPresenter: return "No root view controller available."
        }
    }
}

// MARK: - UIApplication helper

private extension UIApplication {
    var topViewController: UIViewController? {
        guard
            let windowScene = connectedScenes.first as? UIWindowScene,
            let rootVC = windowScene.windows.first?.rootViewController
        else { return nil }
        return rootVC
    }
}
