//
//  DayContextEventRow.swift
//  Olana
//
//  A single event row shown inside the expanded DayContextBar.
//

import SwiftUI

struct DayContextEventRow: View {
    @Environment(\.olanaTheme) private var theme

    let event: OlanaEvent

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var dotColor: Color {
        if let hex = event.calendarColorHex { return Color(hex: hex) }
        switch event.urgency {
        case .high:   return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low:    return theme.colors.urgencyLow
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            Text(Self.timeFmt.string(from: event.start))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(event.title)
                .font(.caption)
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)

            Spacer()
        }
    }
}
