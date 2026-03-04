//
//  GoogleCalendarConnectionRow.swift
//  Olana
//
//  A single connected Google account row shown in CalendarSettingsView.
//  One instance is rendered per account in the Connected Accounts list.
//

import SwiftUI

struct GoogleAccountRow: View {
    @Environment(\.olanaTheme) private var theme
    let account: GoogleOAuthAccount
    let onDisconnect: () -> Void

    @State private var showDisconnectConfirm = false

    var body: some View {
        HStack(spacing: 14) {

            // Google-branded icon
            ZStack {
                Circle().fill(Color.white)
                Text("G")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .red, .yellow, .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? account.email)
                    .font(.body)
                    .foregroundStyle(theme.colors.ink)
                    .lineLimit(1)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                Button("Remove") { showDisconnectConfirm = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .confirmationDialog(
            "Disconnect \(account.email)?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { onDisconnect() }
            Button("Cancel",     role: .cancel)      {}
        } message: {
            Text("Events from this Google account will be removed from Olana. You can reconnect at any time.")
        }
    }
}
