//
//  CalendarSyncEngine.swift
//  Olana
//
//  Pure functions for normalising EKEvents into OlanaEvent, applying calendar
//  urgency settings, and deduplicating events from multiple sources. No state — all methods are static.
//

import Foundation
import EventKit

enum CalendarSyncEngine {

    // MARK: - Urgency on import

    /// Urgency shown for a synced event before the model has judged it. A
    /// placeholder, not a judgement: the model replaces it during backfill.
    /// There are deliberately no keyword rules here. Ranking comes from Apple
    /// Intelligence or not at all.
    static let unjudgedUrgency: EventUrgency = .medium

    /// Applies the calendar's urgency setting, if the user chose one, as an
    /// override the model cannot replace. Otherwise the unjudged placeholder.
    private static func applyImportUrgency(to event: OlanaEvent, calendarID: String,
                                           userCalendars: [UserCalendar]) {
        if let override = userCalendars.first(where: { $0.calendarID == calendarID })?.urgencyOverride {
            event.urgency = override
            event.urgencyOverrideRaw = override.rawValue
            event.urgencyOverrideFromCalendar = true
        } else {
            event.urgency = unjudgedUrgency
        }
    }

    // MARK: - Normalise

    /// Converts a single EKEvent into an OlanaEvent ready for SwiftData insertion.
    static func normalise(
        ekEvent: EKEvent,
        userCalendars: [UserCalendar]
    ) -> OlanaEvent {
        let start   = ekEvent.startDate ?? Date()
        let end     = ekEvent.endDate   ?? start.addingTimeInterval(3600)

        let event = OlanaEvent(
            title:              ekEvent.title ?? "Untitled",
            start:              start,
            end:                end,
            urgency:            unjudgedUrgency,
            recurrenceRule:     .none,
            externalCalendarId: "apple",
            externalEventId:    ekEvent.eventIdentifier,
            isAllDay:           ekEvent.isAllDay,
            notes:              ekEvent.notes,
            location:           ekEvent.location,
            calendarName:       ekEvent.calendar.title,
            calendarColorHex:   hexColor(from: ekEvent.calendar.cgColor)
        )
        event.syncedAt         = Date()
        event.sourceModifiedAt = ekEvent.lastModifiedDate
        applyImportUrgency(to: event, calendarID: ekEvent.calendar.calendarIdentifier,
                           userCalendars: userCalendars)
        return event
    }

    // MARK: - Deduplicate

    /// Removes duplicate events (same title + start time).
    /// When duplicates exist, prefers .apple source.
    static func deduplicate(_ events: [OlanaEvent]) -> [OlanaEvent] {
        // Sort apple source first so it wins dedup
        let sorted = events.sorted {
            ($0.externalCalendarId == "apple" ? 0 : 1) <
            ($1.externalCalendarId == "apple" ? 0 : 1)
        }
        var seen   = Set<String>()
        var result = [OlanaEvent]()
        for event in sorted {
            let key = "\(event.title.lowercased())_\(Int(event.start.timeIntervalSince1970))"
            if seen.insert(key).inserted {
                result.append(event)
            }
        }
        return result
    }

    // MARK: - Google Calendar Normalise

    /// Converts a GEvent + its calendar entry into an OlanaEvent.
    /// Returns nil if the event's start date cannot be parsed.
    static func normalise(
        gEvent: GEvent,
        calendarEntry: GCalendarListEntry,
        userCalendars: [UserCalendar]
    ) -> OlanaEvent? {
        guard let start = parseGEventDate(gEvent.start) else { return nil }
        let end     = parseGEventDate(gEvent.end)
                   ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)
                   ?? start
        let isAllDay = gEvent.start.date != nil   // date-only field = all-day

        let event = OlanaEvent(
            title:              gEvent.summary ?? "Untitled",
            start:              start,
            end:                end,
            urgency:            unjudgedUrgency,
            recurrenceRule:     .none,
            externalCalendarId: "google",
            externalEventId:    gEvent.id,
            isAllDay:           isAllDay,
            notes:              gEvent.description,
            location:           gEvent.location,
            calendarName:       calendarEntry.summary,
            calendarColorHex:   calendarEntry.backgroundColor
        )
        event.syncedAt = Date()
        applyImportUrgency(to: event, calendarID: calendarEntry.id, userCalendars: userCalendars)
        return event
    }

    /// Parses a GEventDateTime that may carry either an RFC 3339 dateTime or a
    /// YYYY-MM-DD date string (for all-day events).
    static func parseGEventDate(_ dt: GEventDateTime) -> Date? {
        if let dtString = dt.dateTime {
            return iso8601.date(from: dtString) ?? iso8601Fractional.date(from: dtString)
        }
        if let dateString = dt.date {
            return allDayFormatter.date(from: dateString)
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let allDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat  = "yyyy-MM-dd"
        f.timeZone    = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Helpers

    private static func hexColor(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let components = cgColor.components,
              components.count >= 3
        else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
