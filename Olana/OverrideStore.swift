//
//  OverrideStore.swift
//  Olana
//
//  The stored side of overrides (PRD v3 §3.11): one record per event or series
//  key, in the CloudKit-backed store with the events. Overrides.swift holds the
//  pure precedence logic.
//

import Foundation
import SwiftData

/// CloudKit needs every attribute optional or defaulted, and no unique constraints.
@Model
final class AssistOverride {
    var key: String = ""
    var scopeRaw: String = OverrideScope.event.rawValue
    var assistModeRaw: String? = nil
    var stepsText: String? = nil       // newline-joined; "" = removed all
    var bringText: String? = nil
    var origin: String? = nil
    var travelMode: String? = nil
    var arriveEarlyMinutes: Int? = nil
    var hiddenHelpersText: String? = nil
    var version: Int = 0
    var updatedAt: Date = Date()

    init(key: String, scope: OverrideScope) {
        self.key = key
        self.scopeRaw = scope.rawValue
    }

    var values: OverrideValues {
        func list(_ s: String?) -> [String]? {
            s.map { $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        return OverrideValues(assistMode: assistModeRaw.flatMap(AssistMode.init(rawValue:)),
                              steps: list(stepsText), bring: list(bringText), origin: origin, travelMode: travelMode,
                              arriveEarlyMinutes: arriveEarlyMinutes, hiddenHelpers: list(hiddenHelpersText), version: version)
    }

    func apply(_ v: OverrideValues) {
        assistModeRaw = v.assistMode?.rawValue
        stepsText = v.steps?.joined(separator: "\n")
        bringText = v.bring?.joined(separator: "\n")
        origin = v.origin
        travelMode = v.travelMode
        arriveEarlyMinutes = v.arriveEarlyMinutes
        hiddenHelpersText = v.hiddenHelpers?.joined(separator: "\n")
        version += 1
        updatedAt = Date()
    }
}

extension OlanaEvent {
    var overrideEventKey: String {
        OverrideKeys.event(source: externalCalendarId, sourceID: externalEventId, iCalUID: iCalUID, localID: id,
                           occurrenceStart: occurrenceStart, start: start)
    }
    var overrideSeriesKey: String? {
        OverrideKeys.series(source: externalCalendarId, seriesID: seriesID, iCalUID: iCalUID,
                            isRecurring: recurrenceRule != .none || seriesID != nil || occurrenceStart != nil,
                            title: title, rule: "\(recurrenceRule.rawValue)")
    }
}
