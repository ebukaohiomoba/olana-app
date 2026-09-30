//
//  UrgencyProbe
//
//  Standalone test harness for the Option 5 architecture. Touches nothing in Olana.
//
//  Run:
//    swift run UrgencyProbe events.txt                        baseline
//    swift run UrgencyProbe events.txt --strip-dates          test 1
//    swift run UrgencyProbe events.txt --fewshot              test 2
//    swift run UrgencyProbe events.txt --split                test 3
//    swift run UrgencyProbe events.txt --strip-dates --fewshot --split
//

import Foundation
import FoundationModels

// MARK: - Semantics

@Generable
enum Consequence: String, CaseIterable { case severe, moderate, minor }

@Generable
enum Movability: String, CaseIterable { case fixed, difficult, flexible }

@Generable
enum PrepNeed: String, CaseIterable { case none, short, medium, long }

@Generable
enum Category: String, CaseIterable {
    case work, health, legalFinance, travel, education
    case family, social, fitness, admin, personal
}

@Generable
struct EventSemantics {
    @Guide(description: "What actually happens to the person if this is missed entirely.")
    var consequence: Consequence

    @Guide(description: "How hard this would be to reschedule.")
    var movability: Movability

    @Guide(description: "True ONLY if the person must produce, write, build, buy, study for or rehearse something before this happens. False for anything they simply show up to.")
    var requiresPreparation: Bool

    @Guide(description: "How much work happens beforehand. Must be none whenever requiresPreparation is false.")
    var prepNeed: PrepNeed

    @Guide(description: "The area of life this belongs to.")
    var category: Category
}

@Generable struct ConsequenceOnly { var consequence: Consequence }
@Generable struct MovabilityOnly  { var movability: Movability }
@Generable struct CategoryOnly    { var category: Category }
@Generable struct PrepOnly {
    @Guide(description: "True only if work must happen before the event. Attending is not work.")
    var requiresPreparation: Bool
    var prepNeed: PrepNeed
}


// ─────────── V2: the model judges, the code only converts units ───────────

@Generable
enum Importance: String, CaseIterable {
    case critical, important, notable, minor, trivial
}

/// How far ahead this specific thing deserves to be on someone's mind.
/// Replaces a universal decay curve: a tax filing earns attention weeks out,
/// a haircut earns it the morning of, and only the model knows which is which.
@Generable
enum AttentionHorizon: String, CaseIterable {
    case hoursBefore, dayBefore, fewDaysBefore, weekBefore, weeksBefore
}

@Generable
struct EventJudgement {
    @Guide(description: "How much is lost if this person does not do this or does not attend.")
    var importance: Importance

    @Guide(description: "How far ahead of the event this should start occupying their attention, given what it is and what it takes to be ready.")
    var horizon: AttentionHorizon
}

let judgementInstructions = """
You are judging calendar events for someone who struggles to work out what deserves
their attention and when. You see a short title and sometimes a calendar name.

IMPORTANCE — what is lost if this does not happen.
  critical   Not recoverable. Money, legal standing, health, or an opportunity that
             will not come back. Deadlines with real penalties. Any step in a hiring
             or admissions process. Anything another organisation moves past you on.
  important  A real cost that can still be recovered. A professional's time wasted,
             a fee, someone meaningfully let down.
  notable    Worth keeping, but missing it costs little beyond mild inconvenience.
  minor      Small. Easily moved, easily skipped.
  trivial    Nothing is lost. Includes anything that happens TO them rather than
             requiring anything FROM them: money arriving, a renewal processing,
             a date being observed.

HORIZON — how far ahead this should start occupying their attention.
Think about what has to be true before the event, not only when it starts.
  hoursBefore     Nothing to prepare, just be there. Most appointments and meetings.
  dayBefore       A little readiness helps: pack, print something, look it over.
  fewDaysBefore   Real work has to happen first: a document, a talk, a meal for guests,
                  revision for a test.
  weekBefore      Substantial work, or a deadline serious enough to sit with.
  weeksBefore     Major undertakings and filings needing sustained effort.

The two are independent. A flight is critical and needs no preparation, so it is
critical + hoursBefore. A hobby deadline may be notable + weekBefore.
"""

func judge(_ title: String, _ cal: String?) async throws -> EventJudgement {
    let p = promptText(title, cal)
    for attempt in 0..<2 {
        let sess = LanguageModelSession(instructions: judgementInstructions)
        do {
            return try await sess.respond(to: p, generating: EventJudgement.self, options: opts).content
        } catch {
            if attempt == 0 { try? await Task.sleep(nanoseconds: 250_000_000); continue }
            throw error
        }
    }
    throw CancellationError()
}

