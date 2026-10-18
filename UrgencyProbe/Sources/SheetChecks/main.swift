//
//  main.swift
//  SheetChecks
//
//  The event sheet (PRD v3 §1.7 Job 4, v2 Job 4 acceptance, v6 §1.10, §3.5,
//  §3.6) and overrides (v3 §3.11). The model files are symlinks into the app.
//  Run: swift run SheetChecks
//

import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     got:", got()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 13))!   // a Tuesday
func at(_ h: Int, _ m: Int, day: Int = 0) -> Date { cal.date(byAdding: .minute, value: (day * 24 + h) * 60 + m, to: base)! }

func assist(_ kind: AssistKind = .appointment, loc: AssistLocationKind = .streetAddress, travel: Bool = true,
            att: AssistAttendance? = .inPerson, effort: Int = 0, helpers: [AssistHelper] = [],
            steps: [String] = [], bring: [String] = [], labels: [String: String] = [:]) -> AssistOutcome {
    .full(AssistResult(source: .model, locationKind: loc, kind: kind, needsTravel: travel, attendance: att,
                       arriveEarlyMinutes: 10, outTheDoorMinutes: 5, effortMinutes: effort, helpers: helpers,
                       steps: steps, bring: bring, linkLabels: labels, dropped: [], version: 1))
}
let dental = ResolvedPlace(name: "Smile Dental", address: "120 W 23rd St", latitude: 40.743, longitude: -73.994,
                           phone: "(212) 555-0100", website: "https://smiledental.example.com")
func input(_ title: String = "Dentist", start: Date = at(15, 0), minutes: Int = 60, now: Date = at(13, 0),
           location: String? = "Smile Dental, 120 W 23rd St", notes: String? = nil, assist a: AssistOutcome? = nil,
           place: ResolvedPlace? = nil, eta: Int? = nil, plus: Bool = true, actBy: Date? = nil) -> SheetInput {
    SheetInput(title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60), location: location,
               facts: NotesCleaner.clean(notes: notes, location: location), assist: a, place: place, actBy: actBy,
               eta: eta.map { ETAFreshness.Effective(seconds: Double($0) * 60, approximate: false) }, hasPlus: plus, now: now, calendar: cal)
}
func kinds(_ c: SheetContent) -> [SheetHelperKind] { c.helpers.map(\.kind) }

// MARK: Helpers with data only, in the model's order

let invite = """
Walk through the Q3 numbers.
Deck: https://docs.google.com/presentation/d/abc/edit
"""
var s = EventSheetBuilder.build(input("Client review", location: "Acme HQ, 500 Market St", notes: invite,
                                      assist: assist(.inPersonMeeting, helpers: [.materials, .leave, .join, .bring],
                                                     bring: ["Printed agenda"], labels: ["L1": "Q3 deck"]),
                                      place: dental, eta: 14))
check("order: the model's, filtered to helpers with data, then the rest",
      kinds(s) == [.materials, .leave, .bring, .place], "\(kinds(s))")
check("materials: the model's label by link ID", s.helpers.first == .materials([SheetMaterial(id: "L1", label: "Q3 deck",
      host: "docs.google.com", url: URL(string: "https://docs.google.com/presentation/d/abc/edit")!)]))
check("no join helper without a meeting link, even when the model lists it", !kinds(s).contains(.join))
check("why line from the kind", s.why == "Because this looks like an in-person meeting")

let noLabels = EventSheetBuilder.build(input(notes: invite, assist: assist()))
if case .materials(let m)? = noLabels.helpers.first(where: { $0.kind == .materials }) {
    check("materials: domain label when the model gave none", m.first?.label == "Google Slides")
} else { check("materials present", false) }

// MARK: Top action from the state machine

check("top: leave-by with Plus and an ETA (start − 14 min − the model's 10 min early)", s.top.line == "Leave by 2:36" && !s.top.locked, s.top.line)
let leaving = EventSheetBuilder.build(input(now: at(14, 37), place: dental, eta: 14))
check("top: LEAVE with lateness and the Directions button, which is the one gold control",
      leaving.top.line == "Leave now · about 6 min late" && leaving.top.button == .directions && leaving.gold == .leave && leaving.goldIsTop,
      "\(leaving.top)")
let free = EventSheetBuilder.build(input(now: at(14, 37), place: dental, eta: 14, plus: false))
check("top: a free user never sees the leave-by time", free.top.locked && free.top.line == "Starts at 3:00" && !free.top.line.contains("2:"),
      free.top.line)
