//
//  EventSheetModel.swift
//  Olana
//
//  What the event sheet shows (PRD v3 §1.7 Job 4, v2 §1.7 Job 4, v6 §1.10, §3.5
//  partial help, §3.6). Pure: one snapshot in, one description out, so every
//  rule here is checked in SheetChecks.
//
//  - The top action is always the state machine's. The model orders only the
//    helpers below it; with no model answer the order is fixed.
//  - A helper with no data never renders. At most one gold button.
//  - Free: Join, Materials, Place, the day-phrase prep line. Plus: leave-by,
//    prep start-by and steps, effort, the bring list. A locked helper says what
//    Plus would add, never the time itself.
//

import Foundation

enum SheetHelperKind: String, CaseIterable, Codable {
    case join, leave, prep, materials, bring, place

    init(_ h: AssistHelper) {
        switch h {
        case .join: self = .join
        case .leave: self = .leave
        case .prep: self = .prep
        case .materials: self = .materials
        case .bring: self = .bring
        case .place: self = .place
        }
    }
}

struct SheetMaterial: Equatable, Hashable {
    let id: String
    let label: String
    let host: String
    let url: URL
}

struct SheetStep: Equatable, Hashable {
    let text: String
    /// The user wrote it (message, saved steps) or the model did (from notes).
    let fromUser: Bool
    var checked: Bool
}

enum SheetHelper: Equatable {
    case join(url: URL, service: String)
    case materials([SheetMaterial])
    /// Items, whether the user wrote any, and whether they're locked (Plus).
    case bring(items: [String], fromUser: Bool, locked: Bool)
    case place(SheetPlace)
    case prep(SheetPrep)
    case leave(SheetLeave)

    var kind: SheetHelperKind {
        switch self {
        case .join: return .join
        case .materials: return .materials
        case .bring: return .bring
        case .place: return .place
        case .prep: return .prep
        case .leave: return .leave
        }
    }
}

struct SheetPlace: Equatable {
    var name: String
    var address: String?
    /// From Apple Maps only (phone guard, PRD v3 §3.8). Labeled "Website".
    var website: URL?
    var phone: String?
    var appleMaps: URL?
    var googleMaps: URL?
    /// Rooms and unclear locations show the text as written, no map links.
    var textOnly: Bool
}

struct SheetPrep: Equatable {
    var steps: [SheetStep]
    /// "about 30 min" (Plus).
    var effort: String?
    /// "Start by 1:00" (Plus) or a day phrase ("Prep today", free).
    var timing: String?
    var locked: Bool
    var done: Bool
}

struct SheetLeave: Equatable {
    /// "Leave by 2:26" when the ETA is known and Plus is on.
    var line: String?
    var locked: Bool
    var appleMaps: URL?
    var googleMaps: URL?
}

struct SheetTopAction: Equatable {
    enum Button: Equatable { case join(URL), directions, imLeaving, imHere, prepDone }
    var phase: ExecPhase
    var line: String
    var button: Button?
    /// Plus phases shown to a free user: the line says what Plus adds.
    var locked: Bool
}

struct SheetContent: Equatable {
    var top: SheetTopAction
    var helpers: [SheetHelper]
    /// The one gold control: the top action's button, or Join near the start.
    var gold: SheetHelperKind?
    var goldIsTop: Bool
    /// "Because this looks like an appointment" (PRD v2 §3.8 why line).
    var why: String?
    /// "Basic help" when the model's full answer isn't available (§3.5).
    var tag: String?
    /// Unranked events ask once, "Is this important?" (PRD v3 §1.6).
    var asksImportant: Bool
    var assistMode: AssistMode
}

struct SheetInput {
    var title: String
    var start: Date
    var end: Date
    var isTask = false
    var isRecurring = false
    var location: String?
    var facts: EventFacts = .empty
    /// The event's own meeting link (native: typed; synced: conferenceData).
    var meetingURL: URL?
    var assist: AssistOutcome?
    var overrides = OverrideResolver.resolve(event: nil, series: nil)
    /// From the add-box message (capture).
    var userSteps: [String] = []
    var userBring: [String] = []
    var arriveEarlyMinutes: Int?
    var attendance: AssistAttendance?
    var place: ResolvedPlace?
    /// start − the model's prep lead, nil when none.
    var actBy: Date?
    /// Travel time in seconds when known (M1-C ETA).
    var eta: TimeInterval?
    var checkedSteps: Set<String> = []
    var state = PhaseState()
    var unranked = false
    var hasPlus = false
    var now: Date
    var calendar: Calendar = .current
}

