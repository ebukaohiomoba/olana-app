//
//  AlertPlanner.swift
//  Olana
//
//  Which reminders should be pending right now, across every event at once
//  (PRD v6 §3.9). Pure: no UserNotifications, no SwiftData, so every rule here
//  runs against fixtures (UrgencyProbe/Sources/PlannerChecks).
//
//  NotificationEngine still decides *when* each event's reminders fire, exactly
//  as before (the floor is "planned exactly as NotificationEngine plans them
//  today"). This file decides which of those fit in iOS's pending limit, and
//  turns the result into a diff against what is already pending.
//
//  Rules from the PRD:
//    • The floor is never counted against the daily cap (v3 §3.9 settings table).
//    • No system path removes a floor reminder: the diff only removes floor
//      requests that the plan no longer wants because their event changed,
//      ended or was deleted, or capacity forces it.
//    • Execution alerts (M1-C) live in their own namespace and are diffed
//      separately, so an execution replan can never touch the floor.
//

import Foundation

// MARK: - Identifiers

enum AlertID {
    /// Floor: `olana:{eventUUID}:{index}`, as today.
    static let floorPrefix = "olana:"
    /// Execution: `olana.exec.{kind}.{eventUUID}.{planVersion}` (PRD §3.9).
    static let execPrefix = "olana.exec."

    static func floor(_ event: UUID, _ index: Int) -> String { "\(floorPrefix)\(event.uuidString):\(index)" }

    static func exec(kind: String, event: UUID, planVersion: String) -> String {
        "\(execPrefix)\(kind).\(event.uuidString).\(planVersion)"
    }

    /// Floor reminders the planner owns. Snoozes share the prefix but are a
    /// user action: the planner never adds or removes them.
    static func isPlannedFloor(_ id: String) -> Bool {
        id.hasPrefix(floorPrefix) && !id.contains(":snooze:")
    }

    static func isExec(_ id: String) -> Bool { id.hasPrefix(execPrefix) }
}

// MARK: - Slots

/// One reminder an event wants, with everything needed to post it.
struct AlertSlot: Equatable {
    enum Kind: Equatable { case floor, exec }

    let id: String
    let kind: Kind
    let eventID: UUID
    let eventStart: Date
    let fireDate: Date
    /// Critical or Always Assist: execution pass 3 instead of pass 5 (M1-C).
    let priority: Bool
    // Content, compared on replan so a changed reminder is replaced.
    let title: String
    let subtitle: String
    let body: String
    let category: String
    let urgencyRaw: Int
    let index: Int

    /// What makes two requests with the same id different enough to replace.
    var contentKey: String {
        "\(Int(fireDate.timeIntervalSince1970))|\(title)|\(subtitle)|\(body)|\(category)"
    }
}

// MARK: - Capacity

enum AlertPlanner {

    /// iOS keeps the 64 soonest pending requests per app; plan to 60.
    static let pendingLimit = 60

    struct Plan: Equatable {
        let keep: [AlertSlot]
        /// Wanted but didn't fit. Logged; a non-empty pass-2 overflow means
        /// more than 60 events in 24 h each have a floor.
        let overflow: [AlertSlot]
    }