if case .leave(let l)? = free.helpers.first(where: { $0.kind == .leave }) {
    check("leave helper: locked for free, Maps still there", l.locked && l.line == nil && l.appleMaps != nil)
} else { check("leave helper present for free users", false, "\(kinds(free))") }

let zoomNotes = "Join Zoom Meeting\nhttps://us02web.zoom.us/j/81234567890"
let call = EventSheetBuilder.build(input("Recruiter screen", now: at(14, 56), location: nil, notes: zoomNotes,
                                         assist: assist(.videoCall, loc: .virtual, travel: false, att: .virtual)))
check("top: JOIN from 5 min before, with the join button, gold", call.top.line == "Join now"
        && call.top.button == .join(URL(string: "https://us02web.zoom.us/j/81234567890")!) && call.gold == .join, "\(call.top)")
let lateJoin = EventSheetBuilder.build(input("Standup", now: at(15, 4), location: nil, notes: zoomNotes))
check("top: 'started 4 min ago' after the start", lateJoin.top.line == "Join now · started 4 min ago", lateJoin.top.line)
let earlyCall = EventSheetBuilder.build(input("Recruiter screen", now: at(14, 30), location: nil, notes: zoomNotes))
check("join helper is free and not gold half an hour out", kinds(earlyCall).first == .join && earlyCall.gold == nil)
check("a link alone is virtual: no leave helper, no place helper", !kinds(call).contains(.leave) && !kinds(call).contains(.place))

let room = EventSheetBuilder.build(input("Standup", location: "NYC-12-Huddle",
                                         assist: assist(.inPersonMeeting, loc: .roomInBuilding, travel: false, att: nil)))
check("room: no leave helper; place shows the text as written, no maps",
      !kinds(room).contains(.leave) && room.helpers.contains(.place(SheetPlace(name: "NYC-12-Huddle", textOnly: true))), "\(room.helpers)")
check("room: no leave-by in the top line", room.top.line == "Starts at 3:00")

// MARK: Prep (Plus) and the day phrase (free)

let prep = EventSheetBuilder.build(input("Client review", now: at(13, 0), notes: invite,
                                         assist: assist(effort: 60, steps: ["Review the deck"]), actBy: at(13, 30)))
if case .prep(let p)? = prep.helpers.first(where: { $0.kind == .prep }) {
    check("prep: steps, effort and start-by with Plus",
          p.steps.map(\.text) == ["Review the deck"] && p.effort == "about 1 h" && p.timing == "Start by 1:30" && !p.locked, "\(p)")
} else { check("prep helper present", false) }
let prepFree = EventSheetBuilder.build(input("Client review", now: at(13, 0), notes: invite,
                                             assist: assist(effort: 60, steps: ["Review the deck"]), plus: false, actBy: at(13, 30)))
if case .prep(let p)? = prepFree.helpers.first(where: { $0.kind == .prep }) {
    check("prep free: the day phrase only, locked, no effort", p.timing == "Prep today" && p.locked && p.effort == nil, "\(p)")
} else { check("prep helper present for free", false) }
check("top free: PREP BY shows the day phrase", prepFree.top.line == "Prep today" && prepFree.top.locked, prepFree.top.line)
let prepNow = EventSheetBuilder.build(input("Client review", now: at(13, 40), assist: assist(effort: 30), actBy: at(13, 30)))
check("top: PREP NOW with a Prep done button", prepNow.top.line.hasPrefix("Prep now · done by") && prepNow.top.button == .prepDone, prepNow.top.line)
var done = input("Client review", now: at(13, 40), assist: assist(effort: 30), actBy: at(13, 30)); done.state.prepDone = true
check("prep done ends the prep phases", EventSheetBuilder.build(done).top.phase != .prepNow)
let farPrep = EventSheetBuilder.build(input("Thesis defense", start: at(15, 0, day: 2), now: at(13, 0), location: nil, actBy: at(9, 0, day: 1)))
check("top: a deadline beyond 12 h shows a day phrase", farPrep.top.line == "Prep by tomorrow morning", farPrep.top.line)
let noPrep = EventSheetBuilder.build(input(assist: assist()))
check("prep: no prep and no steps, no prep helper", !kinds(noPrep).contains(.prep))

// MARK: Steps and bring: the user's words first, then the model's, overrides win

