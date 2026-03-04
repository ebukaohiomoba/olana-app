//
//  OnboardingCalendarScreen.swift
//  Olana
//
//  Onboarding step 6 — calendar import.
//  Detects the login provider the user just authenticated with (Google / Apple)
//  and offers a one-tap connection to the matching calendar service.
//
//  No extra env-object plumbing required — both AuthenticationManager and
//  CalendarIntegrationManager are already injected at the root of the app.
//

import SwiftUI
import FirebaseAuth

struct OnboardingCalendarScreen: View {
    @Binding var currentPage: Int

    @EnvironmentObject private var authManager:     AuthenticationManager
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager

    @State private var oluState:       OluState = .idle
    @State private var isConnecting:   Bool     = false
    @State private var isConnected:    Bool     = false
    @State private var connectionError: String? = nil
    @State private var cardVisible:    Bool     = false
    @State private var cardOffset:     CGFloat  = 24

    // MARK: - Provider detection

    private enum LoginProvider {
        case google, apple, unknown
    }

    private var loginProvider: LoginProvider {
        guard let user = authManager.currentUser else { return .unknown }
        if user.providerData.contains(where: { $0.providerID == "google.com" }) { return .google }
        if user.providerData.contains(where: { $0.providerID == "apple.com"  }) { return .apple  }
        return .unknown
    }

    private var userEmail: String {
        authManager.currentUser?.email ?? authManager.appUser?.email ?? ""
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "F5EDD8")
                .ignoresSafeArea()

            // Olu — small, top right (consistent with every other screen)
            OnboardingOluView(state: $oluState, size: 58)
                .padding(.top, 56)
                .padding(.trailing, 24)

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 108)

                Text(headline)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                    .lineSpacing(4)
                    .padding(.bottom, 12)

                Text(bodyText)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(6)
                    .padding(.bottom, 32)

                // Provider identity card
                providerCard
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardOffset)
                    .padding(.bottom, 12)

                // Inline error message
                if let err = connectionError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption)
                        Text(err)
                            .font(.system(size: 13))
                            .lineLimit(2)
                    }
                    .foregroundStyle(Color(red: 0.8, green: 0.2, blue: 0.2))
                    .padding(.bottom, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    if isConnected {
                        connectedBanner
                    } else {
                        connectButton
                        skipButton
                    }
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                cardVisible = true
                cardOffset  = 0
            }
        }
    }

    // MARK: - Copy

    private var headline: String {
        switch loginProvider {
        case .google:  return "Bring your Google Calendar in."
        case .apple:   return "Bring your Apple Calendar in."
        case .unknown: return "Connect your calendar."
        }
    }

    private var bodyText: String {
        switch loginProvider {
        case .google:
            return "See all your events alongside your tasks. We'll pull from the Google account you just signed in with — nothing leaves your device without permission."
        case .apple:
            return "See all your events alongside your tasks. We'll read from the calendar on this device — nothing is sent anywhere."
        case .unknown:
            return "Connect a calendar so Olana can show your events in one place."
        }
    }

    // MARK: - Provider card

    private var providerCard: some View {
        HStack(spacing: 16) {
            // Provider icon bubble
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 3)
                Image(systemName: providerIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(providerIconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(providerName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                Text(userEmail.isEmpty ? "Signed in" : userEmail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "C4B5A5"))
                    .lineLimit(1)
            }

            Spacer()

            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else if isConnecting {
                ProgressView()
                    .tint(Color(hex: "F0A500"))
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isConnected ? Color.green.opacity(0.4) : Color(hex: "E8D9C4"),
                    lineWidth: isConnected ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    private var providerIcon: String {
        switch loginProvider {
        case .google:  return "g.circle.fill"
        case .apple:   return "apple.logo"
        case .unknown: return "calendar"
        }
    }

    private var providerIconColor: Color {
        switch loginProvider {
        case .google:  return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .apple:   return Color(hex: "3B1F0A")
        case .unknown: return Color(hex: "F0A500")
        }
    }

    private var providerName: String {
        switch loginProvider {
        case .google:  return "Google Calendar"
        case .apple:   return "Apple Calendar"
        case .unknown: return "Calendar"
        }
    }

    // MARK: - Connected banner

    private var connectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Connected! Your events will appear in Olana.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(hex: "3B1F0A"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Buttons

    private var connectButton: some View {
        OnboardingPrimaryButton(
            title: isConnecting ? "Connecting…" : "Connect \(providerName) →",
            action: connect,
            isDisabled: isConnecting
        )
    }

    private var skipButton: some View {
        Button {
            withAnimation(.easeInOut) { currentPage += 1 }
        } label: {
            Text("I'll do this later")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: "5C3D1E"))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connection logic

    private func connect() {
        isConnecting   = true
        connectionError = nil

        Task {
            var success = false

            switch loginProvider {
            case .google:
                do {
                    try await calendarManager.addGoogleAccount()
                    success = true
                } catch {
                    connectionError = "Couldn't connect Google Calendar. You can try again in Settings."
                }

            case .apple, .unknown:
                success = await calendarManager.requestAccess()
                if !success {
                    connectionError = "Calendar access was denied. You can grant it later in Settings → Privacy."
                }
            }

            isConnecting = false

            if success {
                isConnected = true
                oluState    = .celebrate
                // Auto-advance after Olu's brief celebration
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(.easeInOut) { currentPage += 1 }
            }
        }
    }
}
