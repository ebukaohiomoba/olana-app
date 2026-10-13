//
//  SyncMatcher.swift
//  Olana
//
//  Event identity across syncs and sources (PRD v6 §3.12). Pure value types,
//  so every rule runs against fixtures (UrgencyProbe/Sources/SyncChecks).
//
//  The rules, in short:
//    • Match on the source's own id first. EventKit fallback: its external
//      identifier (the iCalUID for CalDAV and Google) plus the occurrence date.
//      A match never gets a new OlanaEvent.id.
//    • Two copies of one event merge only when iCalUID and occurrence start
//      match exactly. Never on title and time.
//    • Across sources, the direct Google copy is kept and the iOS Calendar copy
//      hidden, not deleted. Disconnect Google and it comes back.
//    • When an identifier changes (Exchange, some CalDAV), the event is new. A
//      strict fuzzy match only carries the user's overrides over. It never
//      merges or deletes.
//

import Foundation

struct SyncKeys: Equatable {
    /// The source's own id: Google `id`, EventKit `eventIdentifier`.
    var sourceID: String?
    var title: String
    var start: Date
    var end: Date
    /// Google `iCalUID`; EventKit `calendarItemExternalIdentifier`.
    var iCalUID: String?
    /// The occurrence's original start: Google `originalStartTime`, EventKit
    /// `occurrenceDate`. Equals start for a one-off event.
    var occurrence: Date?
    /// Lowercased email, "mailto:" stripped.
    var organizer: String?

    /// The occurrence a recurring exception keeps when it's moved.
    var occurrenceKey: Date { occurrence ?? start }
}

/// The user's overrides on an event that disappeared, kept 24 h in case it
/// comes back under a new identifier (PRD §3.12).
struct OverrideTombstone: Codable, Equatable {
    let title: String
    let start: Date
    let end: Date
    let organizer: String?
    let removedAt: Date
    let urgencyOverrideRaw: Int?
}

enum SyncMatcher {

    // MARK: Within one source

    /// Indices to keep from one source's fetch. Copies of the same event (the
    /// same invite on two calendars) collapse only on iCalUID + occurrence
    /// start; the first copy wins. Everything else is kept, including two
    /// different events that share a title and time.
    static func dedupeWithinSource(_ incoming: [SyncKeys]) -> [Int] {
        var seen = Set<String>()
        var keep: [Int] = []
        for (i, k) in incoming.enumerated() {
            guard let uid = k.iCalUID, !uid.isEmpty else { keep.append(i); continue }
            if seen.insert("\(uid)|\(Int(k.start.timeIntervalSince1970))").inserted { keep.append(i) }
        }
        return keep
    }

    // MARK: Upsert

    /// Which stored event each incoming one updates. Unmatched incoming events
    /// are new. In order:
    ///   1. source id + start (today's key)
    ///   2. iCalUID + occurrence date (EventKit fallback: survives an
    ///      `eventIdentifier` change, and a moved recurring exception)
    ///   3. source id alone, when exactly one stored event has it and it isn't
    ///      before the window (a one-off event that moved)
    static func match(existing: [(id: UUID, keys: SyncKeys)], incoming: [SyncKeys],
                      windowStart: Date) -> [Int: UUID] {
        var bySourceAndStart: [String: UUID] = [:]
        var byUIDAndOccurrence: [String: UUID] = [:]
        var bySource: [String: [(UUID, Date)]] = [:]
        for (id, k) in existing {
            if let s = k.sourceID {
                bySourceAndStart[key(s, k.start)] = bySourceAndStart[key(s, k.start)] ?? id
                bySource[s, default: []].append((id, k.start))
            }
            if let u = k.iCalUID, !u.isEmpty {
                byUIDAndOccurrence[key(u, k.occurrenceKey)] = byUIDAndOccurrence[key(u, k.occurrenceKey)] ?? id
            }
        }

        var result: [Int: UUID] = [:]
        var taken = Set<UUID>()
        func claim(_ i: Int, _ id: UUID?) -> Bool {
            guard let id, result[i] == nil, taken.insert(id).inserted else { return false }
            result[i] = id
            return true
        }

        for (i, k) in incoming.enumerated() {
            if let s = k.sourceID { _ = claim(i, bySourceAndStart[key(s, k.start)]) }
        }
        for (i, k) in incoming.enumerated() where result[i] == nil {
            if let u = k.iCalUID, !u.isEmpty { _ = claim(i, byUIDAndOccurrence[key(u, k.occurrenceKey)]) }
        }
        for (i, k) in incoming.enumerated() where result[i] == nil {
            guard let s = k.sourceID, let c = bySource[s], c.count == 1, c[0].1 >= windowStart else { continue }
            _ = claim(i, c[0].0)
        }
        return result
    }

    // MARK: Across sources

    /// iOS Calendar copies of events that are also synced directly from Google:
    /// apple id → google id. Exact iCalUID + occurrence start only.
    static func crossSourceDuplicates(apple: [(id: UUID, keys: SyncKeys)],
                                      google: [(id: UUID, keys: SyncKeys)]) -> [UUID: UUID] {
        var googleByKey: [String: UUID] = [:]
        for (id, k) in google {
            guard let u = k.iCalUID, !u.isEmpty else { continue }
            googleByKey[key(u, k.start)] = googleByKey[key(u, k.start)] ?? id
        }
        var out: [UUID: UUID] = [:]
        for (id, k) in apple {
            guard let u = k.iCalUID, !u.isEmpty, let g = googleByKey[key(u, k.start)] else { continue }
            out[id] = g
        }
        return out
    }

    // MARK: Identifier changed

    static let tombstoneLife: TimeInterval = 24 * 3600

    /// A new event that is the same title, start, end and organizer as one
    /// that disappeared in the last 24 h inherits that one's overrides. Only
    /// when exactly one tombstone fits, and only overrides: nothing merges.
    static func carryOver(tombstones: [OverrideTombstone], newEvent k: SyncKeys, now: Date) -> OverrideTombstone? {
        let fits = tombstones.filter {
            now.timeIntervalSince($0.removedAt) <= tombstoneLife
                && $0.title == k.title && $0.start == k.start && $0.end == k.end
                && $0.organizer != nil && $0.organizer == k.organizer
        }
        return fits.count == 1 ? fits[0] : nil
    }

    // MARK: Helpers

    static func normalizedOrganizer(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s.hasPrefix("mailto:") { s.removeFirst("mailto:".count) }
        return s.isEmpty ? nil : s
    }

    private static func key(_ id: String, _ d: Date) -> String { "\(id)|\(Int(d.timeIntervalSince1970))" }
}
