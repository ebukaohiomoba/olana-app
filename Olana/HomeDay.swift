//
//  HomeDay.swift
//  Olana
//
//  What the home screen says, computed from today's events and the clock.
//  Pure value types: no SwiftUI, no SwiftData writes, so every rule here can be
//  checked against a fixed `now` (spec_m0_m1_v2 §14).
//
//  M1-B works from today's data only: urgency, `actBy` and start. M1-C adds
//  leave, get-ready and join phases from EventAssist; the phase enum and the
//  runway ticks are where they slot in.
//

import Foundation

// MARK: - Next card

struct NextCard: Equatable {

    enum Phase: Equatable {
        case startsAt          // Starts at 3:00
        case happeningNow      // Happening now
        case prepAt            // Start prepping at 2:20 (within 12 h)
        case prepLater         // Prep today / Prep by tomorrow morning
        case prepNow           // Prep now
    }

    struct Tick: Equatable {
        enum Kind: Equatable { case now, prep, start }
        let kind: Kind
        let date: Date
    }

    let eventID: UUID
    let title: String
    let urgency: EventUrgency
    let start: Date
    let end: Date
    let place: String?
    let phase: Phase
    /// L1 as two parts so the view can set the gold part. The gold part is the
    /// time or word the person acts on ("2:20", "now", "today").
    let lead: String
    let gold: String
    let trail: String
    /// L4: "3:00 → 4:00 PM · Room 2", with the day when it is not today.
    let detail: String
    /// nil when the runway would not say anything useful (start is > 12 h out,
    /// or the event is already under way).
    let runway: Runway?

    struct Runway: Equatable {
        let from: Date          // left edge; holds still so the fill advances
        let to: Date            // right edge, just past start for the red cap
        let now: Date
        let prepFrom: Date?     // hatched prep window, nil when no prep
        let start: Date
        let ticks: [Tick]

        func x(_ d: Date) -> Double {
            let span = to.timeIntervalSince(from)
            guard span > 0 else { return 0 }
            return min(1, max(0, d.timeIntervalSince(from) / span))
        }

        /// Text equivalent for VoiceOver (spec §14.3).
        var accessibilityText: String {
            var parts: [String] = []
            if let p = prepFrom { parts.append("Prep from \(HomeFormat.clock(p))") }
            parts.append("starts at \(HomeFormat.clock(start))")
            return parts.joined(separator: ", ").capitalizedFirst
        }
    }

    /// "Client review, critical, 3:00 to 4:00" (spec §14.7: tier never by color alone).
    var accessibilityLabel: String {
        "\(title), \(HomeFormat.tierName(urgency)), \(HomeFormat.clock(start)) to \(HomeFormat.clock(end)). \(lead)\(gold)\(trail)"
    }
}

// MARK: - Rail

struct RailItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let start: Date
    let end: Date
    let urgency: EventUrgency
    let isTask: Bool
    let isRecurring: Bool
    /// Start of the hatched prep segment drawn above the bar, nil when none.
    let prepFrom: Date?
    /// A task whose time has passed and isn't done: held at `now`, not red.
    let isOverdueTask: Bool
}

struct DoneItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let time: Date
    let isTask: Bool
}

struct HomeDay: Equatable {
    let now: Date
    let card: NextCard?
    let rail: [RailItem]
    let allDay: [String]
    let done: [DoneItem]
    /// Quiet-hours start today, when quiet hours are on and it's still ahead.
    let bed: Date?
    /// Empty-state peek: the next event that matters on a later day.
    let peek: NextCard?

    var isOpen: Bool { rail.isEmpty }

    var doneLabel: String {
        let n = done.count
        let when = Calendar.current.component(.hour, from: now) < 12 ? "this morning" : "today"
        return "✓ \(n) done \(when)"
    }
}

// MARK: - Builder

enum HomeDayBuilder {

    /// Snapshot of what the builder reads from an OlanaEvent. Keeps the builder
    /// off the SwiftData object so it can run against fixtures.
    struct Input: Equatable {
        let id: UUID
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let isTask: Bool
        let completed: Bool
        let completedAt: Date?
        let isRecurring: Bool
        let location: String?
        /// Stored urgency, which already includes the user's override.
        let urgency: EventUrgency
        /// Scored urgency and actBy for events not yet started; nil when
        /// unjudged or started.
        let scored: UrgencyCombiner.Result?
        /// Prep the model judged necessary, nil when none.
        let prepHours: Double?
    }