    /// Fill `limit` slots in PRD §3.9's pass order. AlarmKit (pass 1) is a
    /// separate system and isn't counted here.
    ///
    ///   2. First floor reminder of every event in the next 24 h
    ///   3. Execution alerts for Critical and Always Assist events, next 24 h
    ///   4. Remaining floor reminders, next 24 h
    ///   5. Execution alerts for other events, next 24 h
    ///   6. First floor reminders, 24 to 48 h
    ///   7. Everything else, 24 to 48 h, soonest first
    ///   8. Floor for events beyond 48 h, soonest first, with whatever is left.
    ///      Not in the PRD's list, which stops at 48 h; without it an event
    ///      further out would lose reminders it has today, and "no system path
    ///      removes a floor reminder". Flagged for the PRD.
    static func plan(_ slots: [AlertSlot], now: Date, limit: Int = pendingLimit) -> Plan {
        let future = slots.filter { $0.fireDate > now }
        let h24 = now.addingTimeInterval(24 * 3600)
        let h48 = now.addingTimeInterval(48 * 3600)

        // The first floor reminder of each event is its earliest one.
        var firstIDs = Set<String>()
        for (_, group) in Dictionary(grouping: future.filter { $0.kind == .floor }, by: \.eventID) {
            if let first = group.min(by: { ($0.fireDate, $0.index) < ($1.fireDate, $1.index) }) {
                firstIDs.insert(first.id)
            }
        }

        func within24(_ s: AlertSlot) -> Bool { s.eventStart <= h24 }
        func within48(_ s: AlertSlot) -> Bool { s.eventStart > h24 && s.eventStart <= h48 }
        // Soonest event first, so that when a pass overflows the soonest win.
        let byEvent: (AlertSlot, AlertSlot) -> Bool = {
            ($0.eventStart, $0.fireDate, $0.id) < ($1.eventStart, $1.fireDate, $1.id)
        }
        let byFire: (AlertSlot, AlertSlot) -> Bool = { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }

        let passes: [[AlertSlot]] = [
            future.filter { $0.kind == .floor && within24($0) && firstIDs.contains($0.id) }.sorted(by: byEvent),
            future.filter { $0.kind == .exec && within24($0) && $0.priority }.sorted(by: byFire),
            future.filter { $0.kind == .floor && within24($0) && !firstIDs.contains($0.id) }.sorted(by: byFire),
            future.filter { $0.kind == .exec && within24($0) && !$0.priority }.sorted(by: byFire),
            future.filter { $0.kind == .floor && within48($0) && firstIDs.contains($0.id) }.sorted(by: byEvent),
            future.filter { within48($0) && !($0.kind == .floor && firstIDs.contains($0.id)) }.sorted(by: byFire),
            future.filter { $0.kind == .floor && $0.eventStart > h48 }.sorted(by: byFire),
        ]

        var keep: [AlertSlot] = []
        var overflow: [AlertSlot] = []
        for pass in passes {
            for s in pass {
                if keep.count < limit { keep.append(s) } else { overflow.append(s) }
            }
        }
        return Plan(keep: keep, overflow: overflow)
    }

    // MARK: Diff

    struct Pending: Equatable {
        let id: String
        let contentKey: String
    }

    struct Diff: Equatable {
        let add: [AlertSlot]
        let remove: [String]
        var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    }

    /// Desired vs pending within one namespace. Requests outside it are
    /// invisible to this diff, which is what keeps execution replans away
    /// from the floor and the other way round.
    static func diff(desired: [AlertSlot], pending: [Pending],
                     in namespace: (String) -> Bool) -> Diff {
        let mine = pending.filter { namespace($0.id) }
        let pendingByID = Dictionary(mine.map { ($0.id, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
        let want = desired.filter { namespace($0.id) }
        let wantIDs = Set(want.map(\.id))

        var add: [AlertSlot] = []
        var remove: [String] = []
        for s in want {
            switch pendingByID[s.id] {
            case nil: add.append(s)
            case let key? where key != s.contentKey:
                remove.append(s.id)      // replaced: same id, new time or text
                add.append(s)
            default: break
            }
        }
        for p in mine where !wantIDs.contains(p.id) { remove.append(p.id) }
        return Diff(add: add, remove: remove)
    }

    // MARK: Integrity

    /// Planned floor reminders that aren't pending (PRD v6 §1.9: the gate is
    /// zero). Execution coverage is a separate metric.
    static func missingFloor(planned: [AlertSlot], pendingIDs: Set<String>, now: Date) -> [AlertSlot] {
        planned.filter { $0.kind == .floor && $0.fireDate > now && !pendingIDs.contains($0.id) }
    }
}
