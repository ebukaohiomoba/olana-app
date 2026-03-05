//
//  UrgencyManager.swift
//  Olana
//
//  PIPELINE (in order):
//  1. Feature extraction  — always runs
//  2. CoreML prediction   — always runs; returns neutral placeholder if model unavailable
//  3. k-NN personalization — blends user correction history (UrgencyCorrectionStore)
//  4. Hard overrides      — only for unambiguous facts (past due, "911"/"emergency")
//  5. Rationale           — informational only, does not change bucket
//

import Foundation
import CoreML
import Combine

class UrgencyManager: ObservableObject {

    static let shared = UrgencyManager()

    private let mlEngine = MLUrgencyEngine()

    @Published var isModelLoaded: Bool = false

    /// Feature vector captured during classify() so logFeedback() can reuse it
    /// without recomputing from text (keeps the correction perfectly aligned).
    private var lastFeatures: [Double]?

    private init() {
        isModelLoaded = mlEngine.isLoaded
    }

    // MARK: - Main Classification

    func classify(
        text: String,
        date: Date?,
        isAllDay: Bool = false,
        location: String? = nil,
        attendees: [String] = [],
        context: EventContext? = nil
    ) -> UrgencyClassification {

        let now        = Date()
        let hoursUntil = (date?.timeIntervalSinceNow ?? (7 * 24 * 3600)) / 3600
        let lowercased = text.lowercased()

        // ── 1. Feature extraction ─────────────────────────────────────────────
        let features = extractFeatures(
            text: text, date: date, isAllDay: isAllDay,
            location: location, attendees: attendees, context: context
        )
        lastFeatures = features

        // ── 2. CoreML — runs unconditionally ──────────────────────────────────
        // When the model is not yet loaded we return a neutral placeholder rather
        // than a rule-based fallback — the UI treats this as "model warming up".
        var result: UrgencyClassification
        if isModelLoaded, let prediction = mlEngine.predict(features: features) {
            result = prediction
        } else {
            result = UrgencyClassification(
                bucket: .medium, score: 5.0, confidence: 0.0,
                engineVersion: "model_unavailable", rationale: nil
            )
        }

        // ── 3. k-NN personalization ───────────────────────────────────────────
        // Blends user correction history. Only overrides when k-NN is strongly
        // consistent (≥80 %) AND ML is uncertain (<80 % confidence).
        result = mlEngine.applyKNNCorrection(to: result, features: features)

        // ── 3b. Score bias (immediate learning from corrections) ──────────────
        // Derived from recent correction direction counts — no retraining needed.
        // Shifts the effective bucket thresholds whenever the user consistently
        // disagrees with ML in the same direction (e.g. always lowers high→medium).
        let bias = UrgencyCorrectionStore.shared.learnedScoreAdjustment
        if abs(bias) >= 0.15 {
            let biasedScore  = result.score + bias
            let biasedBucket: UrgencyBucket = biasedScore < 3.2 ? .low
                                            : biasedScore >= 6.2 ? .high : .medium
            if biasedBucket != result.bucket {
                result = UrgencyClassification(
                    bucket:        biasedBucket,
                    score:         biasedScore,
                    confidence:    result.confidence * 0.92,
                    engineVersion: result.engineVersion + "+bias",
                    rationale:     nil
                )
            }
        }

        // ── 4. Hard overrides (unambiguous facts — not heuristics) ────────────
        if let date, date < now {
            return UrgencyClassification(
                bucket: .high, score: 9.8, confidence: 0.99,
                engineVersion: "override_past_due",
                rationale: "🚨 PAST DUE!"
            )
        }
        // "911" / "emergency" — user literally wrote these words
        if ["911", "call 911", "emergency"].contains(where: { lowercased.contains($0) }) {
            return UrgencyClassification(
                bucket: .high, score: 9.9, confidence: 0.99,
                engineVersion: "override_emergency",
                rationale: "🚨 Emergency language"
            )
        }

        // ── 5. Build rationale (informational only — does not change bucket) ──
        var reasons: [String] = []
        if let r = result.rationale { reasons.append(r) }

        // Time context
        if let date {
            switch hoursUntil {
            case ..<0:    reasons.append("🚨 PAST DUE!")
            case ..<1:    reasons.append("⏰ Within 1 hour")
            case ..<2:    reasons.append("⏰ Within 2 hours")
            case ..<24:   reasons.append("⏰ Today (\(Int(hoursUntil))h away)")
            case ..<48:   reasons.append("📅 Tomorrow")
            case ..<72:   reasons.append("📅 Within 3 days")
            case ..<168:  reasons.append("📅 This week")
            default:      reasons.append("📅 \(Int(hoursUntil / 24)) days away")
            }
        } else {
            reasons.append("❓ No specific date")
        }

        // Keyword signals (informational)
        if lowercased.containsDeadlineKeyword  { reasons.append("📅 Mentions deadline") }
        if lowercased.containsHighStakesKeyword { reasons.append("⭐ High-stakes event") }
        if !attendees.isEmpty                  { reasons.append("👥 \(attendees.count) attendees") }
        if isAllDay                            { reasons.append("📆 All-day event") }

        let fullRationale = reasons.isEmpty ? nil : reasons.joined(separator: " • ")

        return UrgencyClassification(
            bucket: result.bucket,
            score: result.score,
            confidence: result.confidence,
            engineVersion: result.engineVersion,
            rationale: fullRationale
        )
    }

