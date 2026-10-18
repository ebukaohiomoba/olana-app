//
//  Overrides.swift
//  Olana
//
//  Series and event overrides (PRD v3 §3.11). The user's word on an event, or on
//  every event in its series, beats the model. Beta minimum: assist mode, steps,
//  bring, origin, travel mode. Precedence: event > series > model > default.
//
//  Keys:
//  - event: source identity + original occurrence start, so an override
//    follows an occurrence the source moved;
//  - series: the source's series identity (Google recurringEventId, iCalUID),
//    or title + rule for Olana's own repeating events.
//
//  Synced through the user's private iCloud with the events (Persistence).
//

import Foundation

/// PRD v3 §1.6. Free to set (v6 §1.10); what it unlocks follows Plus.
enum AssistMode: String, Codable, CaseIterable {
    case always, normal, noAlerts

    var title: String {
        switch self {
        case .always: return "Always Assist"
        case .normal: return "Normal"
        case .noAlerts: return "No Execution Alerts"
        }
    }
}

enum OverrideScope: String, Codable { case event, series }

/// One override record's values, as plain data (pure; tested in SheetChecks).
struct OverrideValues: Equatable, Codable {
    var assistMode: AssistMode?
    /// nil: not overridden. []: the user removed them all.
    var steps: [String]?
    var bring: [String]?
    var origin: String?            // "home", "work", "current", or a saved place name
    var travelMode: String?        // "driving", "walking", "transit"
    var arriveEarlyMinutes: Int?   // launch tier, kept here so it has a home
    var hiddenHelpers: [String]?
    var version = 0

    var isEmpty: Bool {
        assistMode == nil && steps == nil && bring == nil && origin == nil && travelMode == nil
            && arriveEarlyMinutes == nil && hiddenHelpers == nil
    }
}

/// What an event ends up with after precedence.
struct EffectiveOverrides: Equatable {
    var assistMode: AssistMode
    var steps: [String]?
    var bring: [String]?
    var origin: String?
    var travelMode: String?
    var arriveEarlyMinutes: Int?
    var hiddenHelpers: Set<String>
    /// Series then event version, for the EventAssist cache key and the plan version.
    var versions: [Int]
    /// Where the steps came from, for the sheet's "Saved for this series" note.
    var stepsScope: OverrideScope?
    var bringScope: OverrideScope?
}

enum OverrideResolver {
    static func resolve(event e: OverrideValues?, series s: OverrideValues?,
                        defaultMode: AssistMode = .normal) -> EffectiveOverrides {
        func pick<T>(_ k: KeyPath<OverrideValues, T?>) -> T? { e?[keyPath: k] ?? s?[keyPath: k] }
        return EffectiveOverrides(
            assistMode: pick(\.assistMode) ?? defaultMode,
            steps: pick(\.steps), bring: pick(\.bring), origin: pick(\.origin), travelMode: pick(\.travelMode),
            arriveEarlyMinutes: pick(\.arriveEarlyMinutes),
            hiddenHelpers: Set(pick(\.hiddenHelpers) ?? []),
            versions: [s?.version ?? 0, e?.version ?? 0],
            stepsScope: e?.steps != nil ? .event : (s?.steps != nil ? .series : nil),
            bringScope: e?.bring != nil ? .event : (s?.bring != nil ? .series : nil))
    }
}

enum OverrideKeys {
    /// Source identity + original occurrence start.
    static func event(source: String?, sourceID: String?, iCalUID: String?, localID: UUID,
                      occurrenceStart: Date?, start: Date) -> String {
        let src = source ?? "native"
        let ident = iCalUID ?? sourceID ?? localID.uuidString
        return "\(src)|\(ident)|\(Int((occurrenceStart ?? start).timeIntervalSince1970))"
    }

    /// nil for a one-off event: there's no series to save to.
    static func series(source: String?, seriesID: String?, iCalUID: String?, isRecurring: Bool,
                       title: String, rule: String) -> String? {
        if let source {
            if let seriesID { return "\(source)|series|\(seriesID)" }
            // Recurring EventKit occurrences share the iCalUID.
            if isRecurring, let iCalUID { return "\(source)|series|\(iCalUID)" }
            return nil
        }
        guard isRecurring else { return nil }
        return "native|series|\(title.lowercased())|\(rule)"
    }
}
