//
//  ImminentEventCard.swift
//  Olana
//
//  Pins to the top of the event list when the soonest upcoming event is within
//  `windowMinutes` minutes and hasn't started yet. Disappears when start passes.
//
//  Layout: amber left border · clock icon · "In 45 min" countdown · title & time.
//  Countdown updates every 60 seconds via a passed-in timer tick binding.
//

import SwiftUI

struct ImminentEventCard: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var store: EventStore

    /// Imminent window in minutes (from CalendarPreferences, default 90).
    var windowMinutes: Int = 90

    /// Bind to a @State Int that increments every 60 s so the countdown refreshes.
    var timerTick: Int = 0

    // MARK: - Derived

    private var imminentEvent: OlanaEvent? {
        let now = Date()
        let windowEnd = now.addingTimeInterval(TimeInterval(windowMinutes) * 60)
        return store.events
            .filter { $0.start > now && $0.start <= windowEnd && !$0.completed }
            .min { $0.start < $1.start }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: - Body

    var body: some View {
        if let event = imminentEvent {
            let minutesAway = max(0, Int(event.start.timeIntervalSince(Date()) / 60))
            let countdownText = minutesAway == 0 ? "Starting now" : "In \(minutesAway) min"

            HStack(spacing: 12) {
                // Amber accent bar
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 3)
                    .frame(height: 52)

                Image(systemName: "clock.fill")
                    .font(.callout)
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(countdownText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)

                    Text(event.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.colors.ink)
                        .lineLimit(1)

                    Text(Self.timeFmt.string(from: event.start))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.colors.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.orange.opacity(0.12), radius: 10, x: 0, y: 4)
            .shadow(color: theme.colors.pillShadow, radius: 6, x: 0, y: 2)
        }
    }
}
