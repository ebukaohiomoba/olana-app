//
//  UserPreferences.swift
//  Olana
//
//  CloudKit-backed model for per-user state that must survive device switches.
//  Currently stores calendar integration config; notification preferences are
//  handled separately via NSUbiquitousKeyValueStore (see NotificationProfile.swift).
//

import Foundation
import SwiftData

// MARK: - UserPreferences

@Model
final class UserPreferences {
    /// Identifiers of calendar sources the user has connected.
    /// e.g. ["google", "apple", "outlook"]
    var connectedCalendars: [String] = []

    /// Whether background calendar sync is active.
    var calendarSyncEnabled: Bool = false

    /// Timestamp of the most recent successful calendar sync.
    var lastCalendarSyncDate: Date? = nil

    init(
        connectedCalendars: [String] = [],
        calendarSyncEnabled: Bool = false,
        lastCalendarSyncDate: Date? = nil
    ) {
        self.connectedCalendars  = connectedCalendars
        self.calendarSyncEnabled = calendarSyncEnabled
        self.lastCalendarSyncDate = lastCalendarSyncDate
    }
}

// MARK: - CalendarSource

/// Supported external calendar platforms.
/// Used as the string value stored in UserPreferences.connectedCalendars.
enum CalendarSource: String, CaseIterable {
    case apple   = "apple"
    case google  = "google"
    case outlook = "outlook"

    var displayName: String {
        switch self {
        case .apple:   return "Apple Calendar"
        case .google:  return "Google Calendar"
        case .outlook: return "Outlook"
        }
    }

    var iconName: String {
        switch self {
        case .apple:   return "calendar"
        case .google:  return "globe"
        case .outlook: return "envelope.fill"
        }
    }
}
