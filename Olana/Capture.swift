//
//  Capture.swift
//  Olana
//
//  Capture parse (PRD v6 §1.7a, §3.4a): what Olana reads from the add-box
//  message besides the date and time. Code finds what it can (meeting links,
//  street addresses, numbers); the model points at words for the rest (place,
//  things to bring or do, arrive-early); code checks every word it points at
//  is really in the message, and drops what isn't.
//
//  The model never writes an address, time or number that reaches the screen.
//

import Foundation
import FoundationModels

// MARK: - Model schema (PRD v6 §3.4a)

@Generable
enum ArriveEarlyBucket: String, CaseIterable, Codable {
    case none, few, quarter, half, hour, airport

    /// Code turns the bucket into minutes (principle 3).
    var minutes: Int {
        switch self {
        case .none: return 0
        case .few: return 5
        case .quarter: return 15
        case .half: return 30
        case .hour: return 60
        case .airport: return 120
        }
    }
}

@Generable
enum CaptureAttendance: String, CaseIterable, Codable {
    case inPerson, virtual, unsure
}

@Generable
struct CaptureParse {
    @Guide(description: "Words from the message that name where this happens, copied exactly. Empty if none.")
    var placeText: String
    @Guide(description: "Things to bring or do beforehand, each copied exactly from the message.", .maximumCount(5))
    var prepItems: [String]
    @Guide(description: "Words saying to arrive early, copied exactly. Empty if none.")
    var arriveEarlyText: String
    @Guide(description: "How early to arrive. none unless the message says to arrive early or it is a flight.")
    var arriveEarlyBucket: ArriveEarlyBucket
    @Guide(description: "inPerson, virtual for calls and online meetings, unsure when you cannot tell.")
    var attendance: CaptureAttendance
    @Guide(description: "Would the user need to travel somewhere for this?")
    var likelyNeedsTravel: Bool
}

enum CapturePrompt {
    static let version = 1
    /// Messages are capped for parsing (§3.4a).
    static let maxLength = 500

    static let instructions = """
    You read a short message someone typed to add an event to their calendar. Point at words in \
    the message; never write words that are not in it.

    placeText: the words naming where it happens, copied exactly from the message: a business, \
    venue, street address, room, landmark or someone's home. It usually follows "at", "in" or \
    "from". Leave it empty when the message names no place. The activity is never the place: \
    a message that only says what happens and when has no place. A time is never a place. For a \
    flight or train, the place is where it departs from, never the destination city.

    prepItems: things to bring or do before the event, copied exactly from the message. Only \
    things the message says to bring, take, print, send, review or finish first. Never the \
    event itself and never the words about arriving early. At most five. Usually empty.

    arriveEarlyText: the words that say to arrive early, copied exactly from the message. \
    Empty when the message doesn't say to arrive early.
    arriveEarlyBucket: few for "a few minutes", quarter for about 15 minutes, half for about \
    30, hour for about an hour, airport for flights. none when nothing says to arrive early \
    and it is not a flight.

    attendance: virtual for calls, video meetings, webinars and anything online; inPerson when \
    they go somewhere or someone comes to them; unsure when you cannot tell.
    likelyNeedsTravel: true when they must go somewhere away from where they are.
    """

    static func prompt(_ message: String) -> String {
        "Message: \(String(message.prefix(maxLength)))"
    }
}

/// The model's answer as plain values, so code and tests don't depend on the
/// generated type's initializers.
struct CaptureModelOutput: Equatable {
    var placeText = ""
    var prepItems: [String] = []
    var arriveEarlyText = ""
    var arriveEarlyBucket: ArriveEarlyBucket = .none
    var attendance: CaptureAttendance = .unsure
    var likelyNeedsTravel = false
}

extension CaptureModelOutput {
    init(_ p: CaptureParse) {
        self.init(placeText: p.placeText, prepItems: p.prepItems, arriveEarlyText: p.arriveEarlyText,
                  arriveEarlyBucket: p.arriveEarlyBucket, attendance: p.attendance,
                  likelyNeedsTravel: p.likelyNeedsTravel)
    }
}

// MARK: - Result

struct CaptureItem: Equatable, Codable, Hashable {
    let text: String
    /// "bring X", "pack X", "take X": a bring-list chip. Otherwise a prep step.
    let isBring: Bool
}