var withUser = input("Interview", notes: "Review the job post and bring two copies of the resume.",
                     assist: assist(steps: ["Review the job post", "Practice answers", "Read the brief", "Plan the route"],
                                    bring: ["Resume copies"]))
withUser.userSteps = ["Review my portfolio"]
withUser.userBring = ["Insurance card"]
let w = EventSheetBuilder.build(withUser)
if case .prep(let p)? = w.helpers.first(where: { $0.kind == .prep }) {
    check("steps: the user's first, then up to 3 of the model's", p.steps.map(\.text) == ["Review my portfolio", "Review the job post", "Practice answers", "Read the brief"]
          && p.steps[0].fromUser && !p.steps[1].fromUser, "\(p.steps)")
}
check("bring: the user's first, then the model's", w.helpers.contains(.bring(items: ["Insurance card", "Resume copies"], fromUser: true, locked: false)))
withUser.overrides = OverrideResolver.resolve(event: nil, series: OverrideValues(steps: ["Update the doc"], bring: []))
let ov = EventSheetBuilder.build(withUser)
if case .prep(let p)? = ov.helpers.first(where: { $0.kind == .prep }) {
    check("override: saved series steps replace everything", p.steps.map(\.text) == ["Update the doc"])
}
check("override: an emptied bring list hides Bring", !kinds(ov).contains(.bring))
withUser.overrides = OverrideResolver.resolve(event: OverrideValues(hiddenHelpers: ["place"]), series: nil)
check("override: hidden helpers don't render", !kinds(EventSheetBuilder.build(withUser)).contains(.place))
var checked = withUser; checked.overrides = OverrideResolver.resolve(event: nil, series: nil); checked.checkedSteps = ["Practice answers"]
if case .prep(let p)? = EventSheetBuilder.build(checked).helpers.first(where: { $0.kind == .prep }) {
    check("steps: checked state carried", p.steps.first { $0.text == "Practice answers" }?.checked == true)
}

// MARK: Place (free) and partial help

let placed = EventSheetBuilder.build(input(assist: assist(), place: dental))
if case .place(let p)? = placed.helpers.first(where: { $0.kind == .place }) {
    check("place: name, address, phone and the website from Maps",
          p.name == "Smile Dental" && p.phone == "(212) 555-0100" && p.website?.host == "smiledental.example.com" && !p.textOnly)
    check("place: Apple and Google Maps directions to the coordinate",
          p.appleMaps?.absoluteString.contains("daddr=40.743,-73.994") == true && p.googleMaps?.scheme == "comgooglemaps")
}
let basic = EventSheetBuilder.build(input(notes: zoomNotes + "\nDeck https://figma.com/file/x", assist: .basic(.fallback(locationKind: .streetAddress, needsTravel: true)), place: dental))
check("basic help: tagged, fixed order: top action (join), Materials, Place", basic.tag == "Basic help"
        && Array(kinds(basic).prefix(3)) == [.join, .materials, .place], "\(kinds(basic))")
check("basic help: no why line", basic.why == nil)
let failed = EventSheetBuilder.build(input(assist: AssistOutcome.none))
check("both failed: 'Basic help', no leave-by", failed.tag == "Basic help" && !kinds(failed).contains(.leave), "\(kinds(failed))")
let loading = EventSheetBuilder.build(input(assist: nil))
check("not run yet: no tag", loading.tag == nil)

// MARK: Is this important? and assist modes

var unranked = input("Court date", assist: AssistOutcome.none); unranked.unranked = true
check("unranked: asks 'Is this important?' once", EventSheetBuilder.build(unranked).asksImportant)
unranked.overrides = OverrideResolver.resolve(event: OverrideValues(assistMode: .always, version: 1), series: nil)
check("unranked: answered, not asked again", !EventSheetBuilder.build(unranked).asksImportant)
check("assist mode from overrides", EventSheetBuilder.build(unranked).assistMode == .always)

// MARK: Overrides (PRD v3 §3.11)

let ser = OverrideValues(assistMode: .noAlerts, steps: ["Series step"], bring: ["Series item"], origin: "work", version: 3)
let evt = OverrideValues(steps: ["Event step"], travelMode: "walking", version: 2)
let eff = OverrideResolver.resolve(event: evt, series: ser)
check("precedence: event > series per field", eff.steps == ["Event step"] && eff.bring == ["Series item"]
        && eff.assistMode == .noAlerts && eff.origin == "work" && eff.travelMode == "walking")