    static let runwayHorizon: TimeInterval = 12 * 3600

    static func build(inputs: [Input], focusID: UUID?, now: Date,
                      bed: Date?, calendar: Calendar = .current) -> HomeDay {
        let today = inputs.filter { calendar.isDate($0.start, inSameDayAs: now) }

        let allDay = today.filter { $0.isAllDay && !$0.completed }.map(\.title)
        let timed = today.filter { !$0.isAllDay }

        // Done: tasks marked done today, and events that have ended (decision 10,
        // built as designed). Tasks not done stay on the rail.
        var done: [DoneItem] = []
        var rail: [RailItem] = []
        for e in timed.sorted(by: { $0.start < $1.start }) {
            if e.isTask {
                if e.completed {
                    done.append(DoneItem(id: e.id, title: e.title, time: e.start, isTask: true))
                } else {
                    rail.append(railItem(e, now: now))
                }
            } else if e.end <= now || e.completed {
                done.append(DoneItem(id: e.id, title: e.title, time: e.start, isTask: false))
            } else {
                rail.append(railItem(e, now: now))
            }
        }
        // Overdue tasks sit at `now`, ahead of everything still to come.
        rail.sort { a, b in
            if a.isOverdueTask != b.isOverdueTask { return a.isOverdueTask }
            return a.start < b.start
        }

        let card = pickCard(inputs: inputs, focusID: focusID, now: now, calendar: calendar)
        let peek: NextCard? = {
            guard rail.isEmpty, let c = card, !calendar.isDate(c.start, inSameDayAs: now) else { return nil }
            return c
        }()

        let bedToday = bed.flatMap { b -> Date? in
            guard b > now, calendar.isDate(b, inSameDayAs: now) else { return nil }
            return b
        }

        return HomeDay(now: now,
                       card: rail.isEmpty ? nil : card,
                       rail: rail, allDay: allDay, done: done,
                       bed: bedToday, peek: peek)
    }

    private static func railItem(_ e: Input, now: Date) -> RailItem {
        let prepFrom: Date? = e.prepHours.map { e.start.addingTimeInterval(-$0 * 3600) }
            .flatMap { $0 < e.start && e.start > now ? max($0, now) : nil }
        return RailItem(id: e.id, title: e.title, start: e.start, end: e.end,
                        urgency: e.urgency, isTask: e.isTask, isRecurring: e.isRecurring,
                        prepFrom: prepFrom,
                        isOverdueTask: e.isTask && !e.completed && e.start <= now)
    }

    // MARK: Card

    /// The event under way that matters, else the store's focus event.
    /// Nothing when nothing qualifies: silence is a valid answer.
    private static func pickCard(inputs: [Input], focusID: UUID?, now: Date,
                                 calendar: Calendar) -> NextCard? {
        let underway = inputs
            .filter { !$0.isAllDay && !$0.isTask && !$0.completed
                && $0.start <= now && $0.end > now && $0.urgency != .low }
            .sorted { $0.urgency.rawValue > $1.urgency.rawValue }
            .first
        if let e = underway { return card(e, now: now, calendar: calendar) }

        guard let id = focusID, let e = inputs.first(where: { $0.id == id }) else { return nil }
        return card(e, now: now, calendar: calendar)
    }

    static func card(_ e: Input, now: Date, calendar: Calendar = .current) -> NextCard {
        let urgency = e.scored?.urgency ?? e.urgency
        let prepFrom: Date? = {
            guard let h = e.prepHours, h > 0 else { return nil }
            return e.start.addingTimeInterval(-h * 3600)
        }()

        let phase: NextCard.Phase
        var lead = "", gold = ""
        let trail = ""   // M1-C: " · done by 2:16"
        if e.start <= now {
            phase = .happeningNow
            (lead, gold) = ("Happening ", "now")
        } else if let p = prepFrom {
            if p <= now {
                phase = .prepNow
                (lead, gold) = ("Prep ", "now")
            } else if p.timeIntervalSince(now) <= runwayHorizon {
                phase = .prepAt
                (lead, gold) = ("Start prepping at ", HomeFormat.clock(p))
            } else {
                phase = .prepLater
                (lead, gold) = HomeFormat.prepLater(p, now: now, calendar: calendar)
            }
        } else {
            phase = .startsAt
            if calendar.isDate(e.start, inSameDayAs: now) {
                (lead, gold) = ("Starts at ", HomeFormat.clock(e.start))
            } else {
                (lead, gold) = ("Starts ", "\(HomeFormat.dayName(e.start, now: now, calendar: calendar)) \(HomeFormat.clock(e.start))")
            }
        }

        var detail = HomeFormat.range(e.start, e.end)
        if !calendar.isDate(e.start, inSameDayAs: now) {
            detail = "\(HomeFormat.dayName(e.start, now: now, calendar: calendar).capitalizedFirst) · \(detail)"
        }
        if let place = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            detail += " · \(place)"
        }

