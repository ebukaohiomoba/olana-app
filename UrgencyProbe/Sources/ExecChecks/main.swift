//
//  main.swift
//  ExecChecks
//
//  M1-C's pure core against spec v3 §7 and §11.2 (B1–B16) and PRD v6 §3.9:
//  origin, ETA freshness, the trip resolver and the execution alert planner.
//  The files are symlinks into the app.
//  Run: swift run ExecChecks
//

import Foundation
import CoreLocation

var failures = 0
func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     got:", got()) }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 13))!   // a Tuesday
func at(_ h: Int, _ m: Int, day: Int = 0) -> Date { cal.date(byAdding: .minute, value: (day * 24 + h) * 60 + m, to: base)! }
func coord(_ a: Double, _ b: Double) -> CLLocationCoordinate2D { .init(latitude: a, longitude: b) }
func place(_ n: String) -> ResolvedPlace { ResolvedPlace(name: n, address: nil, latitude: 40.74, longitude: -73.99, phone: nil, website: nil) }

// MARK: Origin (spec §7.5)

let home = place("Home"), work = place("Work")
let hours = WorkHours()
let acme = OriginPicker.Earlier(name: "Acme", end: at(13, 30), coordinate: coord(40.75, -73.98))
check("origin: the previous event's place when it ends within 3 h",
      OriginPicker.pick(start: at(15, 0), earlier: [acme], home: home, work: work, workHours: hours, calendar: cal)?.source == .previousEvent)
check("origin: not after 3 h; work inside work hours",
      OriginPicker.pick(start: at(16, 45), earlier: [acme], home: home, work: work, workHours: hours, calendar: cal)?.source == .work)
check("origin: work needs work hours set",
      OriginPicker.pick(start: at(15, 0), earlier: [], home: home, work: work, workHours: nil, calendar: cal)?.source == .home)
check("origin: outside work hours, home",
      OriginPicker.pick(start: at(19, 0), earlier: [], home: home, work: work, workHours: hours, calendar: cal)?.source == .home)
check("origin: weekend isn't work", OriginPicker.pick(start: at(11, 0, day: 4), earlier: [], home: home, work: work,
                                                       workHours: hours, calendar: cal)?.source == .home)
check("origin: nothing set, none ('Set where you leave from')",
      OriginPicker.pick(start: at(15, 0), earlier: [], home: nil, work: nil, workHours: nil, calendar: cal) == nil)
let overlapA = OriginPicker.Earlier(name: "A", end: at(14, 0), coordinate: coord(1, 1))
let overlapB = OriginPicker.Earlier(name: "B", end: at(14, 50), coordinate: coord(2, 2))
check("origin: overlapping earlier events, the one ending latest",
      OriginPicker.pick(start: at(15, 0), earlier: [overlapA, overlapB], home: nil, work: nil, workHours: nil, calendar: cal)?.name == "B")
let fix = Origin(source: .override, name: "Gym", coordinate: coord(3, 3))
check("origin: the user's correction wins (B15)",
      OriginPicker.pick(start: at(15, 0), earlier: [acme], home: home, work: work, workHours: hours, override: fix, calendar: cal) == fix)

// MARK: ETA freshness (spec §7.6)

let fresh = ETAReading(seconds: 14 * 60, fetchedAt: at(11, 0))
check("eta: fresh reading used as is", ETAFreshness.effective(fresh, start: at(15, 0), now: at(11, 30))
        == .init(seconds: 14 * 60, approximate: false))
check("eta: under 45 min to leave, stale after 10 min: padded 10%, at least 5 min, with 'about' (B2)",
      ETAFreshness.effective(fresh, start: at(15, 0), now: at(14, 20)) == .init(seconds: 19 * 60, approximate: true))
check("eta: padding capped at 20 min", ETAFreshness.padded(5 * 3600) == 5 * 3600 + 20 * 60)
check("eta: over 6 h old is unusable: no leave-by, no leave alert (floor untouched)",
      ETAFreshness.effective(fresh, start: at(19, 0), now: at(17, 1)) == nil)
check("eta: refresh tiers by time until leave-by",
      ETAFreshness.staleAfter(untilLeave: 4 * 3600) == 6 * 3600 && ETAFreshness.staleAfter(untilLeave: 2 * 3600) == 3600
        && ETAFreshness.staleAfter(untilLeave: 30 * 60) == 600)
check("eta: needs refresh when missing or stale",
      ETAFreshness.needsRefresh(nil, leaveBy: nil, now: at(9, 0))
        && !ETAFreshness.needsRefresh(fresh, leaveBy: at(14, 31), now: at(11, 30))
        && ETAFreshness.needsRefresh(fresh, leaveBy: at(14, 31), now: at(14, 15)))
