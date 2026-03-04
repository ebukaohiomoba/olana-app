import Foundation
import Combine
import SwiftData

// MARK: - RecurrenceRule
public enum RecurrenceRule: Int, Codable, CaseIterable, Sendable {
    case none     = 0
    case daily    = 1
    case weekdays = 2
    case weekly   = 3
    case monthly  = 4

    public var displayName: String {
        switch self {
        case .none:     return "Does not repeat"
        case .daily:    return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly:   return "Weekly"
        case .monthly:  return "Monthly"
        }
    }

    public var repeatLabel: String {
        switch self {
        case .none:     return ""
        case .daily:    return "Repeats daily"
        case .weekdays: return "Repeats every weekday"
        case .weekly:   return "Repeats weekly"
        case .monthly:  return "Repeats monthly"
        }
    }

    /// Total number of event instances created (primary + additional occurrences)
    public var totalOccurrences: Int {
        switch self {
        case .none:     return 1
        case .daily:    return 14
        case .weekdays: return 10
        case .weekly:   return 8
        case .monthly:  return 3
        }
    }
}

// MARK: - EventUrgency
public enum EventUrgency: Int, Codable, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

// MARK: - OlanaEvent Model
@Model
public final class OlanaEvent {
    // Note: @Attribute(.unique) is intentionally omitted — CloudKit does not support
    // unique constraints. UUID collision probability is negligible in practice.
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var urgency: EventUrgency
    public var recurrenceRule: RecurrenceRule = RecurrenceRule.none
    public var completed: Bool
    public var completedAt: Date?

    // Calendar integration — tracks which external calendar an event was imported from.
    // nil on events created natively in Olana.
    public var externalCalendarId: String? = nil   // e.g. "google", "apple", "outlook"
    public var externalEventId: String?    = nil   // the source calendar's event identifier

    // Additional fields for external calendar events (all optional with safe defaults
    // so lightweight SwiftData migration works without any migration plan).
    public var isAllDay: Bool = false
    public var notes: String? = nil
    public var location: String? = nil
    public var calendarName: String? = nil       // e.g. "Personal", "Work"
    public var calendarColorHex: String? = nil   // e.g. "#FF3B30"
    public var urgencyOverrideRaw: Int? = nil    // user-set urgency, overrides auto-assign
    public var sourceModifiedAt: Date? = nil     // last-modified timestamp from source calendar
    public var syncedAt: Date? = nil             // when Olana last synced this event

    /// Stable identity for SwiftUI List/ForEach.
    /// Non-recurring: uses the unique UUID string.
    /// Recurring: uses the series key (title + rule) so that when the displayed
    /// occurrence changes after a completion/delete the List sees the same identity
    /// and avoids the "Invalid update" UICollectionView crash.
    public var homeListKey: String {
        if recurrenceRule == RecurrenceRule.none { return id.uuidString }
        return "\(title)|\(recurrenceRule.rawValue)"
    }

    /// The effective urgency: user override takes precedence over auto-assigned urgency.
    public var effectiveUrgency: EventUrgency {
        urgencyOverrideRaw.flatMap { EventUrgency(rawValue: $0) } ?? urgency
    }

    /// Whether this event was imported from an external calendar.
    public var isFromExternalCalendar: Bool { externalCalendarId != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        start: Date,
        end: Date,
        urgency: EventUrgency,
        recurrenceRule: RecurrenceRule = .none,
        completed: Bool = false,
        completedAt: Date? = nil,
        externalCalendarId: String? = nil,
        externalEventId: String? = nil,
        isAllDay: Bool = false,
        notes: String? = nil,
        location: String? = nil,
        calendarName: String? = nil,
        calendarColorHex: String? = nil
    ) {
        self.id                 = id
        self.title              = title
        self.start              = start
        self.end                = end
        self.urgency            = urgency
        self.recurrenceRule     = recurrenceRule
        self.completed          = completed
        self.completedAt        = completedAt
        self.externalCalendarId = externalCalendarId
        self.externalEventId    = externalEventId
        self.isAllDay           = isAllDay
        self.notes              = notes
        self.location           = location
        self.calendarName       = calendarName
        self.calendarColorHex   = calendarColorHex
    }
}
