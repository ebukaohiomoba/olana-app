//
//  UsernameSetupView.swift
//  Olana
//
//  Shown once after first sign-in so the user can pick a searchable username.
//

import SwiftUI

struct UsernameSetupView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @Environment(\.olanaTheme) private var theme

    @State private var username = ""
    @State private var status: UsernameStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var oluState: OluState = .resting

    var body: some View {
        ZStack {
            // Hero gradient — full screen, same palette as progress card
            LinearGradient(
                colors: [theme.colors.heroStart, theme.colors.heroEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Decorative orb
            Circle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 240, height: 240)
                .offset(x: 130, y: -160)
                .allowsHitTesting(false)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // MARK: — Header
                    VStack(spacing: 0) {
                        Spacer().frame(height: 24)

                        OluView(state: $oluState, size: 110)

                        Spacer().frame(height: 24)

                        Text("ONE LAST THING")
                            .font(.system(size: 10, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .tracking(4)

                        Spacer().frame(height: 10)

                        Text("Pick a username")
                            .font(.system(size: 26, weight: .semibold, design: .serif))
                            .foregroundStyle(.white)

                        Spacer().frame(height: 8)

                        Text("This is how friends will find you on Olana.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)

                        Spacer().frame(height: 36)
                    }

                    // MARK: — Input card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("@")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)

                            TextField("username", text: $username)
                                .font(.title2)
                                .textFieldStyle(.plain)
                                .foregroundStyle(.white)
                                .tint(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            // Status indicator
                            Group {
                                switch status {
                                case .idle:
                                    EmptyView()
                                case .checking:
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.8)
                                case .available:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.white)
                                case .taken:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.8))
                                case .invalid:
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.8))
                                case .error:
                                    Image(systemName: "wifi.exclamationmark")
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .font(.title3)
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(inputBorderColor, lineWidth: 1.5)
                        )

                        if let message = statusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.85))
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer().frame(height: 10)

                    Text("3–20 characters · letters, numbers, underscores only")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.horizontal, 32)

                    Spacer().frame(height: 32)

                    // MARK: — Continue Button
                    Button {
                        save()
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(theme.colors.heroEnd)
                            } else {
                                Text("Continue")
                                    .font(.body.weight(.semibold))
                            }
                        }
                        .foregroundStyle(canContinue ? theme.colors.heroEnd : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(canContinue ? .white : Color.white.opacity(0.15))
                                .shadow(
                                    color: canContinue ? Color.black.opacity(0.15) : .clear,
                                    radius: 10, x: 0, y: 5
                                )
                        )
                    }
                    .disabled(!canContinue || isSaving)
                    .padding(.horizontal, 32)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .padding(.top, 8)
                    }

                    Spacer().frame(height: 48)
                }
            }
        }
        .onChange(of: username) { _, newValue in
            scheduleCheck(for: newValue)
        }
        .onChange(of: status) { _, newValue in
            if newValue == .available {
                oluState = .celebrate
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    oluState = .resting
                }
            }
        }
    }

    // MARK: — Computed

    private var canContinue: Bool { status == .available }

    private var inputBorderColor: Color {
        switch status {
        case .available:                return Color.white.opacity(0.8)
        case .taken, .invalid, .error:  return Color.white.opacity(0.5)
        default:                        return Color.white.opacity(0.2)
        }
    }

    private var statusMessage: String? {
        switch status {
        case .taken:             return "That username is already taken."
        case .invalid:           return "Only letters, numbers, and underscores. Min 3 characters."
        case .available:         return "@\(username.lowercased()) is available!"
        case .error(let msg):    return "Couldn't check availability: \(msg)"
        default:                 return nil
        }
    }

    // MARK: — Logic

    private func scheduleCheck(for value: String) {
        status = .idle
        checkTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        guard isValidFormat(trimmed) else {
            status = .invalid
            return
        }

        status = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do {
                let taken = try await FirestoreService.shared.isUsernameTaken(trimmed)
                await MainActor.run { status = taken ? .taken : .available }
            } catch {
                await MainActor.run { status = .error(error.localizedDescription) }
            }
        }
    }

    private func isValidFormat(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 20 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func save() {
        let trimmed = username.trimmingCharacters(in: .whitespaces).lowercased()
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await authManager.updateUsername(trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: — Status

private enum UsernameStatus: Equatable {
    case idle, checking, available, taken, invalid
    case error(String)
}

#Preview {
    UsernameSetupView()
        .environmentObject(AuthenticationManager())
        .olanaThemeProvider(variant: .system)
}
