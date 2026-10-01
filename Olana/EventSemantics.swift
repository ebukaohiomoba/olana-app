//
//  EventSemantics.swift
//  Olana
//
//  Stable semantic properties of an event: what kind of thing it is, judged once
//  and cached forever. Deliberately contains nothing time-dependent — the clock
//  lives in UrgencyCombiner, which is re-run freely.
//
//  Extraction runs on Apple's on-device model with greedy sampling, which is
//  deterministic: the same title returns the same answer every time. There is
//  no fallback. When the model cannot answer, the event is left unranked: it
//  keeps its chronological position and never alerts. A keyword guess that
//  rings an alarm for "Dinner with parents" is worse than no ranking at all.
//

import Foundation
import FoundationModels

// MARK: - Properties

@Generable
public enum Consequence: String, Codable, CaseIterable, Sendable {
    case severe, moderate, minor
}

@Generable
public enum Movability: String, Codable, CaseIterable, Sendable {
    case fixed, difficult, flexible
}

@Generable
public enum PrepNeed: String, Codable, CaseIterable, Sendable {
    case none, short, medium, long

    /// Hours of work assumed to happen before the event starts.
    /// The model is asked for a bucket, never a number: Apple warns against
    /// arithmetic and the on-device model fails simple sums.
    var hours: Double {
        switch self {
        case .none:   return 0
        case .short:  return 2
        case .medium: return 12
        case .long:   return 48
        }
    }
}

@Generable
public enum EventCategory: String, Codable, CaseIterable, Sendable {
    case work, health, legalFinance, travel, education
    case family, social, fitness, admin, personal
}

@Generable
public struct EventSemantics: Codable, Sendable, Equatable {
    @Guide(description: "What actually happens to the person if this is missed entirely.")
    public var consequence: Consequence

    @Guide(description: "How hard this would be to reschedule.")
    public var movability: Movability

    @Guide(description: "True ONLY if the person must produce, write, build, buy, study for or rehearse something before this happens. False for anything they simply show up to.")
    public var requiresPreparation: Bool

    @Guide(description: "How much work happens beforehand. Must be none whenever requiresPreparation is false.")
    public var prepNeed: PrepNeed

    @Guide(description: "The area of life this belongs to.")
    public var category: EventCategory

    public init(consequence: Consequence, movability: Movability,
                requiresPreparation: Bool, prepNeed: PrepNeed, category: EventCategory) {
        self.consequence = consequence
        self.movability = movability
        self.requiresPreparation = requiresPreparation
        self.prepNeed = prepNeed
        self.category = category
    }
}

// MARK: - Prep gating

public extension EventSemantics {

    /// Categories where a claim of "preparation" is almost always the model
    /// pattern-matching rather than reading. Measured: without this gate the
    /// model asserts prep work for dentist appointments, flights and jury duty.
    static let neverPrep: Set<EventCategory> = [.health, .fitness, .admin, .travel]

    /// Preparation after gating. This, not `prepNeed`, is what the combiner uses.
    var effectivePrep: PrepNeed {
        guard requiresPreparation, !Self.neverPrep.contains(category) else { return .none }
        return prepNeed
    }
}

// MARK: - Extraction instructions

public enum EventSemanticsPrompt {

    /// Worked examples matter more than description here. Measured on 76 events:
    /// prose-only instructions produced refusals on tax and legal titles and
    /// collapsed almost everything to "moderate". Anchored examples removed the
    /// refusals entirely and restored the spread.
    ///
    /// Wording here is checked by the system safety filter on every request, and
    /// the filter changes between OS releases. On macOS 27 the phrase "legal
    /// trouble" alone made 26 of 63 calibration titles fail, "Gym" and "Dentist
    /// appointment" included. Run `swift run Calibrate` in UrgencyProbe after any
    /// edit here or any OS update; watch the "Model failures" line.
    public static let instructions = """
    You classify calendar events so a planning app can decide how much attention each deserves.
    You get a short title and sometimes the name of the calendar it came from. Use the calendar
    name as context. Judge only from what the title plainly is.

    CONSEQUENCE — what happens if the person simply does not show up or does not do it.
      severe   money lost, an official obligation missed, health harm, a job or opportunity gone, something
               that cannot be recovered. Examples: Flight departure, Court date, Surgery,
               Final exam, Tax filing, Rent due, Visa appointment, Thesis defence, Closing
               on a house, On-call shift, Custody handoff, Bar exam.
               ANY job interview, screening call, phone screen or recruiter conversation is
               severe. A missed interview cannot be recovered.
      moderate real inconvenience, someone else is let down, a fee, rescheduling hassle.
               Examples: Dentist checkup, Team meeting, Performance review, Dinner
               reservation, Physical therapy, DMV, Contractor visit, A friend's wedding.
      minor    nothing meaningful happens, or the event requires no action at all.
               Examples: Gym, Casual coffee, Netflix, Walking the dog, Browsing a shop,
               Nap, Optional standup, Reading for pleasure, Payday, a birthday, a public
               holiday, anything purely informational that happens whether or not the
               person does anything.

    Do not default to moderate. A real calendar contains a mix of all three.

    MOVABILITY — purely about rescheduling, never about importance.
      fixed     happens without you and cannot move. Examples: Flight, Court date, Exam,
                Concert, Wedding, Live performance, Someone else's recital, Match day,
                Surgery, any deadline, Rent due, Closing, On-call rotation.
      difficult moving costs a professional or several people their time. Examples: Dentist,
                Doctor, DMV, Contractor, Performance review, Interview, Custody handoff.
      flexible  move it freely and nobody is affected. Examples: Gym, Coffee with a friend,
                Errands, Reading, Grocery run, Nap.

    Deadlines and appointments with other people are rarely flexible.

    REQUIRESPREPARATION — work done BEFORE the event, never the event itself.
      Ask: must they MAKE, WRITE, STUDY FOR, REHEARSE, BUY or BUILD something first?
      A title containing "due", "deadline", "homework", "assignment", "draft" or "report"
      describes work the person produces beforehand. Those are always true.
      false  Dentist, Flight, Surgery, Jury duty, Standup, Team meeting, Passport
             appointment, DMV, Bloodwork, Gym, Coffee, Concert, Prescription pickup,
             Court date, Custody handoff, Someone else's recital, Payday, a holiday.
      true   Presentation, Exam, Thesis defence, Tax filing, Report due, Homework due,
             Hosting a dinner, Best man speech, Job interview, Grant application,
             a recital you perform in, Draft due, Pitch to investors.

    Packing is not preparation. Travelling is not preparation. Nerves are not preparation.

    prepNeed: none when requiresPreparation is false. Otherwise short (an hour or two),
    medium (a few hours of real work), long (days of work).
    """

