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

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