        return NextCard(eventID: e.id, title: e.title, urgency: urgency,
                        start: e.start, end: e.end, place: e.location,
                        phase: phase, lead: lead, gold: gold, trail: trail,
                        detail: detail,
                        runway: runway(start: e.start, prepFrom: prepFrom, now: now))
    }

    /// Ticks only for phases that exist (spec §14.3). M1-B has no leave or join,
    /// so a room event never shows a leave tick.
    static func runway(start: Date, prepFrom: Date?, now: Date) -> NextCard.Runway? {
        guard start > now, start.timeIntervalSince(now) <= runwayHorizon else { return nil }

        // The left edge holds still once the clock passes it, so the fill grows.
        let anchor = (prepFrom ?? start).addingTimeInterval(-30 * 60)
        let from = min(now, anchor)
        let to = start.addingTimeInterval(start.timeIntervalSince(from) * 0.05)

        var ticks: [NextCard.Tick] = [.init(kind: .now, date: now)]
        if let p = prepFrom, p > now { ticks.append(.init(kind: .prep, date: p)) }
        ticks.append(.init(kind: .start, date: start))

        return NextCard.Runway(from: from, to: to, now: now,
                               prepFrom: prepFrom.map { max($0, from) },
                               start: start, ticks: ticks)
    }
}

// MARK: - Gaps

enum RailGap {
    /// Free time between two moments, labeled when ≥ 15 min (spec §14.5).
    static func label(from a: Date, to b: Date, windDown: Bool) -> String? {
        let minutes = Int(b.timeIntervalSince(a) / 60)
        guard minutes >= 15 else { return windDown ? "wind down" : nil }
        let free = "\(HomeFormat.duration(minutes)) free"
        return windDown ? "\(free), then wind down" : free
    }
}

// MARK: - Formatting

enum HomeFormat {

    /// "3:00", "10:15". No AM/PM: the card's L4 carries it.
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("h:mm")
        return f.string(from: d)
            .replacingOccurrences(of: " AM", with: "")
            .replacingOccurrences(of: " PM", with: "")
            .replacingOccurrences(of: "\u{202F}AM", with: "")
            .replacingOccurrences(of: "\u{202F}PM", with: "")
    }

    /// "3:00 → 4:00 PM"
    static func range(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let end = f.string(from: b)
        return "\(clock(a)) → \(end)"
    }

    /// "Bed around 10", "Bed around 10:30"
    static func bed(_ d: Date) -> String {
        let m = Calendar.current.component(.minute, from: d)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(m == 0 ? "h" : "h:mm")
        let s = f.string(from: d)
            .replacingOccurrences(of: "\u{202F}PM", with: "").replacingOccurrences(of: " PM", with: "")
            .replacingOccurrences(of: "\u{202F}AM", with: "").replacingOccurrences(of: " AM", with: "")
        return "Bed around \(s)"
    }

    /// "1h 20m", "45m", "2h"
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "tomorrow", "Thursday", "Oct 20"
    static func dayName(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) {
            return "tomorrow"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: d)).day ?? 0
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "MMM d")
        return f.string(from: d)
    }

    /// Prep further than 12 h out: "Prep today", "Prep by tomorrow morning",
    /// "Prep by Thursday".
    static func prepLater(_ p: Date, now: Date, calendar: Calendar) -> (String, String) {
        if calendar.isDate(p, inSameDayAs: now) { return ("Prep ", "today") }
        let day = dayName(p, now: now, calendar: calendar)
        let hour = calendar.component(.hour, from: p)
        let part = hour < 12 ? " morning" : hour < 17 ? " afternoon" : " evening"
        return ("Prep by ", day == "tomorrow" ? day + part : day)
    }

    static func tierName(_ u: EventUrgency) -> String {
        switch u {
        case .high:   return "critical"
        case .medium: return "soon"
        case .low:    return "later"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
