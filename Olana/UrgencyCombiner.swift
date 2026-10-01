//
//  UrgencyCombiner.swift
//  Olana
//
//  Turns stable semantics plus the current clock into a score, a bucket and an
//  alert tier. Pure, synchronous, deterministic and cheap enough to run on every
//  render — which is the point of keeping it separate from extraction.
//
//  Urgency is two things multiplied: what the event is, and how close it is.
//  EventSemantics owns the first and never changes. This file owns the second
//  and is re-run constantly.
//
//  The constants below are a starting calibration, not a finding. They decide
//  what is allowed to interrupt someone, and they should be tuned against real
//  labelled events before the alarm tier is trusted.
//

import Foundation

public enum UrgencyCombiner {

    // MARK: - Tuning

    /// Score at or above which an event is Critical.
    public static var criticalThreshold: Double = 6.5
    /// Score at or above which an event is Soon.
    public static var soonThreshold: Double = 3.5

    // MARK: - Intrinsic weight

    /// How much the event matters, independent of when it is.
    static func baseWeight(_ c: Consequence, _ m: Movability) -> Double {
        switch (c, m) {
        case (.severe, .fixed):       return 1.00
        case (.severe, .difficult):   return 0.92
        case (.severe, .flexible):    return 0.80
        case (.moderate, .fixed):     return 0.62
        case (.moderate, .difficult): return 0.56
        case (.moderate, .flexible):  return 0.44
        case (.minor, .fixed):        return 0.30
        case (.minor, .difficult):    return 0.24
        case (.minor, .flexible):     return 0.18
        }
    }

    /// Piecewise rather than a formula so it can be read and argued with.
    /// Flatter at distance than the obvious decay, because a severe thing a week
    /// out still deserves to be visible.
    static func timePressure(hoursUntil h: Double) -> Double {
        switch h {
        case ..<0:    return 1.00   // callers must filter past events; see `score`
        case ..<2:    return 0.98
        case ..<6:    return 0.92
        case ..<24:   return 0.84
        case ..<48:   return 0.72
        case ..<72:   return 0.62
        case ..<168:  return 0.50
        case ..<336:  return 0.38
        default:      return 0.28
        }
    }

    // MARK: - Result

    public struct Result: Sendable, Equatable {
        public let score: Double            // 0...10
        public let urgency: EventUrgency
        public let tier: AlertTier
        /// When the person actually needs to act, which is the start time pulled
        /// forward by any preparation the event requires.
        public let actBy: Date
        /// True when the prep shift moved this into a higher bucket than the
        /// start time alone would have produced. This is the differentiating
        /// behaviour, so it is worth surfacing rather than hiding.
        public let advancedByPrep: Bool
    }

    public enum AlertTier: Int, Sendable, Comparable {
        case silent = 0
        case notification = 1
        case timeSensitive = 2
        case alarm = 3

        public static func < (a: AlertTier, b: AlertTier) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: - Scoring

    /// Returns nil for events that have already started. Past events are filtered,
    /// never scored: `timePressure` peaks at zero hours, so scoring a stale event
    /// produces a maximum-urgency result for something that no longer matters.
    public static func score(
        semantics: EventSemantics,
        start: Date,
        now: Date = Date()
    ) -> Result? {
        guard start > now else { return nil }

        let prep = semantics.effectivePrep

        // Preparation can never reach further back than now. Without this clamp a
        // wrong prep estimate on a near-term event pushes `actBy` into the past,
        // where `timePressure` returns its maximum, and the event scores 10 for the
        // wrong reason. Measured: "Rent due" in 5 hours, wrongly given 48 hours of
        // prep, scored a perfect 10 on a claim that was nonsense.
        //
        // Clamping to now also states the right thing: if you needed to start
        // earlier than this, the answer is start now, not panic.
        let requested = start.addingTimeInterval(-prep.hours * 3600)
        let actBy = max(requested, now)
        let hoursToAct = actBy.timeIntervalSince(now) / 3600
        let hoursToStart = start.timeIntervalSince(now) / 3600

        let weight = baseWeight(semantics.consequence, semantics.movability)
        let value = weight * timePressure(hoursUntil: hoursToAct) * 10
        let withoutPrep = weight * timePressure(hoursUntil: hoursToStart) * 10

        let urgency = bucket(for: value)
        return Result(
            score: value,
            urgency: urgency,
            tier: tier(score: value, semantics: semantics),
            actBy: actBy,
            advancedByPrep: prep != .none && urgency != bucket(for: withoutPrep)
        )
    }

