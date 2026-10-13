//
//  main.swift
//  SyncChecks
//
//  SyncMatcher against PRD v6 §3.12 and spec v3 §5.7 (A5 to A8).
//  SyncMatcher.swift is a symlink into the app. Run: swift run SyncChecks
//

import Foundation

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }
func k(_ src: String?, _ title: String, _ start: Date, uid: String? = nil, occ: Date? = nil,
       org: String? = nil, hours: Double = 1) -> SyncKeys {
    SyncKeys(sourceID: src, title: title, start: start, end: start.addingTimeInterval(hours * 3600),
             iCalUID: uid, occurrence: occ, organizer: org)
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     ", detail()) }
}

// A5: same Google account directly and through iOS Calendar → one event.
let g = UUID(), a = UUID()
let dup = SyncMatcher.crossSourceDuplicates(
    apple: [(a, k("EK-1", "Client review", at(5), uid: "abc@google.com"))],
    google: [(g, k("gid1", "Client review", at(5), uid: "abc@google.com"))])
check("A5 iCalUID + start merge keeps the Google copy", dup == [a: g], "\(dup)")
let notDup = SyncMatcher.crossSourceDuplicates(
    apple: [(a, k("EK-1", "Client review", at(5), uid: "abc@google.com"))],
    google: [(g, k("gid1", "Client review", at(6), uid: "abc@google.com"))])
check("A5 different start: no merge", notDup.isEmpty)

// A6: Exchange identifier changes → new event, overrides carried, nothing merged.
let old = UUID()
let changedID = k("EK-NEW", "Budget review", at(10), uid: "NEWUID", org: "boss@acme.com")
let m6 = SyncMatcher.match(existing: [(old, k("EK-OLD", "Budget review", at(10), uid: "OLDUID", org: "boss@acme.com"))],
                           incoming: [changedID], windowStart: t0)
check("A6 changed identifier is a new event", m6.isEmpty, "\(m6)")
let tomb = OverrideTombstone(title: "Budget review", start: at(10), end: at(11), organizer: "boss@acme.com",
                             removedAt: t0, urgencyOverrideRaw: 2)
check("A6 overrides carried over", SyncMatcher.carryOver(tombstones: [tomb], newEvent: changedID, now: at(1)) == tomb)
check("A6 not after 24 h", SyncMatcher.carryOver(tombstones: [tomb], newEvent: changedID, now: at(25)) == nil)

// A7: fuzzy-only match → no merge.
check("A7 same title and time, different iCalUID: no cross-source merge",
      SyncMatcher.crossSourceDuplicates(apple: [(a, k("EK-1", "1:1", at(2), uid: "X"))],
                                        google: [(g, k("g1", "1:1", at(2), uid: "Y"))]).isEmpty)
let two11 = [k("g1", "1:1", at(2), uid: "X"), k("g2", "1:1", at(2), uid: "Y")]
check("A7 two different 1:1s at the same time both stay (the old title+time merge dropped one)",
      SyncMatcher.dedupeWithinSource(two11) == [0, 1])
check("A7 no carry-over without an organizer",
      SyncMatcher.carryOver(tombstones: [OverrideTombstone(title: "Gym", start: at(3), end: at(4), organizer: nil, removedAt: t0, urgencyOverrideRaw: 1)],
                            newEvent: k("x", "Gym", at(3)), now: at(1)) == nil)
check("A7 no carry-over when two tombstones fit",
      SyncMatcher.carryOver(tombstones: [tomb, tomb], newEvent: changedID, now: at(1)) == nil)

// A8: event ID stable across an update.
let e = UUID()
let m8 = SyncMatcher.match(existing: [(e, k("gid9", "Standup", at(1)))],
                           incoming: [k("gid9", "Daily standup", at(1))], windowStart: t0)
check("A8 renamed event keeps its id", m8 == [0: e])
let m8b = SyncMatcher.match(existing: [(e, k("gid9", "Standup", at(1)))],
                            incoming: [k("gid9", "Standup", at(3))], windowStart: t0)
check("A8 moved one-off event keeps its id", m8b == [0: e])

// EventKit identifier changed but iCalUID + occurrence same → same event.
let m9 = SyncMatcher.match(existing: [(e, k("EK-A", "Dentist", at(4), uid: "U1", occ: at(4)))],
                           incoming: [k("EK-B", "Dentist", at(4), uid: "U1", occ: at(4))], windowStart: t0)
check("EventKit fallback: iCalUID + occurrence date", m9 == [0: e])

// Recurring: same source id for every occurrence; each keeps its own event.
let r1 = UUID(), r2 = UUID()
let m10 = SyncMatcher.match(existing: [(r1, k("EK-R", "Gym", at(24), uid: "R", occ: at(24))),
                                       (r2, k("EK-R", "Gym", at(48), uid: "R", occ: at(48)))],
                            incoming: [k("EK-R", "Gym", at(48), uid: "R", occ: at(48)),
                                       k("EK-R", "Gym", at(24), uid: "R", occ: at(24))], windowStart: t0)
check("recurring occurrences match their own events", m10 == [0: r2, 1: r1])

// A moved recurring exception keeps its occurrence date.
let m11 = SyncMatcher.match(existing: [(r1, k("EK-R", "Gym", at(24), uid: "R", occ: at(24)))],
                            incoming: [k("EK-R2", "Gym", at(26), uid: "R", occ: at(24))], windowStart: t0)
check("moved recurring exception stays the same event", m11 == [0: r1])

// A new occurrence of a series never takes over a past one.
let m12 = SyncMatcher.match(existing: [(r1, k("EK-Y", "Taxes", at(-24 * 300)))],
                            incoming: [k("EK-Y", "Taxes", at(24 * 60))], windowStart: t0)
check("a lone id before the window isn't reused", m12.isEmpty)

// The same invite on two calendars of one source collapses on iCalUID + start.
check("same invite on two calendars collapses",
      SyncMatcher.dedupeWithinSource([k("g1", "Offsite", at(30), uid: "Z"), k("g2", "Offsite", at(30), uid: "Z")]) == [0])

check("organizer normalised", SyncMatcher.normalizedOrganizer("mailto:Boss@Acme.com ") == "boss@acme.com")

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
