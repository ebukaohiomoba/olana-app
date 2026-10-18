//
//  EventProgress.swift
//  Olana
//
//  What the user did on an event, kept on this phone (PRD v3 §1.7, v6 §3.6,
//  §1.9): checked prep steps, prep done, "I'm leaving" and "I'm here" with
//  their times. The two taps feed departure lateness and ETA error, which are
//  measured separately and never tune the padding on their own.
//
//  Keyed by the override event key, so it follows an occurrence the source moved.
//

import Foundation

struct EventProgress: Codable, Equatable {
    var checkedSteps: [String] = []
    var prepDone = false
    var prepStartedAt: Date?
    var leftAt: Date?
    var arrivedAt: Date?
    var joinedAt: Date?
    /// leaveBy and the ETA when "I'm leaving" was tapped, for the metrics.
    var leaveByAtDeparture: Date?
    var etaAtDeparture: TimeInterval?
    var eventStart: Date?
    /// Leave alert "5 min" taps so far (at most two, spec §7.7).
    var leaveSnoozes: Int?

    var onTheWay: Bool { leftAt != nil && arrivedAt == nil }
    var finished: Bool { arrivedAt != nil || joinedAt != nil }

    /// Departure lateness: I'm leaving − leaveBy (minutes, behavior metric).
    var departureLatenessMinutes: Double? {
        guard let leftAt, let leaveByAtDeparture else { return nil }
        return leftAt.timeIntervalSince(leaveByAtDeparture) / 60
    }

    /// ETA error: (I'm here − I'm leaving) − ETA (minutes). Only trips with both taps.
    var etaErrorMinutes: Double? {
        guard let leftAt, let arrivedAt, let etaAtDeparture else { return nil }
        return (arrivedAt.timeIntervalSince(leftAt) - etaAtDeparture) / 60
    }

    /// Step 1 checked = "started" (PRD v2 §1.7).
    mutating func toggle(step: String, firstStep: String?, now: Date) {
        if let i = checkedSteps.firstIndex(of: step) { checkedSteps.remove(at: i) }
        else {
            checkedSteps.append(step)
            if step == firstStep, prepStartedAt == nil { prepStartedAt = now }
        }
    }
}

enum EventProgressMetrics {
    /// PRD v3 §3.7: padding is tuned if the median absolute ETA error is over
    /// 5 min across at least 20 trips.
    static func shouldTunePadding(_ all: [EventProgress]) -> Bool {
        let errors = all.compactMap(\.etaErrorMinutes).map(abs).sorted()
        guard errors.count >= 20 else { return false }
        let mid = errors.count / 2
        let median = errors.count % 2 == 0 ? (errors[mid - 1] + errors[mid]) / 2 : errors[mid]
        return median > 5
    }
}

final class EventProgressStore: @unchecked Sendable {
    static let shared = EventProgressStore(defaults: .standard)
    private let defaults: UserDefaults
    private let key = "olanaEventProgress_v1"
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

    private func all() -> [String: EventProgress] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: EventProgress].self, from: $0) } ?? [:]
    }

    func get(_ eventKey: String) -> EventProgress {
        lock.lock(); defer { lock.unlock() }
        return all()[eventKey] ?? EventProgress()
    }

    func update(_ eventKey: String, eventStart: Date, _ change: (inout EventProgress) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var everything = all()
        var p = everything[eventKey] ?? EventProgress()
        change(&p)
        p.eventStart = eventStart
        everything[eventKey] = p
        // Missed steps vanish after the event (no guilt): keep 30 days for metrics.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        everything = everything.filter { ($0.value.eventStart ?? .distantFuture) > cutoff }
        if let data = try? JSONEncoder().encode(everything) { defaults.set(data, forKey: key) }
    }

    var values: [EventProgress] { lock.lock(); defer { lock.unlock() }; return Array(all().values) }

    func clear() { defaults.removeObject(forKey: key) }
}