/// Unit conversion only. These say what the words mean, not what matters.
func horizonHours(_ h: AttentionHorizon) -> Double {
    switch h {
    case .hoursBefore:   return 6
    case .dayBefore:     return 24
    case .fewDaysBefore: return 72
    case .weekBefore:    return 168
    case .weeksBefore:   return 504
    }
}

func importanceValue(_ i: Importance) -> Double {
    switch i {
    case .critical:  return 10
    case .important: return 7
    case .notable:   return 4.5
    case .minor:     return 2.5
    case .trivial:   return 1
    }
}

/// How much it matters, scaled by how far into its own attention window we are.
/// No global decay curve: every event carries its own.
func scoreV2(_ j: EventJudgement, hoursUntil: Double) -> Double {
    let window = horizonHours(j.horizon)
    let entered = max(0, min(1, (window - hoursUntil) / window))
    let surge = entered * entered * (3 - 2 * entered)   // smoothstep

    // Importance still counts outside the window, or everything distant collapses
    // to zero and the ordering becomes arbitrary. The horizon decides when a thing
    // climbs, not whether it exists.
    let floorShare = 0.25
    return importanceValue(j.importance) * (floorShare + (1 - floorShare) * surge)
}


// ─────────── V3: the model sees event + context + time, and rates urgency ───────────

@Generable
enum UrgencyRating: String, CaseIterable {
    case rightNow      // this needs attention today, ahead of other things
    case soon          // on the radar this week, act before it arrives
    case scheduled     // known about, nothing to do yet
    case background    // no action needed, will happen or will not
}

@Generable
struct UrgencyVerdict {
    @Guide(description: "How much attention this deserves right now, given both what it is and how far away it is.")
    var rating: UrgencyRating

    @Guide(description: "A rank from 0 to 100 for ordering against other events. Higher means it should appear further up the list.")
    var rank: Int
}

let holisticInstructions = """
You are ranking calendar events for someone who struggles to work out what deserves
their attention right now. For each event you are told what it is and how far away it is.

Judge both together. The same event deserves different attention at different distances:
an exam in five weeks is not urgent, the same exam tomorrow is. A flight in an hour is
urgent, the same flight next month is not.

Weigh what is lost if it is missed, whether it can be rescheduled, and whether work has
to happen before it. Something requiring days of preparation becomes urgent well before
it starts. Something you only attend becomes urgent shortly before it starts.

rating:
  rightNow    needs attention today, ahead of other things
  soon        act on it this week, before it arrives
  scheduled   known about, nothing to do about it yet
  background  no action is required at all, from anyone

rank: 0 to 100, for ordering against everything else on the calendar. Use the full
range. A flight tomorrow and a gym session tomorrow should be far apart.
"""

func describeDistance(_ hours: Double) -> String {
    if hours < 1  { return "starting within the hour" }
    if hours < 6  { return "in \(Int(hours)) hours, later today" }
    if hours < 24 { return "in \(Int(hours)) hours" }
    if hours < 48 { return "tomorrow" }
    if hours < 168 { return "in \(Int(hours / 24)) days" }
    if hours < 336 { return "in about a week and a half" }
    return "in about \(Int(hours / 168)) weeks"
}

func rateHolistically(_ title: String, _ cal: String?, hours: Double) async throws -> UrgencyVerdict {
    var p = "Event: \(title)"
    if let name = sanitizedCalendarName(cal) { p += "\nCalendar: \(name)" }
    p += "\nWhen: \(describeDistance(hours))"
    for attempt in 0..<2 {
        let sess = LanguageModelSession(instructions: holisticInstructions)
        do {
            return try await sess.respond(to: p, generating: UrgencyVerdict.self, options: opts).content
        } catch {
            if attempt == 0 { try? await Task.sleep(nanoseconds: 250_000_000); continue }
            throw error
        }
    }
    throw CancellationError()
}

// MARK: - Instructions

let baseInstructions = """
You classify calendar events so a planning app can decide how much attention each deserves.

You get only a short title, sometimes a calendar name. Judge from what the event plainly is.

consequence: what happens if the person simply does not go.
movability: how hard to reschedule, not how important.
requiresPreparation: true only if they must make, write, study for, rehearse or buy something \
beforehand. Attending is not preparation. Travelling is not preparation.
prepNeed: none whenever requiresPreparation is false.
"""

