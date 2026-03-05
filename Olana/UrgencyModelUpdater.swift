//
//  UrgencyModelUpdater.swift
//  Olana
//
//  Wraps MLUpdateTask to fine-tune the UrgencyBucketModel on-device using
//  the correction samples stored by UrgencyCorrectionStore.
//
//  HOW IT WORKS
//  ─────────────
//  1.  After `minCorrectionsForUpdate` user corrections accumulate,
//      UrgencyManager calls updateIfNeeded(engine:).
//  2.  We build an MLArrayBatchProvider from all stored samples.
//  3.  MLUpdateTask fine-tunes the model starting from whichever version
//      is currently active (personalized if it exists, bundle otherwise).
//      This is incremental — each update builds on the previous one.
//  4.  The updated model is saved to the app's Documents directory as
//      "UrgencyBucketModel_personalized.mlmodelc".
//  5.  MLUrgencyEngine.reloadPersonalizedModel() is called to hot-swap
//      the in-memory model without restarting the app.
//
//  REQUIREMENT
//  ────────────
//  The UrgencyBucketModel must have been exported from Create ML with
//  "Make Model Updatable" enabled (Neural Network Classifier only).
//  If the model is NOT updatable, MLUpdateTask throws immediately and
//  we log a clear message — k-NN correction still works as a fallback.
//
//  COOLDOWN
//  ─────────
//  Updates are throttled to at most once every 7 days to prevent rapid
//  model drift from short bursts of atypical corrections.
//

import Foundation
import CoreML

final class UrgencyModelUpdater {

    static let shared = UrgencyModelUpdater()

    // MARK: - File locations

    /// Where the on-device fine-tuned model lives (outside the bundle so it is writable).
    static var personalizedModelURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UrgencyBucketModel_personalized.mlmodelc")
    }

    // MARK: - Config

    private let updateCooldown: TimeInterval = 7 * 24 * 3600   // 7 days
    private let lastUpdateKey = "urgency_model_last_update_date"
    private let minSamplesForBatch = 10   // won't attempt update with fewer than this many samples

    // MARK: - State

    private var isUpdating = false
    private init() {}

    // MARK: - Public

    /// Attempt to fine-tune the model in the background.
    /// Safe to call from any thread/Task — does nothing if already updating or on cooldown.
    func updateIfNeeded(engine: MLUrgencyEngine) {
        let store = UrgencyCorrectionStore.shared

        guard store.shouldTriggerUpdate else { return }
        guard !isUpdating               else { return }
        guard !isOnCooldown             else {
            print("🕐 UrgencyModelUpdater: update skipped — cooldown active (next allowed in \(cooldownRemainingDays)d)")
            return
        }
        guard let sourceURL = sourceModelURL else {
            print("❌ UrgencyModelUpdater: no source model found in bundle or documents")
            return
        }
        guard let batchProvider = makeBatchProvider(from: store.samples),
              batchProvider.count >= minSamplesForBatch
        else {
            print("⚠️ UrgencyModelUpdater: not enough valid samples for update (need \(minSamplesForBatch)+)")
            return
        }

        isUpdating = true

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        do {
            let task = try MLUpdateTask(
                forModelAt: sourceURL,
                trainingData: batchProvider,
                configuration: config
            ) { [weak self] context in
                self?.handleCompletion(context: context, engine: engine)
            }
            task.resume()
            print("🔄 UrgencyModelUpdater: update started (\(store.samples.count) samples, source: \(sourceURL.lastPathComponent))")
        } catch {
            // Most common reason: model was not exported with "Make Model Updatable".
            // k-NN correction in MLUrgencyEngine still adapts without this.
            print("⚠️ UrgencyModelUpdater: MLUpdateTask unavailable — \(error.localizedDescription)")
            print("   → Tip: in Create ML, enable 'Make Model Updatable' on the UrgencyBucketModel.")
            print("   → k-NN personalization is still active and will adapt predictions.")
            isUpdating = false
        }
    }

    // MARK: - Private

    private var isOnCooldown: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date else { return false }
        return Date().timeIntervalSince(last) < updateCooldown
    }

    private var cooldownRemainingDays: Int {
        guard let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date else { return 0 }
        let remaining = updateCooldown - Date().timeIntervalSince(last)
        return max(0, Int(remaining / 86400))
    }

    /// Prefer the personalized model as source so each update is incremental.
    private var sourceModelURL: URL? {
        let personalized = Self.personalizedModelURL
        if FileManager.default.fileExists(atPath: personalized.path) { return personalized }
        return Bundle.main.url(forResource: "UrgencyBucketModel", withExtension: "mlmodelc")
    }

    private func handleCompletion(context: MLUpdateContext, engine: MLUrgencyEngine) {
        defer { isUpdating = false }

        if let error = context.task.error {
            print("❌ UrgencyModelUpdater: update failed — \(error.localizedDescription)")
            return
        }

        do {
            try context.model.write(to: Self.personalizedModelURL)
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
            UrgencyCorrectionStore.shared.markUpdateCompleted()
            engine.reloadPersonalizedModel()
            print("✅ UrgencyModelUpdater: personalized model saved and hot-swapped")
        } catch {
            print("❌ UrgencyModelUpdater: failed to save updated model — \(error.localizedDescription)")
        }
    }

    // MARK: - Training batch

    /// Feature names must match UrgencyBucketModel's input spec exactly.
    private let featureNames = [
        "hours_until_start", "is_past_due", "within_24h", "within_72h", "within_14d",
        "hour_of_day", "has_casual_keyword", "beyond_14d", "day_of_week", "is_weekend",
        "has_deadline_keyword", "has_asap", "has_urgent", "has_tentative_keyword",
        "has_highstakes_keyword", "text_length", "word_count", "has_question_mark",
        "has_exclamation", "is_all_day", "has_location", "has_attendees",
        "attendee_count", "has_external_attendee", "external_attendee_ratio",
        "has_overlap_30m", "has_dense_hour", "travel_slack_minutes", "has_tight_travel",
        "deadline_and_close", "stakes_and_close", "allday_no_deadline"
    ]

    private func makeBatchProvider(from samples: [UrgencyFeedback]) -> MLArrayBatchProvider? {
        var providers: [MLFeatureProvider] = []

        for sample in samples where sample.features.count == 32 {
            var dict: [String: MLFeatureValue] = [:]
            for (i, name) in featureNames.enumerated() {
                dict[name] = MLFeatureValue(double: sample.features[i])
            }
            // "label" is the target output key Create ML uses for updatable classifiers
            dict["label"] = MLFeatureValue(string: sample.userChoice)

            if let provider = try? MLDictionaryFeatureProvider(dictionary: dict) {
                providers.append(provider)
            }
        }

        guard providers.count >= minSamplesForBatch else { return nil }
        return MLArrayBatchProvider(array: providers)
    }
}
