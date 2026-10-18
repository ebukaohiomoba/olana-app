//
//  HomeDay.swift
//  Olana
//
//  What the home screen says, computed from today's events and the clock.
//  Pure value types: no SwiftUI, no SwiftData writes, so every rule here can be
//  checked against a fixed `now` (spec_m0_m1_v2 §14).
//
//  Card selection and the card line follow PRD v6 §3.6 and §1.7. The times
//  come from ExecTimes. M1-B has only prep and start: with no effort and no
//  attendance, prepStartBy is actBy and prepDeadline is start. EventAssist
//  (M1-C) adds effort, leave, get-ready and join; those phases slot into
//  `Phase`, `rank` and the runway ticks.
//

import Foundation

// MARK: - Next card

struct NextCard: Equatable {

    /// PRD v6 §3.6, in first-match order.
    enum Phase: Equatable {
        case join              // Join now · started 4 min ago
        case onTheWay          // On the way · arrive about 2:58
        case leave             // Leave now · about 4 min late
        case getReady          // Get ready · leave at 2:26
        case prepNow           // Prep now · about 1 h, done by 3:00
        case prepBy            // Start prepping by 2:20 / Prep today / Prep by tomorrow morning
        case leaveBy           // Leave by 2:26 · 14 min walk
        case happeningNow      // Happening now · Room 2
        case startsAt          // Starts at 3:00
    }

    struct Tick: Equatable {
        enum Kind: Equatable { case now, prep, leave, join, start }
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
    /// The smaller second line: the next action after this one, when there is
    /// one within 2 h (PRD v6 §1.7). "Next: Pick up prescription · starts at 5:30"
    var secondary: String? = nil
    /// At most one inline action under the runway (spec v3 §14.8).
    var action: CardAction? = nil

    struct Runway: Equatable {
        let from: Date          // left edge; holds still so the fill advances
        let to: Date            // right edge, just past start for the red cap
        let now: Date
        let prepFrom: Date?     // hatched prep window, nil when no prep
        /// End of the prep window: prepDeadline (get-ready, join-open or start).
        var prepTo: Date? = nil
        /// Get-ready to start for travel events (dotted).
        var travelFrom: Date? = nil
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
            for t in ticks where t.kind == .leave { parts.append("leave at \(HomeFormat.clock(t.date))") }
            for t in ticks where t.kind == .join { parts.append("join at \(HomeFormat.clock(t.date))") }
            parts.append("starts at \(HomeFormat.clock(start))")
            return parts.joined(separator: ", ").capitalizedFirst
        }
    }

    /// The card's line as plain text: "Start prepping by 2:20".
    var line: String { lead + gold + trail }

    /// One element, title then line, as in PRD §3.15 ("Client review, leave by
    /// 2:26, 14 minute walk"), then tier and time so tier is never color alone.
    var accessibilityLabel: String {
        var parts = [title, line.lowercasedFirst, HomeFormat.tierName(urgency),
                     "\(HomeFormat.clock(start)) to \(HomeFormat.clock(end))"]
        if let secondary { parts.append(secondary) }
        return parts.joined(separator: ", ")
    }
}

/// The card's one inline action (spec v3 §14.8): the one that moves the phase
/// forward, else the question this event is waiting on.
enum CardAction: Equatable {
    case imLeaving, imHere, prepDone, join
    /// §7.9: no usable place, looks like travel. Opens a text field; Online and
    /// Not needed are shortcuts.
    case whereIsThis
    /// §7.2: a place and a link, nobody said which.
    case inPersonOrOnline
    /// §7.8: refused or placeholder; Yes = Always Assist, No = No Execution Alerts.
    case isImportant
    /// §7.5: the first trip with a real place and nowhere saved to leave from.
    /// Set up opens Getting there; Not now asks no more.
    case whereFrom