enum EventSheetBuilder {
    static let defaultOrder: [SheetHelperKind] = [.join, .leave, .prep, .materials, .bring, .place]
    static let maxModelSteps = 3
    static let maxModelBring = 4

    static func build(_ i: SheetInput) -> SheetContent {
        let result = assistResult(i.assist)
        let meeting = i.meetingURL ?? i.facts.meetingURL
        let locationKind = result?.locationKind
        let geocodable = i.place != nil || locationKind == .streetAddress || locationKind == .namedPlace
        let isRoomish = locationKind == .roomInBuilding || locationKind == .unclear || locationKind == .virtual

        // Attendance (PRD v6 §3.4): a link alone is virtual, a place alone is in person.
        let attendance: AssistAttendance? = {
            if let a = i.attendance { return a }
            if meeting != nil && !geocodable { return .virtual }
            if meeting == nil && geocodable { return .inPerson }
            return result?.attendance
        }()
        let needsTravel = !i.isTask && attendance != .virtual && geocodable && !isRoomish
            && (result?.needsTravel ?? (i.place != nil))

        let effort = PrepEffort(rawValue: result?.effortMinutes ?? 0) ?? .none
        let times = ExecTimes(.init(start: i.start, end: i.end, actBy: i.actBy, effort: effort,
                                    attendance: attendance == .virtual ? .virtual : (attendance == .inPerson ? .inPerson : .none),
                                    hasMeetingLink: meeting != nil, needsTravel: needsTravel, eta: i.eta,
                                    arriveEarly: TimeInterval((i.overrides.arriveEarlyMinutes ?? i.arriveEarlyMinutes
                                                               ?? result?.arriveEarlyMinutes ?? 15) * 60),
                                    outTheDoor: TimeInterval((result?.outTheDoorMinutes ?? 5) * 60), isTask: i.isTask))
        let phase = times.phase(now: i.now, state: i.state)

        // Helpers with data.
        var available: [SheetHelperKind: SheetHelper] = [:]
        if let meeting { available[.join] = .join(url: meeting, service: i.facts.meetingService?.name ?? MeetingLinks.service(of: meeting)?.name ?? "meeting") }

        let materials = i.facts.links.map { l in
            SheetMaterial(id: l.id, label: result?.linkLabels[l.id] ?? l.domainLabel, host: l.host, url: l.url)
        }
        if !materials.isEmpty { available[.materials] = .materials(materials) }

        let (bring, bringFromUser) = bringItems(i, result: result)
        if !bring.isEmpty { available[.bring] = .bring(items: bring, fromUser: bringFromUser, locked: !i.hasPlus) }

        if let p = placeHelper(i, kind: locationKind, isRoomish: isRoomish) { available[.place] = .place(p) }

        let steps = stepItems(i, result: result)
        if times.hasPrep || !steps.isEmpty {
            available[.prep] = .prep(SheetPrep(
                steps: steps,
                effort: i.hasPlus && effort != .none ? "about \(duration(effort.rawValue))" : nil,
                timing: prepTiming(times, i: i),
                locked: !i.hasPlus,
                done: i.state.prepDone))
        }

        if needsTravel {
            let (apple, google) = mapsLinks(i)
            available[.leave] = .leave(SheetLeave(
                line: i.hasPlus ? times.leaveBy.map { "Leave by \(clock($0, i.calendar))" } : nil,
                locked: !i.hasPlus, appleMaps: apple, googleMaps: google))
        }

        // Order: the model's, filtered to helpers with data, then the rest in the
        // default order. Without a full answer, the fixed order (§3.5).
        let hidden = Set(i.overrides.hiddenHelpers.compactMap(SheetHelperKind.init(rawValue:)))
        var order: [SheetHelperKind]
        if let r = result, r.source == .model, !r.helpers.isEmpty {
            order = r.helpers.map(SheetHelperKind.init)
            for k in defaultOrder where !order.contains(k) { order.append(k) }
        } else {
            let topKind: SheetHelperKind? = meeting != nil ? .join : (needsTravel ? .leave : nil)
            order = (topKind.map { [$0] } ?? []) + [.materials, .place]
            for k in defaultOrder where !order.contains(k) { order.append(k) }
        }
        let helpers = order.filter { !hidden.contains($0) }.compactMap { available[$0] }

        let top = topAction(phase, times: times, meeting: meeting, i: i)
        // One gold control: the top action's button when it's join or leave,
        // otherwise Join within 2 minutes of the start (PRD v2 §1.7).
        var gold: SheetHelperKind?
        var goldIsTop = false
        switch top.button {
        case .join?: gold = .join; goldIsTop = true
        case .directions?: gold = .leave; goldIsTop = true
        default:
            if meeting != nil, i.start.timeIntervalSince(i.now) <= 120, phase != .done { gold = .join }
        }

        let tag: String? = {
            switch i.assist {
            case .basic?, .none?: return "Basic help"
            default: return nil
            }
        }()

        return SheetContent(top: top, helpers: helpers, gold: gold, goldIsTop: goldIsTop,
                            why: result?.source == .model ? why(result?.kind) : nil, tag: tag,
                            asksImportant: i.unranked && i.overrides.assistMode == .normal && i.overrides.versions == [0, 0],
                            assistMode: i.overrides.assistMode)
    }