let principleInstructions = """
You classify calendar events so a planning app can decide how much attention each deserves.
You get a short title and sometimes the name of the calendar it came from.

CONSEQUENCE — what happens to this person if they simply do not show up or do not do it.
  severe   Something is lost that cannot be recovered by rescheduling: money, legal
           standing, health, or an opportunity that will not come again. Anything with
           a legal or financial deadline. Any step in a hiring or admissions process,
           whatever it is called. Anything where another organisation moves on without you.
  moderate Someone is inconvenienced, a fee is charged, or a professional's time is
           wasted, but the thing can happen later.
  minor    Nothing meaningful is lost. This includes anything that happens TO the person
           rather than requiring something FROM them: money arriving, a date passing, a
           renewal processing, a day being observed. If the person does nothing and the
           outcome is unchanged, it is minor.

Do not default to moderate. Decide which of the three it is.

MOVABILITY — only about rescheduling.
  fixed     Happens on its own schedule whether or not this person attends, or is a
            deadline that does not move.
  difficult Rescheduling costs someone else, usually a professional, their time.
  flexible  Moving it affects nobody.

REQUIRESPREPARATION — work done BEFORE, never the event itself.
  Ask one question: between now and then, must this person MAKE, WRITE, STUDY, REHEARSE,
  COOK, BUY or ASSEMBLE something for it? If they only have to arrive, the answer is false.
  Producing a document, a talk, a meal or an answer is preparation. Travelling to a place,
  packing a bag, and feeling nervous are not.

prepNeed: none when requiresPreparation is false. Otherwise short (an hour or two),
medium (a few hours of real work), long (days of work).
"""

let anchoredInstructions = """
    You classify calendar events so a planning app can decide how much attention each deserves.
    You get a short title and sometimes the name of the calendar it came from. Use the calendar
    name as context. Judge only from what the title plainly is.

    CONSEQUENCE — what happens if the person simply does not show up or does not do it.
      severe   money lost, legal trouble, health harm, a job or opportunity gone, something
               that cannot be recovered. Examples: Flight departure, Court date, Surgery,
               Final exam, Tax filing, Rent due, Visa appointment, Thesis defence, Closing
               on a house, On-call shift, Custody handoff, Bar exam.
               ANY job interview, screening call, phone screen or recruiter conversation is
               severe. A missed interview cannot be recovered.
      moderate real inconvenience, someone else is let down, a fee, rescheduling hassle.
               Examples: Dentist checkup, Team meeting, Performance review, Dinner
               reservation, Physical therapy, DMV, Contractor visit, A friend's wedding.
      minor    nothing meaningful happens, or the event requires no action at all.
               Examples: Gym, Casual coffee, Netflix, Walking the dog, Browsing a shop,
               Nap, Optional standup, Reading for pleasure, Payday, a birthday, a public
               holiday, anything purely informational that happens whether or not the
               person does anything.

    Do not default to moderate. A real calendar contains a mix of all three.

    MOVABILITY — purely about rescheduling, never about importance.
      fixed     happens without you and cannot move. Examples: Flight, Court date, Exam,
                Concert, Wedding, Live performance, Someone else's recital, Match day,
                Surgery, any deadline, Rent due, Closing, On-call rotation.
      difficult moving costs a professional or several people their time. Examples: Dentist,
                Doctor, DMV, Contractor, Performance review, Interview, Custody handoff.
      flexible  move it freely and nobody is affected. Examples: Gym, Coffee with a friend,
                Errands, Reading, Grocery run, Nap.

    Deadlines and appointments with other people are rarely flexible.

    REQUIRESPREPARATION — work done BEFORE the event, never the event itself.
      Ask: must they MAKE, WRITE, STUDY FOR, REHEARSE, BUY or BUILD something first?
      A title containing "due", "deadline", "homework", "assignment", "draft" or "report"
      describes work the person produces beforehand. Those are always true.
      false  Dentist, Flight, Surgery, Jury duty, Standup, Team meeting, Passport
             appointment, DMV, Bloodwork, Gym, Coffee, Concert, Prescription pickup,
             Court date, Custody handoff, Someone else's recital, Payday, a holiday.
      true   Presentation, Exam, Thesis defence, Tax filing, Report due, Homework due,
             Hosting a dinner, Best man speech, Job interview, Grant application,
             a recital you perform in, Draft due, Pitch to investors.

    Packing is not preparation. Travelling is not preparation. Nerves are not preparation.

    prepNeed: none when requiresPreparation is false. Otherwise short (an hour or two),
    medium (a few hours of real work), long (days of work).
"""

// MARK: - Config

let args = CommandLine.arguments
let path = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "events.txt"
let stripDates = args.contains("--strip-dates")
let useFewShot = args.contains("--fewshot")
let usePrinciples = args.contains("--principles")
let noPrepGate = args.contains("--no-prep-gate")
let useSplit   = args.contains("--split")
let vsCurrent  = args.contains("--vs-current")
let sweepMode  = args.contains("--sweep")
let rankMode   = args.contains("--rank")
let useV2      = args.contains("--v2")
let useV3      = args.contains("--v3")
let instructions = usePrinciples ? principleInstructions : (useFewShot ? anchoredInstructions : baseInstructions)
let opts = GenerationOptions(sampling: .greedy)

