//
//  main.swift
//  HomeChecks
//
//  Card selection and card copy against PRD v6 §3.6 and §1.7, on fixed clocks.
//  HomeDay.swift is a symlink into the app, so this checks what ships.
//  Run: swift run HomeChecks
//

import Foundation

let cal = Calendar.current
let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 13))!   // a Tuesday
func at(_ h: Int, _ m: Int, day: Int = 0) -> Date {
    cal.date(byAdding: .minute, value: (day * 24 + h) * 60 + m, to: base)!
}

func ev(_ title: String, _ start: Date, minutes: Int = 60, _ u: EventUrgency = .medium,
        prep: Double? = nil, place: String? = nil, assisted: Bool = true,
        score: Double? = nil, done: Bool = false) -> HomeDayBuilder.Input {
    let scored = score.map {
        UrgencyCombiner.Result(score: $0, urgency: u, tier: .notification, actBy: start, advancedByPrep: false)
    }
    return .init(id: UUID(), title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60),
                 isAllDay: false, isTask: false, completed: done, completedAt: nil, isRecurring: false,
                 location: place, urgency: u, scored: scored, prepHours: prep, assisted: assisted)
}

var failures = 0
func check(_ name: String, _ inputs: [HomeDayBuilder.Input], now: Date,
           title: String?, line: String? = nil, secondary: String?? = nil) {
    let card = HomeDayBuilder.build(inputs: inputs, now: now, bed: nil).card
        ?? HomeDayBuilder.build(inputs: inputs, now: now, bed: nil).peek
    var ok = card?.title == title
    if let line { ok = ok && card?.line == line }
    if let secondary { ok = ok && card?.secondary == secondary }
    print(ok ? "PASS" : "FAIL", name)
    if !ok {
        failures += 1
        print("     got:", card?.title ?? "nil", "|", card?.line ?? "-", "|", card?.secondary ?? "-")
    }
}

// The mockup day.
check("mockup: prep by 2:20",
      [ev("Client review", at(15, 0), .high, prep: 40.0/60, place: "Room 2"),
       ev("Pick up prescription", at(17, 30), minutes: 15, prep: 10.0/60),
       ev("Gym", at(19, 0), .low, assisted: false)],
      now: at(13, 52), title: "Client review", line: "Start prepping by 2:20", secondary: .some(nil))

// Time beats score: the earliest actionable moment wins (§3.6 step 2).
check("earliest moment beats higher score",
      [ev("Board meeting", at(9, 0, day: 1), .high, score: 9.5),
       ev("Dentist", at(16, 0), score: 4)],
      now: at(13, 0), title: "Dentist", line: "Starts at 4:00")

// Active phases beat upcoming moments (§3.6 step 1).
check("PREP NOW beats an earlier upcoming start",
      [ev("Client review", at(15, 0), .high, prep: 1),
       ev("Standup", at(14, 40), minutes: 15)],
      now: at(14, 30), title: "Client review", line: "Prep now · done by 3:00")

check("PREP NOW beats NOW",
      [ev("Workshop", at(14, 25)),
       ev("Client review", at(15, 0), .high, prep: 1)],
      now: at(14, 30), title: "Client review")

// Grace for room events: min(start + 10, end), then off the card (§3.6).
check("happening now within grace, with the place",
      [ev("Client review", at(15, 0), place: "Room 2")],
      now: at(15, 9), title: "Client review", line: "Happening now · Room 2")
check("falls off the card after grace",
      [ev("Client review", at(15, 0), place: "Room 2"),
       ev("1:1", at(17, 0))],
      now: at(15, 11), title: "1:1")

// Only assisted events (§1.6).
check("minor event is never the card, even when earliest",
      [ev("Coffee", at(14, 0), .low, assisted: false),
       ev("Interview", at(16, 0), .high)],
      now: at(13, 0), title: "Interview")
check("nothing assisted: no card",
      [ev("Coffee", at(14, 0), .low, assisted: false)],
      now: at(13, 0), title: nil)

// Ties go to the higher urgency score (§3.6 step 3).
check("tie on moment: higher score wins",
      [ev("Sync", at(16, 0), score: 4.0),
       ev("Review", at(16, 0), .high, score: 7.0)],
      now: at(13, 0), title: "Review")

// Secondary line: the next action within 2 h (§1.7).
check("secondary line within 2 h",
      [ev("Client review", at(15, 0)), ev("Pick up prescription", at(16, 30))],
      now: at(14, 45), title: "Client review",
      secondary: .some("Next: Pick up prescription · starts at 4:30"))
check("no secondary line beyond 2 h",
      [ev("Client review", at(15, 0)), ev("Pick up prescription", at(17, 0))],
      now: at(14, 45), title: "Client review", secondary: .some(nil))

// Copy: the 12 h test is on the prep deadline (§1.7).
check("deadline beyond 12 h: day phrase",
      [ev("Quarterly review", at(11, 0, day: 1), prep: 2)],
      now: at(13, 0), title: "Quarterly review", line: "Prep by tomorrow morning")
check("deadline within 12 h: time",
      [ev("Quarterly review", at(9, 0, day: 1), prep: 2)],
      now: at(22, 0), title: "Quarterly review", line: "Start prepping by 7:00")

// PREP NOW with a far deadline isn't active; it waits at the deadline.
check("far PREP NOW does not beat a nearer start",
      [ev("Thesis defense", at(15, 0, day: 2), .high, prep: 51),
       ev("Dentist", at(16, 0))],
      now: at(13, 0), title: "Dentist")
check("prep starting before a nearer start wins (earliest moment)",
      [ev("Thesis defense", at(15, 0, day: 2), .high, prep: 48),
       ev("Dentist", at(16, 0))],
      now: at(13, 0), title: "Thesis defense", line: "Prep today")