check("eta: over 4 h is 'Plan travel'", ETAFreshness.isPlanTravel(4.5 * 3600) && !ETAFreshness.isPlanTravel(3 * 3600))
check("eta: phrase", ETAFreshness.phrase(14 * 60, mode: .walking) == "14 min walk" && ETAFreshness.phrase(65 * 60, mode: .driving) == "1 h 5 min drive")
check("eta: cache key rounds to ~100 m and includes mode",
      ETAFreshness.cacheKey(from: coord(40.74001, -73.99), to: coord(40.75, -73.98), mode: .walking)
        == ETAFreshness.cacheKey(from: coord(40.74004, -73.99003), to: coord(40.75, -73.98), mode: .walking)
        && ETAFreshness.cacheKey(from: coord(40.74, -73.99), to: coord(40.75, -73.98), mode: .driving)
        != ETAFreshness.cacheKey(from: coord(40.74, -73.99), to: coord(40.75, -73.98), mode: .walking))

// MARK: Trip resolver (spec §7.1–7.2)

func assist(_ loc: AssistLocationKind = .streetAddress, travel: Bool = true, att: AssistAttendance? = .inPerson,
            early: Int = 15, door: Int = 10, effort: Int = 0) -> AssistResult {
    AssistResult(source: .model, locationKind: loc, kind: .appointment, needsTravel: travel, attendance: att,
                 arriveEarlyMinutes: early, outTheDoorMinutes: door, effortMinutes: effort, helpers: [], steps: [], bring: [],
                 linkLabels: [:], dropped: [], version: 1)
}
let walk14 = ETAFreshness.Effective(seconds: 14 * 60, approximate: false)
let b1 = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "500 Market St", assist: assist(),
                                         place: place("Acme"), eta: walk14))
check("B1: get-ready 2:21, leave 2:31 (ETA 14, arrive early 15, out the door 10)",
      b1.times.getReadyAt == at(14, 21) && b1.times.leaveBy == at(14, 31) && b1.times.isTravel, "\(b1.times)")
let zoom = URL(string: "https://zoom.us/j/1234567")!
let virt = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), meetingURL: zoom, assist: assist(.virtual, travel: false, att: .virtual)))
check("attendance: a link alone is virtual; JOIN times, no travel", virt.attendance == .virtual && virt.times.isVirtual && !virt.needsTravel)
let hybrid = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "Acme HQ", meetingURL: zoom,
                                             assist: assist(att: .unsure), place: place("Acme"), eta: walk14))
check("attendance: place and link with the model unsure asks once (B12)", hybrid.asksAttendance && hybrid.attendance == .unsure && !hybrid.times.isTravel)
let answered = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "Acme HQ", meetingURL: zoom,
                                               assist: assist(att: .unsure), attendanceAnswer: .inPerson, place: place("Acme"), eta: walk14))
check("attendance: the user's answer is used and not asked again", !answered.asksAttendance && answered.times.isTravel)
let room = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "NYC-12-Huddle",
                                           assist: assist(.roomInBuilding, travel: false, att: nil), eta: walk14))
check("B3: a room has no leave-by", room.times.leaveBy == nil && !room.needsTravel && room.roomish)
let far = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "1 Main St, Austin", assist: assist(),
                                          place: place("Austin"), eta: .init(seconds: 5 * 3600, approximate: false)))
check("over 4 h of travel: 'Plan travel', no leave-by", far.planTravel && far.times.leaveBy == nil)
let typed = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "Smile Dental", assist: assist(early: 5),
                                            place: place("Smile"), eta: walk14, arriveEarlyOverride: nil, arriveEarlyTyped: 10))
check("buffers: typed arrive-early beats the model", typed.arriveEarlyMinutes == 10 && typed.times.leaveBy == at(14, 36))
let fb = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "500 Market St",
                                         assist: .fallback(locationKind: .streetAddress, needsTravel: true), place: place("Acme"), eta: walk14))
check("B8: fallback uses default buffers 15 / 5 and no effort",
      fb.arriveEarlyMinutes == 15 && fb.outTheDoorMinutes == 5 && fb.times.effort == .none && fb.times.leaveBy == at(14, 31))
let noETA = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "500 Market St", assist: assist(), place: place("Acme")))
check("no ETA: needs travel but no leave-by yet", noETA.needsTravel && noETA.times.leaveBy == nil)
let task = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), isTask: true, location: "500 Market St", assist: assist(),
                                           place: place("Acme"), eta: walk14))
check("a task never travels", !task.needsTravel && task.times.leaveBy == nil)

// MARK: Execution alerts (spec §7.7, PRD §3.9)

