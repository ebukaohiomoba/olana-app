//
//  Calibrate
//
//  Scores Olana's SHIPPING urgency engine against labelled events. The engine
//  files (EventSemantics.swift, UrgencyCombiner.swift) are symlinks into the
//  app, so this measures exactly what ships. The old CoreML engine is scored on
//  the same labels for comparison.
//
//  Run:
//    swift run Calibrate calib.txt                       measure + sweep
//    swift run Calibrate calib.txt --passes 2            also check determinism
//    swift run Calibrate calib.txt --old <dir>           also score the old engine
//    swift run Calibrate calib.txt --fresh               ignore the semantics cache
//

import Foundation
import FoundationModels
import CoreML

// MARK: - Input

struct Row {
    let title: String
    let hours: Double
    let cal: String?
    let expected: String   // C S L -
    let alarm: String      // y n ?
}

func load(_ path: String) throws -> [Row] {
    try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { line -> Row? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            let p = t.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count >= 5, let h = Double(p[1]) else { return nil }
            return Row(title: p[0], hours: h, cal: p[2].isEmpty ? nil : p[2],
                       expected: p[3], alarm: p[4])
        }
}

// MARK: - Config

let args = CommandLine.arguments
let path = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "calib.txt"
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let passes = Int(arg("--passes") ?? "1") ?? 1
let oldDir = arg("--old")
let fresh = args.contains("--fresh")

guard case .available = SystemLanguageModel.default.availability else {
    print("Apple Intelligence unavailable on this Mac."); exit(1)
}

let rows = try load(path)

// MARK: - Extraction (mirrors AIAssistant.extractSemantics)

let options = GenerationOptions(sampling: .greedy)

func extractOnce(_ title: String, _ cal: String?) async -> (EventSemantics?, Double, Bool) {
    let prompt = EventSemanticsPrompt.prompt(title: title, calendarName: cal)
    let t0 = Date()
    var retried = false
    for attempt in 0..<2 {
        let session = LanguageModelSession(instructions: EventSemanticsPrompt.instructions)
        do {
            let s = try await session.respond(to: prompt, generating: EventSemantics.self,
                                              options: options).content
            return (s, Date().timeIntervalSince(t0), retried)
        } catch {
            if attempt == 0 { retried = true; try? await Task.sleep(nanoseconds: 250_000_000) }
        }
    }
    return (nil, Date().timeIntervalSince(t0), retried)
}

// Cache keyed on the prompt text, so editing the instructions invalidates it.
struct CacheFile: Codable { var promptHash: String; var entries: [String: EventSemantics] }
let cachePath = "calib-cache.json"
let promptHash = String(EventSemanticsPrompt.instructions.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) })
var cache = CacheFile(promptHash: promptHash, entries: [:])
if !fresh, let d = FileManager.default.contents(atPath: cachePath),
   let c = try? JSONDecoder().decode(CacheFile.self, from: d), c.promptHash == promptHash {
    cache = c
}

func key(_ r: Row) -> String { "\(r.title)|\(r.cal ?? "")" }

var semantics: [String: EventSemantics] = [:]
var failures: [String] = []
var retries = 0
var latencies: [Double] = []
var disagreements: [String] = []

let unique = Dictionary(grouping: rows, by: key).compactMap { $0.value.first }
    .filter { !EventSemantics.isLowInformation(title: $0.title) }

print("Judging \(unique.count) unique titles\(passes > 1 ? " × \(passes) passes" : "")…")
for r in unique {
    let k = key(r)
    if passes == 1, let hit = cache.entries[k] { semantics[k] = hit; continue }
    var answers: [EventSemantics] = []
    for _ in 0..<passes {
        let (s, dt, retried) = await extractOnce(r.title, r.cal)
        latencies.append(dt)
        if retried { retries += 1 }
        if let s { answers.append(s) }
    }
    guard let first = answers.first else { failures.append(r.title); continue }
    if answers.contains(where: { $0 != first }) { disagreements.append(r.title) }
    semantics[k] = first
    cache.entries[k] = first
}
if let d = try? JSONEncoder().encode(cache) { FileManager.default.createFile(atPath: cachePath, contents: d) }

// MARK: - Scoring

let now = Date(timeIntervalSince1970: 1_800_000_000)

