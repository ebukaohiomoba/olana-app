//
//  ExportCalendar
//
//  Dumps event TITLES and start times from your local calendars into the
//  UrgencyProbe input format. Titles only. No attendees, locations, notes,
//  URLs or descriptions are read or written. The file stays on this machine,
//  and the probe sends titles to Apple's on-device model, so nothing leaves
//  the device at any point.
//
//  Usage:  swift run ExportCalendar [outfile] [daysBack] [daysForward]
//

import Foundation
import EventKit

let outPath  = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "my-events.txt"
let daysBack = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 60 : 60
let daysFwd  = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 120 : 120

let store = EKEventStore()

let granted: Bool
do {
    granted = try await store.requestFullAccessToEvents()
} catch {
    print("Calendar access error: \(error.localizedDescription)")
    exit(1)
}

guard granted else {
    print("""
    Calendar access denied.

    Grant it in System Settings, Privacy & Security, Calendars, then run again.
    If no prompt appeared, run this directly in your own Terminal so macOS can show it.
    """)
    exit(1)
}

let now = Date()
let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: now)!
let end   = Calendar.current.date(byAdding: .day, value: daysFwd, to: now)!

let calendars = store.calendars(for: .event)
let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
let events = store.events(matching: predicate)

// Keep at most 3 instances of any repeated title so recurring meetings do not
// swamp the sample, and so the variety in the file reflects the variety in life.
var seen: [String: Int] = [:]
var lines: [String] = []
var skippedRecurring = 0
var emptyTitles = 0

// Nearest-to-now first, so the 3-instance cap keeps upcoming occurrences
// rather than the oldest ones sitting 60 days in the past.
for e in events.sorted(by: {
    abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
}) {
    let raw = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { emptyTitles += 1; continue }

    let key = raw.lowercased()
    let count = seen[key, default: 0]
    if count >= 3 { skippedRecurring += 1; continue }
    seen[key] = count + 1

    let hours = e.startDate.timeIntervalSince(now) / 3600
    // Pipes would break the probe's parser.
    let title = raw.replacingOccurrences(of: "|", with: "/")
    let cal = (e.calendar.title).replacingOccurrences(of: "|", with: "/")
    lines.append("\(title) | \(String(format: "%.1f", hours)) | \(cal)")
}

let header = """
# Exported from your local calendars on \(ISO8601DateFormatter().string(from: now))
# Window: \(daysBack) days back to \(daysFwd) days forward
# Titles only. No attendees, locations or notes were read.
# Repeated titles capped at 3 instances each.

"""
try (header + lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)

// Quick shape report so you know what you are about to test against.
let uniqueTitles = seen.count
let shortTitles = seen.keys.filter { $0.split(separator: " ").count <= 2 }.count
let calNames = Set(events.compactMap { $0.calendar.title })

print("""

Wrote \(lines.count) events to \(outPath)

  calendars scanned     \(calendars.count) (\(calNames.sorted().joined(separator: ", ")))
  events in window      \(events.count)
  unique titles         \(uniqueTitles)
  recurring dupes cut   \(skippedRecurring)
  untitled events       \(emptyTitles)
  titles of 1-2 words   \(shortTitles)/\(uniqueTitles)  <- likely low-signal for the model

Next:
  swift run UrgencyProbe \(outPath) --strip-dates --fewshot
  swift run UrgencyProbe \(outPath) --strip-dates --fewshot --vs-current

""")
