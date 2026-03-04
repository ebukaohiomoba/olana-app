//
//  UserCalendar.swift
//  Olana
//
//  SwiftData model representing a connected external calendar (Apple Calendar source,
//  future: Google, Outlook). Stored per calendar — not per event — so the user can
//  toggle individual calendars and set urgency overrides at the calendar level.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - UserCalendar

@Model
final class UserCalendar {
    /// EKCalendar.calendarIdentifier (Apple) or Google Calendar ID.
    var calendarID: String = ""

    /// Display name shown in CalendarSettingsView (e.g. "Personal", "Work").
    var name: String = ""

    /// Raw value of CalendarSource enum — stored as String for CloudKit compat.
    var sourceRaw: String = CalendarSource.apple.rawValue

    /// Hex colour string from the source calendar (e.g. "#FF3B30"). Used for dot indicators.
    var colorHex: String? = nil

    /// Whether this calendar's events are synced and shown in Olana.
    var isEnabled: Bool = true

    /// Optional user-set urgency override for all events in this calendar.
    /// nil = auto-assign urgency per event. Stored as raw Int for CloudKit compat.
    var urgencyOverrideRaw: Int? = nil

    init(
        calendarID: String,
        name: String,
        source: CalendarSource = .apple,
        colorHex: String? = nil,
        isEnabled: Bool = true
    ) {
        self.calendarID        = calendarID
        self.name              = name
        self.sourceRaw         = source.rawValue
        self.colorHex          = colorHex
        self.isEnabled         = isEnabled
    }

    // MARK: - Computed helpers

    var source: CalendarSource {
        CalendarSource(rawValue: sourceRaw) ?? .apple
    }

    var urgencyOverride: EventUrgency? {
        get { urgencyOverrideRaw.flatMap { EventUrgency(rawValue: $0) } }
        set { urgencyOverrideRaw = newValue?.rawValue }
    }

    /// SwiftUI Color derived from colorHex. Falls back to .accentColor.
    var displayColor: Color {
        guard let hex = colorHex else { return .accentColor }
        return Color(hex: hex)
    }
}

// MARK: - CalendarPreferences

/// Singleton-style SwiftData record for calendar display preferences.
/// Only one instance should exist in the store (created on first launch).
@Model
final class CalendarPreferences {
    /// How many minutes before an event's start it is considered "imminent".
    var imminentWindowMinutes: Int = 90

    /// Whether to show the DayContextBar on the Home screen.
    var showDayContextBar: Bool = true

    /// Whether to show the ImminentEventCard pinned to the top of the event list.
    var showImminentCard: Bool = true

    // Urgency overrides per calendar — stored as parallel arrays because
    // SwiftData/CloudKit does not support Dictionary storage.
    var urgencyOverrideCalendarIDs: [String] = []
    var urgencyOverrideValues: [Int] = []

    init() {}

    func urgencyOverride(for calendarID: String) -> EventUrgency? {
        guard let idx = urgencyOverrideCalendarIDs.firstIndex(of: calendarID) else { return nil }
        return EventUrgency(rawValue: urgencyOverrideValues[idx])
    }

    func setUrgencyOverride(_ urgency: EventUrgency?, for calendarID: String) {
        if let idx = urgencyOverrideCalendarIDs.firstIndex(of: calendarID) {
            if let urgency {
                urgencyOverrideValues[idx] = urgency.rawValue
            } else {
                urgencyOverrideCalendarIDs.remove(at: idx)
                urgencyOverrideValues.remove(at: idx)
            }
        } else if let urgency {
            urgencyOverrideCalendarIDs.append(calendarID)
            urgencyOverrideValues.append(urgency.rawValue)
        }
    }
}