struct Scored {
    let row: Row
    let sem: EventSemantics?
    let score: Double?        // nil = unranked
    let alarm: Bool
}

let scored: [Scored] = rows.map { r in
    guard let s = semantics[key(r)] else { return Scored(row: r, sem: nil, score: nil, alarm: false) }
    let start = now.addingTimeInterval(r.hours * 3600)
    let res = UrgencyCombiner.score(semantics: s, start: start, now: now)
    let plan = UrgencyCombiner.alarmPlan(semantics: s, start: start, now: now)
    return Scored(row: r, sem: s, score: res?.score, alarm: plan?.tier == .alarm)
}

func bucket(_ score: Double?, crit: Double, soon: Double) -> String {
    guard let score else { return "-" }
    return score >= crit ? "C" : (score >= soon ? "S" : "L")
}
let rank = ["L": 0, "S": 1, "C": 2]

struct Tally { var right = 0, over = 0, under = 0, total = 0
    var pct: Double { total == 0 ? 0 : Double(right) / Double(total) * 100 } }

func tally(crit: Double, soon: Double) -> Tally {
    var t = Tally()
    for s in scored where s.row.expected != "-" {
        t.total += 1
        let got = bucket(s.score, crit: crit, soon: soon)
        if got == s.row.expected { t.right += 1 }
        else if (rank[got] ?? -1) > (rank[s.row.expected] ?? -1) { t.over += 1 }
        else { t.under += 1 }
    }
    return t
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
}
func hrs(_ h: Double) -> String { h < 48 ? "\(Int(h))h" : "\(Int(h / 24))d" }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

let curC = UrgencyCombiner.criticalThreshold, curS = UrgencyCombiner.soonThreshold

// MARK: - Report: per event

print("")
print("PER EVENT · current thresholds C ≥ \(f1(curC)), S ≥ \(f1(curS))")
print(String(repeating: "=", count: 104))
print(pad("EVENT", 34) + pad("IN", 6) + pad("CONSEQ", 9) + pad("MOVE", 10) + pad("PREP", 7)
      + pad("SCORE", 7) + pad("GOT", 5) + pad("WANT", 6) + pad("ALARM", 8) + "")
print(String(repeating: "-", count: 104))
for s in scored {
    let got = bucket(s.score, crit: curC, soon: curS)
    let bOK = got == s.row.expected
    let aOK = s.row.alarm == "?" || (s.alarm == (s.row.alarm == "y"))
    let alarmCol = (s.alarm ? "yes" : "no") + (s.row.alarm == "?" ? "" : (aOK ? "" : " ✗"))
    print(pad(s.row.title, 34) + pad(hrs(s.row.hours), 6)
          + pad(s.sem?.consequence.rawValue ?? "—", 9) + pad(s.sem?.movability.rawValue ?? "—", 10)
          + pad(s.sem?.effectivePrep.rawValue ?? "—", 7)
          + pad(s.score.map(f1) ?? "—", 7) + pad(got, 5)
          + pad(s.row.expected + (bOK ? "" : " ✗"), 6) + alarmCol)
}

// MARK: - Report: summary

let cur = tally(crit: curC, soon: curS)
let unrankedWanted = scored.filter { $0.row.expected == "-" }
let unrankedRight = unrankedWanted.filter { $0.score == nil && $0.sem == nil }.count
let alarmRows = scored.filter { $0.row.alarm != "?" }
let falseAlarms = alarmRows.filter { $0.alarm && $0.row.alarm == "n" }
let missedAlarms = alarmRows.filter { !$0.alarm && $0.row.alarm == "y" }

print("")
print("SUMMARY")
print(String(repeating: "=", count: 60))
print("Buckets right        \(cur.right)/\(cur.total)  (\(f1(cur.pct))%)   too high \(cur.over), too low \(cur.under)")
print("Placeholders skipped \(unrankedRight)/\(unrankedWanted.count)")
print("False alarms         \(falseAlarms.count)/\(alarmRows.filter { $0.row.alarm == "n" }.count)  \(falseAlarms.map(\.row.title).joined(separator: ", "))")
print("Missed alarms        \(missedAlarms.count)/\(alarmRows.filter { $0.row.alarm == "y" }.count)  \(missedAlarms.map(\.row.title).joined(separator: ", "))")
print("Model failures       \(failures.count)  \(failures.joined(separator: ", "))")
if !latencies.isEmpty {
    let sorted = latencies.sorted()
    print("Latency              median \(String(format: "%.2f", sorted[sorted.count / 2]))s, max \(String(format: "%.2f", sorted.last!))s  (\(latencies.count) calls, \(retries) needed a retry)")
}
if passes > 1 {
    print("Determinism          \(unique.count - disagreements.count)/\(unique.count) identical across \(passes) passes  \(disagreements.joined(separator: ", "))")
}

