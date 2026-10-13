//
//  main.swift
//  PlannerChecks
//
//  AlertPlanner against PRD v6 §3.9 and spec v3 §5.7 (A1, A2, A9), plus the
//  capacity guarantee. AlertPlanner.swift is a symlink into the app.
//  Run: swift run PlannerChecks
//

import Foundation

let now = Date(timeIntervalSince1970: 1_800_000_000)
func h(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

/// An event's floor: reminders at the given hours before its start.
func floor(_ event: UUID, start: Date, before: [Double]) -> [AlertSlot] {
    before.enumerated().map { i, b in
        AlertSlot(id: AlertID.floor(event, i), kind: .floor, eventID: event, eventStart: start,
                  fireDate: start.addingTimeInterval(-b * 3600), priority: false,
                  title: "E", subtitle: "s\(i)", body: "b", category: "EVENT_MEDIUM", urgencyRaw: 1, index: i)
    }
}
func exec(_ event: UUID, start: Date, fire: Date, priority: Bool) -> AlertSlot {
    AlertSlot(id: AlertID.exec(kind: "leave", event: event, planVersion: "v1"), kind: .exec, eventID: event,
              eventStart: start, fireDate: fire, priority: priority,
              title: "E", subtitle: "", body: "Leave now", category: "EXEC", urgencyRaw: 2, index: 0)
}
func pending(_ slots: [AlertSlot]) -> [AlertPlanner.Pending] { slots.map { .init(id: $0.id, contentKey: $0.contentKey) } }

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     ", detail()) }
}

// A1: 70 synced events in the next 48 h, 3 reminders each (210 wanted).
var a1: [AlertSlot] = []
var firstOf24: [String] = []
for i in 0..<70 {
    let id = UUID(), start = h(1 + Double(i) * 0.67)            // spread over ~47 h
    let f = floor(id, start: start, before: [24, 2, 0.25].filter { start.addingTimeInterval(-$0 * 3600) > now })
    a1 += f
    if start <= h(24), let first = f.min(by: { $0.fireDate < $1.fireDate }) { firstOf24.append(first.id) }
}
let p1 = AlertPlanner.plan(a1, now: now)
check("A1 plan fits in 60", p1.keep.count == 60, "\(p1.keep.count)")
check("A1 every event in 24 h has its first floor pending",
      Set(firstOf24).isSubset(of: Set(p1.keep.map(\.id))),
      "\(Set(firstOf24).subtracting(p1.keep.map(\.id)).count) missing")
let keptBeyond24 = p1.keep.filter { $0.eventStart > h(24) }
let droppedWithin24 = p1.overflow.filter { $0.eventStart <= h(24) }
check("A1 nothing beyond 24 h is kept while anything within 24 h is dropped",
      keptBeyond24.isEmpty || droppedWithin24.isEmpty,
      "kept beyond 24 h: \(keptBeyond24.count), dropped within 24 h: \(droppedWithin24.count)")

// A2: replanning against what the first replan left pending changes nothing.
let d1 = AlertPlanner.diff(desired: p1.keep, pending: [], in: AlertID.isPlannedFloor)
let d2 = AlertPlanner.diff(desired: p1.keep, pending: pending(p1.keep), in: AlertID.isPlannedFloor)
check("A2 first replan adds the plan", d1.add.count == 60 && d1.remove.isEmpty)
check("A2 second replan is a no-op", d2.isEmpty, "add \(d2.add.count) remove \(d2.remove.count)")

// A9: an execution diff with only floor requests pending leaves them alone.
let ev = UUID()
let floorOnly = floor(ev, start: h(3), before: [2, 0.25])
let e9 = AlertPlanner.diff(desired: [exec(ev, start: h(3), fire: h(2.5), priority: true)],
                           pending: pending(floorOnly), in: AlertID.isExec)
