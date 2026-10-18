//
//  ExecTimes.swift
//  Olana
//
//  The execution times of one event (PRD v6 §1.7 Job 2 and §3.6, spec v3
//  §7.1). All code: the model only supplies the effort bucket and, through
//  the combiner, the prep lead behind actBy. Pure Foundation, so HomeChecks
//  runs it against fixed clocks.
//
//    leaveBy      = start − ETA − arriveEarly
//    getReadyAt   = leaveBy − outTheDoor
//    joinOpen     = start − 5 min
//    prepDeadline = getReadyAt (travel) | joinOpen (virtual) | start
//    prepStartBy  = min(actBy, prepDeadline − effort)
//    grace        = min(start + 20 | 15 | 10, end)   in person | virtual | other
//

import Foundation

/// How long the prep work takes (EventAssist bucket, spec §6.2).
enum PrepEffort: Int, CaseIterable, Codable {
    case none = 0, fifteen = 15, thirty = 30, sixty = 60, oneTwenty = 120

    var duration: TimeInterval { TimeInterval(rawValue * 60) }
}

/// Spec §7.2. Stored as an override in M1-C; `none` until then.
enum Attendance: String, Codable {
    case inPerson, virtual, none
}

struct ExecTimes: Equatable {

    struct Inputs: Equatable {
        var start: Date
        var end: Date
        /// start − the model's prep lead. Not the combiner's `actBy`, which is
        /// clamped to now for scoring: a start-by that moves with the clock
        /// would give the prep alert a new planVersion on every replan.
        /// nil when the model judged no prep.
        var actBy: Date?
        var effort: PrepEffort = .none
        var attendance: Attendance = .none
        var hasMeetingLink = false
        var needsTravel = false
        /// Seconds, from the ETA cache. nil means no leave-by.
        var eta: TimeInterval?
        var arriveEarly: TimeInterval = 15 * 60
        var outTheDoor: TimeInterval = 5 * 60
        /// Tasks get prep only, never travel or join (spec §9).
        var isTask = false
    }

    static let joinLead: TimeInterval = 5 * 60

    /// Set only for travel events.
    let leaveBy: Date?
    let getReadyAt: Date?
    let joinOpen: Date
    let prepDeadline: Date
    /// nil when there's no prep, or no time to do it before the deadline.
    let prepStartBy: Date?
    let effort: PrepEffort
    let grace: Date
    /// In person, needs travel, and leaveBy known.
    let isTravel: Bool
    /// Virtual with a meeting link.
    let isVirtual: Bool

    var hasPrep: Bool { prepStartBy != nil }

    /// Where PREP NOW counts as an upcoming moment when its deadline is more
    /// than 12 h out (PRD §3.6): prepDeadline − effort.
    var prepMoment: Date { prepDeadline.addingTimeInterval(-effort.duration) }

    init(_ i: Inputs) {
        let travelETA = (!i.isTask && i.attendance == .inPerson && i.needsTravel) ? i.eta : nil
        let leaveBy = travelETA.map { i.start.addingTimeInterval(-$0 - i.arriveEarly) }
        let getReadyAt = leaveBy.map { $0.addingTimeInterval(-i.outTheDoor) }
        let isVirtual = !i.isTask && i.attendance == .virtual && i.hasMeetingLink
        let joinOpen = i.start.addingTimeInterval(-Self.joinLead)

        let deadline = getReadyAt ?? (isVirtual ? joinOpen : i.start)

        // Prep exists when the model asked for lead time or EventAssist gave
        // an effort. With no effort the start-by is actBy (spec §7.1), capped
        // at the deadline by the PRD's min(). A window that closes before it
        // opens has nothing to show.
        var startBy: Date?
        if i.actBy.map({ $0 < i.start }) == true || i.effort != .none {
            let fromEffort = deadline.addingTimeInterval(-i.effort.duration)
            let s = i.actBy.map { min($0, fromEffort) } ?? fromEffort
            startBy = s < deadline ? s : nil
        }

        // Travel implies in person, so in person covers it.
        let graceLead: TimeInterval = !i.isTask && i.attendance == .inPerson ? 20 * 60
            : isVirtual ? 15 * 60 : 10 * 60

        self.leaveBy = leaveBy
        self.getReadyAt = getReadyAt
        self.joinOpen = joinOpen
        self.prepDeadline = deadline
        self.prepStartBy = startBy
        self.effort = i.effort
        self.grace = min(i.start.addingTimeInterval(graceLead), i.end)
        self.isTravel = leaveBy != nil
        self.isVirtual = isVirtual
    }
}
