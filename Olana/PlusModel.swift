//
//  PlusModel.swift
//  Olana
//
//  Olana Plus (PRD v6 §1.10, §1.12 H4). Pure rules, stored state in
//  PlusStore:
//
//  - Preview: the first 5 Plus moments the user actually experiences are free.
//    A moment is a Plus alert acted on (tapped, Directions, I'm leaving) or a
//    Plus helper used on the sheet. Scheduled-but-ignored alerts don't count.
//    One moment per event per kind, so opening the same sheet twice isn't two.
//    No card, no time limit.
//  - After the 5th: one calm screen says what Plus did, with the price.
//  - Beta: a fake-door paywall. "Get Plus" records intent and unlocks for free.
//  - Never charge a device that fails the Apple Intelligence gate.
//
//  The Apple Intelligence gate (PRD v3 §1.11 step 2) is here too: which screen
//  a device gets, from the model's availability.
//

import Foundation

enum PlusMomentKind: String, Codable, CaseIterable {
    case leftOnTime      // leave alert acted on, Directions, I'm leaving
    case gotReady        // get-ready alert acted on
    case prepStarted     // prep alert acted on, a step checked, prep done
    case bringUsed       // the bring list used
    case alarm           // an AlarmKit alarm answered
}

struct PlusMoment: Codable, Equatable {
    var kind: PlusMomentKind
    var eventKey: String
    var at: Date
}

struct PlusState: Codable, Equatable {
    var purchased = false
    /// Beta fake door: tapped "Get Plus" (intent recorded, unlocked free).
    var fakeDoorAt: Date?
    var moments: [PlusMoment] = []
    /// The summary screen was shown after the preview ran out.
    var summaryShownAt: Date?
}

enum PlusRules {
    static let previewMoments = 5
    static let prices = (yearly: "$39.99/yr", monthly: "$4.99/mo", lifetime: "$79.99 lifetime")

    static func hasPlus(_ s: PlusState, gatePassed: Bool) -> Bool {
        guard gatePassed else { return false }   // nothing to sell without Apple Intelligence
        return s.purchased || s.fakeDoorAt != nil || s.moments.count < previewMoments
    }

    static func inPreview(_ s: PlusState) -> Bool {
        !s.purchased && s.fakeDoorAt == nil && s.moments.count < previewMoments
    }

    /// Records a moment once per event and kind. Returns the new state and
    /// whether this moment ended the preview (show the summary).
    static func record(_ m: PlusMoment, in s: PlusState) -> (PlusState, endedPreview: Bool) {
        guard inPreview(s) else { return (s, false) }
        guard !s.moments.contains(where: { $0.kind == m.kind && $0.eventKey == m.eventKey }) else { return (s, false) }
        var next = s
        next.moments.append(m)
        return (next, next.moments.count == previewMoments)
    }

    /// "Got you out the door 3 times", most specific first.
    static func summary(_ s: PlusState) -> [String] {
        func count(_ k: PlusMomentKind) -> Int { s.moments.filter { $0.kind == k }.count }
        func times(_ n: Int) -> String { n == 1 ? "once" : (n == 2 ? "twice" : "\(n) times") }
        var lines: [String] = []
        let out = count(.leftOnTime) + count(.gotReady)
        if out > 0 { lines.append("Got you out the door \(times(out))") }
        if count(.prepStarted) > 0 { lines.append("Got prep started \(times(count(.prepStarted)))") }
        if count(.bringUsed) > 0 { lines.append("Had your things ready \(times(count(.bringUsed)))") }
        if count(.alarm) > 0 { lines.append("Woke you for what mattered \(times(count(.alarm)))") }
        return lines
    }
}

// MARK: - Apple Intelligence gate (PRD v3 §1.11 step 2, §1.10)

enum IntelligenceGate: Equatable {
    case available
    /// The device can't run Apple Intelligence: explanation, no paywall.
    case notEligible
    /// Eligible but switched off: deep link to Settings.
    case turnedOff
    /// Downloading: continue, with a banner.
    case downloading

    /// From FoundationModels' unavailable reason, as a string so this stays pure.
    static func from(reason: String?) -> IntelligenceGate {
        switch reason {
        case nil: return .available
        case "appleIntelligenceNotEnabled": return .turnedOff
        case "modelNotReady": return .downloading
        default: return .notEligible
        }
    }

    /// Plus can be sold only when the model can run (or is about to).
    var canSellPlus: Bool { self == .available || self == .downloading }

    var title: String {
        switch self {
        case .available: return ""
        case .notEligible: return "Olana needs Apple Intelligence"
        case .turnedOff: return "Turn on Apple Intelligence"
        case .downloading: return "Apple Intelligence is getting ready"
        }
    }

    var message: String {
        switch self {
        case .available: return ""
        case .notEligible:
            return "Olana judges what matters on your iPhone, without sending your calendar anywhere. That needs Apple Intelligence, which this iPhone doesn't have. Your reminders still work."
        case .turnedOff:
            return "Olana uses Apple Intelligence on your iPhone to work out what matters. Turn it on in Settings › Apple Intelligence & Siri."
        case .downloading:
            return "Your events will be judged as soon as it's ready. Everything else works now."
        }
    }
}
