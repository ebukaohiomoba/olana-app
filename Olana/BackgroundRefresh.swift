//
//  BackgroundRefresh.swift
//  Olana
//
//  DEBUG only, for now. The `com.olana.refresh` BGAppRefreshTask in the order
//  PRD v6 §3.2 sets, each step useful if the run is cut off after it:
//
//    0  if !isProtectedDataAvailable → reschedule, exit            ← S3 measures this
//    1  Sync                                                        M1-A
//    2  Plan alerts from known facts; integrity check               M1-A
//    3  ETA refresh                                                 M1-C
//    4  Replan                                                      M1-A
//    5  Model: up to 3 jobs, stop on rateLimited or < 8 s left      ← S1 measures the budget
//    6  Replan if step 5 produced anything                          M1-A
//
//  For S1 step 5 deliberately keeps calling past 3 jobs, until rateLimited or
//  the time guard, so we learn the real budget. It sends made-up titles with
//  the shipping EventSemantics prompt and stores nothing, so no event data
//  changes. M1-A replaces this file with the real run and drops the spike code.
//

#if DEBUG
import Foundation
import UIKit
import BackgroundTasks
import FoundationModels
import ActivityKit

enum BackgroundRefresh {

    static let identifier = "com.olana.refresh"

    /// Assume the system's ~30 s refresh budget; stop the model step with 8 s
    /// left (PRD §3.2 step 5).
    static let assumedBudget: TimeInterval = 30
    static let stopWithLeft: TimeInterval = 8

    /// Toggle for S2's background half, set from the Spikes screen.
    static var tryLiveActivityInBackground: Bool {
        get { UserDefaults.standard.bool(forKey: "spikeS2Background") }
        set { UserDefaults.standard.set(newValue, forKey: "spikeS2Background") }
    }

    private static var observer: NSObjectProtocol?

    /// Call from `didFinishLaunching`, before it returns.
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            run(task)
        }
        SpikeLog.write("bg", "registered", ["ok": "\(ok)"])
        // Request the next run on every foreground (spec §5.4).
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in schedule(reason: "foreground") }
    }

    /// Earliest begin 30 min (spec §5.4). Submitting again replaces the request.
    static func schedule(reason: String) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SpikeLog.write("bg", "submit failed", ["reason": reason, "error": "\(error)"])
        }
    }

    // MARK: - Run

    private static func run(_ task: BGAppRefreshTask) {
        let started = Date()
        let runID = String(UUID().uuidString.prefix(8))
        schedule(reason: "run")

        let once = CompleteOnce(task)
        let work = Task { @MainActor in
            await steps(runID: runID, started: started)
        }
        task.expirationHandler = {
            work.cancel()
            SpikeLog.write("bg", "expired", ["run": runID,
                                             "elapsed": String(format: "%.1f", Date().timeIntervalSince(started))])
            once.complete(false)
        }
        Task {
            let completed = await work.value
            once.complete(completed)
        }
    }

    @MainActor
    private static func steps(runID: String, started: Date) async -> Bool {
        let protected = UIApplication.shared.isProtectedDataAvailable
        SpikeLog.write("bg", "run start", [
            "run": runID,
            "protectedData": "\(protected)",
            "lowPower": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "model": "\(SystemLanguageModel.default.availability)",
        ])

        // Step 0 (S3). Nothing past here may touch SwiftData or the keychain.
        guard protected else {
            SpikeLog.write("s3", "exit at step 0: locked since reboot", ["run": runID])
            return true
        }

        // Steps 1 to 4 are M1-A.
        SpikeLog.write("bg", "steps 1-4 not built (M1-A)", ["run": runID])

        if tryLiveActivityInBackground { await s2Background(runID: runID) }

        // Step 5 (S1).
        let result = await s1Budget(runID: runID, started: started)
        SpikeLog.write("s1", "run end", [
            "run": runID,
            "ok": "\(result.ok)", "failed": "\(result.failed)",
            "stop": result.stop,
            "elapsed": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
        return true
    }

    /// setTaskCompleted must be called exactly once, and both the expiration
    /// handler and the normal end can reach it.
    private final class CompleteOnce: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var done = false
        init(_ task: BGTask) { self.task = task }
        func complete(_ success: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: success)
        }
    }

    // MARK: - S1

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
