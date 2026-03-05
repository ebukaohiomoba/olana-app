//
//  UrgencyCorrectionStore.swift
//  Olana
//
//  Persists every urgency feedback event (both confirmations and corrections)
//  to a JSON file in the app's Documents directory.
//
//  ON-DEVICE LEARNING — two mechanisms:
//
//  1. Weighted k-NN  (instant, every classify call)
//     Finds the k most similar past events by cosine similarity over a
//     feature-normalised vector. Each neighbor votes with weight = similarity
//     score so closer events count more. Pre-cached unit-norm vectors make
//     each query a pure dot-product loop — no sqrt, no allocation per call.
//
//  2. Score bias  (learnedScoreAdjustment, applied in UrgencyManager)
//     Inspects the last 50 events and sums up how often the user corrects
//     in each direction (high→medium, medium→low, etc.). Returns a net score
//     delta (capped ±1.5) that shifts the effective bucket thresholds without
//     any retraining. Works from the first 2-3 corrections.
//

import Foundation

// MARK: - UrgencyFeedback

/// One data point: what ML predicted vs what the user actually chose.
struct UrgencyFeedback: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let features: [Double]       // 32-element feature vector
    let mlPrediction: String     // "low" | "medium" | "high"
    let userChoice: String       // "low" | "medium" | "high"
    let text: String             // raw event text (for debugging / future retraining)

    /// True when the user changed the ML suggestion — these are the learning signal.
    var isCorrection: Bool { mlPrediction != userChoice }
}

// MARK: - UrgencyCorrectionStore

final class UrgencyCorrectionStore {

    static let shared = UrgencyCorrectionStore()

    // MARK: - Tuneable thresholds

    /// Rolling window — older samples beyond this are discarded.
    private let maxStoredSamples = 500

    /// Minimum number of *corrections* since the last model update
    /// before we ask MLUpdateTask to re-train.
    let minCorrectionsForUpdate = 15

    /// Don't trigger an update if the correction rate is suspiciously low —
    /// it probably means the model is already doing well.
    let minCorrectionRateForUpdate = 0.08   // 8 %

    // MARK: - State

    private(set) var samples: [UrgencyFeedback] = []
    private(set) var correctionsSinceLastUpdate: Int = 0

    /// Pre-computed unit-normed, feature-scaled vectors for each sample.
    /// Rebuilt on load and appended on record — makes k-NN a pure dot-product loop.
    private var normalizedCache: [[Double]] = []

    // MARK: - Feature normalisation scales
    //
    // Maps each of the 32 features to a rough [0, 1] range before cosine
    // similarity. Without this, hours_until_start (0–720) completely drowns
    // out every binary/categorical feature.
    //
    // Order must exactly match UrgencyManager.extractFeatures return array.

    private static let featureScales: [Double] = [
        336, 1,  1,  1,  1,   // f0-4:  hours_until_start (cap 14d), past_due, 24h, 72h, 14d
        23,  1,  1,  6,  1,   // f5-9:  hour_of_day, casual_kw, beyond_14d, weekday, weekend
        1,   1,  1,  1,  1,   // f10-14: deadline_kw, asap, urgent, tentative, highstakes
        100, 15, 1,  1,        // f15-18: text_length, word_count, question, exclamation
        1,   1,  1,  10, 1, 1, // f19-24: all_day, location, attendees, count, external, ratio
        1,   1,  60, 1,        // f25-28: overlap, dense, travel_slack, tight_travel
        1,   1,  1             // f29-31: deadline_close, stakes_close, allday_no_deadline
    ]