    // MARK: Pieces

    static func assistResult(_ o: AssistOutcome?) -> AssistResult? {
        switch o {
        case .full(let r)?, .basic(let r)?: return r
        default: return nil
        }
    }

    /// The user's list wins when saved; otherwise the user's own items, then the model's.
    static func bringItems(_ i: SheetInput, result: AssistResult?) -> ([String], Bool) {
        if let saved = i.overrides.bring { return (saved, true) }
        var out = i.userBring
        for b in (result?.bring ?? []).prefix(maxModelBring) where !out.contains(where: { $0.lowercased() == b.lowercased() }) {
            out.append(b)
        }
        return (out, !i.userBring.isEmpty)
    }

    static func stepItems(_ i: SheetInput, result: AssistResult?) -> [SheetStep] {
        if let saved = i.overrides.steps {
            return saved.map { SheetStep(text: $0, fromUser: true, checked: i.checkedSteps.contains($0)) }
        }
        var out = i.userSteps.map { SheetStep(text: $0, fromUser: true, checked: i.checkedSteps.contains($0)) }
        for s in (result?.steps ?? []).prefix(maxModelSteps) where !out.contains(where: { $0.text.lowercased() == s.lowercased() }) {
            out.append(SheetStep(text: s, fromUser: false, checked: i.checkedSteps.contains(s)))
        }
        return out
    }

    static func placeHelper(_ i: SheetInput, kind: AssistLocationKind?, isRoomish: Bool) -> SheetPlace? {
        if let p = i.place {
            let (apple, google) = mapsLinks(i)
            return SheetPlace(name: p.name, address: p.address, website: p.website.flatMap(URL.init(string:)).flatMap(URLGuard.validate),
                              phone: p.phone, appleMaps: apple, googleMaps: google, textOnly: false)
        }
        guard let text = i.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              MeetingLinks.service(of: URL(string: text) ?? URL(fileURLWithPath: "/")) == nil,
              !text.lowercased().hasPrefix("http") else { return nil }
        if isRoomish || kind == nil || kind == AssistLocationKind.none {
            return SheetPlace(name: text, textOnly: true)
        }
        let (apple, google) = mapsLinks(i)
        return SheetPlace(name: text, appleMaps: apple, googleMaps: google, textOnly: false)
    }

    /// Apple Maps and Google Maps directions (PRD v3 §1.7 Job 3: Maps handoff).
    static func mapsLinks(_ i: SheetInput) -> (URL?, URL?) {
        let dest: String
        if let p = i.place { dest = "\(p.latitude),\(p.longitude)" }
        else if let l = i.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { dest = l }
        else { return (nil, nil) }
        var a = URLComponents(string: "https://maps.apple.com/")!
        a.queryItems = [URLQueryItem(name: "daddr", value: dest)]
        if let p = i.place { a.queryItems?.append(URLQueryItem(name: "q", value: p.name)) }
        var g = URLComponents(string: "comgooglemaps://")!
        g.queryItems = [URLQueryItem(name: "daddr", value: dest)]
        return (a.url, g.url)
    }

    static func prepTiming(_ t: ExecTimes, i: SheetInput) -> String? {
        guard let startBy = t.prepStartBy, i.now < t.prepDeadline, !i.state.prepDone else { return nil }
        // Free users get the day phrase only (PRD v6 §1.10).
        if !i.hasPlus || t.prepDeadline.timeIntervalSince(i.now) > 12 * 3600 {
            return dayPhrase(startBy, now: i.now, calendar: i.calendar)
        }
        return i.now >= startBy ? "Prep now · done by \(clock(t.prepDeadline, i.calendar))"
                                : "Start by \(clock(startBy, i.calendar))"
    }