    /// The question for an event, from what's known (pure, tested in HomeChecks).
    /// Phase actions come first in `HomeDayBuilder.card`; this is the fallback.
    static func question(unranked: Bool, modeChosen: Bool, asksAttendance: Bool, assisted: Bool, start: Date, now: Date,
                         hasUsablePlace: Bool, hasLink: Bool, looksLikeTravel: Bool, travelNotNeeded: Bool,
                         needsOrigin: Bool = false) -> CardAction? {
        if unranked && !modeChosen { return .isImportant }
        if asksAttendance { return .inPersonOrOnline }
        if assisted, start > now, start.timeIntervalSince(now) <= 24 * 3600, !hasUsablePlace, !hasLink,
           looksLikeTravel, !travelNotNeeded { return .whereIsThis }
        if needsOrigin, assisted, start > now, start.timeIntervalSince(now) <= 24 * 3600 { return .whereFrom }
        return nil
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
        /// Gets execution help (PRD §1.6): Moderate+ consequence, or the user
        /// said it matters. Only assisted events can be on the card.
        let assisted: Bool
        /// M1-C: the trip-resolved times (TripResolver). nil falls back to
        /// actBy-only times, as in M1-B.
        var exec: ExecTimes? = nil
        var state = PhaseState()
        /// "14 min walk", for the leave-by line.
        var tripPhrase: String? = nil
        var etaSeconds: TimeInterval? = nil
        /// Stale ETA: times say "about".
        var approximate = false
        /// Plus phases (leave-by, get ready, leave, prep timing) show their
        /// time only with Plus; free shows the start (PRD v6 §1.10).
        var hasPlus = true
        /// The question this event is waiting on (CardAction.question).
        var question: CardAction? = nil
    }

    static let runwayHorizon: TimeInterval = 12 * 3600

    static func build(inputs: [Input], now: Date,
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

        let card = pickCard(inputs: inputs, now: now, calendar: calendar)
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
        let prepFrom: Date? = times(e).prepStartBy
            .flatMap { e.start > now ? max($0, now) : nil }
        return RailItem(id: e.id, title: e.title, start: e.start, end: e.end,
                        urgency: e.urgency, isTask: e.isTask, isRecurring: e.isRecurring,
                        prepFrom: prepFrom,
                        isOverdueTask: e.isTask && !e.completed && e.start <= now)
    }

    // MARK: Card

    /// The event's execution times. Until M1-C there's no effort, attendance
    /// or ETA, so only actBy (start − the model's prep lead) feeds in.
    static func times(_ e: Input) -> ExecTimes {
        if let exec = e.exec { return exec }
        let actBy = e.prepHours.flatMap { $0 > 0 ? e.start.addingTimeInterval(-$0 * 3600) : nil }
        return ExecTimes(.init(start: e.start, end: e.end, actBy: actBy, isTask: e.isTask))
    }

    /// Where an event stands right now, for selection and for its line.
    struct Standing {
        let phase: NextCard.Phase
        /// Active phases come first (PRD §3.6). Lower is stronger.
        let activeRank: Int?
        /// For inactive events: the next actionable moment.
        let moment: Date
    }

    /// PRD v6 §3.6, first match wins. nil when done (completed, or past grace),
    /// which drops the event off the card, no guilt.
    static func standing(_ e: Input, now: Date) -> Standing? {
        guard !e.completed, !e.isAllDay, !e.isTask else { return nil }
        let t = times(e)
        switch t.phase(now: now, state: e.state) {
        case .done:
            return nil
        case .join:
            return Standing(phase: .join, activeRank: 0, moment: t.joinOpen)
        case .leave:
            return Standing(phase: .leave, activeRank: 0, moment: t.leaveBy ?? e.start)
        case .onTheWay:
            return Standing(phase: .onTheWay, activeRank: 1, moment: t.leaveBy ?? e.start)
        case .getReady:
            return Standing(phase: .getReady, activeRank: 2, moment: t.getReadyAt ?? e.start)
        case .prepNow:
            // PREP NOW is active only when the deadline is within 12 h;
            // further out it counts as an upcoming moment at deadline − effort.
            let near = t.prepDeadline.timeIntervalSince(now) <= runwayHorizon
            return Standing(phase: .prepNow, activeRank: near ? 3 : nil, moment: t.prepMoment)
        case .prepBy:
            return Standing(phase: .prepBy, activeRank: nil, moment: t.prepStartBy ?? t.prepDeadline)
        case .leaveBy:
            return Standing(phase: .leaveBy, activeRank: nil, moment: t.getReadyAt ?? t.leaveBy ?? e.start)
        case .now:
            return Standing(phase: .happeningNow, activeRank: 4, moment: e.start)
        case .starts:
            return Standing(phase: .startsAt, activeRank: nil, moment: t.isVirtual ? t.joinOpen : e.start)
        }
    }

