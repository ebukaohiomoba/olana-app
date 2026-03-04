//
//  CalendarDataStore.swift
//  Olana
//
//  SwiftData-backed store for UserCalendar objects and CalendarPreferences.
//  Owned by CalendarIntegrationManager and exposed to settings views.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class CalendarDataStore: ObservableObject {

    @Published private(set) var userCalendars: [UserCalendar] = []
    @Published private(set) var preferences: CalendarPreferences

    private let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer = CalendarPersistence.shared.container) {
        self.container = container
        self.context   = ModelContext(container)

        // Bootstrap preferences before running load() so `preferences` is always set
        let prefDesc = FetchDescriptor<CalendarPreferences>()
        if let existing = try? context.fetch(prefDesc).first {
            preferences = existing
        } else {
            let fresh = CalendarPreferences()
            context.insert(fresh)
            try? context.save()
            preferences = fresh
        }

        load()
    }

    // MARK: - Load

    func load() {
        let calDesc = FetchDescriptor<UserCalendar>()
        userCalendars = (try? context.fetch(calDesc)) ?? []

        let prefDesc = FetchDescriptor<CalendarPreferences>()
        if let existing = try? context.fetch(prefDesc).first {
            preferences = existing
        }
    }

    // MARK: - UserCalendar mutations

    func upsertCalendar(_ calendar: UserCalendar) {
        if let existing = userCalendars.first(where: { $0.calendarID == calendar.calendarID }) {
            existing.name     = calendar.name
            existing.colorHex = calendar.colorHex
            // Don't overwrite isEnabled or urgencyOverride — user controls those
        } else {
            context.insert(calendar)
            userCalendars.append(calendar)
        }
        save()
    }

    /// Removes UserCalendar records from a specific source whose IDs are no longer present.
    /// Scoped to one source so Apple and Google lists don't clobber each other.
    func removeCalendars(notIn calendarIDs: Set<String>, source: CalendarSource) {
        let toRemove = userCalendars.filter {
            $0.source == source && !calendarIDs.contains($0.calendarID)
        }
        for cal in toRemove { context.delete(cal) }
        userCalendars.removeAll { $0.source == source && !calendarIDs.contains($0.calendarID) }
        save()
    }

    func setEnabled(_ enabled: Bool, forCalendarID id: String) {
        guard let cal = userCalendars.first(where: { $0.calendarID == id }) else { return }
        cal.isEnabled = enabled
        save()
        objectWillChange.send()
    }

    func setUrgencyOverride(_ urgency: EventUrgency?, forCalendarID id: String) {
        guard let cal = userCalendars.first(where: { $0.calendarID == id }) else { return }
        cal.urgencyOverride = urgency
        save()
        objectWillChange.send()
    }

    // MARK: - Preferences mutations

    func setImminentWindow(_ minutes: Int) {
        preferences.imminentWindowMinutes = minutes
        save()
        objectWillChange.send()
    }

    func setShowDayContextBar(_ show: Bool) {
        preferences.showDayContextBar = show
        save()
        objectWillChange.send()
    }

    func setShowImminentCard(_ show: Bool) {
        preferences.showImminentCard = show
        save()
        objectWillChange.send()
    }

    // MARK: - Private

    private func save() {
        try? context.save()
    }
}
