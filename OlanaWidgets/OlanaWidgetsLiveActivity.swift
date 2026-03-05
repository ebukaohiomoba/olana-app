//
//  OlanaWidgetsLiveActivity.swift
//  OlanaWidgets
//
//  Live Activity UI for Olana events — Lock Screen banner + Dynamic Island.
//  Uses OlanaEventAttributes (defined in OlanaActivityAttributes.swift).
//
//  REQUIRED: OlanaActivityAttributes.swift must be added to the OlanaWidgets
//  target. Select the file in Xcode → File Inspector → Target Membership → check OlanaWidgets.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Urgency helpers (no app-type dependency)

private func urgencyColor(_ raw: Int) -> Color {
    switch raw {
    case 2:  return Color(red: 1.0,  green: 0.27, blue: 0.23)   // vivid red
    case 1:  return Color(red: 1.0,  green: 0.62, blue: 0.04)   // vivid amber
    default: return Color(red: 0.18, green: 0.62, blue: 1.0)    // vivid sky blue
    }
}

private func urgencyLabel(_ raw: Int) -> String {
    switch raw {
    case 2:  return "Critical"
    case 1:  return "Soon"
    default: return "Later"
    }
}

private func urgencySymbol(_ raw: Int) -> String {
    switch raw {
    case 2:  return "exclamationmark.triangle.fill"
    case 1:  return "clock.badge.fill"
    default: return "calendar.badge.clock"
    }
}

// MARK: - Lock Screen / Banner view
// Uses @Environment(\.colorScheme) to adapt between light and dark mode.
// The Dynamic Island pill is always dark, so those views use white text throughout.

@available(iOS 16.2, *)
private struct OlanaLockScreenView: View {
    let context: ActivityViewContext<OlanaEventAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var color: Color { urgencyColor(context.attributes.urgencyRaw) }

    private var primaryText:   Color { isDark ? .white               : .primary }
    private var secondaryText: Color { isDark ? .white.opacity(0.55) : .secondary }

    var body: some View {
        HStack(spacing: 0) {

            // Left urgency accent bar
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.trailing, 14)

            // Event title + urgency badge
            VStack(alignment: .leading, spacing: 5) {
                Text(context.attributes.eventTitle)
                    .font(.headline)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: urgencySymbol(context.attributes.urgencyRaw))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                    Text(urgencyLabel(context.attributes.urgencyRaw))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }
            }

            Spacer()

            // Countdown + start time
            VStack(alignment: .trailing, spacing: 5) {
                if context.state.status == "done" {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Text(timerInterval: Date()...context.state.eventStart, countsDown: true)
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(color)
                }

                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(secondaryText)
                    Text(context.state.eventStart, style: .time)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(isDark ? Color.black.opacity(0.88) : Color.white.opacity(0.97))
        .activitySystemActionForegroundColor(primaryText)
    }
}

// MARK: - Widget

@available(iOS 16.2, *)
struct OlanaWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OlanaEventAttributes.self) { context in
            OlanaLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {

                // ── Expanded (long-press) ────────────────────────────────────
                //
                // Leading: urgency icon + full event title on one horizontal line
                // Trailing: large live countdown with "remaining" sublabel
                // Bottom: start time chip + urgency badge

                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: urgencySymbol(context.attributes.urgencyRaw))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(urgencyColor(context.attributes.urgencyRaw))
                        Text(context.attributes.eventTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.status == "done" {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(timerInterval: Date()...context.state.eventStart, countsDown: true)
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(urgencyColor(context.attributes.urgencyRaw))
                                .multilineTextAlignment(.trailing)
                            Text("remaining")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                        Text(context.state.eventStart, style: .time)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(urgencyLabel(context.attributes.urgencyRaw))
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(urgencyColor(context.attributes.urgencyRaw))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(urgencyColor(context.attributes.urgencyRaw).opacity(0.2))
                            )
                    }
                }

            } compactLeading: {
                // Event title runs horizontally from the left side of the pill
                HStack(spacing: 5) {
                    Circle()
                        .fill(urgencyColor(context.attributes.urgencyRaw))
                        .frame(width: 7, height: 7)
                    Text(context.attributes.eventTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            } compactTrailing: {
                // Live countdown on the right side of the pill
                if context.state.status == "done" {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(timerInterval: Date()...context.state.eventStart, countsDown: true)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(urgencyColor(context.attributes.urgencyRaw))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 44)
                }

            } minimal: {
                Image(systemName: urgencySymbol(context.attributes.urgencyRaw))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(urgencyColor(context.attributes.urgencyRaw))
            }
            .widgetURL(URL(string: "olana://event/\(context.attributes.eventId)"))
            .keylineTint(urgencyColor(context.attributes.urgencyRaw))
        }
    }
}
