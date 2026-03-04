//
//  DayContextBar.swift
//  Olana
//
//  Home-screen ambient bar showing today's events at a glance.
//
//  Collapsed:  "3 events today"  |  "Next: 2:30 · Doctors appt ˅"
//  Expanded:   spring-animated list of today's non-all-day events (max 5)
//              plus a "See all in Calendar →" link if there are more.
//
//  Colour: white 60% opacity background, 12pt corner radius, 1pt border.
//  No alert styling — this is ambient context, not a warning.
//

import SwiftUI

struct DayContextBar: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var store: EventStore

    @State private var isExpanded = false

    // MARK: - Derived data

    private var todayNonAllDay: [OlanaEvent] {
        let cal = Calendar.current
        return store.events
            .filter { cal.isDateInToday($0.start) && !$0.isAllDay && !$0.completed }
            .sorted { $0.start < $1.start }
    }

    private var nextEvent: OlanaEvent? {
        todayNonAllDay.first { $0.start > Date() }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: - Body

    var body: some View {
        let events = todayNonAllDay
        guard !events.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                // ── Collapsed row ──────────────────────────────────────
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 0) {
                        Text("\(events.count) event\(events.count == 1 ? "" : "s") today")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let next = nextEvent {
                            HStack(spacing: 4) {
                                Text("Next: \(Self.timeFmt.string(from: next.start)) · \(next.title)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(theme.colors.ink)
                                    .lineLimit(1)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                // ── Expanded list ──────────────────────────────────────
                if isExpanded {
                    Divider()
                        .padding(.horizontal, 14)

                    VStack(spacing: 6) {
                        ForEach(events.prefix(5)) { event in
                            DayContextEventRow(event: event)
                        }
                        if events.count > 5 {
                            HStack {
                                Spacer()
                                Text("See all in Calendar →")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.colors.ribbon)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.colors.cardBorder, lineWidth: 1)
                    )
            )
            .shadow(color: theme.colors.pillShadow.opacity(0.08), radius: 8, x: 0, y: 3)
        )
    }
}
