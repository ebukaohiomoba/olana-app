//
//  FocusCard.swift
//  Olana
//
//  The one thing worth attention right now.
//
//  A ranked list is still a list, and for someone whose difficulty is deciding
//  what to start, a list of twelve correctly ordered things is still twelve
//  things. This surfaces exactly one, with a short reason, and says nothing
//  when nothing qualifies. Silence is a valid and frequent answer.
//

import SwiftUI

struct FocusCard: View {

    let event: OlanaEvent
    let result: UrgencyCombiner.Result
    let reason: String
    var onTap: () -> Void = {}

    @Environment(\.olanaTheme) private var theme

    private var accent: Color {
        switch result.urgency {
        case .high:   return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low:    return theme.colors.urgencyLow
        }
    }

    /// "Start now" when preparation pulled the moment forward, otherwise the
    /// event's own time. This is the whole differentiating idea in one line.
    private var timingLabel: String {
        if result.advancedByPrep {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return "Start \(f.localizedString(for: result.actBy, relativeTo: Date()))"
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: event.start, relativeTo: Date()).capitalized
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {

                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                    Text(result.advancedByPrep ? "WORTH STARTING" : "WORTH KNOWING")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(theme.colors.slate)
                    Spacer()
                }

                Text(event.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(timingLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                    Text("·")
                        .foregroundStyle(theme.colors.slate)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(theme.colors.slate)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.colors.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.colors.cardBorder, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                // A thin edge rather than a filled card: this sits above the day
                // list and should read as emphasis, not as an alert.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title). \(timingLabel). \(reason)")
    }
}
