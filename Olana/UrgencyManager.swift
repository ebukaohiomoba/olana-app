//
//  UrgencyManager.swift
//  Olana
//
//  Orchestrates urgency. Three moving parts, deliberately small:
//
//    1. EventSemantics  — what the event is. Extracted once by Apple's on-device
//                         model, cached on OlanaEvent, never recomputed.
//    2. UrgencyCombiner — what the clock says. Pure and re-run freely.
//    3. This file       — fetch or extract semantics, hand them to the combiner.
//
//  There is no training, no correction history and no personalisation in the
//  ranking path. The model is the same for every user on their first event,
//  which is the property the previous CoreML stack could not provide.
//
//  Ranking requires Apple Intelligence. Without it, or for any event the model
//  cannot judge, there are no semantics: the event keeps its chronological
//  position and never alerts. There is no keyword fallback by design.
//

import Foundation
import Combine
import SwiftData

// MARK: - Compatibility surface

/// Kept so existing callers (AddEventView, OnboardingScreen6) continue to work.
public typealias UrgencyBucket = EventUrgency

public struct UrgencyClassification: Sendable, Equatable {
    public let bucket: EventUrgency
    public let score: Double
    public let semantics: EventSemantics
    public let tier: UrgencyCombiner.AlertTier
    public let rationale: String?
}

// MARK: - Manager

@MainActor
public final class UrgencyManager: ObservableObject {

    public static let shared = UrgencyManager()

    /// Bump when EventSemanticsPrompt.instructions changes, to invalidate caches.
    /// 2: keyword fallback removed, so any semantics it produced are discarded.
    public static let promptVersion = 2

    /// Failed extractions of the same title before it is left unranked for good.
    static let maxFailures = 3

    @Published public private(set) var isModelAvailable: Bool = false

    private init() {
        isModelAvailable = AIAssistant.shared.isAvailable
    }

    /// Re-read Apple Intelligence state. Call on foreground: the user can turn it
    /// on in Settings, and the model finishes downloading while we are suspended.
    public func refresh() {
        AIAssistant.shared.refreshAvailability()
        isModelAvailable = AIAssistant.shared.isAvailable
    }

    // MARK: - Classification

    /// Classify free text, for the capture path where no OlanaEvent exists yet.
    /// nil when the model cannot judge it, so the UI offers no suggestion rather
    /// than presenting a default as if it were one.
    public func classify(text: String, date: Date?,
                         calendarName: String? = nil) async -> UrgencyClassification? {
        guard case .judged(let sem) = await AIAssistant.shared.semantics(
            title: text, calendarName: calendarName
        ) else { return nil }
        return build(sem, start: date)
    }

    /// Classify a stored event, using its cached semantics when they are still valid.
    /// Extracts and writes the cache back when they are missing or stale.
    public func classify(event: OlanaEvent, context: ModelContext? = nil) async -> UrgencyClassification? {
        if let cached = event.cachedSemantics {
            return build(cached, start: event.start)
        }
        let judged = event.record(await AIAssistant.shared.semantics(
            title: event.title, calendarName: event.calendarName
        ))
        try? context?.save()
        return judged.map { build($0, start: event.start) }
    }

    /// Synchronous score for an event whose semantics are already cached.
    /// Returns nil for past events and for events not yet extracted, so callers
    /// can leave those in chronological order rather than guessing at them.
    public nonisolated func cachedScore(for event: OlanaEvent,
                                        now: Date = Date()) -> UrgencyCombiner.Result? {
        guard let sem = event.cachedSemantics else { return nil }
        return UrgencyCombiner.score(semantics: sem, start: event.start, now: now)
    }

    private func build(_ sem: EventSemantics, start: Date?) -> UrgencyClassification {
        guard let start, let r = UrgencyCombiner.score(semantics: sem, start: start) else {
            // No date, or already started. Neither is a ranking question.
            return UrgencyClassification(
                bucket: .low, score: 0, semantics: sem,
                tier: .silent, rationale: nil
            )
        }
        return UrgencyClassification(
            bucket: r.urgency,
            score: r.score,
            semantics: sem,
            tier: r.tier,
            rationale: UrgencyCombiner.explain(r, semantics: sem, start: start)
        )
    }

    // MARK: - Telemetry

    /// Record that the user changed the suggested urgency. Nothing in the ranking
    /// path reads this. It exists so that if disagreement turns out to be common
    /// and patterned, a per-category bias layer can be built on real evidence
    /// rather than on the assumption that one is needed.
    public func logDisagreement(title: String, suggested: EventUrgency,
                                chosen: EventUrgency, semantics: EventSemantics?) {
        guard suggested != chosen else { return }
        let row: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "title": title,
            "suggested": String(suggested.rawValue),
            "chosen": String(chosen.rawValue),
            "consequence": semantics?.consequence.rawValue ?? "",
            "movability": semantics?.movability.rawValue ?? "",
            "category": semantics?.category.rawValue ?? ""
        ]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("urgency_disagreements.jsonl")
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Backfill