    /// Convenience — classify a stored OlanaEvent directly.
    func classify(event: OlanaEvent, context: EventContext? = nil) -> UrgencyClassification {
        classify(text: event.title, date: event.start, context: context)
    }

    // MARK: - Feedback Logging (on-device learning)

    /// Call this every time the user saves an event.
    /// Both confirmations (user agreed) and corrections (user changed) are recorded —
    /// confirmations are important to prevent the k-NN from only seeing error cases.
    func logFeedback(
        text: String,
        date: Date?,
        mlPrediction: UrgencyBucket,
        userChoice: UrgencyBucket
    ) {
        // Reuse the exact features from the preceding classify() call so the
        // correction aligns with what the model actually saw
        let features = lastFeatures ?? extractFeatures(
            text: text, date: date, isAllDay: false,
            location: nil, attendees: [], context: nil
        )

        UrgencyCorrectionStore.shared.record(
            features: features,
            mlPrediction: mlPrediction,
            userChoice: userChoice,
            text: text
        )

        // Trigger background fine-tuning if the update threshold is reached
        if UrgencyCorrectionStore.shared.shouldTriggerUpdate {
            let engine = mlEngine
            Task.detached(priority: .background) {
                UrgencyModelUpdater.shared.updateIfNeeded(engine: engine)
            }
        }
    }

    // MARK: - Feature Extraction (unchanged)