    /// Ranked candidates: active first (JOIN = LEAVE > ON THE WAY > GET READY >
    /// PREP NOW > NOW), then the earliest upcoming moment, ties to the higher
    /// urgency score. Only assisted events take part.
    static func ranked(_ inputs: [Input], now: Date) -> [(Input, Standing)] {
        inputs.compactMap { e -> (Input, Standing)? in
            guard e.assisted, let s = standing(e, now: now) else { return nil }
            return (e, s)
        }
        .sorted { a, b in
            let (ea, sa) = a, (eb, sb) = b
            switch (sa.activeRank, sb.activeRank) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil) where sa.moment != sb.moment: return sa.moment < sb.moment
            default:
                let (xa, xb) = (ea.scored?.score ?? 0, eb.scored?.score ?? 0)
                return xa != xb ? xa > xb : ea.start < eb.start
            }
        }
    }

    /// The top candidate, with the next one as the secondary line when its
    /// action is within 2 h. Nothing when nothing qualifies: silence is valid.
    private static func pickCard(inputs: [Input], now: Date, calendar: Calendar) -> NextCard? {
        let list = ranked(inputs, now: now)
        guard let (top, standing) = list.first else { return nil }
        var c = card(top, standing: standing, now: now, calendar: calendar)
        if list.count > 1 {
            let (next, ns) = list[1]
            if ns.activeRank != nil || ns.moment.timeIntervalSince(now) <= 2 * 3600 {
                let line = card(next, standing: ns, now: now, calendar: calendar).line
                c.secondary = "Next: \(next.title) · \(line.lowercasedFirst)"
            }
        }
        return c
    }

    static func card(_ e: Input, standing: Standing, now: Date,
                     calendar: Calendar = .current) -> NextCard {
        let urgency = e.scored?.urgency ?? e.urgency
        let t = times(e)
        let prepFrom = t.prepStartBy
        let place = e.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlace = !(place ?? "").isEmpty

        var lead = "", gold = "", trail = ""
        let about = e.approximate ? "about " : ""
        let effort = t.effort == .none ? nil : ExecFormat.duration(t.effort.rawValue)
        // Free: the start instead of a Plus time; prep as a day phrase only.
        var phase = standing.phase
        if !e.hasPlus, [.leave, .getReady, .leaveBy, .onTheWay].contains(phase) {
            phase = now >= e.start ? .happeningNow : .startsAt
        }
        switch phase {
        case .join:
            let late = Int(now.timeIntervalSince(e.start) / 60)
            (lead, gold, trail) = ("Join ", "now", late >= 1 ? " · started \(late) min ago" : "")
        case .leave:
            let late = t.leaveBy.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
            (lead, gold, trail) = ("Leave ", "now", late >= 1 ? " · about \(late) min late" : "")
        case .getReady:
            (lead, gold) = ("Get ready · leave at ", about + HomeFormat.clock(t.leaveBy ?? e.start))
        case .onTheWay:
            let arrive = e.etaSeconds.map { now.addingTimeInterval($0) }
            if let arrive { (lead, gold) = ("On the way · arrive about ", HomeFormat.clock(arrive)) }
            else { (lead, gold) = ("On the way", "") }
        case .leaveBy:
            (lead, gold) = ("Leave by ", about + HomeFormat.clock(t.leaveBy ?? e.start))
            if let trip = e.tripPhrase { trail = " · \(trip)" }
        case .prepNow:
            if !e.hasPlus {
                (lead, gold) = ("Prep due ", "today")
            } else {
                (lead, gold, trail) = ("Prep ", "now", " · \(effort.map { "about \($0), " } ?? "")done by \(HomeFormat.clock(t.prepDeadline))")
            }
        case .prepBy:
            let p = standing.moment
            if e.hasPlus, t.prepDeadline.timeIntervalSince(now) <= runwayHorizon {
                (lead, gold) = ("Start prepping by ", HomeFormat.clock(p))
                if let effort {
                    trail = " · about \(effort)" + (t.getReadyAt.map { ", done before you get ready at \(HomeFormat.clock($0))" } ?? "")
                }
            } else {
                (lead, gold) = HomeFormat.prepLater(p, now: now, calendar: calendar)
                if e.hasPlus, let effort { trail = " · about \(effort)" }
            }
        case .happeningNow:
            (lead, gold) = ("Happening ", "now")
            if hasPlace, let place { trail = " · \(place)" }
        case .startsAt:
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

        // One inline action: the phase's own, else the open question.
        let phaseAction: CardAction? = {
            switch phase {
            case .join: return .join
            case .getReady, .leave: return .imLeaving
            case .onTheWay: return .imHere
            case .prepNow: return e.hasPlus ? .prepDone : nil
            default: return nil
            }
        }()
        return NextCard(eventID: e.id, title: e.title, urgency: urgency,
                        start: e.start, end: e.end, place: e.location,
                        phase: standing.phase, lead: lead, gold: gold, trail: trail,
                        detail: detail,
                        runway: runway(start: e.start, prepFrom: prepFrom, now: now,
                                       prepTo: prepFrom == nil ? nil : t.prepDeadline,
                                       leave: e.hasPlus ? t.leaveBy : nil, travelFrom: e.hasPlus ? t.getReadyAt : nil,
                                       join: t.isVirtual ? t.joinOpen : nil),
                        action: phaseAction ?? e.question)
    }

    /// Ticks only for phases that exist (spec §14.3). M1-B has no leave or join,
    /// so a room event never shows a leave tick.
    static func runway(start: Date, prepFrom: Date?, now: Date, prepTo: Date? = nil,
                       leave: Date? = nil, travelFrom: Date? = nil, join: Date? = nil) -> NextCard.Runway? {
        guard start > now, start.timeIntervalSince(now) <= runwayHorizon else { return nil }

        // The left edge holds still once the clock passes it, so the fill grows.
        let anchor = (prepFrom ?? start).addingTimeInterval(-30 * 60)
        let from = min(now, anchor)
        let to = start.addingTimeInterval(start.timeIntervalSince(from) * 0.05)

        var ticks: [NextCard.Tick] = [.init(kind: .now, date: now)]
        if let p = prepFrom, p > now { ticks.append(.init(kind: .prep, date: p)) }
        // Ticks only for phases that exist: leave for travel, join for virtual.
        if let l = leave, l > now { ticks.append(.init(kind: .leave, date: l)) }
        if let j = join, j > now { ticks.append(.init(kind: .join, date: j)) }
        ticks.append(.init(kind: .start, date: start))

        return NextCard.Runway(from: from, to: to, now: now,
                               prepFrom: prepFrom.map { max($0, from) }, prepTo: prepTo,
                               travelFrom: travelFrom.map { max($0, from) },
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
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Just-in-time asks (PRD v3 §1.11 steps 5 and 6)

/// What home asks once, and when. Notifications come right after first value,
/// with the user's own next event as the example; the calendar-alerts tip
/// comes once, a week after onboarding. One at a time, notifications first.
enum JustInTimeAsk: Equatable {
    case notifications(eventTitle: String?)
    case calendarBackupTip

    static let tipAfter: TimeInterval = 7 * 24 * 3600

    static func next(notificationsUndetermined: Bool, notificationsAsked: Bool, nextEventTitle: String?,
                     onboardedAt: Date?, tipShown: Bool, now: Date) -> JustInTimeAsk? {
        if notificationsUndetermined && !notificationsAsked { return .notifications(eventTitle: nextEventTitle) }
        if !tipShown, let onboardedAt, now.timeIntervalSince(onboardedAt) >= tipAfter { return .calendarBackupTip }
        return nil
    }

    var title: String {
        switch self {
        case .notifications(let t?): return "Want a heads-up before \(t)?"
        case .notifications(nil): return "Want a heads-up before what matters?"
        case .calendarBackupTip: return "Keep your calendar's own alerts on"
        }
    }

    var message: String {
        switch self {
        case .notifications:
            return "Olana reminds you before your events, earlier for the ones that need prep."
        case .calendarBackupTip:
            return "Olana only knows about events once it has synced them. Your calendar's own alerts cover anything added on another device in the meantime."
        }
    }
}