    // MARK: - Persistence

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("urgency_feedback.json")
    }()

    private init() { load() }

    // MARK: - Public API

    /// Record one classification event. Call this every time the user saves
    /// an event regardless of whether they changed the suggestion — both
    /// confirmations and corrections are valuable training signal.
    func record(
        features: [Double],
        mlPrediction: UrgencyBucket,
        userChoice: UrgencyBucket,
        text: String
    ) {
        let feedback = UrgencyFeedback(
            id: UUID(),
            timestamp: Date(),
            features: features,
            mlPrediction: mlPrediction.rawValue,
            userChoice: userChoice.rawValue,
            text: text
        )

        samples.append(feedback)
        normalizedCache.append(normalizeForKNN(features))
        if feedback.isCorrection { correctionsSinceLastUpdate += 1 }

        // Keep rolling window
        if samples.count > maxStoredSamples {
            samples         = Array(samples.suffix(maxStoredSamples))
            normalizedCache = Array(normalizedCache.suffix(maxStoredSamples))
        }

        save()
    }

    /// Call after MLUpdateTask completes so the counter resets correctly.
    func markUpdateCompleted() {
        correctionsSinceLastUpdate = 0
        save()
    }

    // MARK: - Derived metrics

    var shouldTriggerUpdate: Bool {
        correctionsSinceLastUpdate >= minCorrectionsForUpdate &&
        correctionRate >= minCorrectionRateForUpdate
    }

    /// Fraction of all stored samples where the user disagreed with ML.
    var correctionRate: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.filter(\.isCorrection).count) / Double(samples.count)
    }

    // MARK: - Weighted k-NN

    /// Weighted k-NN vote over the user's correction history.
    /// Each neighbor's vote is weighted by its cosine similarity to the query,
    /// so closer events have more influence.
    ///
    /// Returns the winning label and its normalised confidence (0–1),
    /// or nil if there aren't enough samples.
    func weightedVote(for query: [Double], k: Int = 5) -> (label: String, confidence: Double)? {
        guard query.count == 32, !normalizedCache.isEmpty else { return nil }

        let queryNorm = normalizeForKNN(query)

        // Score every sample — O(n × 32) dot products, no allocations inside
        let top = zip(samples, normalizedCache)
            .filter { $0.0.features.count == 32 }
            .map    { (s, nv) in (s, cosineSim(queryNorm, nv)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)

        var votes: [String: Double] = [:]
        var totalWeight = 0.0
        for (sample, sim) in top {
            let w = max(0, sim)   // negative similarity = opposite direction, ignore
            votes[sample.userChoice, default: 0] += w
            totalWeight += w
        }

        guard totalWeight > 0,
              let (label, weight) = votes.max(by: { $0.value < $1.value })
        else { return nil }

        return (label, weight / totalWeight)
    }

    // MARK: - Score bias (immediate learning layer)

    /// Net score adjustment derived from the user's recent correction history.
    ///
    /// Looks at the last 50 saved events. Each correction in a direction adds
    /// a small offset (0.15 per step, 0.30 for two-bucket jumps). The result
    /// is clamped to ±1.5 on a 0–10 score scale.
    ///
    /// Applied by UrgencyManager after the ML+k-NN result — shifts the effective
    /// bucket thresholds without any retraining. Works from the 2nd–3rd correction.
    var learnedScoreAdjustment: Double {
        guard samples.count >= 3 else { return 0 }

        let recent      = samples.suffix(50)
        let corrections = recent.filter(\.isCorrection)
        guard corrections.count >= 2 else { return 0 }

        var downward = 0.0
        var upward   = 0.0
        for c in corrections {
            switch (c.mlPrediction, c.userChoice) {
            case ("high",   "medium"): downward += 0.15
            case ("high",   "low"):    downward += 0.30
            case ("medium", "low"):    downward += 0.15
            case ("low",    "medium"): upward   += 0.15
            case ("low",    "high"):   upward   += 0.30
            case ("medium", "high"):   upward   += 0.15
            default: break
            }
        }
        return max(-1.5, min(1.5, upward - downward))
    }

    // MARK: - Private helpers

    /// Scale features to [0,1] by known range, then unit-norm.
    /// The result is cached so the k-NN loop is a pure dot product.
    private func normalizeForKNN(_ v: [Double]) -> [Double] {
        guard v.count == 32 else { return v }
        let scaled = zip(v, Self.featureScales).map { val, scale in
            min(1.0, abs(val) / scale)
        }
        return unitNorm(scaled)
    }

    private func unitNorm(_ v: [Double]) -> [Double] {
        let mag = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }

    private func cosineSim(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard
            let data    = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([UrgencyFeedback].self, from: data)
        else { return }
        samples         = decoded
        normalizedCache = decoded.map { normalizeForKNN($0.features) }
    }
}