    /// Extract semantics for events that do not have them yet.
    ///
    /// Forward-looking and bounded on purpose. A freshly connected calendar can
    /// hold hundreds of events; extracting all of them at once would be a visible
    /// battery cost for no benefit, since past events are never ranked.
    /// Returns the events it gave semantics to, so the caller can re-schedule
    /// notifications for them now that the alarm gate has something to read.
    ///
    /// Does nothing while Apple Intelligence is unavailable. Those events stay
    /// pending, not unrankable, so they are picked up once the model is ready.
    @discardableResult
    public func backfill(events: [OlanaEvent], context: ModelContext,
                         limit: Int = 40, horizonDays: Int = 60) async -> [OlanaEvent] {
        let now = Date()
        let horizon = now.addingTimeInterval(Double(horizonDays) * 86400)

        let pending = events
            .filter { $0.start > now && $0.start < horizon }
            .filter { $0.cachedSemantics == nil && !$0.isUnrankable }
            .sorted { $0.start < $1.start }        // nearest first: they matter soonest
            .prefix(limit)

        guard !pending.isEmpty, isModelAvailable else { return [] }

        var populated: [OlanaEvent] = []
        for event in pending {
            let outcome = await AIAssistant.shared.semantics(
                title: event.title, calendarName: event.calendarName
            )
            // Became unavailable mid-run (turned off, low power). Stop asking.
            if case .unavailable = outcome { break }
            if event.record(outcome) != nil { populated.append(event) }
        }
        try? context.save()
        return populated
    }
}

// MARK: - OlanaEvent cache bridging

public extension OlanaEvent {

    /// True when the stored sem* fields were written for this title and prompt.
    private var semIsCurrent: Bool {
        semVersion == UrgencyManager.promptVersion && semTitle == title
    }

    /// Cached semantics, or nil when absent, stale, or derived from a different title.
    var cachedSemantics: EventSemantics? {
        guard semIsCurrent,
              let c = semConsequence.flatMap(Consequence.init(rawValue:)),
              let m = semMovability.flatMap(Movability.init(rawValue:)),
              let p = semPrepNeed.flatMap(PrepNeed.init(rawValue:)),
              let g = semCategory.flatMap(EventCategory.init(rawValue:)),
              let r = semRequiresPrep
        else { return nil }
        return EventSemantics(consequence: c, movability: m,
                              requiresPreparation: r, prepNeed: p, category: g)
    }

    /// No semantics and none coming until the title or prompt changes: either a
    /// placeholder title, or one the model has failed on too many times.
    /// Backfill skips these.
    var isUnrankable: Bool {
        guard semIsCurrent, semConsequence == nil else { return false }
        guard let failures = semFailures else { return true }     // placeholder
        return failures >= UrgencyManager.maxFailures
    }

    /// Store the result of an extraction attempt. Returns the semantics when the
    /// model judged the event, nil otherwise.
    @discardableResult
    internal func record(_ outcome: AIAssistant.SemanticsOutcome) -> EventSemantics? {
        switch outcome {
        case .judged(let s):
            applySemantics(s)
            return s
        case .placeholder:
            clearSemantics()
            semFailures = nil
        case .failed:
            let previous = semIsCurrent && semConsequence == nil ? (semFailures ?? 0) : 0
            clearSemantics()
            semFailures = previous + 1
        case .unavailable:
            break   // nothing was attempted; leave the event pending
        }
        return nil
    }

    private func clearSemantics() {
        semConsequence = nil; semMovability = nil; semRequiresPrep = nil
        semPrepNeed = nil; semCategory = nil
        semVersion = UrgencyManager.promptVersion
        semTitle = title
    }

    func applySemantics(_ s: EventSemantics) {
        semConsequence  = s.consequence.rawValue
        semMovability   = s.movability.rawValue
        semRequiresPrep = s.requiresPreparation
        semPrepNeed     = s.prepNeed.rawValue
        semCategory     = s.category.rawValue
        semVersion      = UrgencyManager.promptVersion
        semTitle        = title
        semFailures     = nil

        refreshUrgency()
    }

    /// Keep `urgency` equal to what the app should act on.
    ///
    /// Most of the app (rows, notification profiles, Live Activities) reads
    /// `urgency` directly, not `effectiveUrgency`. So an override has to be
    /// written into `urgency` itself, or the model's judgement silently wins
    /// over the user's choice everywhere except the calendar grid.
    ///
    /// Order: an override (the user's, or their calendar setting), then the
    /// model's judgement scored for now. With neither, `urgency` is left alone.
    func refreshUrgency(now: Date = Date()) {
        if let override = urgencyOverrideRaw.flatMap(EventUrgency.init(rawValue:)) {
            urgency = override
        } else if let semantics = cachedSemantics,
                  let result = UrgencyCombiner.score(semantics: semantics, start: start, now: now) {
            urgency = result.urgency
        }
    }
}