check("done events never show",
      [ev("Client review", at(15, 0), done: true), ev("1:1", at(17, 0))],
      now: at(13, 0), title: "1:1")

// Execution times (PRD v6 §1.7, §3.6; spec v3 §7.1).
func times(minutes: Int = 60, actBy: Date? = nil, effort: PrepEffort = .none,
           _ attendance: Attendance = .none, link: Bool = false, travel: Bool = false,
           eta: Int? = nil, task: Bool = false) -> ExecTimes {
    let s = at(15, 0)
    return ExecTimes(.init(start: s, end: s.addingTimeInterval(Double(minutes) * 60), actBy: actBy, effort: effort,
                           attendance: attendance, hasMeetingLink: link, needsTravel: travel,
                           eta: eta.map { Double($0) * 60 }, isTask: task))
}
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     got:", got()) }
}

let plain = times(actBy: at(14, 20))
expect("times: no effort, prep start-by is actBy and the deadline is start",
       plain.prepStartBy == at(14, 20) && plain.prepDeadline == at(15, 0) && plain.grace == at(15, 10), "\(plain)")
expect("times: no prep lead and no effort means no prep", !times().hasPrep)
expect("times: effort alone sets start-by at deadline − effort", times(effort: .thirty).prepStartBy == at(14, 30))
expect("times: start-by is the earlier of actBy and deadline − effort",
       times(actBy: at(14, 0), effort: .thirty).prepStartBy == at(14, 0)
         && times(actBy: at(14, 50), effort: .thirty).prepStartBy == at(14, 30))

let trip = times(actBy: at(14, 0), effort: .sixty, .inPerson, travel: true, eta: 14)
expect("times: travel, leave by start − ETA − 15, get ready 5 before, prep done by get-ready",
       trip.isTravel && trip.leaveBy == at(14, 31) && trip.getReadyAt == at(14, 26)
         && trip.prepDeadline == at(14, 26) && trip.prepStartBy == at(13, 26) && trip.grace == at(15, 20), "\(trip)")
expect("times: travel with no effort and actBy after get-ready has no prep window",
       !times(actBy: at(14, 50), .inPerson, travel: true, eta: 14).hasPrep)
expect("times: in person with no ETA is not travel; deadline is start, grace 20",
       { let t = times(actBy: at(14, 0), .inPerson, travel: true); return !t.isTravel && t.prepDeadline == at(15, 0) && t.grace == at(15, 20) }())

let call = times(effort: .fifteen, .virtual, link: true)
expect("times: virtual with a link, join opens 5 before, prep done by then, grace 15",
       call.isVirtual && call.joinOpen == at(14, 55) && call.prepDeadline == at(14, 55)
         && call.prepStartBy == at(14, 40) && call.grace == at(15, 15), "\(call)")
expect("times: virtual without a link is not virtual",
       { let t = times(.virtual); return !t.isVirtual && t.prepDeadline == at(15, 0) && t.grace == at(15, 10) }())
expect("times: a task never travels or joins, but keeps prep",
       { let t = times(actBy: at(14, 0), .inPerson, travel: true, eta: 14, task: true)
         return !t.isTravel && !t.isVirtual && t.prepStartBy == at(14, 0) && t.prepDeadline == at(15, 0) }())
expect("times: grace never runs past the end", times(minutes: 5).grace == at(15, 5))
expect("times: PREP NOW's upcoming moment is deadline − effort", trip.prepMoment == at(13, 26))

// Phases (PRD v6 §3.6), first match wins. trip: prep 13:26–14:26, get ready 14:26, leave 14:31, start 15:00, grace 15:20.
expect("phase: before prep, PREP BY", trip.phase(now: at(13, 0)) == .prepBy)
expect("phase: in the prep window, PREP NOW", trip.phase(now: at(13, 30)) == .prepNow)
expect("phase: prep done skips to LEAVE BY", trip.phase(now: at(13, 30), state: .init(prepDone: true)) == .leaveBy)
expect("phase: at get-ready, GET READY (prep has ended)", trip.phase(now: at(14, 27)) == .getReady)
expect("phase: at leave-by, LEAVE, on time", trip.phase(now: at(14, 31)) == .leave(lateMinutes: 0))
expect("phase: 6 min late, LEAVE stays with the lateness", trip.phase(now: at(14, 37)) == .leave(lateMinutes: 6))
expect("phase: I'm leaving, ON THE WAY", trip.phase(now: at(14, 33), state: .init(onTheWay: true)) == .onTheWay)
expect("phase: after grace, DONE", trip.phase(now: at(15, 21)) == .done)
expect("phase: I'm here, DONE", trip.phase(now: at(14, 50), state: .init(finished: true)) == .done)
expect("phase: virtual, JOIN from join-open until grace", call.phase(now: at(14, 54)) == .prepNow
         && call.phase(now: at(14, 55)) == .join && call.phase(now: at(15, 14)) == .join && call.phase(now: at(15, 16)) == .done)
expect("phase: no travel, no prep: STARTS then NOW", times().phase(now: at(14, 0)) == .starts && times().phase(now: at(15, 5)) == .now)
expect("phase: active ranks JOIN = LEAVE > ON THE WAY > GET READY > PREP NOW > NOW",
       ExecPhase.join.activeRank == 0 && ExecPhase.leave(lateMinutes: 3).activeRank == 0 && ExecPhase.onTheWay.activeRank == 1
         && ExecPhase.getReady.activeRank == 2 && ExecPhase.prepNow.activeRank == 3 && ExecPhase.now.activeRank == 4
         && ExecPhase.starts.activeRank == nil && ExecPhase.leaveBy.activeRank == nil)

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
