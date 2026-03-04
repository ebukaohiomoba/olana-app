//
//  UrgencyCorrectionStore.swift
//  Olana
//
//  Persists every urgency feedback event (both confirmations and corrections)
//  to a JSON file in the app's Documents directory. Also provides the k-NN
//  neighbor lookup used by MLUrgencyEngine for immediate personalization.
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
        if feedback.isCorrection { correctionsSinceLastUpdate += 1 }

        // Keep rolling window
        if samples.count > maxStoredSamples {
            samples = Array(samples.suffix(maxStoredSamples))
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

    // MARK: - k-NN lookup

    /// Returns the k samples most similar to `query` by cosine similarity.
    /// Used by MLUrgencyEngine to blend user history into the prediction.
    func nearestNeighbors(to query: [Double], k: Int = 5) -> [UrgencyFeedback] {
        guard query.count == 32 else { return [] }

        let queryNorm = unitNorm(query)

        return samples
            .filter { $0.features.count == 32 }
            .map    { ($0, cosineSim(queryNorm, unitNorm($0.features))) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map    { $0.0 }
    }

    // MARK: - Math helpers

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
        samples = decoded
    }
}
