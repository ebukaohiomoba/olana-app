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
    /// True when the override came from the calendar's urgency setting rather
    /// than from the user editing this event. Sync may update or clear a
    /// calendar override; it never touches the user's own.
    public var urgencyOverrideFromCalendar: Bool? = nil
    public var sourceModifiedAt: Date? = nil     // last-modified timestamp from source calendar
    public var syncedAt: Date? = nil             // when Olana last synced this event
    /// True for user-created tasks (reminder with a start time only, no meaningful duration).
    /// Always false for events imported from Google/Apple Calendar.
    public var isTask: Bool = false

    // MARK: - Identity (PRD v6 §3.12)
    // Filled on the next sync; until then the source id + start match still works.
    /// Google `iCalUID`; EventKit `calendarItemExternalIdentifier`.
    public var iCalUID: String? = nil
    /// The occurrence's original start: Google `originalStartTime`, EventKit
    /// `occurrenceDate`. A moved recurring exception keeps it.
    public var occurrenceStart: Date? = nil
    /// Google `recurringEventId`.
    public var seriesID: String? = nil
    /// EventKit `calendarItemIdentifier`.
    public var calendarItemID: String? = nil
    /// Organizer email, lowercased. Used only to carry overrides over when an
    /// identifier changes.
    public var organizer: String? = nil
    /// Set on an iOS Calendar copy of an event that's also synced directly
    /// from Google: the id of the copy that's kept. Hidden, not deleted.
    public var duplicateOf: UUID? = nil

    // MARK: - Event input (PRD v6 §1.7a, §3.11)
    // From the add-box message for native events. Optional with defaults so
    // lightweight migration keeps working. `location` and `notes` above are
    // reused: the place words and the original message.
    /// Join link: from the message (native) or the invite (synced, M1-C).
    public var meetingURLString: String? = nil
    /// Things to do first, one per line, in the user's words.
    public var prepItemsText: String? = nil
    /// Things to bring, one per line, in the user's words.
    public var bringItemsText: String? = nil
    /// From "be there 15 min early" or the arrive-early bucket. Capped 0 to 180.
    public var arriveEarlyMinutes: Int? = nil
    /// Where `location` came from: "typed", "calendar" or "asked" (Where is this?).
    public var placeSource: String? = nil
    /// "inPerson", "virtual" or "unsure", from the message or the user.
    public var attendanceRaw: String? = nil
    /// The model thought this needs travel (drives "Where is this?").
    public var likelyNeedsTravel: Bool? = nil

    // MARK: - Resolved place (PRD v6 §3.4a step 6)
    // Filled when MapKit finds exactly one match, or the user picks one.
    public var placeName: String? = nil
    public var placeAddress: String? = nil
    public var placeLatitude: Double? = nil
    public var placeLongitude: Double? = nil
    public var placePhone: String? = nil
    public var placeWebsite: String? = nil

    // MARK: - Cached semantics (Option 5)
    // Stable properties of the event, extracted once and never recomputed. All
    // optional with defaults so lightweight SwiftData migration keeps working.
    // The clock lives in UrgencyCombiner, not here, so none of this goes stale.
    public var semConsequence: String? = nil
    public var semMovability: String? = nil
    public var semRequiresPrep: Bool? = nil
    public var semPrepNeed: String? = nil
    public var semCategory: String? = nil
    /// Bumped when the extraction prompt changes, to invalidate cached answers.
    public var semVersion: Int? = nil
    /// The title the semantics were derived from, so an edit re-extracts.
    /// Stored as the string itself: `String.hashValue` is reseeded every launch,
    /// so a stored hash never matches again after the app restarts.
    public var semTitle: String? = nil
    /// Consecutive failed extractions for this title. After a few, the event is
    /// treated as unrankable so it stops taking a backfill slot every launch.
    public var semFailures: Int? = nil

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

    public var meetingURL: URL? { meetingURLString.flatMap(URL.init(string:)).flatMap(URLGuard.validate) }
    public var prepItems: [String] { Self.lines(prepItemsText) }
    public var bringItems: [String] { Self.lines(bringItemsText) }
    public var hasResolvedPlace: Bool { placeLatitude != nil && placeLongitude != nil }

    static func lines(_ s: String?) -> [String] {
        (s ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Copies what the add-box message gave (§1.7a) onto this event.
    func applyCapture(_ c: CaptureResult, message: String) {
        notes = message
        if let place = c.placeText { location = place; placeSource = "typed" }
        meetingURLString = c.meetingURL?.absoluteString
        prepItemsText = c.steps.isEmpty ? nil : c.steps.joined(separator: "\n")
        bringItemsText = c.bring.isEmpty ? nil : c.bring.joined(separator: "\n")
        arriveEarlyMinutes = c.arriveEarlyMinutes
        attendanceRaw = c.attendance?.rawValue
        likelyNeedsTravel = c.likelyNeedsTravel
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
        calendarColorHex: String? = nil,
        isTask: Bool = false
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
        self.isTask             = isTask
    }
}

// MARK: - Resolved place

extension OlanaEvent {
    func applyPlace(_ p: ResolvedPlace) {
        placeName = p.name
        placeAddress = p.address
        placeLatitude = p.latitude
        placeLongitude = p.longitude
        placePhone = p.phone
        placeWebsite = p.website
    }

    var resolvedPlace: ResolvedPlace? {
        guard let placeLatitude, let placeLongitude else { return nil }
        return ResolvedPlace(name: placeName ?? location ?? "Place", address: placeAddress, latitude: placeLatitude,
                             longitude: placeLongitude, phone: placePhone, website: placeWebsite)
    }
}