func ev(_ trip: TripFacts, critical: Bool = true, moderate: Bool = true, mode: AssistMode = .normal, unranked: Bool = false,
        progress: EventProgress = .init(), bring: [String] = [], eta: Int? = 14) -> ExecEvent {
    ExecEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Client review", times: trip.times,
              urgencyRaw: 2, critical: critical, moderatePlus: moderate, mode: mode, unranked: unranked,
              outTheDoorMinutes: trip.outTheDoorMinutes, etaSeconds: eta.map { Double($0) * 60 }, travelMode: .walking,
              bring: bring, progress: progress)
}
let s = ExecSettings()
let b1Slots = ExecutionPlanner.slots(ev(b1, bring: ["Laptop"]), settings: s, now: at(11, 0), calendar: cal)
check("B1: get-ready at 2:21 and leave at 2:31",
      b1Slots.map(\.fireDate) == [at(14, 21), at(14, 31)], "\(b1Slots.map { ($0.fireDate, $0.body) })")
check("copy: 'Get ready · leave at 2:31 · bring laptop' and 'Leave now · 14 min walk'",
      b1Slots.map(\.body) == ["Get ready · leave at 2:31 · bring laptop", "Leave now · 14 min walk"], "\(b1Slots.map(\.body))")
check("ids: execution namespace with a planVersion, priority for Critical",
      b1Slots.allSatisfy { AlertID.isPlannedExec($0.id) && $0.kind == .exec && $0.priority })
let door5 = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "x", assist: assist(door: 5), place: place("Acme"), eta: walk14))
check("get-ready only when out the door ≥ 10 min",
      ExecutionPlanner.slots(ev(door5), settings: s, now: at(11, 0), calendar: cal).map(\.body) == ["Leave now · 14 min walk"])

let moderate = ExecutionPlanner.slots(ev(b1, critical: false), settings: s, now: at(11, 0), calendar: cal)
check("Moderate+ below Critical: travel alerts only", moderate.count == 2)
let moderateVirtual = ExecutionPlanner.slots(ev(virt, critical: false), settings: s, now: at(11, 0), calendar: cal)
check("Moderate+ below Critical: no join, no prep", moderateVirtual.isEmpty)
check("Minor: nothing", ExecutionPlanner.slots(ev(b1, critical: false, moderate: false), settings: s, now: at(11, 0), calendar: cal).isEmpty)
check("Unranked: nothing until a mode is picked; Always Assist after 'Yes'",
      ExecutionPlanner.slots(ev(b1, critical: false, unranked: true), settings: s, now: at(11, 0), calendar: cal).isEmpty
        && ExecutionPlanner.slots(ev(b1, critical: false, mode: .always, unranked: true), settings: s, now: at(11, 0), calendar: cal).count == 2)
check("No Execution Alerts: nothing", ExecutionPlanner.slots(ev(b1, mode: .noAlerts), settings: s, now: at(11, 0), calendar: cal).isEmpty)
var noPlus = s; noPlus.hasPlus = false
check("free: no prep, get-ready or leave alerts", ExecutionPlanner.slots(ev(b1), settings: noPlus, now: at(11, 0), calendar: cal).isEmpty)
let joinSlots = ExecutionPlanner.slots(ev(virt), settings: noPlus, now: at(11, 0), calendar: cal)
check("join: Critical virtual, start − 1 min, free", joinSlots.map(\.fireDate) == [at(14, 59)] && joinSlots.first?.body == "Client review starts in 1 min")
var toggles = s; toggles.leave = false
check("toggles: Leave off removes the leave alert", ExecutionPlanner.slots(ev(b1), settings: toggles, now: at(11, 0), calendar: cal).count == 1)

// B9: prep effort 120, actBy 1:00, travel at 3:00, get-ready 2:16 → prep alert at 12:16.
let b9 = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "x", assist: assist(early: 15, door: 10, effort: 120),
                                         place: place("Acme"), actBy: at(13, 0), eta: .init(seconds: 19 * 60, approximate: false)))
let b9Slots = ExecutionPlanner.slots(ev(b9), settings: s, now: at(9, 0), calendar: cal)
check("B9: prep start-by 12:16, before get-ready 2:16", b9.times.getReadyAt == at(14, 16) && b9.times.prepStartBy == at(12, 16), "\(b9.times)")
check("B9: prep alert at 12:16 with the effort", b9Slots.first?.fireDate == at(12, 16) && b9Slots.first?.body == "Start prepping for Client review · about 2 h",
      "\(b9Slots.map { ($0.fireDate, $0.body) })")