// MARK: - Report: confusion

print("")
print("CONFUSION (rows = wanted, columns = got)")
print("        C    S    L    -")
for want in ["C", "S", "L"] {
    var line = "  \(want)  "
    for got in ["C", "S", "L", "-"] {
        let n = scored.filter { $0.row.expected == want && bucket($0.score, crit: curC, soon: curS) == got }.count
        line += pad(String(n), 5)
    }
    print(line)
}

// MARK: - Report: threshold sweep

print("")
print("THRESHOLD SWEEP · best 8 (ties: fewer over-escalations, then nearest current)")
print(String(repeating: "=", count: 60))
var grid: [(c: Double, s: Double, t: Tally)] = []
for c in stride(from: 4.0, through: 9.5, by: 0.25) {
    for s in stride(from: 1.0, to: c, by: 0.25) {
        grid.append((c, s, tally(crit: c, soon: s)))
    }
}
grid.sort { a, b in
    if a.t.right != b.t.right { return a.t.right > b.t.right }
    if a.t.over != b.t.over { return a.t.over < b.t.over }
    return abs(a.c - curC) + abs(a.s - curS) < abs(b.c - curC) + abs(b.s - curS)
}
for g in grid.prefix(8) {
    print("  C ≥ \(String(format: "%.2f", g.c))  S ≥ \(String(format: "%.2f", g.s))   \(g.t.right)/\(g.t.total) (\(f1(g.t.pct))%)  over \(g.t.over)  under \(g.t.under)")
}
print("  current: C ≥ \(f1(curC))  S ≥ \(f1(curS))   \(cur.right)/\(cur.total) (\(f1(cur.pct))%)")

// MARK: - Report: old engine

if let oldDir {
    let bucketModel = try CurrentImpl.loadModel("\(oldDir)/UrgencyBucketModel.mlpackage")
    let scoreModel = try CurrentImpl.loadModel("\(oldDir)/UrgencyScoreModel.mlpackage")

    func norm(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("high") || l.contains("crit") || l == "2" { return "C" }
        if l.contains("med") || l.contains("soon") || l == "1" { return "S" }
        return "L"
    }
    var ml = Tally(), kw = Tally()
    var mlAlarmish = 0
    for s in scored where s.row.expected != "-" {
        let m = norm(CurrentImpl.predict(bucketModel: bucketModel, scoreModel: scoreModel,
                                         title: s.row.title, hoursUntil: s.row.hours)?.bucket ?? "low")
        let k = norm(CurrentImpl.keywordPath(title: s.row.title, hoursUntil: s.row.hours))
        for (got, t) in [(m, 0), (k, 1)] {
            var x = t == 0 ? ml : kw
            x.total += 1
            if got == s.row.expected { x.right += 1 }
            else if (rank[got] ?? 0) > (rank[s.row.expected] ?? 0) { x.over += 1 } else { x.under += 1 }
            if t == 0 { ml = x } else { kw = x }
        }
        if m == "C" && s.row.alarm == "n" { mlAlarmish += 1 }
    }
    print("")
    print("OLD ENGINE ON THE SAME LABELS")
    print(String(repeating: "=", count: 60))
    print("  New (Apple Intelligence)   \(cur.right)/\(cur.total) (\(f1(cur.pct))%)  over \(cur.over)  under \(cur.under)")
    print("  Old CoreML (add-event)     \(ml.right)/\(ml.total) (\(f1(ml.pct))%)  over \(ml.over)  under \(ml.under)")
    print("  Old keywords (synced)      \(kw.right)/\(kw.total) (\(f1(kw.pct))%)  over \(kw.over)  under \(kw.under)")
    print("  Old CoreML called a non-severe event Critical \(mlAlarmish) times")
}
print("")
