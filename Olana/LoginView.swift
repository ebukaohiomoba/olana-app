//
//  LoginView.swift
//  Olana
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @Environment(\.olanaTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var errorMessage: String?
    @State private var showError = false
    @State private var oluState: OluState = .idle

    var body: some View {
        ZStack {
            // Hero gradient — full screen
            LinearGradient(
                colors: [theme.colors.heroStart, theme.colors.heroEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Decorative orbs (match progress card language)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 320, height: 320)
                .offset(x: 140, y: -200)
                .allowsHitTesting(false)

            Circle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 200, height: 200)
                .offset(x: -120, y: 260)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // MARK: — Olu + Tagline
                VStack(spacing: 0) {
                    OluView(state: $oluState, size: 160)

                    Spacer().frame(height: 32)

                    Text("OLANA")
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .tracking(5)

                    Spacer().frame(height: 12)

                    Text("a calmer way to\nmanage your time")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                }

                Spacer()

                // MARK: — Sign-In Buttons
                VStack(spacing: 13) {
                    // Google
                    Button {
                        Task { await signInWithGoogle() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.body.weight(.medium))
                            Text("Continue with Google")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(theme.colors.heroEnd)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white)
                                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(authManager.isLoading)

                    // Apple — request nonce in the button's request closure,
                    // handle the result directly in onCompletion (no overlay hack).
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = authManager.prepareAppleSignIn()
                    } onCompletion: { result in
                        Task {
                            do {
                                try await authManager.handleAppleSignIn(result)
                            } catch let error as ASAuthorizationError
                                where error.code == .canceled {
                                // User dismissed the sheet — not an error
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(authManager.isLoading)
                }
                .padding(.horizontal, 32)

                if authManager.isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 20)
                }

                Spacer().frame(height: 32)

                Text("By continuing, you agree to our Terms and Privacy Policy.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 32)
            }
        }
        .alert("Sign-In Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    // MARK: — Actions

    private func signInWithGoogle() async {
        do {
            try await authManager.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

}

#Preview {
    LoginView()
        .environmentObject(AuthenticationManager())
        .olanaThemeProvider(variant: .system)
}
