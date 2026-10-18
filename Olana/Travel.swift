//
//  Travel.swift
//  Olana
//
//  Getting there (spec v3 §7.4–7.6; PRD v3 §3.7): where the user leaves from,
//  how they travel, and how far to trust an ETA. Pure; the MapKit call lives
//  in TravelService.
//
//  Origin, first match:
//    1. the previous event's place, if it ends within 3 h of this start
//       (overlaps: the one ending latest);
//    2. work, only with a work place and work hours, and the event inside them;
//    3. home, if set;
//    4. otherwise none: "Set where you leave from".
//  A correction on the event (override) beats all of these.
//
//  ETA freshness: stale ETAs are padded 10% (5 to 20 min) and shown with
//  "about". A failed ETA keeps the last good one if under 6 h old, padded;
//  otherwise no leave-by and no leave alert. The floor is never touched.
//

import Foundation
import CoreLocation

enum TravelMode: String, Codable, CaseIterable {
    case walking, driving, transit

    var word: String {
        switch self {
        case .walking: return "walk"
        case .driving: return "drive"
        case .transit: return "transit"
        }
    }
}

/// Where the user leaves from.
struct Origin: Equatable {
    enum Source: String, Equatable { case previousEvent, work, home, current, override }
    var source: Source
    var name: String
    var coordinate: CLLocationCoordinate2D

    static func == (a: Origin, b: Origin) -> Bool {
        a.source == b.source && a.name == b.name
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

/// Work hours as minutes from midnight on weekdays (1 = Sunday … 7 = Saturday).
struct WorkHours: Codable, Equatable {
    var startMinute = 9 * 60
    var endMinute = 17 * 60
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    func contains(_ d: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: d)
        guard let wd = c.weekday, weekdays.contains(wd) else { return false }
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= startMinute && m < endMinute
    }
}

enum OriginPicker {
    struct Earlier: Equatable {
        var name: String
        var end: Date
        var coordinate: CLLocationCoordinate2D
        static func == (a: Earlier, b: Earlier) -> Bool { a.name == b.name && a.end == b.end }
    }

    static let previousWindow: TimeInterval = 3 * 3600

    static func pick(start: Date, earlier: [Earlier], home: ResolvedPlace?, work: ResolvedPlace?,
                     workHours: WorkHours?, override: Origin? = nil, calendar: Calendar = .current) -> Origin? {
        if let override { return override }
        // 1. The previous event's place: ended before this starts, within 3 h.
        //    Overlapping events count too; the one ending latest wins.
        let candidates = earlier.filter { $0.end <= start.addingTimeInterval(15 * 60) && start.timeIntervalSince($0.end) <= previousWindow }
        if let prev = candidates.max(by: { $0.end < $1.end }) {
            return Origin(source: .previousEvent, name: prev.name, coordinate: prev.coordinate)
        }
        // 2. Work, only inside work hours that the user set.
        if let work, let workHours, workHours.contains(start, calendar: calendar) {
            return Origin(source: .work, name: work.name, coordinate: work.coordinate)
        }
        // 3. Home.
        if let home { return Origin(source: .home, name: home.name, coordinate: home.coordinate) }
        return nil
    }
}

// MARK: - ETA freshness (spec v3 §7.6)

struct ETAReading: Codable, Equatable {
    var seconds: TimeInterval
    var fetchedAt: Date
}

enum ETAFreshness {
    /// What leave-by uses, and whether the line says "about".
    struct Effective: Equatable {
        var seconds: TimeInterval
        var approximate: Bool
    }

    /// How long a reading stays fresh, by time until leave-by.
    static func staleAfter(untilLeave: TimeInterval) -> TimeInterval {
        if untilLeave > 3 * 3600 { return 6 * 3600 }
        if untilLeave > 45 * 60 { return 3600 }
        return 10 * 60
    }

    /// Whether to fetch again now (foreground or background).
    static func needsRefresh(_ r: ETAReading?, leaveBy: Date?, now: Date) -> Bool {
        guard let r else { return true }
        let until = leaveBy.map { $0.timeIntervalSince(now) } ?? .infinity
        return now.timeIntervalSince(r.fetchedAt) >= staleAfter(untilLeave: until)
    }

    /// 10%, at least 5 and at most 20 minutes.
    static func padded(_ s: TimeInterval) -> TimeInterval {
        s + min(max(s * 0.10, 5 * 60), 20 * 60)
    }

    /// The ETA to plan with, or nil when there's none worth using (> 6 h old).
    /// `start` gives the leave-by estimate for the freshness tier.
    static func effective(_ r: ETAReading?, start: Date, now: Date) -> Effective? {
        guard let r else { return nil }
        let age = now.timeIntervalSince(r.fetchedAt)
        guard age < 6 * 3600 else { return nil }
        let leaveBy = start.addingTimeInterval(-r.seconds)
        let stale = age >= staleAfter(untilLeave: leaveBy.timeIntervalSince(now))
        return stale ? Effective(seconds: padded(r.seconds), approximate: true) : Effective(seconds: r.seconds, approximate: false)
    }

    /// Over 4 h of travel: "Plan travel", not a leave-by (spec §7.4).
    static func isPlanTravel(_ seconds: TimeInterval) -> Bool { seconds > 4 * 3600 }

    /// "14 min walk", "1 h 5 min drive".
    static func phrase(_ seconds: TimeInterval, mode: TravelMode) -> String {
        let m = Int((seconds / 60).rounded())
        let d = m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
        return "\(d) \(mode.word)"
    }

    /// Cache key: origin, place and mode, coordinates to ~100 m.
    static func cacheKey(from o: CLLocationCoordinate2D, to p: CLLocationCoordinate2D, mode: TravelMode) -> String {
        func r(_ x: Double) -> String { String(format: "%.3f", x) }
        return "\(r(o.latitude)),\(r(o.longitude))>\(r(p.latitude)),\(r(p.longitude))|\(mode.rawValue)"
    }
}