check("max 3 per event", b9Slots.count == 3)
var prepped = EventProgress(); prepped.prepDone = true
check("prep done: no prep alert", !ExecutionPlanner.slots(ev(b9, progress: prepped), settings: s, now: at(9, 0), calendar: cal).contains { $0.body.hasPrefix("Start prepping") })

// B7: quiet 10pm–7am, Critical flight 7:30am, leave-by 5:10am.
var quiet = s; quiet.quiet = QuietHours(startHour: 22, endHour: 7)
let flight = TripResolver.resolve(TripInputs(start: at(7, 30, day: 1), end: at(10, 0, day: 1), location: "JFK T4",
                                             assist: assist(.namedPlace, early: 90, door: 10), place: place("JFK"), eta: .init(seconds: 50 * 60, approximate: false)))
let crit = ExecutionPlanner.slots(ev(flight), settings: quiet, now: at(21, 0), calendar: cal)
check("B7: Critical leave alert fires at 5:10 in quiet hours", crit.contains { $0.fireDate == at(5, 10, day: 1) && $0.body.hasPrefix("Leave") },
      "\(crit.map { ($0.fireDate, $0.body) })")
check("B7: get-ready is skipped in quiet hours", !crit.contains { $0.body.hasPrefix("Get ready") })
check("B7: a non-Critical leave alert doesn't fire in quiet hours",
      ExecutionPlanner.slots(ev(flight, critical: false), settings: quiet, now: at(21, 0), calendar: cal).isEmpty)
let earlyPrep = TripResolver.resolve(TripInputs(start: at(11, 0), end: at(12, 0), assist: assist(.none, travel: false, att: nil, effort: 60), actBy: at(5, 0)))
let moved = ExecutionPlanner.slots(ev(earlyPrep), settings: quiet, now: at(1, 0), calendar: cal)
check("quiet: a prep alert moves to the end of quiet hours", moved.first?.fireDate == at(7, 0), "\(moved.map(\.fireDate))")
let latePrep = TripResolver.resolve(TripInputs(start: at(7, 45), end: at(8, 0), assist: assist(.none, travel: false, att: nil, effort: 60), actBy: at(5, 0)))
check("quiet: skipped if quiet hours end after deadline − effort",
      ExecutionPlanner.slots(ev(latePrep), settings: quiet, now: at(1, 0), calendar: cal).isEmpty)

// B10, B11: ETA lost, I'm leaving.
let lost = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "x", assist: assist(), place: place("Acme"), eta: nil))
check("B10: ETA lost, no get-ready or leave alerts (the diff removes them; floor untouched)",
      ExecutionPlanner.slots(ev(lost), settings: s, now: at(11, 0), calendar: cal).isEmpty)
var leaving = EventProgress(); leaving.leftAt = at(14, 25)
check("B11: on the way, no leave alert", ExecutionPlanner.slots(ev(b1, progress: leaving), settings: s, now: at(14, 26), calendar: cal).isEmpty)
check("past alerts aren't planned", ExecutionPlanner.slots(ev(b1), settings: s, now: at(14, 25), calendar: cal).map(\.body) == ["Leave now · 14 min walk"])

// planVersion changes with what the alert depends on.
let v1 = ExecutionPlanner.planVersion(ev(b1), settings: s)
let later = TripResolver.resolve(TripInputs(start: at(15, 0), end: at(16, 0), location: "x", assist: assist(), place: place("Acme"),
                                            eta: .init(seconds: 20 * 60, approximate: false)))
check("planVersion: a new ETA gives new ids, so the old alerts are replaced",
      ExecutionPlanner.planVersion(ev(later), settings: s) != v1 && ExecutionPlanner.planVersion(ev(b1), settings: s) == v1)

// Leave snooze: 5 min, recomputed lateness, at most twice.
let sn1 = ExecutionPlanner.leaveSnooze(ev(b1), snoozesSoFar: 0, now: at(14, 33), calendar: cal)
check("snooze: 5 min later with lateness", sn1?.fireDate == at(14, 38) && sn1?.body == "Leave now · about 7 min late", "\(String(describing: sn1))")
check("snooze: a leave snooze is never diffed away", sn1.map { AlertID.isExec($0.id) && !AlertID.isPlannedExec($0.id) } == true)
check("snooze: at most twice", ExecutionPlanner.leaveSnooze(ev(b1), snoozesSoFar: 2, now: at(14, 33), calendar: cal) == nil)
check("snooze: not past grace", ExecutionPlanner.leaveSnooze(ev(b1), snoozesSoFar: 0, now: at(15, 17), calendar: cal) == nil)

// Capacity: Critical execution alerts are pass 3, ahead of other floor reminders.
let planned = AlertPlanner.plan(b1Slots, now: at(11, 0))
check("capacity: execution alerts fit in the plan", planned.keep.count == 2)

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
