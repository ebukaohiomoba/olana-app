//
//  EventDraft.swift
//  Olana
//
//  The structured shape Foundation Models fills in when parsing free-form capture
//  text, plus the validated value the app actually uses.
//
//  Dates cross this boundary as ISO 8601 strings rather than Date. Guided
//  generation cannot produce a Date directly, and asking the model for date
//  arithmetic is asking for the thing it is worst at, so the model resolves
//  relative phrases against a supplied "current time" and hands back an absolute
//  timestamp that Swift parses.
//
//  Enums also cross as strings. EventUrgency and RecurrenceRule are persisted
//  SwiftData types; keeping the generable surface separate means the model
//  cannot put the store into a state the app does not expect.
//

import Foundation
import FoundationModels

// MARK: - Generable draft

@Generable
struct EventDraft {

    @Guide(description: "Short event title with leading verbs like 'add', 'schedule' or 'remind me to' removed.")
    var title: String

    @Guide(description: "Start date and time as ISO 8601, for example 2026-08-27T15:00:00Z. Resolve relative phrases against the supplied current time.")
    var startISO8601: String

    @Guide(description: "End date and time as ISO 8601. Empty string when the user did not state a duration or a range. Never invent one.")
    var endISO8601: String

    @Guide(description: "One of: low, medium, high. Use medium unless the text says otherwise.")
    var urgency: String

    @Guide(description: "One of: none, daily, weekly, monthly. Use none unless the text states a repeat.")
    var recurrence: String
}

// MARK: - Resolved value

struct ResolvedEventDraft: Equatable, Sendable {
    let title: String
    let start: Date
    /// nil when the user did not state a duration. Callers decide the default
    /// rather than having one invented for them.
    let end: Date?
    let urgency: EventUrgency
    let recurrenceRule: RecurrenceRule
}

// MARK: - Parsing and validation

extension EventDraft {

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Also accepts a bare "2026-08-27T15:00:00" with no zone, which the model
    /// emits fairly often, interpreting it as local time.
    private static let localFallback: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return isoFractional.date(from: t)
            ?? isoPlain.date(from: t)
            ?? localFallback.date(from: t)
    }

    var parsedStart: Date? { Self.parseDate(startISO8601) }
    var parsedEnd: Date? { Self.parseDate(endISO8601) }

    /// Rejects drafts the app should not act on. Deliberately strict: falling back
    /// to the manual form is a small cost, while silently creating an event on the
    /// wrong day is the kind of error that loses trust in the whole feature.
    func validate(now: Date = Date()) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let start = parsedStart else { return false }

        // A parse that lands far in the past almost always means the model
        // misread a relative phrase rather than that the user meant it.
        guard start > now.addingTimeInterval(-24 * 3600) else { return false }
        // Two years out is past the point of plausible capture from one sentence.
        guard start < now.addingTimeInterval(730 * 24 * 3600) else { return false }

        if let end = parsedEnd {
            guard end > start else { return false }
            guard end.timeIntervalSince(start) < 30 * 24 * 3600 else { return false }
        }
        return true
    }

    /// Call only after `validate` returns true.
    func resolve() -> ResolvedEventDraft? {
        guard let start = parsedStart else { return nil }
        return ResolvedEventDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: start,
            end: parsedEnd,
            urgency: Self.mapUrgency(urgency),
            recurrenceRule: Self.mapRecurrence(recurrence)
        )
    }

    static func mapUrgency(_ raw: String) -> EventUrgency {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high", "critical", "urgent": return .high
        case "low", "later", "minor":      return .low
        default:                           return .medium
        }
    }

    static func mapRecurrence(_ raw: String) -> RecurrenceRule {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "daily":   return .daily
        case "weekly":  return .weekly
        case "monthly": return .monthly
        default:        return RecurrenceRule.none
        }
    }
}
