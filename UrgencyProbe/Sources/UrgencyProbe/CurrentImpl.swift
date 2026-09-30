//
//  CurrentImpl.swift
//
//  Faithful replication of Olana's SHIPPING urgency path, so it can be run
//  head to head against the Option 5 probe on identical input.
//
//  Two paths are replicated because production has two:
//    1. UrgencyManager.classify   — XGBoost, used only by AddEventView
//    2. CalendarSyncEngine.assignUrgency — keyword chain, used by every
//       imported calendar event
//
//  extractFeatures is mirrored with the production defaults: both real call
//  sites pass only (text, date), so isAllDay / location / attendees / context
//  fall through and features 19-28 are constant zero.
//

import Foundation
import CoreML

enum CurrentImpl {

    // Keyword lists, verbatim from UrgencyManager.swift
    static let deadlineK   = ["deadline", "due", "submit", "final", "deliver", "turn in"]
    static let tentativeK  = ["maybe", "tentative", "possibly", "might", "tbd", "to be determined"]
    static let casualK     = ["coffee", "lunch", "catch up", "browse", "errand", "walk", "read",
                              "relax", "chill", "hang out", "netflix", "movie", "game", "gym", "workout"]
    static let highStakesK = ["ceo", "exec", "board", "client", "presentation", "demo", "interview",
                              "doctor", "surgery", "court", "wedding", "exam", "performance", "funeral"]

    // CalendarSyncEngine.swift criticalKeywords, verbatim
    static let syncCriticalK = ["deadline", "interview", "presentation", "exam", "surgery",
                                "flight", "final", "urgent", "critical", "demo", "launch",
                                "due", "submit", "defend", "pitch"]

    static let featureNames = [
        "hours_until_start", "is_past_due", "within_24h", "within_72h", "within_14d",
        "hour_of_day", "has_casual_keyword", "beyond_14d", "day_of_week", "is_weekend",
        "has_deadline_keyword", "has_asap", "has_urgent", "has_tentative_keyword",
        "has_highstakes_keyword", "text_length", "word_count", "has_question_mark",
        "has_exclamation", "is_all_day", "has_location", "has_attendees",
        "attendee_count", "has_external_attendee", "external_attendee_ratio",
        "has_overlap_30m", "has_dense_hour", "travel_slack_minutes", "has_tight_travel",
        "deadline_and_close", "stakes_and_close", "allday_no_deadline"
    ]

    static func hit(_ s: String, _ words: [String]) -> Bool {
        words.contains { s.contains($0) }
    }

    /// Mirror of UrgencyManager.extractFeatures with production defaults.
    static func features(title: String, hoursUntil: Double) -> [String: Double] {
        let now = Date()
        let eventDate = now.addingTimeInterval(hoursUntil * 3600)
        let low = title.lowercased()

        let h = max(hoursUntil, 0)
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: eventDate))
        let weekday = Double(cal.component(.weekday, from: eventDate) - 1)

        let hasDeadline = hit(low, deadlineK)
        let hasStakes = hit(low, highStakesK)
        let within72 = h < 72 && hoursUntil >= 0

        let vals: [Double] = [
            h,
            hoursUntil < 0 ? 1 : 0,
            (h < 24 && hoursUntil >= 0) ? 1 : 0,
            within72 ? 1 : 0,
            (h < 336 && hoursUntil >= 0) ? 1 : 0,
            hour,
            hit(low, casualK) ? 1 : 0,
            h > 336 ? 1 : 0,
            weekday,
            [0.0, 6.0].contains(weekday) ? 1 : 0,
            hasDeadline ? 1 : 0,
            low.contains("asap") ? 1 : 0,
            low.contains("urgent") ? 1 : 0,
            hit(low, tentativeK) ? 1 : 0,
            hasStakes ? 1 : 0,
            Double(title.count),
            Double(title.split(separator: " ").count),
            title.contains("?") ? 1 : 0,
            title.contains("!") ? 1 : 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,      // features 19-28: dead at inference
            (hasDeadline && within72) ? 1 : 0,
            (hasStakes && within72) ? 1 : 0,
            0                                    // allday_no_deadline: isAllDay is always false
        ]

        var dict: [String: Double] = [:]
        for (i, n) in featureNames.enumerated() { dict[n] = vals[i] }
        return dict
    }

    /// CalendarSyncEngine.assignUrgency — the path every imported event takes.
    static func keywordPath(title: String, hoursUntil: Double) -> String {
        let low = title.lowercased()
        if syncCriticalK.contains(where: { low.contains($0) }) { return "high" }
        if hoursUntil >= 0 && hoursUntil < 24 { return hoursUntil <= 3 ? "high" : "medium" }
        if hoursUntil < 48 { return "medium" }
        if hoursUntil < 168 { return "medium" }
        return "low"
    }

    static func loadModel(_ path: String) throws -> MLModel {
        let url = URL(fileURLWithPath: path)
        let compiled = try MLModel.compileModel(at: url)
        return try MLModel(contentsOf: compiled)
    }

    struct MLResult { let bucket: String; let confidence: Double; let score: Double }

    static func predict(bucketModel: MLModel, scoreModel: MLModel,
                        title: String, hoursUntil: Double) -> MLResult? {
        let f = features(title: title, hoursUntil: hoursUntil)
        var fv: [String: MLFeatureValue] = [:]
        for (k, v) in f { fv[k] = MLFeatureValue(double: v) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: fv) else { return nil }

        var score = Double.nan
        if let out = try? scoreModel.prediction(from: provider) {
            for n in out.featureNames {
                if let v = out.featureValue(for: n), v.type == .double { score = v.doubleValue; break }
            }
        }

        guard let out = try? bucketModel.prediction(from: provider) else { return nil }
        var label = "?"
        var conf = Double.nan
        for key in ["classProbability", "classLabelProbs", "probabilities"] {
            if let d = out.featureValue(for: key)?.dictionaryValue {
                var best = ("?", -1.0)
                for (k, v) in d {
                    let s = (k as? String) ?? "\(k)"
                    if v.doubleValue > best.1 { best = (s, v.doubleValue) }
                }
                label = best.0; conf = best.1; break
            }
        }
        if label == "?" {
            for key in ["target", "classLabel", "label"] {
                if let v = out.featureValue(for: key), v.type == .string { label = v.stringValue; break }
            }
        }
        return MLResult(bucket: label.lowercased(), confidence: conf, score: score)
    }
}
