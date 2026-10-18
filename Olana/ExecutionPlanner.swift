//
//  ExecutionPlanner.swift
//  Olana
//
//  Execution alerts (PRD v6 §3.9, spec v3 §7.7): prep, get-ready, leave and
//  join, at most 3 per event. Pure; NotificationEngine.executionPlan calls it
//  and the capacity passes and diff in AlertPlanner do the rest. Floor
//  reminders are never touched from here.
//
//  Who gets what (Normal mode):
//    Critical (score at acting ≥ 6.5): prep, get-ready, leave, join
//    Moderate+ below Critical:         get-ready and leave only if it needs travel
//    Minor, unranked (no mode picked): nothing
//  Always Assist gets everything; No Execution Alerts gets nothing.
//  Prep, get-ready and leave are Plus; join is free (it's a fact).
//
//  Quiet hours: prep moves to the end of quiet hours (skipped if that's after
//  deadline − effort); get-ready is skipped; leave is skipped unless Critical;
//  join fires (Critical only).
//

import Foundation

struct QuietHours: Equatable {
    var startHour: Int
    var endHour: Int

    func contains(_ d: Date, calendar: Calendar) -> Bool {
        let h = calendar.component(.hour, from: d)
        return startHour > endHour ? (h >= startHour || h < endHour) : (h >= startHour && h < endHour)
    }

    /// The next end of quiet hours at or after `d`.
    func end(after d: Date, calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: d)
        c.hour = endHour; c.minute = 0; c.second = 0
        let sameDay = calendar.date(from: c)!
        return sameDay > d ? sameDay : calendar.date(byAdding: .day, value: 1, to: sameDay)!
    }
}

struct ExecSettings: Equatable {
    var prep = true
    var getReady = true
    var leave = true
    var quiet: QuietHours?
    var hasPlus = true
    var settingsVersion = 0
}

struct ExecEvent {
    var id: UUID
    var title: String
    var times: ExecTimes
    var isAllDay = false
    var completed = false
    var urgencyRaw: Int
    /// Score at acting ≥ 6.5 (UrgencyCombiner).
    var critical: Bool
    /// Moderate or severe consequence (assisted under Normal).
    var moderatePlus: Bool
    var mode: AssistMode = .normal
    var unranked = false
    var outTheDoorMinutes = 5
    var etaSeconds: TimeInterval?
    var etaApproximate = false
    var travelMode: TravelMode = .driving
    var bring: [String] = []
    var progress = EventProgress()
    var overrideVersions: [Int] = []
}

enum ExecutionPlanner {
    static let maxLeaveSnoozes = 2
    static let leaveSnoozeMinutes = 5

    enum Allowed: Equatable { case none, travelOnly, all }

    /// The rules table, before Plus and toggles.
    static func allowed(_ e: ExecEvent) -> Allowed {
        switch e.mode {
        case .noAlerts: return .none
        case .always: return .all
        case .normal:
            if e.unranked { return .none }
            if e.critical { return .all }
            return e.moderatePlus ? .travelOnly : .none
        }
    }

    static func planVersion(_ e: ExecEvent, settings: ExecSettings) -> String {
        ExecPlanInputs(start: e.times.start, end: e.times.end, leaveBy: e.times.leaveBy, getReadyAt: e.times.getReadyAt,
                       prepStartBy: e.times.prepStartBy, assistMode: e.mode.rawValue, overrideVersions: e.overrideVersions,
                       settingsVersion: settings.settingsVersion).planVersion
    }

