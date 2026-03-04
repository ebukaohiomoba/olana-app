//
//  MLUrgencyEngine.swift
//  Olana
//

import Foundation
import CoreML

final class MLUrgencyEngine {

    // Score model stays bundle-only (no personalized version needed)
    private let scoreModel: UrgencyScoreModel?

    // Bucket model uses MLModel directly so both bundle and personalized
    // versions can be loaded via the same code path
    private var bucketModel: MLModel?

    var isLoaded: Bool { scoreModel != nil && bucketModel != nil }

    // MARK: - Init

    init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        scoreModel  = try? UrgencyScoreModel(configuration: config)
        bucketModel = Self.loadBucketModel(config: config)

        if isLoaded {
            let source = FileManager.default.fileExists(
                atPath: UrgencyModelUpdater.personalizedModelURL.path
            ) ? "personalized" : "bundle"
            print("✅ MLUrgencyEngine: loaded (\(source) bucket model)")
        } else {
            print("❌ MLUrgencyEngine: model load failed — rule-based fallback active")
        }
    }

    // MARK: - Hot-swap after on-device update

    /// Replace the in-memory bucket model with the freshly saved personalized version.
    /// Called by UrgencyModelUpdater after a successful MLUpdateTask.
    func reloadPersonalizedModel() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let updated = Self.loadBucketModel(config: config) else {
            print("⚠️ MLUrgencyEngine: reloadPersonalizedModel — no model to load")
            return
        }
        bucketModel = updated
        print("✅ MLUrgencyEngine: hot-swapped to personalized bucket model")
    }

    // MARK: - Prediction

    /// Returns a classification whose `confidence` is the real softmax probability,
    /// not a hardcoded constant.
    func predict(features: [Double]) -> UrgencyClassification? {
        guard features.count == 32 else {
            print("❌ MLUrgencyEngine: expected 32 features, got \(features.count)")
            return nil
        }

        // ── Score (0-10) ─────────────────────────────────────────────────────
        let score: Double
        if let scoreModel,
           let input  = makeScoreInput(features),
           let output = try? scoreModel.prediction(input: input) {
            score = output.target
        } else {
            score = 5.0
        }

        // ── Bucket + real softmax confidence ─────────────────────────────────
        guard let bucketModel,
              let input  = makeRawBucketInput(features),
              let output = try? bucketModel.prediction(from: input)
        else {
            // Score model succeeded but bucket failed — derive bucket from score
            let fallback: UrgencyBucket = score < 3.5 ? .low : score >= 7.0 ? .high : .medium
            return UrgencyClassification(
                bucket: fallback, score: score, confidence: 0.55,
                engineVersion: "score_only", rationale: nil
            )
        }

        let (bucket, confidence) = resolveBucketAndConfidence(from: output, fallbackScore: score)

        return UrgencyClassification(
            bucket: bucket,
            score: score,
            confidence: confidence,          // actual softmax probability
            engineVersion: "ml_v1",
            rationale: nil
        )
    }

    // MARK: - k-NN personalization layer

    /// Blends the ML prediction with a weighted vote from the user's own correction history.
    ///
    /// Override rules (all three must hold):
    /// - k-NN vote is strongly consistent (≥80 % of neighbors agree)
    /// - ML is not highly confident (<0.80)
    /// - k-NN and ML disagree on the bucket
    func applyKNNCorrection(
        to base: UrgencyClassification,
        features: [Double]
    ) -> UrgencyClassification {
        let store = UrgencyCorrectionStore.shared
        guard store.samples.count >= 5 else { return base }

        let neighbors = store.nearestNeighbors(to: features, k: 5)
        guard !neighbors.isEmpty else { return base }

        // Equal-weight vote across neighbors
        var votes: [String: Double] = [:]
        let weight = 1.0 / Double(neighbors.count)
        for n in neighbors { votes[n.userChoice, default: 0] += weight }

        guard
            let (topLabel, topStrength) = votes.max(by: { $0.value < $1.value }),
            let knnBucket = UrgencyBucket(rawValue: topLabel),
            topStrength >= 0.80,
            base.confidence < 0.80,
            knnBucket != base.bucket
        else { return base }

        print("🔀 k-NN: \(base.bucket.rawValue) → \(knnBucket.rawValue) "
            + "(vote \(Int(topStrength * 100))%, ML conf \(Int(base.confidence * 100))%)")

        return UrgencyClassification(
            bucket: knnBucket,
            score: scoreFromBucket(knnBucket),
            confidence: topStrength * 0.85,   // slight discount for k-NN uncertainty
            engineVersion: "knn_v1",
            rationale: "Based on your previous choices"
        )
    }

    // MARK: - Private: model loading

    private static func loadBucketModel(config: MLModelConfiguration) -> MLModel? {
        // 1. Personalized model (written by UrgencyModelUpdater after MLUpdateTask)
        let personalized = UrgencyModelUpdater.personalizedModelURL
        if FileManager.default.fileExists(atPath: personalized.path),
           let model = try? MLModel(contentsOf: personalized, configuration: config) {
            return model
        }
        // 2. Bundle model
        if let url   = Bundle.main.url(forResource: "UrgencyBucketModel", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url, configuration: config) {
            return model
        }
        return nil
    }

    // MARK: - Private: output parsing

    /// Two-step resolution:
    /// 1. Softmax probability dictionary — gives the real confidence value.
    /// 2. String classLabel — confidence unknown; use 0.65 as a conservative estimate.
    /// 3. Derive from score as last resort.
    private func resolveBucketAndConfidence(
        from output: MLFeatureProvider,
        fallbackScore: Double
    ) -> (bucket: UrgencyBucket, confidence: Double) {

        // Step 1 — probability dictionary (softmax)
        for key in ["classLabelProbs", "classProbability", "probabilities"] {
            guard let dict = output.featureValue(for: key)?.dictionaryValue else { continue }

            var probs: [UrgencyBucket: Double] = [:]
            for (k, v) in dict {
                let label = (k as? String ?? "\(k)").lowercased()
                if let bucket = normalizedBucket(label) {
                    probs[bucket, default: 0] += v.doubleValue
                }
            }
            if let (bucket, prob) = probs.max(by: { $0.value < $1.value }) {
                return (bucket, prob)
            }
        }

        // Step 2 — string label
        for key in ["classLabel", "label", "predictedLabel"] {
            guard let fv = output.featureValue(for: key), fv.type == .string else { continue }
            if let bucket = normalizedBucket(fv.stringValue) {
                return (bucket, 0.65)   // real softmax unavailable
            }
        }

        // Step 3 — derive from score
        let bucket: UrgencyBucket = fallbackScore < 3.5 ? .low : fallbackScore >= 7.0 ? .high : .medium
        return (bucket, 0.55)
    }

    private func normalizedBucket(_ raw: String) -> UrgencyBucket? {
        switch raw.lowercased() {
        case "low",    "later":    return .low
        case "medium", "soon":     return .medium
        case "high",   "critical": return .high
        default:
            switch Int(raw) {
            case 0: return .low
            case 1: return .medium
            case 2: return .high
            default: return nil
            }
        }
    }

    private func scoreFromBucket(_ b: UrgencyBucket) -> Double {
        switch b { case .low: return 2.5; case .medium: return 5.5; case .high: return 8.5 }
    }

    // MARK: - Private: input builders

    private func makeScoreInput(_ f: [Double]) -> UrgencyScoreModelInput? {
        try? UrgencyScoreModelInput(
            hours_until_start: f[0],  is_past_due: f[1],           within_24h: f[2],
            within_72h: f[3],         within_14d: f[4],             hour_of_day: f[5],
            is_morning: f[6],         is_evening: f[7],             day_of_week: f[8],
            is_weekend: f[9],         has_deadline_keyword: f[10],  has_asap: f[11],
            has_urgent: f[12],        has_tentative_keyword: f[13], has_highstakes_keyword: f[14],
            text_length: f[15],       word_count: f[16],            has_question_mark: f[17],
            has_exclamation: f[18],   is_all_day: f[19],            has_location: f[20],
            has_attendees: f[21],     attendee_count: f[22],        has_external_attendee: f[23],
            external_attendee_ratio: f[24], has_overlap_30m: f[25], has_dense_hour: f[26],
            travel_slack_minutes: f[27], has_tight_travel: f[28],   deadline_and_close: f[29],
            stakes_and_close: f[30],  allday_no_deadline: f[31]
        )
    }

    /// Build an MLFeatureProvider from raw [Double] — used for both bundle and
    /// personalized MLModel instances (neither needs the autogenerated input class).
    private func makeRawBucketInput(_ f: [Double]) -> MLFeatureProvider? {
        let names = [
            "hours_until_start", "is_past_due", "within_24h", "within_72h", "within_14d",
            "hour_of_day", "is_morning", "is_evening", "day_of_week", "is_weekend",
            "has_deadline_keyword", "has_asap", "has_urgent", "has_tentative_keyword",
            "has_highstakes_keyword", "text_length", "word_count", "has_question_mark",
            "has_exclamation", "is_all_day", "has_location", "has_attendees",
            "attendee_count", "has_external_attendee", "external_attendee_ratio",
            "has_overlap_30m", "has_dense_hour", "travel_slack_minutes", "has_tight_travel",
            "deadline_and_close", "stakes_and_close", "allday_no_deadline"
        ]
        var dict: [String: MLFeatureValue] = [:]
        for (i, name) in names.enumerated() { dict[name] = MLFeatureValue(double: f[i]) }
        return try? MLDictionaryFeatureProvider(dictionary: dict)
    }
}

// MARK: - Supporting Types

enum UrgencyBucket: String, Codable, CaseIterable {
    case low    = "low"
    case medium = "medium"
    case high   = "high"
}

struct UrgencyClassification {
    let bucket: UrgencyBucket
    let score: Double        // 0-10
    let confidence: Double   // real softmax probability (0-1), not a training accuracy stat
    let engineVersion: String
    let rationale: String?
}
