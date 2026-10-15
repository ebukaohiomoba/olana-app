//
//  BackgroundRefreshSpikes.swift
//  Olana
//
//  DEBUG only. M0 spike measurements riding on the real background run
//  (spec v3 §2.1): S1 keeps calling the model after step 5 until rateLimited
//  or the time guard, to learn the budget; S2 optionally tries a scheduled
//  Live Activity from the background. Manual runs from the Spikes screen are
//  tagged and left out of the S1 numbers.
//

#if DEBUG
import Foundation
import FoundationModels
import ActivityKit

extension BackgroundRefresh {

    /// S1: after the real work, keep calling the model to measure the budget.
    static var measureBudget: Bool {
        get { UserDefaults.standard.object(forKey: "spikeS1Measure") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "spikeS1Measure") }
    }

    /// S2's background half, set from the Spikes screen.
    static var tryLiveActivityInBackground: Bool {
        get { UserDefaults.standard.bool(forKey: "spikeS2Background") }
        set { UserDefaults.standard.set(newValue, forKey: "spikeS2Background") }
    }

    /// The same steps, started by hand. The simulator never runs BGTasks.
    @MainActor
    static func runManually() async {
        _ = await steps(runID: "manual-" + String(UUID().uuidString.prefix(4)), started: Date(), manual: true)
    }

    @MainActor
    static func debugSpikes(runID: String, started: Date, manual: Bool) async {
        if tryLiveActivityInBackground { await s2Background(runID: runID) }
        guard measureBudget else { return }
        let r = await s1Budget(runID: runID, started: started)
        SpikeLog.write("s1", "run end", [
            "run": runID, "manual": "\(manual)",
            "ok": "\(r.ok)", "failed": "\(r.failed)", "stop": r.stop,
            "elapsed": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
    }

    /// Made-up titles: the budget question doesn't need real events, and these
    /// never get written anywhere.
    static let probeTitles = [
        "Dentist cleaning", "Quarterly review", "Pick up dry cleaning", "1:1 with Sam",
        "Flight to Denver", "Rent due", "Team standup", "Parent-teacher conference",
        "Gym", "Car service appointment", "Submit expense report", "Haircut",
    ]

    struct S1Result { var ok = 0, failed = 0, stop = "" }

    @MainActor
    static func s1Budget(runID: String, started: Date) async -> S1Result {
        var r = S1Result()
        guard case .available = SystemLanguageModel.default.availability else {
            r.stop = "model unavailable"
            return r
        }
        let options = GenerationOptions(sampling: .greedy)
        var i = 0
        while true {
            if Task.isCancelled { r.stop = "expired"; break }
            let left = assumedBudget - Date().timeIntervalSince(started)
            if left < stopWithLeft { r.stop = "time guard"; break }
            if i >= 60 { r.stop = "cap 60"; break }

            let title = probeTitles[i % probeTitles.count]
            let t0 = Date()
            let session = LanguageModelSession(instructions: EventSemanticsPrompt.instructions)
            do {
                _ = try await session.respond(to: EventSemanticsPrompt.prompt(title: title, calendarName: nil),
                                              generating: EventSemantics.self, options: options)
                r.ok += 1
                SpikeLog.write("s1", "call ok", ["run": runID, "i": "\(i)",
                                                 "secs": String(format: "%.2f", Date().timeIntervalSince(t0))])
            } catch let error as LanguageModelSession.GenerationError {
                r.failed += 1
                let kind: String
                switch error {
                case .rateLimited: kind = "rateLimited"
                case .refusal, .guardrailViolation: kind = "refusal"
                default: kind = "other"
                }
                SpikeLog.write("s1", "call failed", ["run": runID, "i": "\(i)", "kind": kind, "error": "\(error)"])
                if kind == "rateLimited" { r.stop = "rateLimited"; break }
            } catch {
                r.failed += 1
                SpikeLog.write("s1", "call failed", ["run": runID, "i": "\(i)", "kind": "other", "error": "\(error)"])
            }
            i += 1
        }
        return r
    }

    // MARK: - S2 (background half)

    @MainActor
    static func s2Background(runID: String) async {
        do {
            _ = try SpikeLiveActivity.requestScheduled(minutesFromNow: 10, label: "background")
            SpikeLog.write("s2", "background scheduled request ok", ["run": runID])
        } catch {
            SpikeLog.write("s2", "background scheduled request failed", ["run": runID, "error": "\(error)"])
        }
    }
}

// MARK: - Scheduled Live Activity (S2)

enum SpikeLiveActivity {
    /// iOS 26 scheduled start: `request(…, alertConfiguration:, start:)`.
    @MainActor
    static func requestScheduled(minutesFromNow: Double, label: String) throws -> String {
        let start = Date(timeIntervalSinceNow: minutesFromNow * 60)
        let eventStart = start.addingTimeInterval(15 * 60)
        let attributes = OlanaEventAttributes(eventId: "spike-s2-\(UUID().uuidString)",
                                              eventTitle: "S2 test (\(label))", urgencyRaw: 2)
        let state = OlanaEventAttributes.ContentState(eventStart: eventStart, minutesRemaining: 15, status: "upcoming")
        let activity = try Activity<OlanaEventAttributes>.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: eventStart.addingTimeInterval(300)),
            pushType: nil,
            style: .standard,
            alertConfiguration: AlertConfiguration(title: "S2 test", body: "Scheduled Live Activity started", sound: .default),
            start: start
        )
        return activity.id
    }
}
#endif