// MARK: - Date stripping

let datePatterns: [String] = [
    #"\bin \d+ (day|days|hour|hours|week|weeks|month|months)\b"#,
    #"\bin (a|one|two|three|four|five|six|seven|ten) (day|days|hour|hours|week|weeks|month|months)\b"#,
    #"\b(next|this|last) (week|weekend|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
    #"\bon (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
    #"\b(tomorrow|today|tonight|yesterday|tmrw)\b"#,
    #"\bat \d{1,2}(:\d{2})?\s?(am|pm)?\b"#,
    #"\b\d{1,2}(:\d{2})?\s?(am|pm)\b"#,
]

func stripDatePhrases(_ s: String) -> String {
    var out = s
    for p in datePatterns {
        out = out.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
    }
    out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,-"))
    return out.isEmpty ? s : out
}

// MARK: - Extraction

func sanitizedCalendarName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    guard !name.contains("@"), !name.contains("://") else { return nil }
    if UUID(uuidString: name) != nil { return nil }
    let alphanumeric = name.filter { $0.isLetter || $0.isNumber }
    if !alphanumeric.isEmpty {
        let digits = alphanumeric.filter(\.isNumber).count
        if Double(digits) / Double(alphanumeric.count) > 0.4 { return nil }
    }
    let generic: Set<String> = ["calendar", "default", "events", "untitled", "home", "ical"]
    guard !generic.contains(name.lowercased()) else { return nil }
    guard name.count <= 32 else { return nil }
    return name
}

func isLowInformation(title: String) -> Bool {
        let cleaned = stripDatePhrases(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return true }

        // Strip punctuation and names-with-numbers so "1:1 with Marcus" reduces to
        // the part that would have to carry meaning.
        let words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }

        // Placeholders that describe the calendar rather than the commitment.
        let placeholders: Set<String> = [
            "hold", "held", "blocked", "block", "busy", "ooo", "oof", "pto", "wfh",
            "tbd", "tba", "placeholder", "reserved", "unavailable", "away",
            "sync", "meeting", "call", "chat", "catchup", "touchpoint", "standup",
            "check", "checkin", "review", "session", "time", "slot", "focus",
            "misc", "other", "event", "appointment", "reminder", "task", "todo"
        ]

        // A single word that is only a placeholder tells us nothing.
        if words.count <= 1 {
            return words.first.map { placeholders.contains($0) } ?? true
        }

        // Filler that adds no meaning when it is all that is left.
        let filler: Set<String> = ["with", "and", "the", "a", "an", "for", "to", "on",
                                   "my", "our", "re", "w", "vs", "at", "of", "in"]
        let meaningful = words.filter { !placeholders.contains($0) && !filler.contains($0) }

        // "1:1 with Marcus" leaves ["marcus"], a name that says nothing about the
        // commitment. "Sync with legal" leaves ["legal"], which does. The line is
        // imperfect; erring toward declining to rank is the cheaper mistake.
        return meaningful.isEmpty
}

func promptText(_ title: String, _ calendar: String?) -> String {
    var p = "Event title: \(title)"
    if let name = sanitizedCalendarName(calendar) { p += "\nCalendar: \(name)" }
    return p
}

func extractCombined(_ title: String, _ cal: String?) async throws -> EventSemantics {
    let p = promptText(title, cal)
    // Retry once: refusals are transient under sustained extraction, not per-title.
    for attempt in 0..<2 {
        let s = LanguageModelSession(instructions: instructions)
        do {
            return try await s.respond(to: p, generating: EventSemantics.self, options: opts).content
        } catch {
            if attempt == 0 { try? await Task.sleep(nanoseconds: 250_000_000); continue }
            throw error
        }
    }
    throw CancellationError()
}

func extractSplit(_ title: String, _ cal: String?) async throws -> EventSemantics {
    let p = promptText(title, cal)
    let sc = LanguageModelSession(instructions: instructions)
    let c = try await sc.respond(to: p + "\n\nOnly judge consequence.", generating: ConsequenceOnly.self, options: opts).content
    let sm = LanguageModelSession(instructions: instructions)
    let m = try await sm.respond(to: p + "\n\nOnly judge movability.", generating: MovabilityOnly.self, options: opts).content
    let sp = LanguageModelSession(instructions: instructions)
    let pr = try await sp.respond(to: p + "\n\nOnly judge preparation.", generating: PrepOnly.self, options: opts).content
    let sg = LanguageModelSession(instructions: instructions)
    let g = try await sg.respond(to: p + "\n\nOnly judge category.", generating: CategoryOnly.self, options: opts).content
    return EventSemantics(consequence: c.consequence, movability: m.movability,
                          requiresPreparation: pr.requiresPreparation, prepNeed: pr.prepNeed,
                          category: g.category)
}