    /// Temporal phrases carry no semantic information and measurably perturb the
    /// answer: "Dentist appointment" and "Dentist appointment in two days" returned
    /// different judgements until these were stripped. The date is parsed elsewhere.
    private static let datePatterns: [String] = [
        #"\bin \d+ (day|days|hour|hours|week|weeks|month|months)\b"#,
        #"\bin (a|one|two|three|four|five|six|seven|ten) (day|days|hour|hours|week|weeks|month|months)\b"#,
        #"\b(next|this|last) (week|weekend|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        #"\bon (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        #"\b(tomorrow|today|tonight|yesterday|tmrw)\b"#,
        #"\bat \d{1,2}(:\d{2})?\s?(am|pm)?\b"#,
        #"\b\d{1,2}(:\d{2})?\s?(am|pm)\b"#,
    ]

    public static func stripDatePhrases(_ s: String) -> String {
        var out = s
        for p in datePatterns {
            out = out.replacingOccurrences(of: p, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,-"))
        return out.isEmpty ? s : out
    }

    /// Calendar names are user- and provider-generated, and most of what arrives
    /// is not a name at all. Apple and Google label calendars with the account's
    /// email address, and an address in the prompt is both useless as context and
    /// measurably harmful: "Payday" classifies fine under a calendar called
    /// "Personal" and is refused outright under "someone@gmail.com".
    ///
    /// So only pass through things that read like a label a person chose.
    static func sanitizedCalendarName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // Email addresses and anything URL-shaped.
        guard !name.contains("@"), !name.contains("://") else { return nil }

        // Provider identifiers: UUIDs, long hex strings, anything mostly digits.
        if UUID(uuidString: name) != nil { return nil }
        let alphanumeric = name.filter { $0.isLetter || $0.isNumber }
        if !alphanumeric.isEmpty {
            let digits = alphanumeric.filter(\.isNumber).count
            if Double(digits) / Double(alphanumeric.count) > 0.4 { return nil }
        }

        // Generic labels that carry no signal.
        let generic: Set<String> = ["calendar", "default", "events", "untitled", "home", "ical"]
        guard !generic.contains(name.lowercased()) else { return nil }

        // A long name is a phrase, not a category. Nothing beyond this length has
        // ever helped the classification.
        guard name.count <= 32 else { return nil }

        return name
    }

    public static func prompt(title: String, calendarName: String?) -> String {
        var p = "Event title: \(stripDatePhrases(title))"
        if let name = sanitizedCalendarName(calendarName) { p += "\nCalendar: \(name)" }
        return p
    }
}

// MARK: - Low-information titles

public extension EventSemantics {

    /// True when a title carries too little meaning to classify honestly.
    ///
    /// Real calendars are full of placeholders: "Hold", "OOO", "Blocked", "Sync",
    /// "1:1". Measured on held-out titles, the model answers these with a confident
    /// `moderate`/`fixed`, which scores 4.9 and generates a notification — putting
    /// a calendar-blocking placeholder above a doctor's appointment.
    ///
    /// No instruction fixes this, because the problem is an absence of information
    /// rather than a misreading of it. So detect it and decline to rank. The event
    /// keeps its chronological position and stays silent, which is the honest answer.
    static func isLowInformation(title: String) -> Bool {
        let cleaned = EventSemanticsPrompt.stripDatePhrases(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return true }

        // Strip punctuation and names-with-numbers so "1:1 with Marcus" reduces to
        // the part that would have to carry meaning.
        let words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }

        // Placeholders that describe the calendar rather than the commitment.
        let placeholders: Set<String> = [
            "hold", "held", "blocked", "block", "busy", "ooo", "oof", "pto", "wfh",
            "tbd", "tba", "placeholder", "reserved", "unavailable", "away",
            "sync", "meeting", "call", "chat", "catchup", "touchpoint", "standup",
            "check", "checkin", "review", "session", "time", "slot", "focus",
            "misc", "other", "event", "appointment", "reminder", "task", "todo"
        ]

        // A single word that is only a placeholder tells us nothing.
        if words.count <= 1 {
            return words.first.map { placeholders.contains($0) } ?? true
        }

        // Filler that adds no meaning when it is all that is left.
        let filler: Set<String> = ["with", "and", "the", "a", "an", "for", "to", "on",
                                   "my", "our", "re", "w", "vs", "at", "of", "in"]
        let meaningful = words.filter { !placeholders.contains($0) && !filler.contains($0) }

        // "1:1 with Marcus" leaves ["marcus"], a name that says nothing about the
        // commitment. "Sync with legal" leaves ["legal"], which does. The line is
        // imperfect; erring toward declining to rank is the cheaper mistake.
        return meaningful.isEmpty
    }
}