    private func extractFeatures(
        text: String,
        date: Date?,
        isAllDay: Bool,
        location: String?,
        attendees: [String],
        context: EventContext?
    ) -> [Double] {

        let now       = Date()
        let eventDate = date ?? Calendar.current.date(byAdding: .day, value: 7, to: now)!

        let lowercased = text.lowercased()

        // TIME FEATURES (0-9)
        let hoursUntilStart = max(eventDate.timeIntervalSince(now) / 3600, 0)
        let isPastDue  = eventDate < now
        let within24h  = hoursUntilStart < 24  && hoursUntilStart >= 0
        let within72h  = hoursUntilStart < 72  && hoursUntilStart >= 0
        let within14d  = hoursUntilStart < 336 && hoursUntilStart >= 0

        let calendar          = Calendar.current
        let hour              = calendar.component(.hour,    from: eventDate)
        let weekday           = calendar.component(.weekday, from: eventDate) - 1
        let hasCasualKeyword  = lowercased.containsCasualKeyword
        let beyondTwoWeeks    = hoursUntilStart > 336   // f[7]: >14 days away
        let isWeekend         = [0, 6].contains(weekday)

        // TEXT FEATURES (10-18)
        let hasDeadlineKeyword    = lowercased.containsDeadlineKeyword
        let hasAsap               = lowercased.contains("asap")
        let hasUrgent             = lowercased.contains("urgent")
        let hasTentativeKeyword   = lowercased.containsTentativeKeyword
        let hasHighStakesKeyword  = lowercased.containsHighStakesKeyword
        let textLength            = Double(text.count)
        let wordCount             = Double(text.components(separatedBy: .whitespacesAndNewlines)
                                          .filter { !$0.isEmpty }.count)
        let hasQuestionMark       = text.contains("?")
        let hasExclamation        = text.contains("!")

        // EVENT FEATURES (19-24)
        let hasLocation     = location != nil && !location!.isEmpty
        let hasAttendees    = !attendees.isEmpty
        let attendeeCount   = Double(attendees.count)
        let externalAtt     = attendees.filter { !$0.contains("@yourdomain.com") }
        let hasExternal     = !externalAtt.isEmpty
        let externalRatio   = attendees.isEmpty ? 0.0 : Double(externalAtt.count) / Double(attendees.count)

        // CONTEXT FEATURES (25-28)
        let hasOverlap30m      = context?.hasOverlappingEvent ?? false
        let hasDenseHour       = context?.hasDenseHour ?? false
        let travelSlack        = context?.travelSlackMinutes ?? 0.0
        let hasTightTravel     = hasLocation && travelSlack < 15  // only meaningful with a location

        // INTERACTION FEATURES (29-31)
        let deadlineAndClose   = hasDeadlineKeyword && within72h
        let stakesAndClose     = hasHighStakesKeyword && within72h
        let alldayNoDeadline   = isAllDay && !hasDeadlineKeyword

        return [
            hoursUntilStart,        isPastDue ? 1.0 : 0.0,   within24h ? 1.0 : 0.0,
            within72h ? 1.0 : 0.0,  within14d ? 1.0 : 0.0,   Double(hour),
            hasCasualKeyword ? 1.0 : 0.0,  beyondTwoWeeks ? 1.0 : 0.0,  Double(weekday),
            isWeekend ? 1.0 : 0.0,
            hasDeadlineKeyword ? 1.0 : 0.0,  hasAsap ? 1.0 : 0.0,   hasUrgent ? 1.0 : 0.0,
            hasTentativeKeyword ? 1.0 : 0.0, hasHighStakesKeyword ? 1.0 : 0.0,
            textLength, wordCount,  hasQuestionMark ? 1.0 : 0.0,  hasExclamation ? 1.0 : 0.0,
            isAllDay ? 1.0 : 0.0,   hasLocation ? 1.0 : 0.0,  hasAttendees ? 1.0 : 0.0,
            attendeeCount,          hasExternal ? 1.0 : 0.0,   externalRatio,
            hasOverlap30m ? 1.0 : 0.0, hasDenseHour ? 1.0 : 0.0, travelSlack,
            hasTightTravel ? 1.0 : 0.0,
            deadlineAndClose ? 1.0 : 0.0, stakesAndClose ? 1.0 : 0.0, alldayNoDeadline ? 1.0 : 0.0
        ]
    }

}

// MARK: - Supporting Types

struct EventContext {
    let hasOverlappingEvent: Bool
    let hasDenseHour: Bool
    let travelSlackMinutes: Double

    init(hasOverlappingEvent: Bool = false, hasDenseHour: Bool = false, travelSlackMinutes: Double = 0) {
        self.hasOverlappingEvent = hasOverlappingEvent
        self.hasDenseHour        = hasDenseHour
        self.travelSlackMinutes  = travelSlackMinutes
    }
}

// MARK: - String Extensions

extension String {
    var containsDeadlineKeyword: Bool {
        ["deadline", "due", "submit", "final", "deliver", "turn in"]
            .contains { lowercased().contains($0) }
    }
    var containsTentativeKeyword: Bool {
        ["maybe", "tentative", "possibly", "might", "tbd", "to be determined"]
            .contains { lowercased().contains($0) }
    }
    var containsCasualKeyword: Bool {
        ["coffee", "lunch", "catch up", "browse", "errand", "walk", "read",
         "relax", "chill", "hang out", "netflix", "movie", "game", "gym", "workout"]
            .contains { lowercased().contains($0) }
    }
    var containsHighStakesKeyword: Bool {
        // "meeting" removed (too generic — causes false high urgency on standups)
        ["ceo", "exec", "board", "client", "presentation", "demo", "interview",
         "doctor", "surgery", "court", "wedding", "exam", "performance", "funeral"]
            .contains { lowercased().contains($0) }
    }
}
