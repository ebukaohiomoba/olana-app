//
//  AppServices.swift
//  Olana
//
//  The one event store, calendar data store and calendar manager per process.
//  The UI and the background run (BackgroundRefresh) share them, so a
//  background launch and the app never hold two stores over the same data.
//
//  Created lazily: the background run must not open the store before it has
//  checked the phone has been unlocked since restart (PRD §3.2 step 0), because
//  Persistence deletes and recreates its store when it can't open it.
//

import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: EventStore
    let calendarDataStore: CalendarDataStore
    let calendarManager: CalendarIntegrationManager

    private init() {
        store = EventStore()
        calendarDataStore = CalendarDataStore()
        calendarManager = CalendarIntegrationManager()
        calendarManager.setup(dataStore: calendarDataStore, eventStore: store)
        // The alert planner sees every event at once (PRD §3.9). Only here, so
        // a short-lived store (a preview) can't leave it pointing at nothing.
        let store = store
        NotificationEngine.shared.eventsProvider = { [weak store] in store?.events }
        NotificationEngine.shared.overridesProvider = { [weak store] e in
            store?.effectiveOverrides(for: e) ?? OverrideResolver.resolve(event: nil, series: nil)
        }
    }
}