struct UnrankableTitle: Error {}

func extract(_ title: String, _ cal: String?) async throws -> (EventSemantics, TimeInterval) {
    if isLowInformation(title: title) { throw UnrankableTitle() }
    let t = stripDates ? stripDatePhrases(title) : title
    let t0 = Date()
    let sem = useSplit ? try await extractSplit(t, cal) : try await extractCombined(t, cal)
    return (sem, Date().timeIntervalSince(t0))
}

// MARK: - Combiner

func prepHours(_ p: PrepNeed) -> Double {
    switch p { case .none: return 0; case .short: return 2; case .medium: return 12; case .long: return 48 }
}

func baseWeight(_ c: Consequence, _ m: Movability) -> Double {
    switch (c, m) {
    case (.severe, .fixed):        return 1.00
    case (.severe, .difficult):    return 0.92
    case (.severe, .flexible):     return 0.80
    case (.moderate, .fixed):      return 0.62
    case (.moderate, .difficult):  return 0.56
    case (.moderate, .flexible):   return 0.44
    case (.minor, .fixed):         return 0.30
    case (.minor, .difficult):     return 0.24
    case (.minor, .flexible):      return 0.18
    }
}

func timePressure(_ h: Double) -> Double {
    switch h {
    case ..<0:    return 1.00
    case ..<2:    return 0.98
    case ..<6:    return 0.92
    case ..<24:   return 0.84
    case ..<48:   return 0.72
    case ..<72:   return 0.62
    case ..<168:  return 0.50
    case ..<336:  return 0.38
    default:      return 0.28
    }
}

enum Bucket: String { case critical = "CRITICAL", soon = "SOON", later = "LATER" }
func bucket(_ s: Double) -> Bucket { s >= 6.5 ? .critical : (s >= 3.5 ? .soon : .later) }

let neverPrep: Set<Category> = [.health, .fitness, .admin, .travel]
func effectivePrep(_ s: EventSemantics) -> PrepNeed {
    guard s.requiresPreparation else { return .none }
    if !noPrepGate, neverPrep.contains(s.category) { return .none }
    return s.prepNeed
}

func alarmTier(_ score: Double, _ s: EventSemantics) -> String {
    if score >= 6.5 && s.consequence == .severe { return "ALARM" }
    if score >= 6.5 { return "time-sens" }
    if score >= 3.5 { return "notify" }
    return "silent"
}

func actByHours(_ s: EventSemantics, hours: Double) -> Double {
    // Prep can never reach further back than now.
    max(hours - prepHours(effectivePrep(s)), 0)
}

func scoreOf(_ s: EventSemantics, hours: Double) -> Double {
    baseWeight(s.consequence, s.movability) * timePressure(actByHours(s, hours: hours)) * 10
}

// MARK: - Input

struct TestEvent { let title: String; let hours: Double; let cal: String?; let pair: String? }

func loadEvents(_ path: String) throws -> [TestEvent] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        let p = t.split(separator: "|", omittingEmptySubsequences: false)
                 .map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count >= 2, let h = Double(p[1]) else { return nil }
        return TestEvent(title: p[0], hours: h,
                         cal: p.count >= 3 && !p[2].isEmpty ? p[2] : nil,
                         pair: p.count >= 4 && !p[3].isEmpty ? p[3] : nil)
    }
}

// MARK: - Output helpers

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "\u{2026}" : s + String(repeating: " ", count: n - s.count)
}
func hrs(_ h: Double) -> String { h < 0 ? "past" : (h < 48 ? "\(Int(h))h" : "\(Int(h/24))d") }

// MARK: - Main

guard FileManager.default.fileExists(atPath: path) else {
    print("No input file at \(path)"); exit(1)
}
if case .unavailable(let r) = SystemLanguageModel.default.availability {
    print("Foundation Models unavailable: \(r)"); exit(1)
}

let events = try loadEvents(path)
let modeBits = [stripDates ? "strip-dates" : nil, useFewShot ? "fewshot" : nil, useSplit ? "split" : nil]
let mode = modeBits.compactMap { $0 }.joined(separator: " + ")