check("precedence: scopes recorded", eff.stepsScope == .event && eff.bringScope == .series)
check("versions: series then event, for cache keys", eff.versions == [3, 2])
check("default mode is Normal", OverrideResolver.resolve(event: nil, series: nil).assistMode == .normal)
let moved = OverrideKeys.event(source: "google", sourceID: "abc_20261013", iCalUID: "uid1", localID: UUID(),
                               occurrenceStart: at(9, 0), start: at(11, 0))
check("keys: an occurrence moved at the source keeps its key (original start)",
      moved == OverrideKeys.event(source: "google", sourceID: "abc_20261013", iCalUID: "uid1", localID: UUID(),
                                  occurrenceStart: at(9, 0), start: at(14, 0)))
check("keys: Google series by recurringEventId",
      OverrideKeys.series(source: "google", seriesID: "rec1", iCalUID: "uid1", isRecurring: true, title: "1:1", rule: "0") == "google|series|rec1")
check("keys: a one-off synced event has no series",
      OverrideKeys.series(source: "apple", seriesID: nil, iCalUID: "uid2", isRecurring: false, title: "Lunch", rule: "0") == nil)
check("keys: native repeating events key on title and rule",
      OverrideKeys.series(source: nil, seriesID: nil, iCalUID: nil, isRecurring: true, title: "Gym", rule: "2") == "native|series|gym|2")

// MARK: Plus (PRD v6 §1.10)

var plus = PlusState()
check("plus: the preview starts unlocked", PlusRules.hasPlus(plus, gatePassed: true) && PlusRules.inPreview(plus))
check("plus: never sold or unlocked without Apple Intelligence", !PlusRules.hasPlus(plus, gatePassed: false))
var ended = false
for (i, k) in [PlusMomentKind.leftOnTime, .prepStarted, .leftOnTime, .bringUsed, .gotReady].enumerated() {
    (plus, ended) = PlusRules.record(PlusMoment(kind: k, eventKey: "e\(i)", at: at(9, i)), in: plus)
    if i < 4 { check("plus: moment \(i + 1) doesn't end the preview", !ended) }
}
check("plus: the 5th moment ends the preview and locks", ended && !PlusRules.hasPlus(plus, gatePassed: true))
check("plus: summary says what Plus did", PlusRules.summary(plus) == ["Got you out the door 3 times", "Got prep started once", "Had your things ready once"],
      "\(PlusRules.summary(plus))")
var dup = PlusState()
(dup, _) = PlusRules.record(PlusMoment(kind: .prepStarted, eventKey: "a", at: at(9, 0)), in: dup)
(dup, _) = PlusRules.record(PlusMoment(kind: .prepStarted, eventKey: "a", at: at(9, 5)), in: dup)
check("plus: the same moment on the same event counts once", dup.moments.count == 1)
var door = plus; door.fakeDoorAt = at(10, 0)
check("plus: the beta fake door unlocks", PlusRules.hasPlus(door, gatePassed: true))
check("plus: after the preview, more moments aren't recorded", PlusRules.record(PlusMoment(kind: .alarm, eventKey: "z", at: at(11, 0)), in: plus).0 == plus)
check("gate: reasons map to screens", IntelligenceGate.from(reason: nil) == .available
        && IntelligenceGate.from(reason: "appleIntelligenceNotEnabled") == .turnedOff
        && IntelligenceGate.from(reason: "modelNotReady") == .downloading
        && IntelligenceGate.from(reason: "deviceNotEligible") == .notEligible)
check("gate: never sell to a device that fails it", !IntelligenceGate.notEligible.canSellPlus && !IntelligenceGate.turnedOff.canSellPlus
        && IntelligenceGate.downloading.canSellPlus)

// MARK: Formatting

check("day phrase: same day, tomorrow by part of day, then weekday",
      EventSheetBuilder.dayPhrase(at(18, 0), now: at(9, 0), calendar: cal) == "Prep today"
        && EventSheetBuilder.dayPhrase(at(14, 0, day: 1), now: at(9, 0), calendar: cal) == "Prep by tomorrow afternoon"
        && EventSheetBuilder.dayPhrase(at(9, 0, day: 2), now: at(9, 0), calendar: cal) == "Prep by Thursday")
check("durations", EventSheetBuilder.duration(30) == "30 min" && EventSheetBuilder.duration(120) == "2 h" && EventSheetBuilder.duration(90) == "1 h 30 min")

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