    public static func bucket(for score: Double) -> EventUrgency {
        if score >= criticalThreshold { return .high }
        if score >= soonThreshold     { return .medium }
        return .low
    }

    /// Deliberately conservative about the top tier. A full alarm cuts through
    /// Silent and Focus, and a single wrong one gets the permission revoked in
    /// one tap — so it requires severe consequence, not merely a high score.
    static func tier(score: Double, semantics: EventSemantics) -> AlertTier {
        if score >= criticalThreshold && semantics.consequence == .severe { return .alarm }
        if score >= criticalThreshold { return .timeSensitive }
        if score >= soonThreshold     { return .notification }
        return .silent
    }

    // MARK: - Alarm plan

    public struct AlarmPlan: Sendable, Equatable {
        public let tier: AlertTier
        /// When it rings: the moment preparation has to start, or the event itself.
        public let fireDate: Date
        /// True when it rings ahead of the event because work is needed first.
        public let advancedByPrep: Bool
    }

    /// Whether an event earns an alarm, and when it should ring. nil when it does not.
    ///
    /// Judged as of the moment the alarm would ring, not the moment it is
    /// scheduled. `tier` depends on the clock, so asking "is this alarm-worthy
    /// right now?" days ahead always said no: a flight five days out scored 5.0,
    /// got no alarm, and nothing asked again. At the moment of acting, time
    /// pressure is at its peak, so this comes down to what the event is, which is
    /// what should decide whether something may ring through Silent and Focus.
    public static func alarmPlan(semantics: EventSemantics, start: Date,
                                 now: Date = Date()) -> AlarmPlan? {
        guard start > now else { return nil }

        let prep = semantics.effectivePrep
        let prepStart = start.addingTimeInterval(-prep.hours * 3600)
        // If the time to start preparing has already passed, an alarm now would
        // be a jolt about something they can no longer do on time. Ring for the
        // event itself instead.
        let advanced = prep != .none && prepStart > now
        let fireDate = advanced ? prepStart : start

        let scoreWhenActing = baseWeight(semantics.consequence, semantics.movability)
            * timePressure(hoursUntil: 0) * 10
        let t = tier(score: scoreWhenActing, semantics: semantics)
        guard t >= .timeSensitive else { return nil }
        return AlarmPlan(tier: t, fireDate: fireDate, advancedByPrep: advanced)
    }

    // MARK: - Explanation

    /// One short line, because the reason has to be readable at a glance to be
    /// worth anything. Longer than a phrase and it becomes another thing to process.
    public static func explain(_ r: Result, semantics: EventSemantics, start: Date,
                               now: Date = Date()) -> String {
        if r.advancedByPrep {
            let days = max(1, Int((start.timeIntervalSince(r.actBy)) / 86400))
            return "Needs about \(days) day\(days == 1 ? "" : "s") of work first"
        }
        let h = start.timeIntervalSince(now) / 3600
        switch (semantics.consequence, h) {
        case (.severe, ..<24):  return "Hard to recover if missed, and it is today"
        case (.severe, _):      return "Hard to recover if missed"
        case (.moderate, ..<6): return "Starting soon"
        case (.moderate, _):    return "Worth not missing"
        default:                return "No rush"
        }
    }
}