    static func slots(_ e: ExecEvent, settings s: ExecSettings, now: Date, calendar: Calendar = .current) -> [AlertSlot] {
        guard !e.isAllDay, !e.completed, !e.progress.finished else { return [] }
        let allowed = allowed(e)
        guard allowed != .none else { return [] }
        let t = e.times
        let version = planVersion(e, settings: s)
        let priority = e.critical || e.mode == .always
        var out: [AlertSlot] = []

        func slot(_ kind: ExecKind, _ fire: Date, _ body: String, _ category: String, index: Int) -> AlertSlot {
            AlertSlot(id: AlertID.exec(kind, event: e.id, planVersion: version), kind: .exec, eventID: e.id,
                      eventStart: t.start, fireDate: fire, priority: priority, title: e.title, subtitle: "",
                      body: body, category: category, urgencyRaw: e.urgencyRaw, index: index)
        }
        func quiet(_ d: Date) -> Bool { s.quiet?.contains(d, calendar: calendar) ?? false }

        // Prep (Plus): Critical and Always Assist only.
        if allowed == .all, s.hasPlus, s.prep, let startBy = t.prepStartBy, !e.progress.prepDone {
            var fire = startBy
            var ok = true
            if quiet(fire), let q = s.quiet {
                fire = q.end(after: fire, calendar: calendar)
                // Too late to be useful once quiet hours end.
                ok = fire <= t.prepMoment
            }
            if ok, fire > now, fire < t.prepDeadline {
                let effort = t.effort == .none ? "" : " · about \(ExecFormat.duration(t.effort.rawValue))"
                out.append(slot(.prep, fire, "Start prepping for \(e.title)\(effort)", "EXEC_PREP", index: 0))
            }
        }

        // Get-ready and leave (Plus): need travel and a leave-by.
        if s.hasPlus, t.isTravel, let leaveBy = t.leaveBy, !e.progress.onTheWay {
            let about = e.etaApproximate ? "about " : ""
            if s.getReady, let getReadyAt = t.getReadyAt, e.outTheDoorMinutes >= 10, getReadyAt > now, !quiet(getReadyAt) {
                var body = "Get ready · leave at \(about)\(ExecFormat.clock(leaveBy, calendar))"
                if let first = e.bring.first { body += " · bring \(first.lowercased())" }
                out.append(slot(.getReady, getReadyAt, body, "EXEC_GETREADY", index: 1))
            }
            if s.leave, leaveBy > now, !quiet(leaveBy) || e.critical {
                let trip = e.etaSeconds.map { " · \(about)\(ETAFreshness.phrase($0, mode: e.travelMode))" } ?? ""
                out.append(slot(.leave, leaveBy, "Leave now\(trip)", "EXEC_LEAVE", index: 2))
            }
        }

        // Join (free): virtual with a link, Critical only, start − 1 min.
        if t.isVirtual, e.critical || e.mode == .always, e.progress.joinedAt == nil {
            let fire = t.start.addingTimeInterval(-60)
            if fire > now, !quiet(fire) || e.critical {
                out.append(slot(.join, fire, "\(e.title) starts in 1 min", "EXEC_JOIN", index: 2))
            }
        }
        return Array(out.prefix(3))
    }

    /// "5 min" on a leave alert: once more with recomputed lateness, at most
    /// twice. nil when used up or the user is already on the way.
    static func leaveSnooze(_ e: ExecEvent, snoozesSoFar: Int, now: Date, calendar: Calendar = .current) -> AlertSlot? {
        guard snoozesSoFar < maxLeaveSnoozes, !e.progress.onTheWay, !e.progress.finished,
              let leaveBy = e.times.leaveBy else { return nil }
        let fire = now.addingTimeInterval(TimeInterval(leaveSnoozeMinutes * 60))
        guard fire < e.times.grace else { return nil }
        let late = Int(fire.timeIntervalSince(leaveBy) / 60)
        let body = late > 0 ? "Leave now · about \(late) min late" : "Leave now"
        let id = AlertID.exec(kind: "\(ExecKind.leaveSnooze.rawValue)", event: e.id, planVersion: "s\(snoozesSoFar + 1)")
        return AlertSlot(id: id, kind: .exec, eventID: e.id, eventStart: e.times.start, fireDate: fire, priority: true,
                         title: e.title, subtitle: "", body: body, category: "EXEC_LEAVE", urgencyRaw: e.urgencyRaw, index: 3)
    }
}
