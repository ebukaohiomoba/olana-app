//
//  Trip.swift
//  Olana
//
//  One place that turns what Olana knows about an event into its execution
//  times (spec v3 §7.1–7.2, PRD v6 §3.4). The card, the sheet and the alert
//  planner all call this, so they can never disagree about leave-by.
//
//  Attendance (code's facts beat the model):
//    meeting link only       → virtual
//    geocodable place only   → in person
//    both                    → the user's answer, else the model's (unsure asks)
//    neither                 → none
//  Travel: in person, a geocodable place (not a room or unclear), and the
//  model or the place says go there. Buffers: the user's override, then the
//  message ("be there 15 min early"), then the model, then 15 / 5.
//

import Foundation

struct TripInputs {
    var start: Date
    var end: Date
    var isTask = false
    var isAllDay = false
    var location: String?
    var meetingURL: URL?
    var assist: AssistResult?
    /// The user's "In person or online?" answer (override).
    var attendanceAnswer: AssistAttendance?
    /// From the add-box message (capture).
    var attendanceTyped: AssistAttendance?
    var place: ResolvedPlace?
    /// start − the model's prep lead.
    var actBy: Date?
    var eta: ETAFreshness.Effective?
    var arriveEarlyOverride: Int?
    var arriveEarlyTyped: Int?
}

struct TripFacts {
    var times: ExecTimes
    var attendance: AssistAttendance?
    /// Wants travel help (in person at a real place). Leave-by also needs an ETA.
    var needsTravel: Bool
    var geocodable: Bool
    var roomish: Bool
    var arriveEarlyMinutes: Int
    var outTheDoorMinutes: Int
    /// Both a place and a link, and nobody has said which: ask once.
    var asksAttendance: Bool
    /// Travel over 4 h: "Plan travel", no leave-by.
    var planTravel: Bool
}

enum TripResolver {
    static func resolve(_ i: TripInputs) -> TripFacts {
        let kind = i.assist?.locationKind
        let geocodable = i.place != nil || kind == .streetAddress || kind == .namedPlace
        let roomish = i.place == nil && (kind == .roomInBuilding || kind == .unclear || kind == .virtual)
        let hasLink = i.meetingURL != nil

        var attendance: AssistAttendance?
        var asks = false
        if i.isTask || i.isAllDay {
            attendance = nil
        } else if hasLink && !geocodable {
            attendance = .virtual
        } else if geocodable && !hasLink {
            attendance = .inPerson
        } else if geocodable && hasLink {
            attendance = i.attendanceAnswer ?? i.attendanceTyped ?? i.assist?.attendance ?? .unsure
            asks = attendance == .unsure
        } else {
            attendance = i.attendanceAnswer ?? i.attendanceTyped
        }

        let needsTravel = !i.isTask && !i.isAllDay && attendance == .inPerson && geocodable && !roomish
            && ((i.assist?.needsTravel ?? true) || i.place != nil)

        let planTravel = needsTravel && (i.eta.map { ETAFreshness.isPlanTravel($0.seconds) } ?? false)
        let arriveEarly = i.arriveEarlyOverride ?? i.arriveEarlyTyped
            ?? (i.assist?.source == .model && (i.assist?.arriveEarlyMinutes ?? 0) > 0 ? i.assist?.arriveEarlyMinutes : nil) ?? 15
        let outTheDoor = (i.assist?.source == .model ? i.assist?.outTheDoorMinutes : nil).flatMap { $0 > 0 ? $0 : nil } ?? 5
        let effort = PrepEffort(rawValue: i.assist?.source == .model ? (i.assist?.effortMinutes ?? 0) : 0) ?? .none

        let execAttendance: Attendance = attendance == .virtual ? .virtual : (attendance == .inPerson ? .inPerson : .none)
        let times = ExecTimes(.init(
            start: i.start, end: i.end, actBy: i.actBy, effort: effort, attendance: execAttendance,
            hasMeetingLink: hasLink, needsTravel: needsTravel && !planTravel,
            eta: planTravel ? nil : i.eta?.seconds,
            arriveEarly: TimeInterval(arriveEarly * 60), outTheDoor: TimeInterval(outTheDoor * 60), isTask: i.isTask))
        return TripFacts(times: times, attendance: attendance, needsTravel: needsTravel, geocodable: geocodable, roomish: roomish,
                         arriveEarlyMinutes: arriveEarly, outTheDoorMinutes: outTheDoor, asksAttendance: asks, planTravel: planTravel)
    }
}
