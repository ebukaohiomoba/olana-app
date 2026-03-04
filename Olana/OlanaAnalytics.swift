//
//  OlanaAnalytics.swift
//  Olana
//
//  Thin wrapper around FirebaseAnalytics.
//  All event names and parameter keys are defined here so there are no
//  magic strings scattered across the codebase and everything is easy to
//  search for in the Firebase console.
//

import Foundation
import FirebaseAnalytics

enum OlanaAnalytics {

    // MARK: - Events

    /// User created a new event.
    static func eventCreated(urgency: EventUrgency, recurrenceRule: RecurrenceRule, titleWordCount: Int) {
        Analytics.logEvent("event_created", parameters: [
            "urgency":          urgency.analyticsName,
            "recurrence_rule":  recurrenceRule.analyticsName,
            "is_recurring":     recurrenceRule != .none ? "true" : "false",
            "title_word_count": titleWordCount
        ])
    }

    /// User marked an event as complete.
    static func eventCompleted(urgency: EventUrgency, xpEarned: Int, streakDays: Int, isRecurring: Bool) {
        Analytics.logEvent("event_completed", parameters: [
            "urgency":      urgency.analyticsName,
            "xp_earned":    xpEarned,
            "streak_days":  streakDays,
            "is_recurring": isRecurring ? "true" : "false"
        ])
    }

    /// User undid a completion (tapped the checkmark on an already-done event).
    static func eventUncompleted(urgency: EventUrgency) {
        Analytics.logEvent("event_uncompleted", parameters: [
            "urgency": urgency.analyticsName
        ])
    }

    /// User deleted a single event occurrence.
    static func eventDeleted(urgency: EventUrgency, isRecurring: Bool) {
        Analytics.logEvent("event_deleted", parameters: [
            "urgency":      urgency.analyticsName,
            "is_recurring": isRecurring ? "true" : "false"
        ])
    }

    /// User deleted an entire recurring series (this + all upcoming).
    static func seriesDeleted(urgency: EventUrgency, recurrenceRule: RecurrenceRule) {
        Analytics.logEvent("series_deleted", parameters: [
            "urgency":         urgency.analyticsName,
            "recurrence_rule": recurrenceRule.analyticsName
        ])
    }

    /// User saved edits to an existing event.
    static func eventEdited(urgencyChanged: Bool, recurrenceChanged: Bool) {
        Analytics.logEvent("event_edited", parameters: [
            "urgency_changed":    urgencyChanged    ? "true" : "false",
            "recurrence_changed": recurrenceChanged ? "true" : "false"
        ])
    }

    /// User switched to a tab.
    static func tabViewed(_ tab: AppTab) {
        Analytics.logEvent("tab_viewed", parameters: [
            "tab_name": tab.analyticsName
        ])
    }

    /// User signed in (or up) with a social provider.
    /// Uses Firebase's reserved "login" event name so it appears in the
    /// standard Audience reports automatically.
    static func login(method: SignInMethod) {
        Analytics.logEvent(AnalyticsEventLogin, parameters: [
            AnalyticsParameterMethod: method.rawValue
        ])
    }

    // MARK: - Supporting types

    enum AppTab {
        case home, calendar, friends, settings
        var analyticsName: String {
            switch self {
            case .home:     return "home"
            case .calendar: return "calendar"
            case .friends:  return "friends"
            case .settings: return "settings"
            }
        }
    }

    enum SignInMethod: String {
        case google = "google"
        case apple  = "apple"
    }
}

// MARK: - Convenience extensions

private extension EventUrgency {
    var analyticsName: String {
        switch self {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        }
    }
}

private extension RecurrenceRule {
    var analyticsName: String {
        switch self {
        case .none:     return "none"
        case .daily:    return "daily"
        case .weekdays: return "weekdays"
        case .weekly:   return "weekly"
        case .monthly:  return "monthly"
        }
    }
}