struct CaptureResult: Equatable {
    var placeText: String?
    /// Found by the address detector, not the model.
    var placeIsStreetAddress = false
    var meetingURL: URL?
    var meetingService: MeetingService?
    var attendance: CaptureAttendance?
    var items: [CaptureItem] = []
    var arriveEarlyText: String?
    var arriveEarlyMinutes: Int?
    var likelyNeedsTravel = false
    /// Model output that failed the substring check, for the log (§3.4a step 5).
    var dropped: [String] = []
    /// True when the model ran; false when only code found things.
    var modelRan = false

    var bring: [String] { items.filter(\.isBring).map(\.text) }
    var steps: [String] { items.filter { !$0.isBring }.map(\.text) }
}

// MARK: - Code side

enum CaptureCode {

    /// Steps 2 and 3: links and street addresses, by detector.
    static func detect(_ message: String) -> (meeting: URL?, address: String?) {
        let urls = NotesCleaner.detectURLs(in: message).map(URLGuard.unwrap).compactMap(URLGuard.validate)
        let meeting = urls.first { MeetingLinks.service(of: $0) != nil }
        var address: String?
        if let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let m = d.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let r = Range(m.range, in: message) {
            address = String(message[r]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return (meeting, address)
    }

    /// Step 5: case- and whitespace-insensitive substring check.
    static func appears(_ phrase: String, in message: String) -> Bool {
        let p = squash(phrase), m = squash(message)
        return !p.isEmpty && m.contains(p)
    }

    static func squash(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Step 7: a number in the arrive-early words → minutes, capped 0 to 180.
    static func minutes(fromArriveEarly text: String) -> Int? {
        let t = " " + text.lowercased() + " "
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                       "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
                                       "forty-five": 45, "fortyfive": 45, "sixty": 60, "ninety": 90]
        if t.contains("half an hour") || t.contains("half hour") || t.contains("half-hour") { return 30 }
        if t.contains("an hour and a half") || t.contains("hour and a half") { return 90 }
        let pattern = #"(\d+(?:\.\d+)?|[a-z\-]+)\s*-?\s*(minutes|minute|mins|min|m|hours|hour|hrs|hr|h)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let qr = Range(match.range(at: 1), in: t), let ur = Range(match.range(at: 2), in: t) else { return nil }
        let q = String(t[qr])
        guard let value = Double(q) ?? words[q] else { return nil }
        let isHours = t[ur].hasPrefix("h")
        let minutes = Int((isHours ? value * 60 : value).rounded())
        return min(max(minutes, 0), 180)
    }

    /// The model's place words are dropped when they are just the activity
    /// (the whole message minus times and links): the copied-title failure.
    static func isWholeMessage(_ place: String, title: String) -> Bool {
        squash(place) == squash(title)
    }

    static let bringVerbs = ["bring", "pack", "take", "grab", "don't forget", "dont forget", "remember"]
    /// An item starting with one of these is something to do, not to bring,
    /// even after "bring" ("bring the forms and review the deck").
    static let doVerbs: Set<String> = ["review", "print", "send", "read", "finish", "write", "prepare", "prep",
                                       "practice", "call", "email", "fill", "sign", "update", "book", "buy", "pick",
                                       "check", "confirm", "submit", "study", "rehearse", "charge", "download",
                                       "make", "draft", "go", "look", "order", "renew", "pay", "clean", "wash"]

    /// Combine detector facts, the model's pointers and the message (§3.4a order).
    /// `title` is the existing title extraction (dates and times removed).
    static func combine(message: String, title: String, model: CaptureModelOutput?) -> CaptureResult {
        var r = CaptureResult()
        let found = detect(message)
        r.meetingURL = found.meeting
        r.meetingService = found.meeting.flatMap(MeetingLinks.service(of:))

        if let address = found.address {
            r.placeText = address
            r.placeIsStreetAddress = true
        }

        guard let model else {
            r.attendance = found.meeting != nil ? .virtual : (found.address != nil ? .inPerson : nil)
            return r
        }
        r.modelRan = true

        // "at the tipsy cow" → "the tipsy cow": the lead-in isn't part of the place.
        let place = model.placeText.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"^(?i)(at|in|from|@)\s+"#, with: "", options: .regularExpression)
        if r.placeText == nil, !place.isEmpty {
            if !appears(place, in: message) { r.dropped.append("place: \(place)") }
            else if isWholeMessage(place, title: title) || isTimePhrase(place) || startsMessage(place, message) {
                r.dropped.append("place (not a place): \(place)")
            }
            else { r.placeText = place }
        }

        var seen = Set<String>()
        for raw in model.prepItems.prefix(5) {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !item.isEmpty, !seen.contains(squash(item)) else { continue }
            guard appears(item, in: message) else { r.dropped.append("item: \(item)"); continue }
            // Not the place, not the arrive-early words, and not the event itself
            // (the words the message starts with).
            if let p = r.placeText, squash(p) == squash(item) { continue }
            let early = squash(model.arriveEarlyText)
            if !early.isEmpty, early.contains(squash(item)) || squash(item).contains(early) { continue }
            if isArriveEarlyPhrase(item) { continue }
            if startsMessage(item, message) { r.dropped.append("item (the event itself): \(item)"); continue }
            seen.insert(squash(item))
            let stripped = stripVerb(item)
            let firstWord = squash(item).split(separator: " ").first.map(String.init) ?? ""
            let isBring = bringVerbs.contains { squash(item).hasPrefix($0 + " ") }
                || (!doVerbs.contains(firstWord) && followsBringVerb(item, in: message))
            r.items.append(CaptureItem(text: stripped.prefix(1).uppercased() + stripped.dropFirst(), isBring: isBring))
        }

        let early = model.arriveEarlyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !early.isEmpty {
            if appears(early, in: message) && isArriveEarlyPhrase(early) {
                r.arriveEarlyText = early
                r.arriveEarlyMinutes = minutes(fromArriveEarly: early) ?? nonZero(model.arriveEarlyBucket.minutes)
            } else {
                r.dropped.append("early: \(early)")
            }
        } else if model.arriveEarlyBucket == .airport {
            r.arriveEarlyMinutes = ArriveEarlyBucket.airport.minutes
        }

        // Attendance: a link alone is virtual and the model can't override it (§3.4).
        if r.meetingURL != nil && r.placeText == nil { r.attendance = .virtual }
        else { r.attendance = model.attendance }
        // A named place you attend in person means going there, unless it's home.
        let placeMeansTravel = r.placeText.map { !isHome($0) } ?? false
        r.likelyNeedsTravel = r.attendance != .virtual
            && (model.likelyNeedsTravel || r.placeIsStreetAddress || (placeMeansTravel && r.attendance == .inPerson))
        return r
    }

    static func nonZero(_ m: Int) -> Int? { m > 0 ? m : nil }

    /// Words that say when to arrive, not something to bring ("be there 15 min early").
    static func isArriveEarlyPhrase(_ s: String) -> Bool {
        let t = " " + squash(s) + " "
        if [" early ", " earlier ", " ahead ", " beforehand ", " before it starts ", " before start "].contains(where: { t.contains($0) }) { return true }
        return t.range(of: #"^ (need to |have to |must )?(be|get) there "#, options: .regularExpression) != nil
            || t.hasPrefix(" arrive ")
    }

    /// The phrase is how the message begins: that's the activity, not a place or an item.
    static func startsMessage(_ phrase: String, _ message: String) -> Bool {
        squash(message).hasPrefix(squash(phrase))
    }

    static func isHome(_ place: String) -> Bool {
        ["my place", "home", "my house", "my apartment", "my apt", "our place", "our house"].contains(squash(place))
    }

    static func isTimePhrase(_ s: String) -> Bool {
        let t = squash(s)
        if t.range(of: #"^(at )?\d{1,2}(:\d{2})?\s*(am|pm|a\.m|p\.m)?$"#, options: .regularExpression) != nil { return true }
        return ["noon", "midnight", "tonight", "tomorrow", "today", "morning", "evening", "afternoon"].contains(t)
    }

    static func stripVerb(_ item: String) -> String {
        let lower = item.lowercased()
        for v in bringVerbs where lower.hasPrefix(v + " ") {
            return String(item.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return item
    }

    /// "bring my insurance card and ID": items after a bring verb are bring
    /// items even when the model copied only the noun.
    static func followsBringVerb(_ item: String, in message: String) -> Bool {
        let m = squash(message), i = squash(item)
        guard let r = m.range(of: i) else { return false }
        let before = m[..<r.lowerBound]
        // Look back to the clause start (comma or period) for a bring verb.
        let clause = before.split(whereSeparator: { ",.;".contains($0) }).last.map(String.init) ?? String(before)
        return bringVerbs.contains { clause.contains($0 + " ") }
    }

    // MARK: Title

    /// The title with the words that became chips removed (§1.7a). Recomputed
    /// from the chips that are still on, so removing a chip puts its words back.
    static func title(_ base: String, removing phrases: [String]) -> String {
        var t = " " + base + " "
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where !phrase.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            // The phrase with its lead-in: "at Smile Dental", "bring insurance card", "and ID".
            let lead = #"(?:\s*,?\s*(?:and\s+)?(?:need to be there|need to get there|be there|get there|be|arrive|at|in|@|from|on|via|bring|pack|take|grab|remember|don't forget|dont forget|also)\s+(?:my\s+|the\s+|your\s+)?)?"#
            t = t.replacingOccurrences(of: lead + escaped + #"(?=[\s,.;!]|$)"#, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Tidy: dangling connectors and punctuation left behind.
        t = t.replacingOccurrences(of: #"\s+([,.;!])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,;])\s*([,;.!])"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"^(?:,|and|also)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[\s,;]+(?:and|also|at|in|from|to|on|with)?$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        guard let first = t.first else { return base }
        return first.uppercased() + t.dropFirst()
    }

    /// The phrases the chips took, for `title(_:removing:)`.
    static func chipPhrases(_ r: CaptureResult, message: String) -> [String] {
        var out: [String] = []
        if let p = r.placeText { out.append(p) }
        if let e = r.arriveEarlyText { out.append(e) }
        if let url = r.meetingURL {
            // The link as typed (detector text), so it leaves the title too.
            out += NotesCleaner.detectURLs(in: message).filter { URLGuard.unwrap($0) == url || $0 == url }.map(\.absoluteString)
        }
        for item in r.items { out.append(item.text) }
        return out
    }
}

// MARK: - Review-step draft (the chips' state)

/// One chip, identified by what it carries so removal is stable.
enum CaptureChipID: Hashable {
    case place, link, early
    case bring(String), step(String)
}

struct CaptureDraft: Equatable {
    var result = CaptureResult()
    var removed: Set<CaptureChipID> = []
    var match: PlaceMatch?
    var picked: ResolvedPlace?
    /// The message text the result was read from (corrections append to it).
    var message = ""

    /// The capture with removed chips taken out: what gets saved.
    var effective: CaptureResult {
        var r = result
        if removed.contains(.place) { r.placeText = nil; r.placeIsStreetAddress = false }
        if removed.contains(.link) { r.meetingURL = nil; r.meetingService = nil
            if r.attendance == .virtual && r.placeText == nil { r.attendance = nil } }
        if removed.contains(.early) { r.arriveEarlyText = nil; r.arriveEarlyMinutes = nil }
        r.items = r.items.filter { !removed.contains($0.isBring ? .bring($0.text) : .step($0.text)) }
        return r
    }

    /// The place to save: picked from "Which one?", or the single match.
    var place: ResolvedPlace? {
        guard !removed.contains(.place), result.placeText != nil else { return nil }
        if let picked { return picked }
        if case .resolved(let p)? = match { return p }
        return nil
    }

    /// Show "Where is it? (optional)": no place, no link, and it looks in person.
    func asksWhere(isTask: Bool) -> Bool {
        let e = effective
        return !isTask && e.placeText == nil && e.meetingURL == nil && e.attendance != .virtual
            && (e.likelyNeedsTravel || e.attendance == .inPerson)
    }

    /// A place or a meeting link makes it an event: tasks have neither (§1.7a).
    var impliesEvent: Bool {
        let e = effective
        return e.placeText != nil || e.meetingURL != nil
    }

    /// A new read of an edited message. Chips that read the same keep what the
    /// user did to them (removed, or a place picked from "Which one?").
    func reparsed(_ r: CaptureResult, message: String) -> CaptureDraft {
        var next = CaptureDraft(result: r, message: message)
        if r.placeText != nil, r.placeText == result.placeText {
            next.match = match
            next.picked = picked
            if removed.contains(.place) { next.removed.insert(.place) }
        }
        if r.meetingURL != nil, r.meetingURL == result.meetingURL, removed.contains(.link) { next.removed.insert(.link) }
        if r.arriveEarlyText != nil, r.arriveEarlyText == result.arriveEarlyText, removed.contains(.early) {
            next.removed.insert(.early)
        }
        for id in removed {
            switch id {
            case .bring(let t) where r.bring.contains(t): next.removed.insert(id)
            case .step(let t) where r.steps.contains(t): next.removed.insert(id)
            default: break
            }
        }
        return next
    }

    /// The title with chip words taken out of `base`. Tasks show no place or
    /// arrive-early chip, so those words stay in a task's title.
    func title(_ base: String, isTask: Bool) -> String {
        var shown = effective
        if isTask { shown.placeText = nil; shown.arriveEarlyText = nil }
        return CaptureCode.title(base, removing: CaptureCode.chipPhrases(shown, message: message))
    }

    /// What the 📍 chip says, including what MapKit found: the place's name and
    /// address, "Which …?", or "not found" (no leave-by).
    var placeChip: (label: String, detail: String?, found: Bool?)? {
        guard let words = effective.placeText else { return nil }
        if let picked { return (picked.name, picked.address, true) }
        switch match {
        case .resolved(let p)?: return (p.name, p.address, true)
        case .choose?: return ("Which \(words)?", nil, nil)
        case PlaceMatch.none?: return (words, "not found", false)
        default: return (words, nil, nil)
        }
    }
}

// MARK: - Task or event (no switch)

/// Whether a typed message is an event (has a span, a place or a call) or a
/// task (a thing to do by a time, kept until checked off). There is no switch:
/// the end-time chip is the override (add an end and it's an event, remove it
/// and it's a task).
enum AddKind {
    static func isEvent(hasEnd: Bool, draft: CaptureDraft, message: String) -> Bool {
        if hasEnd || draft.impliesEvent { return true }
        if isDeadline(message) { return false }
        let attendance = draft.effective.attendance
        return attendance == .inPerson || attendance == .virtual
    }

    /// "Report due Friday", "pay rent by the 1st", "remind me to call the bank":
    /// a deadline or a to-do, not something that happens at a time.
    static func isDeadline(_ message: String) -> Bool {
        let t = " " + CaptureCode.squash(message) + " "
        if [" due ", " deadline ", " remind me to ", " reminder to ", " don't forget to ", " dont forget to "]
            .contains(where: { t.contains($0) }) { return true }
        let byWhen = #" (by|before) (\d|noon|midnight|tonight|today|tomorrow|eod|end of|the end|mon|tue|wed|thu|fri|sat|sun|next|this)"#
        return t.range(of: byWhen, options: .regularExpression) != nil
    }

    /// The message for the date detector: deadline connectors removed, since
    /// NSDataDetector splits "tomorrow by 5pm" into noon tomorrow and 5pm today,
    /// and reads "due friday 5pm" as a time today.
    static func dateText(_ message: String) -> String {
        message.replacingOccurrences(of: #"(?i)\b(by|due|before)\b\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}

// MARK: - Model call

enum CaptureParser {
    #if DEBUG
    /// Screenshot fixtures: a fixed model answer, for simulators without the model.
    nonisolated(unsafe) static var fixtureOutput: CaptureModelOutput?
    /// How long the fixture answer takes, to show the working state.
    nonisolated(unsafe) static var fixtureDelay: Double = 0
    #endif

    /// Runs the model once with one retry on a non-safety error. Returns nil when
    /// unavailable, refused or failed; the event then saves as today (§3.4a).
    static func parse(_ message: String) async -> CaptureModelOutput? {
        #if DEBUG
        if let fixtureOutput {
            try? await Task.sleep(for: .seconds(fixtureDelay))
            return fixtureOutput
        }
        #endif
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let options = GenerationOptions(sampling: .greedy)
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: CapturePrompt.instructions)
            do {
                let out = try await session.respond(to: CapturePrompt.prompt(message), generating: CaptureParse.self,
                                                    options: options).content
                return CaptureModelOutput(out)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .refusal, .guardrailViolation: return nil
                default: if attempt == 1 { return nil }
                }
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    /// Code facts, then the model, then the checks.
    static func run(message: String, title: String) async -> CaptureResult {
        let model = await parse(message)
        return CaptureCode.combine(message: message, title: title, model: model)
    }
}
