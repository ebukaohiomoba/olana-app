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

    /// Execution alerts the planner owns. A leave snooze shares the namespace
    /// but is a user action, like a floor snooze: never diffed away.
    static func isPlannedExec(_ id: String) -> Bool {
        isExec(id) && !id.hasPrefix("\(execPrefix)leaveSnooze.")
    }
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

        let firstIDs = firstFloorIDs(future)

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

    /// The first floor reminder of each event is its earliest one.
    static func firstFloorIDs(_ slots: [AlertSlot]) -> Set<String> {
        var ids = Set<String>()
        for (_, group) in Dictionary(grouping: slots.filter { $0.kind == .floor }, by: \.eventID) {
            if let first = group.min(by: { ($0.fireDate, $0.index) < ($1.fireDate, $1.index) }) {
                ids.insert(first.id)
            }
        }
        return ids
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

    /// What the gate counts (spec v3 §5.6): planned floor reminders that
    /// aren't pending, plus first floor reminders in the next 24 h that
    /// capacity pushed out (the §5.3 guarantee). Later floor reminders over
    /// capacity are overflow, logged but not missing.
    struct FloorCheck: Equatable {
        let notPending: [AlertSlot]
        let capacity: [AlertSlot]
        var missing: Int { notPending.count + capacity.count }
        /// Spec §5.6 reasons; notAuthorized is decided before planning.
        var reason: String? { !capacity.isEmpty ? "capacity" : notPending.isEmpty ? nil : "unknown" }
    }

    static func floorCheck(_ plan: Plan, pendingIDs: Set<String>, now: Date) -> FloorCheck {
        let firstIDs = firstFloorIDs(plan.keep + plan.overflow)
        let h24 = now.addingTimeInterval(24 * 3600)
        return FloorCheck(
            notPending: missingFloor(planned: plan.keep, pendingIDs: pendingIDs, now: now),
            capacity: plan.overflow.filter { firstIDs.contains($0.id) && $0.eventStart <= h24 && $0.fireDate > now })
    }
}

// MARK: - Observable delivery

/// Spec v3 §5.6 step 3, reported and not gated. Remembers when each planned
/// alert should fire; at the next check, counts the ones that came due
/// against the ones we could see: still in Notification Center, shown while
/// the app was open, or tapped. iOS hides some deliveries (cleared from
/// Notification Center while the app was closed), so it's an estimate.
/// The M1-A gate's running totals (spec §5.6: one week, zero missing). The
/// result history rolls at 200 entries, which a busy week can outrun; this
/// never rolls, so the gate is read from here.
struct IntegritySummary: Codable, Equatable {
    var since: Date?
    var checks = 0
    /// Checks with a planned floor reminder still missing.
    var missingChecks = 0
    var lastMissingAt: Date?
    var lastMissingReason: String?
    /// Checks made with notifications off. Not a planner failure, but not
    /// evidence either, so they're counted apart and break the clean run.
    var notAuthorizedChecks = 0
    /// Start of the current run of clean, authorized checks.
    var cleanSince: Date?
    var execMissingChecks = 0
    var deliveryDue = 0
    var deliveryObserved = 0

    mutating func add(at: Date, missing: Int, reason: String?, execMissing: Int = 0,
                      deliveryDue due: Int = 0, deliveryObserved observed: Int = 0) {
        if since == nil { since = at }
        checks += 1
        if execMissing > 0 { execMissingChecks += 1 }
        deliveryDue += due
        deliveryObserved += observed
        if reason == "notAuthorized" {
            notAuthorizedChecks += 1
            cleanSince = nil
        } else if missing > 0 {
            missingChecks += 1
            lastMissingAt = at
            lastMissingReason = reason ?? "unknown"
            cleanSince = nil
        } else if cleanSince == nil {
            cleanSince = at
        }
    }

    /// The gate: a clean, authorized run at least `days` long.
    func gatePassed(now: Date, days: Double = 7) -> Bool {
        cleanSince.map { now.timeIntervalSince($0) >= days * 86400 } ?? false
    }
}

final class DeliveryLedger: @unchecked Sendable {

    struct Check: Equatable {
        let due: Int
        let observed: Int
    }

    static let shared = DeliveryLedger(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let ledgerKey = "olanaFireLedger_v1"
    private let seenKey = "olanaSeenAlerts_v1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// From willPresent and didReceive, on whatever thread the delegate uses.
    func noteSeen(_ id: String, at date: Date = Date()) {
        guard AlertID.isPlannedFloor(id) || AlertID.isPlannedExec(id) else { return }
        lock.lock(); defer { lock.unlock() }
        var seen = load(seenKey)
        seen[id] = date.timeIntervalSince1970
        save(seen, seenKey)
    }

    /// Count what came due since the last check, then remember the new plan.
    /// `delivered` is Notification Center's id → delivery date.
    func check(kept: [AlertSlot], delivered: [String: Date], now: Date) -> Check {
        lock.lock(); defer { lock.unlock() }
        let t = now.timeIntervalSince1970
        var seen = load(seenKey)
        let due = load(ledgerKey).filter { $0.value <= t }

        // Floor ids repeat across replans, so only a sighting at or after the
        // fire time (a minute's slack) counts for this firing.
        let observed = due.filter { id, fire in
            let at = max(delivered[id]?.timeIntervalSince1970 ?? 0, seen[id] ?? 0)
            return at >= fire - 60
        }.count

        var next: [String: Double] = [:]
        for s in kept where s.fireDate > now { next[s.id] = s.fireDate.timeIntervalSince1970 }
        save(next, ledgerKey)
        for id in due.keys { seen.removeValue(forKey: id) }
        save(seen.filter { $0.value > t - 48 * 3600 }, seenKey)
        return Check(due: due.count, observed: observed)
    }

    /// Drop a cancelled alert's expected firing, so a reminder removed on
    /// purpose (Mark done, a deleted event) isn't counted as undelivered.
    func forget(where matches: (String) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for key in [ledgerKey, seenKey] { save(load(key).filter { !matches($0.key) }, key) }
    }

    private func load(_ key: String) -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private func save(_ value: [String: Double], _ key: String) {
        defaults.set(value, forKey: key)
    }
}