check("A9 execution diff never removes floor", e9.remove.isEmpty && e9.add.count == 1)
let f9 = AlertPlanner.diff(desired: floorOnly, pending: pending(floorOnly) + [.init(id: AlertID.exec(kind: "leave", event: ev, planVersion: "v1"), contentKey: "x")],
                           in: AlertID.isPlannedFloor)
check("A9 floor diff never removes execution alerts", f9.isEmpty)

// Namespaces don't collide.
check("ids: floor and exec prefixes are disjoint",
      !AlertID.isExec(AlertID.floor(ev, 0)) && !AlertID.isPlannedFloor(AlertID.exec(kind: "prep", event: ev, planVersion: "1")))
check("ids: snoozes and immediates are never planned floor",
      !AlertID.isPlannedFloor("olana:\(ev.uuidString):snooze:123"))

// Guarantee overflow: 65 events in 24 h → the soonest 60 win.
var g: [AlertSlot] = []
var starts: [(Date, String)] = []
for i in 0..<65 {
    let id = UUID(), start = h(0.5 + Double(i) * 0.3)
    let f = floor(id, start: start, before: [0.25])
    g += f; starts.append((start, f[0].id))
}
let pg = AlertPlanner.plan(g, now: now)
let soonest60 = Set(starts.sorted { $0.0 < $1.0 }.prefix(60).map(\.1))
check("guarantee: over 60 events in 24 h, the soonest win", Set(pg.keep.map(\.id)) == soonest60 && pg.overflow.count == 5)

// Pass order: execution for Critical (pass 3) beats remaining floor (pass 4).
let e3 = UUID(), f3 = UUID()
let crit = exec(e3, start: h(5), fire: h(4.5), priority: true)
let extraFloor = floor(f3, start: h(6), before: [5, 1])   // second one is "remaining"
let p3 = AlertPlanner.plan([crit] + extraFloor, now: now, limit: 2)
check("pass 3 before pass 4", p3.keep.contains(crit) && p3.keep.contains(extraFloor[0]) && !p3.keep.contains(extraFloor[1]))

// Pass 8: events beyond 48 h keep their floor when there's room.
let far = UUID()
let farFloor = floor(far, start: h(24 * 7), before: [24, 2])
let p8 = AlertPlanner.plan(farFloor, now: now)
check("pass 8: floor beyond 48 h is kept when there's room", p8.keep.count == 2)
let p8full = AlertPlanner.plan(a1 + farFloor, now: now)
check("pass 8: beyond 48 h never displaces nearer events", !p8full.keep.contains(where: { $0.eventID == far }))

// Changed reminder (new time) is replaced, not duplicated.
var moved = floorOnly
moved[1] = AlertSlot(id: moved[1].id, kind: .floor, eventID: ev, eventStart: h(3.5), fireDate: h(3.25), priority: false,
                     title: "E", subtitle: "s1", body: "b", category: "EVENT_MEDIUM", urgencyRaw: 1, index: 1)
let dm = AlertPlanner.diff(desired: moved, pending: pending(floorOnly), in: AlertID.isPlannedFloor)
check("moved event: its reminder is replaced", dm.remove == [moved[1].id] && dm.add.map(\.id) == [moved[1].id])

// Deleted event: its floor goes; snoozes stay.
let snooze = AlertPlanner.Pending(id: "olana:\(ev.uuidString):snooze:1", contentKey: "z")
let dd = AlertPlanner.diff(desired: [], pending: pending(floorOnly) + [snooze], in: AlertID.isPlannedFloor)
check("deleted event: floor removed, snooze untouched", Set(dd.remove) == Set(floorOnly.map(\.id)))

// Integrity: missing = planned but not pending.
let miss = AlertPlanner.missingFloor(planned: floorOnly, pendingIDs: [floorOnly[0].id], now: now)
check("integrity counts what's missing", miss.map(\.id) == [floorOnly[1].id])

// Past reminders are never planned.
let past = floor(UUID(), start: h(1), before: [3, 0.5])
check("past reminders are dropped", AlertPlanner.plan(past, now: now).keep.count == 1)

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