    static func topAction(_ phase: ExecPhase, times t: ExecTimes, meeting: URL?, i: SheetInput) -> SheetTopAction {
        let cal = i.calendar
        let plus = i.hasPlus
        switch phase {
        case .done:
            return SheetTopAction(phase: phase, line: i.state.finished ? "Done" : "Ended", button: nil, locked: false)
        case .join:
            let late = Int(i.now.timeIntervalSince(i.start) / 60)
            let line = late >= 1 ? "Join now · started \(late) min ago" : "Join now"
            return SheetTopAction(phase: phase, line: line, button: meeting.map { .join($0) }, locked: false)
        case .onTheWay:
            let arrive = i.eta.map { i.now.addingTimeInterval($0) }
            return SheetTopAction(phase: phase, line: arrive.map { "On the way · arrive about \(clock($0, cal))" } ?? "On the way",
                                  button: .imHere, locked: false)
        case .leave(let late):
            guard plus else { return lockedStart(i) }
            return SheetTopAction(phase: phase, line: late > 0 ? "Leave now · about \(late) min late" : "Leave now",
                                  button: .directions, locked: false)
        case .getReady:
            guard plus, let leaveBy = t.leaveBy else { return lockedStart(i) }
            return SheetTopAction(phase: phase, line: "Get ready · leave at \(clock(leaveBy, cal))", button: .imLeaving, locked: false)
        case .prepNow:
            guard plus else { return SheetTopAction(phase: phase, line: "Prep due today", button: .prepDone, locked: true) }
            return SheetTopAction(phase: phase, line: "Prep now · done by \(clock(t.prepDeadline, cal))", button: .prepDone, locked: false)
        case .prepBy:
            let startBy = t.prepStartBy ?? t.prepDeadline
            guard plus else { return SheetTopAction(phase: phase, line: dayPhrase(startBy, now: i.now, calendar: cal), button: nil, locked: true) }
            let line = t.prepDeadline.timeIntervalSince(i.now) <= 12 * 3600
                ? "Start prepping by \(clock(startBy, cal))" : dayPhrase(startBy, now: i.now, calendar: cal)
            return SheetTopAction(phase: phase, line: line, button: nil, locked: false)
        case .leaveBy:
            guard plus, let leaveBy = t.leaveBy else { return lockedStart(i) }
            return SheetTopAction(phase: phase, line: "Leave by \(clock(leaveBy, cal))", button: nil, locked: false)
        case .now:
            let place = i.location.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            return SheetTopAction(phase: phase, line: "Happening now\(place)", button: nil, locked: false)
        case .starts:
            let line = cal.isDate(i.start, inSameDayAs: i.now) ? "Starts at \(clock(i.start, cal))"
                : "Starts \(dayName(i.start, now: i.now, calendar: cal)) \(clock(i.start, cal))"
            return SheetTopAction(phase: phase, line: line, button: nil, locked: false)
        }
    }

    /// A Plus phase for a free user: the start time, and that leave-by is Plus.
    /// Never the leave-by time itself (PRD v6 §1.10 locked state).
    static func lockedStart(_ i: SheetInput) -> SheetTopAction {
        let line = i.calendar.isDate(i.start, inSameDayAs: i.now) ? "Starts at \(clock(i.start, i.calendar))"
            : "Starts \(dayName(i.start, now: i.now, calendar: i.calendar)) \(clock(i.start, i.calendar))"
        return SheetTopAction(phase: .starts, line: line, button: nil, locked: true)
    }

    static func why(_ kind: AssistKind?) -> String? {
        guard let kind else { return nil }
        let phrase: String
        switch kind {
        case .inPersonMeeting: phrase = "an in-person meeting"
        case .videoCall: phrase = "a video call"
        case .phoneCall: phrase = "a phone call"
        case .appointment: phrase = "an appointment"
        case .workout: phrase = "a workout"
        case .errand: phrase = "an errand"
        case .social: phrase = "plans with people"
        case .travel: phrase = "travel"
        case .classSession: phrase = "a class"
        case .deadline: phrase = "a deadline"
        case .focus: phrase = "focus time"
        case .other: return nil
        }
        return "Because this looks like \(phrase)"
    }

    // MARK: Formatting

    static func clock(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        return String(format: "%d:%02d", h, c.minute ?? 0)
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }

    static func dayName(_ d: Date, now: Date, calendar cal: Calendar) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow" }
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    /// "Prep today", "Prep by tomorrow morning", "Prep by Thursday".
    static func dayPhrase(_ d: Date, now: Date, calendar cal: Calendar) -> String {
        if cal.isDate(d, inSameDayAs: now) || d <= now { return "Prep today" }
        let hour = cal.component(.hour, from: d)
        let part = hour < 12 ? "morning" : (hour < 17 ? "afternoon" : "evening")
        let day = dayName(d, now: now, calendar: cal)
        return day == "tomorrow" ? "Prep by tomorrow \(part)" : "Prep by \(day)"
    }
}