if rankMode && useV3 {
    struct R3 { let e: TestEvent; let v: UrgencyVerdict }
    var rows: [R3] = []
    var skipped: [TestEvent] = []
    for e in events {
        if isLowInformation(title: e.title) { skipped.append(e); continue }
        let t = stripDates ? stripDatePhrases(e.title) : e.title
        guard let v = try? await rateHolistically(t, e.cal, hours: e.hours)
        else { skipped.append(e); continue }
        rows.append(R3(e: e, v: v))
    }
    rows.sort { (a: R3, b: R3) -> Bool in a.v.rank > b.v.rank }

    print("")
    print("RANKED · V3 · model sees event + context + distance, rates directly")
    print(String(repeating: "=", count: 86))
    print(pad("#", 4) + pad("EVENT", 32) + pad("STARTS", 9) + pad("RANK", 7) + "RATING")
    print(String(repeating: "-", count: 86))
    for (i, r) in rows.enumerated() {
        print(pad(String(i + 1), 4) + pad(r.e.title, 32) + pad(hrs(r.e.hours), 9)
              + pad(String(r.v.rank), 7) + r.v.rating.rawValue)
    }
    if !skipped.isEmpty {
        print("")
        print("NOT RANKED")
        for e in skipped { print("     " + pad(e.title, 32) + hrs(e.hours)) }
    }
    print("")
    exit(0)
}

if rankMode && useV2 {
    struct R2 { let e: TestEvent; let j: EventJudgement; let score: Double }
    var rows: [R2] = []
    var skipped: [TestEvent] = []
    for e in events {
        if isLowInformation(title: e.title) { skipped.append(e); continue }
        guard let j = try? await judge(stripDates ? stripDatePhrases(e.title) : e.title, e.cal)
        else { skipped.append(e); continue }
        rows.append(R2(e: e, j: j, score: scoreV2(j, hoursUntil: e.hours)))
    }
    rows.sort { (a: R2, b: R2) -> Bool in a.score > b.score }

    print("")
    print("RANKED · V2 · model judges importance and horizon, code only converts units")
    print(String(repeating: "=", count: 92))
    print(pad("#", 4) + pad("EVENT", 32) + pad("STARTS", 8) + pad("SCORE", 7)
          + pad("IMPORTANCE", 12) + "HORIZON")
    print(String(repeating: "-", count: 92))
    for (i, r) in rows.enumerated() {
        print(pad(String(i + 1), 4) + pad(r.e.title, 32) + pad(hrs(r.e.hours), 8)
              + pad(String(format: "%.1f", r.score), 7)
              + pad(r.j.importance.rawValue, 12) + r.j.horizon.rawValue)
    }
    if !skipped.isEmpty {
        print("")
        print("NOT RANKED")
        for e in skipped { print("     " + pad(e.title, 32) + hrs(e.hours)) }
    }
    print("")
    exit(0)
}

if rankMode {
    struct Ranked { let e: TestEvent; let sem: EventSemantics; let score: Double; let actBy: Double }
    var ranked: [Ranked] = []
    var unranked: [TestEvent] = []

    for e in events {
        guard let (sem, _) = try? await extract(e.title, e.cal) else { unranked.append(e); continue }
        let actBy = actByHours(sem, hours: e.hours)
        ranked.append(Ranked(e: e, sem: sem, score: scoreOf(sem, hours: e.hours), actBy: actBy))
    }
    ranked.sort { (a: Ranked, b: Ranked) -> Bool in a.score > b.score }

    print("")
    print("RANKED ORDER · \(ranked.count) events")
    print("The only question here: is anything in the wrong place?")
    print(String(repeating: "=", count: 98))
    print(pad("#", 4) + pad("EVENT", 32) + pad("STARTS", 8) + pad("ACT BY", 9)
          + pad("SCORE", 7) + pad("BUCKET", 10) + "WHY IT SITS HERE")
    print(String(repeating: "-", count: 98))

    for (i, x) in ranked.enumerated() {
        let prep = effectivePrep(x.sem)
        let why = "\(x.sem.consequence.rawValue)/\(x.sem.movability.rawValue)"
            + (prep != .none ? " +\(prep.rawValue) prep" : "")
        print(pad(String(i + 1), 4) + pad(x.e.title, 32) + pad(hrs(x.e.hours), 8)
              + pad(hrs(x.actBy), 9) + pad(String(format: "%.1f", x.score), 7)
              + pad(bucket(x.score).rawValue, 10) + why)
    }

    if !unranked.isEmpty {
        print("")
        print("NOT RANKED · stay in chronological order, never alerted")
        for e in unranked { print("     " + pad(e.title, 32) + hrs(e.hours)) }
    }
    print("")
    exit(0)
}

