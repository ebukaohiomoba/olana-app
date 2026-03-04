//
//  CalendarSyncEngine.swift
//  Olana
//
//  Pure functions for normalising EKEvents into OlanaEvent, auto-assigning urgency,
//  and deduplicating events from multiple sources. No state — all methods are static.
//

import Foundation
import EventKit

enum CalendarSyncEngine {

    // MARK: - Keyword List (urgency auto-assign)

    private static let criticalKeywords: [String] = [
        "deadline", "interview", "presentation", "exam", "surgery",
        "flight", "final", "urgent", "critical", "demo", "launch",
        "due", "submit", "defend", "pitch"
    ]

    // MARK: - Urgency Assignment

    /// Assigns EventUrgency to an EKEvent using the first-match priority chain:
    ///   1. Per-calendar override on UserCalendar
    ///   2. All-day → .low (background)
    ///   3. Title contains critical keyword → .high
    ///   4. Today, within 3 hours → .high
    ///   5. Today, more than 3 hours away → .medium
    ///   6. Tomorrow or this week → .medium
    ///   7. Everything else → .low
    static func assignUrgency(
        to event: EKEvent,
        userCalendars: [UserCalendar]
    ) -> EventUrgency {
        let calID = event.calendar.calendarIdentifier

        // 1. Per-calendar override
        if let override = userCalendars.first(where: { $0.calendarID == calID })?.urgencyOverride {
            return override
        }

        // 2. All-day → background
        if event.isAllDay { return .low }

        // 3. Keyword match
        let lower = (event.title ?? "").lowercased()
        if criticalKeywords.contains(where: { lower.contains($0) }) { return .high }

        // 4–7. Time-based
        let now   = Date()
        let cal   = Calendar.current
        let start = event.startDate ?? now

        if cal.isDateInToday(start) {
            let hoursUntil = start.timeIntervalSince(now) / 3600
            return hoursUntil <= 3 ? .high : .medium
        }
        if cal.isDateInTomorrow(start) { return .medium }
        if let days = cal.dateComponents([.day], from: now, to: start).day, days <= 7 {
            return .medium
        }
        return .low
    }

    // MARK: - Normalise

    /// Converts a single EKEvent into an OlanaEvent ready for SwiftData insertion.
    static func normalise(
        ekEvent: EKEvent,
        userCalendars: [UserCalendar]
    ) -> OlanaEvent {
        let urgency = assignUrgency(to: ekEvent, userCalendars: userCalendars)
        let start   = ekEvent.startDate ?? Date()
        let end     = ekEvent.endDate   ?? start.addingTimeInterval(3600)

        let event = OlanaEvent(
            title:              ekEvent.title ?? "Untitled",
            start:              start,
            end:                end,
            urgency:            urgency,
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

        let urgency = assignUrgencyGoogle(
            title:      gEvent.summary ?? "",
            start:      start,
            isAllDay:   isAllDay,
            calendarID: calendarEntry.id,
            userCalendars: userCalendars
        )

        let event = OlanaEvent(
            title:              gEvent.summary ?? "Untitled",
            start:              start,
            end:                end,
            urgency:            urgency,
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
        return event
    }

    private static func assignUrgencyGoogle(
        title: String,
        start: Date,
        isAllDay: Bool,
        calendarID: String,
        userCalendars: [UserCalendar]
    ) -> EventUrgency {
        if let override = userCalendars.first(where: { $0.calendarID == calendarID })?.urgencyOverride {
            return override
        }
        if isAllDay { return .low }
        let lower = title.lowercased()
        if criticalKeywords.contains(where: { lower.contains($0) }) { return .high }
        let now = Date()
        let cal = Calendar.current
        if cal.isDateInToday(start) {
            return start.timeIntervalSince(now) / 3600 <= 3 ? .high : .medium
        }
        if cal.isDateInTomorrow(start) { return .medium }
        if let days = cal.dateComponents([.day], from: now, to: start).day, days <= 7 {
            return .medium
        }
        return .low
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
