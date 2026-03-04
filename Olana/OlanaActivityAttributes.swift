//
//  OlanaActivityAttributes.swift
//  Olana
//
//  Shared between the Olana app target and the widget extension target.
//  Add this file to both targets via File Inspector → Target Membership.
//
//  OlanaEventAttributes has NO dependencies on app-only types (EventUrgency,
//  OlanaEvent, SwiftData, etc.) so it compiles cleanly inside the widget extension.
//

import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct OlanaEventAttributes: ActivityAttributes {
    /// Dynamic content — updated as the event approaches.
    public struct ContentState: Codable, Hashable {
        var eventStart: Date       // drives the system countdown timer on Lock Screen
        var minutesRemaining: Int
        var status: String         // "upcoming" | "starting" | "done"
    }

    // Static attributes (set once at request time)
    var eventId: String
    var eventTitle: String
    var urgencyRaw: Int            // EventUrgency.rawValue stored as Int — no app-type dependency
}

