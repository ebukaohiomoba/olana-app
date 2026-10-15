//
//  BackgroundRefresh.swift
//  Olana
//
//  The `com.olana.refresh` background run, in PRD v6 §3.2's order. Alerts
//  before AI, and each step is useful if the run is cut off after it:
//
//    0  Not unlocked since restart → request the next run, exit
//    1  Sync: EventKit, then Google if its token is readable        (≤ 10 s)
//    2  Plan alerts from known facts and cached judgments; integrity check
//    3  ETA refresh                                                 M1-C
//    4  Replan after the ETA refresh                                M1-C
//    5  Model: up to 3 jobs, stop on rateLimited or < 8 s left      (M1-A: EventSemantics backfill)
//    6  Replan if step 5 produced anything
//
//  The next run is requested at the end of every run and on every foreground,
//  no sooner than 30 min (spec v3 §5.4).
//
//  Step 0 is not `UIApplication.isProtectedDataAvailable`, which the PRD names:
//  that is false whenever the phone is locked, which is when most background
//  runs happen, so the run would almost never do anything. The PRD's intent
//  (§3.2 storage protection) is "before the first unlock after a reboot,
//  nothing is readable". FirstUnlock checks exactly that. Nothing before it
//  may open the store: Persistence deletes and recreates a store it can't open.
//

import Foundation
import UIKit
import BackgroundTasks

enum BackgroundRefresh {

    static let identifier = "com.olana.refresh"

    /// The system gives a refresh about 30 s. Model work stops with 8 s left.
    static let assumedBudget: TimeInterval = 30
    static let stopWithLeft: TimeInterval = 8
    static let syncBudget: TimeInterval = 10
    static let modelJobs = 3

    private static var observer: NSObjectProtocol?

    /// Call from `didFinishLaunching`, before it returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            run(task)
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            FirstUnlock.writeMarker()
            schedule(reason: "foreground")
        }
    }

    /// Earliest begin 30 min. Submitting again replaces the pending request.
    static func schedule(reason: String) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log("submit failed", ["reason": reason, "error": "\(error)"])
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
            // Progress is saved step by step, and each replan is atomic per
            // event, so a cut-off run never leaves half a plan.
            work.cancel()
            log("expired", ["run": runID, "elapsed": elapsed(started)])
            once.complete(false)
        }
        Task {
            let ok = await work.value
            once.complete(ok)
        }
    }

    @MainActor
    static func steps(runID: String, started: Date, manual: Bool = false) async -> Bool {
        log("run start", ["run": runID, "manual": "\(manual)",
                          "protectedData": "\(UIApplication.shared.isProtectedDataAvailable)",
                          "unlockedSinceBoot": "\(FirstUnlock.hasUnlockedSinceBoot)"])

        // 0. Not unlocked since restart: nothing is readable. Pending alerts still fire.
        guard FirstUnlock.hasUnlockedSinceBoot else {
            log("exit at step 0: locked since restart", ["run": runID], spike: "s3")
            return true
        }

        let services = AppServices.shared
        let engine = NotificationEngine.shared

        // 1. Sync, capped at 10 s. If it overruns, plan from what's known; the
        //    sync finishes on its own and its replan picks up the rest.
        let synced = await within(syncBudget) { await services.calendarManager.performQuickSync() }
        log("step 1 sync", ["run": runID, "finished": "\(synced)", "elapsed": elapsed(started)])
        if Task.isCancelled { return false }

        // 2. Plan from known facts and cached judgments. Re-score against the
        //    clock first, so an event that escalated gets its new profile.
        for event in services.store.refreshUrgencies() {
            await engine.refreshAlarm(for: event)
        }
        let integrity = await engine.replan("background")
        log("step 2 plan", ["run": runID, "missing": "\(integrity?.missing ?? -1)",
                            "added": "\(integrity?.added ?? 0)", "elapsed": elapsed(started)])
        if Task.isCancelled { return false }

        // 3 and 4 (ETA refresh, replan) arrive with leave-by in M1-C.

        // 5. Model work, bounded: up to 3 jobs, never past 8 s before the end.
        let deadline = started.addingTimeInterval(assumedBudget - stopWithLeft)
        let judged = await services.store.backgroundBackfill(limit: modelJobs, deadline: deadline)
        log("step 5 model", ["run": runID, "judged": "\(judged.count)", "elapsed": elapsed(started)])
        if Task.isCancelled { return false }

        // 6. Judgments unlock alarms and change reminder profiles.
        if !judged.isEmpty {
            for event in judged { await engine.refreshAlarm(for: event) }
            await engine.replan("background model")
        }

        #if DEBUG
        await debugSpikes(runID: runID, started: started, manual: manual)
        #endif
        log("run end", ["run": runID, "elapsed": elapsed(started)])
        return true
    }

    // MARK: - Helpers

    /// Runs `op`, waiting at most `seconds`. The work isn't cancelled on
    /// timeout; the caller just stops waiting for it.
    @MainActor
    private static func within(_ seconds: TimeInterval, _ op: @escaping @MainActor () async -> Void) async -> Bool {
        let work = Task { @MainActor in await op() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func elapsed(_ since: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(since))
    }

    static func log(_ event: String, _ fields: [String: String] = [:], spike: String = "bg") {
        #if DEBUG
        SpikeLog.write(spike, event, fields)
        #else
        print("BackgroundRefresh: \(event) \(fields)")
        #endif
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
}

// MARK: - Unlocked since restart

/// Whether files protected until first unlock are readable, which is what
/// "unlocked since restart" means for the store, caches and keychain.
enum FirstUnlock {

    private static var marker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("olana_first_unlock.marker")
    }

    /// Written from the foreground, where it's always readable.
    static func writeMarker() {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("1".utf8).write(to: marker, options: .completeFileProtectionUntilFirstUserAuthentication)
    }

    static var hasUnlockedSinceBoot: Bool {
        // No marker yet (first launch was in the background): fall back to the
        // stricter check, which is never wrong in the unsafe direction.
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return UIApplication.shared.isProtectedDataAvailable
        }
        return (try? Data(contentsOf: marker)) != nil
    }
}
