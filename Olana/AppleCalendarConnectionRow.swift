//
//  AppleCalendarConnectionRow.swift
//  Olana
//
//  Shows the current EventKit authorization status with a contextual action button.
//

import SwiftUI
import EventKit

struct AppleCalendarConnectionRow: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.red))

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Calendar")
                    .font(.body)
                    .foregroundStyle(theme.colors.ink)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private var statusSubtitle: String {
        switch calendarManager.authorizationStatus {
        case .authorized, .fullAccess: return "Connected"
        case .denied, .restricted:    return "Access denied — tap to open Settings"
        case .notDetermined:          return "Not connected"
        @unknown default:             return "Unknown"
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch calendarManager.authorizationStatus {
        case .authorized, .fullAccess:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)

        case .denied, .restricted:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.colors.ribbon)

        default:
            Button("Connect") {
                Task { await calendarManager.requestAccess() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.colors.ribbon)
        }
    }
}