if sweepMode {
    let base = "/Users/chukwuebukaohiomoba/Documents/Novel/Olana/"
    let bm = try? CurrentImpl.loadModel(base + "UrgencyBucketModel.mlpackage")
    let sm = try? CurrentImpl.loadModel(base + "UrgencyScoreModel.mlpackage")
    func toBucket(_ s: String) -> String {
        switch s { case "high": return "CRIT"; case "medium": return "SOON"
                   case "low": return "LATER"; default: return "?" }
    }
    func shortB(_ b: Bucket) -> String {
        switch b { case .critical: return "CRIT"; case .soon: return "SOON"; case .later: return "LATER" }
    }

    let offsets: [Double] = [3, 12, 24, 72, 168, 336]
    print("")
    print("TIME SWEEP · semantics extracted ONCE per title, combiner re-run per offset")
    print(String(repeating: "=", count: 108))
    print(pad("TITLE", 30) + pad("MODEL", 9) + offsets.map { pad($0 < 48 ? "\(Int($0))h" : "\(Int($0/24))d", 8) }.joined())
    print(String(repeating: "-", count: 108))

    for e in events {
        guard let (sem, _) = try? await extract(e.title, e.cal) else {
            print(pad(e.title, 30) + "REFUSED"); continue
        }
        let o5 = offsets.map { pad(shortB(bucket(scoreOf(sem, hours: $0))), 8) }.joined()
        print(pad(e.title, 30) + pad("option5", 9) + o5)

        if let bm, let sm {
            let cur = offsets.map { h -> String in
                let r = CurrentImpl.predict(bucketModel: bm, scoreModel: sm, title: e.title, hoursUntil: h)
                return pad(toBucket(r?.bucket ?? "?"), 8)
            }.joined()
            print(pad("", 30) + pad("current", 9) + cur)
        }
        let kw = offsets.map { pad(toBucket(CurrentImpl.keywordPath(title: e.title, hoursUntil: $0)), 8) }.joined()
        print(pad("", 30) + pad("keyword", 9) + kw)
        print(pad("", 30) + pad("", 9) + "semantics: \(sem.consequence.rawValue)/\(sem.movability.rawValue)/"
              + "\(effectivePrep(sem).rawValue)/\(sem.category.rawValue)")
        print("")
    }
    exit(0)
}

if vsCurrent {
    let base = "/Users/chukwuebukaohiomoba/Documents/Novel/Olana/"
    guard let bm = try? CurrentImpl.loadModel(base + "UrgencyBucketModel.mlpackage"),
          let sm = try? CurrentImpl.loadModel(base + "UrgencyScoreModel.mlpackage") else {
        print("Could not load the shipping CoreML models"); exit(1)
    }

    func toBucket(_ s: String) -> String {
        switch s { case "high": return "CRITICAL"; case "medium": return "SOON"
                   case "low": return "LATER"; default: return s.uppercased() }
    }

    print("")
    print("HEAD TO HEAD · \(events.count) events")
    print(String(repeating: "=", count: 104))
    print(pad("EVENT", 32) + pad("WHEN", 6) + pad("CURRENT ML", 13) + pad("(conf)", 9)
          + pad("CURRENT KEYWD", 15) + pad("OPTION 5", 12) + "ALARM")
    print(String(repeating: "-", count: 104))

    var mlDist: [String: Int] = [:], kwDist: [String: Int] = [:], o5Dist: [String: Int] = [:]
    var mlKwDisagree = 0
    var o5Results: [String: EventSemantics] = [:]
    var mlResults: [String: String] = [:], kwResults: [String: String] = [:]
    var confs: [Double] = []

    for e in events {
        let ml = CurrentImpl.predict(bucketModel: bm, scoreModel: sm,
                                     title: e.title, hoursUntil: e.hours)
        let mlB = toBucket(ml?.bucket ?? "?")
        let kwB = toBucket(CurrentImpl.keywordPath(title: e.title, hoursUntil: e.hours))
        if let c = ml?.confidence, !c.isNaN { confs.append(c) }

        var o5B = "REFUSED", alarm = "-"
        if let (sem, _) = try? await extract(e.title, e.cal) {
            o5Results[e.title] = sem
            let sc = scoreOf(sem, hours: e.hours)
            o5B = bucket(sc).rawValue
            alarm = alarmTier(sc, sem)
            o5Dist[o5B, default: 0] += 1
        }
        mlDist[mlB, default: 0] += 1
        kwDist[kwB, default: 0] += 1
        mlResults[e.title] = mlB
        kwResults[e.title] = kwB
        if mlB != kwB { mlKwDisagree += 1 }

        print(pad(e.title, 32) + pad(hrs(e.hours), 6) + pad(mlB, 13)
              + pad(ml.map { String(format: "%.2f", $0.confidence) } ?? "-", 9)
              + pad(kwB, 15) + pad(o5B, 12) + alarm)
    }

    // Which approach separates minimal pairs?
    let prs = Dictionary(grouping: events.filter { $0.pair != nil }, by: { $0.pair! })
    var mlSep = 0, kwSep = 0, o5Sep = 0, total = 0
    for key in prs.keys.sorted() {
        let g = prs[key]!
        guard g.count == 2 else { continue }
        total += 1
        if mlResults[g[0].title] != mlResults[g[1].title] { mlSep += 1 }
        if kwResults[g[0].title] != kwResults[g[1].title] { kwSep += 1 }
        if let a = o5Results[g[0].title], let b = o5Results[g[1].title],
           a.consequence != b.consequence || a.movability != b.movability
            || a.requiresPreparation != b.requiresPreparation { o5Sep += 1 }
    }

    print(String(repeating: "-", count: 104))
    print("Distribution")
    print("  current ML      \(mlDist.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  "))")
    print("  current keyword \(kwDist.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  "))")
    print("  option 5        \(o5Dist.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  "))")
    print("")
    print("Minimal pairs separated (of \(total))")
    print("  current ML      \(mlSep)")
    print("  current keyword \(kwSep)")
    print("  option 5        \(o5Sep)")
    print("")
    if !confs.isEmpty {
        let over80 = confs.filter { $0 >= 0.80 }.count
        print(String(format: "Current ML mean confidence %.2f · at or above 0.80 on %d/%d events",
                     confs.reduce(0,+)/Double(confs.count), over80, confs.count))
        print("  (the k-NN personalisation layer only fires below 0.80)")
    }
    print("The two shipping paths disagree with each other on \(mlKwDisagree)/\(events.count) events")
    print("")
    exit(0)
}

print("")
print("UrgencyProbe · \(events.count) events · greedy · \(mode.isEmpty ? "BASELINE" : mode)")
print(String(repeating: "=", count: 106))
print(pad("EVENT", 32) + pad("WHEN", 6) + pad("CONSEQ", 10) + pad("MOVE", 11)
      + pad("PREP", 8) + pad("CATEGORY", 13) + pad("SCORE", 7) + pad("BUCKET", 10) + "ALARM")
print(String(repeating: "-", count: 106))

var results: [String: EventSemantics] = [:]
var latencies: [TimeInterval] = []
var refused: [String] = []
var severeCount = 0, fixedCount = 0, prepCount = 0

for e in events {
    do {
        let (sem, ms) = try await extract(e.title, e.cal)
        latencies.append(ms)
        results[e.title] = sem
        if sem.consequence == .severe { severeCount += 1 }
        if sem.movability == .fixed { fixedCount += 1 }
        if effectivePrep(sem) != .none { prepCount += 1 }
        let sc = scoreOf(sem, hours: e.hours)
        print(pad(e.title, 32) + pad(hrs(e.hours), 6)
              + pad(sem.consequence.rawValue, 10) + pad(sem.movability.rawValue, 11)
              + pad(effectivePrep(sem).rawValue, 8) + pad(sem.category.rawValue, 13)
              + pad(String(format: "%.1f", sc), 7) + pad(bucket(sc).rawValue, 10)
              + alarmTier(sc, sem))
    } catch {
        refused.append(e.title)
        print(pad(e.title, 32) + (error is UnrankableTitle ? "— no opinion, stays chronological" : "REFUSED"))
    }
}

let pairs = Dictionary(grouping: events.filter { $0.pair != nil }, by: { $0.pair! })
if !pairs.isEmpty {
    print("")
    print("MINIMAL PAIRS · did context change the judgement?")
    print(String(repeating: "-", count: 106))
    var distinguished = 0, comparable = 0
    for key in pairs.keys.sorted() {
        let group = pairs[key]!
        guard group.count == 2,
              let a = results[group[0].title], let b = results[group[1].title] else { continue }
        comparable += 1
        let differs = a.consequence != b.consequence || a.movability != b.movability
            || a.requiresPreparation != b.requiresPreparation
        if differs { distinguished += 1 }
        func line(_ t: String, _ s: EventSemantics) -> String {
            pad(t, 34) + pad(s.consequence.rawValue, 10) + pad(s.movability.rawValue, 11)
                + pad(s.requiresPreparation ? "prep" : "no-prep", 9) + s.category.rawValue
        }
        print((differs ? "  ok  " : "  --  ") + line(group[0].title, a))
        print("      " + line(group[1].title, b))
    }
    print("")
    print("Distinguished \(distinguished) of \(comparable) pairs")
}

print(String(repeating: "-", count: 106))
if !latencies.isEmpty {
    print(String(format: "Latency avg %.2fs  worst %.2fs  total %.0fs",
                 latencies.reduce(0,+)/Double(latencies.count), latencies.max()!, latencies.reduce(0,+)))
}
let n = max(results.count, 1)
print("Distribution: severe \(severeCount)/\(n) · fixed \(fixedCount)/\(n) · prep fired \(prepCount)/\(n)")
print("Refused: \(refused.count)/\(events.count)" + (refused.isEmpty ? "" : " -> " + refused.joined(separator: ", ")))
print("")
