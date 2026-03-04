//
//  CalendarIntegrationManager.swift
//  Olana
//
//  Top-level singleton that orchestrates EventKit (Apple) and Google Calendar
//  permission, calendar-list refresh, and sync cycles.
//  Inject as an @EnvironmentObject from ContentView.
//

import Foundation
import Combine
import EventKit
import SwiftData

// MARK: - Sync State

enum CalendarSyncState: Equatable {
    case idle
    case syncing
    case error(String)
}

// MARK: - CalendarIntegrationManager

@MainActor
final class CalendarIntegrationManager: ObservableObject {

    // MARK: Published state (drives UI)
    @Published private(set) var syncState:    CalendarSyncState = .idle
    @Published private(set) var lastSyncDate: Date?             = nil
    @Published private(set) var syncError:    String?           = nil

    // MARK: Sub-components
    let eventKitProvider = EventKitProvider()
    let googleProvider   = GoogleCalendarProvider()

    // Set by setup(dataStore:eventStore:) called from ContentView.onAppear
    private var dataStore: CalendarDataStore?
    private var eventStore: EventStore?

    private var accessRequestObserver: NSObjectProtocol?
    /// Forwards GoogleOAuthManager changes to CalendarIntegrationManager subscribers
    /// so SwiftUI views that observe calendarManager also re-render on Google state changes.
    private var googleOAuthCancellable: AnyCancellable?

    // MARK: - Init

    init() {
        eventKitProvider.checkStatus()

        googleOAuthCancellable = GoogleOAuthManager.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Lifecycle

    func setup(dataStore: CalendarDataStore, eventStore: EventStore) {
        self.dataStore  = dataStore
        self.eventStore = eventStore

        // GoogleOAuthManager loads persisted accounts from UserDefaults on init —
        // no explicit restore step needed here.

        // Re-sync whenever the user edits Apple Calendar from outside the app.
        eventKitProvider.startObserving { [weak self] in
            Task { @MainActor [weak self] in
                await self?.performFullSync()
            }
        }

        // Observe consent-sheet confirmation posted by CalendarView.
        accessRequestObserver = NotificationCenter.default.addObserver(
            forName: .calendarAccessRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.requestAccess()
            }
        }
    }

    func teardown() {
        eventKitProvider.stopObserving()
        if let token = accessRequestObserver {
            NotificationCenter.default.removeObserver(token)
            accessRequestObserver = nil
        }
    }

    // MARK: - Apple Authorization

    var isAuthorized: Bool { eventKitProvider.isAuthorized }
    var authorizationStatus: EKAuthorizationStatus { eventKitProvider.authorizationStatus }

    @discardableResult
    func requestAccess() async -> Bool {
        let granted = await eventKitProvider.requestAccess()
        if granted {
            await refreshAppleCalendarList()
            await performFullSync()
        }
        return granted
    }

    // MARK: - Google: multi-account

    var googleConnectedAccounts: [GoogleOAuthAccount] { GoogleOAuthManager.shared.connectedAccounts }
    var isGoogleConnecting: Bool                      { GoogleOAuthManager.shared.isConnecting }
    var hasGoogleAccounts: Bool                       { !GoogleOAuthManager.shared.connectedAccounts.isEmpty }

    func addGoogleAccount() async throws {
        try await GoogleOAuthManager.shared.addAccount()
        await refreshGoogleCalendarList()
        await performFullSync()
    }

    func removeGoogleAccount(id: String) {
        GoogleOAuthManager.shared.removeAccount(id: id)
        guard let eventStore, let dataStore else { return }

        if GoogleOAuthManager.shared.connectedAccounts.isEmpty {
            // No more Google accounts — wipe all Google-sourced data.
            eventStore.syncExternalCalendarEvents(
                source: "google", from: .distantPast, to: .distantFuture, events: []
            )
            dataStore.removeCalendars(notIn: [], source: .google)
        } else {
            // Re-sync so events from the removed account disappear.
            Task { await performFullSync() }
        }
    }

    // MARK: - Calendar Lists

    /// Syncs Apple EKCalendars into UserCalendar SwiftData objects.
    func refreshAppleCalendarList() async {
        guard let dataStore else { return }
        let ekCalendars = eventKitProvider.fetchCalendars()
        let ids         = Set(ekCalendars.map { $0.calendarIdentifier })

        for ekCal in ekCalendars {
            let uc = UserCalendar(
                calendarID: ekCal.calendarIdentifier,
                name:       ekCal.title,
                source:     .apple,
                colorHex:   hexColor(from: ekCal.cgColor)
            )
            dataStore.upsertCalendar(uc)
        }
        dataStore.removeCalendars(notIn: ids, source: .apple)
    }

    /// Syncs Google Calendar lists for all connected accounts into UserCalendar records.
    func refreshGoogleCalendarList() async {
        guard let dataStore else { return }
        var allIDs: Set<String> = []

        for account in GoogleOAuthManager.shared.connectedAccounts {
            do {
                let entries = try await googleProvider.fetchCalendarList(for: account.id)
                for entry in entries {
                    let uc = UserCalendar(
                        calendarID: entry.id,
                        name:       "\(entry.summary) (\(account.email))",
                        source:     .google,
                        colorHex:   entry.backgroundColor
                    )
                    dataStore.upsertCalendar(uc)
                    allIDs.insert(entry.id)
                }
            } catch {
                print("CalendarIntegrationManager: Google calendar list refresh failed for \(account.email) — \(error)")
            }
        }
        dataStore.removeCalendars(notIn: allIDs, source: .google)
    }

    /// Refreshes both Apple and Google calendar lists.
    func refreshCalendarList() async {
        await refreshAppleCalendarList()
        await refreshGoogleCalendarList()
    }

    // MARK: - Sync Cycles

    /// Quick sync: today + tomorrow. Called on every foreground transition.
    func performQuickSync() async {
        guard let dataStore, let eventStore else { return }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: now.startOfDay) ?? now

        if eventKitProvider.isAuthorized {
            await _appleSync(from: now.startOfDay, to: end, dataStore: dataStore, eventStore: eventStore)
        }
        if hasGoogleAccounts {
            await _googleSync(from: now.startOfDay, to: end, dataStore: dataStore, eventStore: eventStore)
        }
    }

    /// Full sync: 90 days. Called on first grant, EKEventStoreChanged, and manual refresh.
    func performFullSync() async {
        guard let dataStore, let eventStore else { return }

        syncState = .syncing
        let now   = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 90, to: now.startOfDay) else {
            syncState = .idle
            return
        }

        if eventKitProvider.isAuthorized {
            await _appleSync(from: now.startOfDay, to: end, dataStore: dataStore, eventStore: eventStore)
        }
        if hasGoogleAccounts {
            await _googleSync(from: now.startOfDay, to: end, dataStore: dataStore, eventStore: eventStore)
        }

        lastSyncDate = Date()
        syncState    = .idle
        syncError    = nil
    }

    // MARK: - Apple sync implementation

    private func _appleSync(
        from start: Date,
        to end: Date,
        dataStore: CalendarDataStore,
        eventStore: EventStore
    ) async {
        let enabledIDs = Set(dataStore.userCalendars
            .filter { $0.source == .apple && $0.isEnabled }
            .map { $0.calendarID })
        let allCalendars = eventKitProvider.fetchCalendars()

        let calendarsToFetch: [EKCalendar]? = enabledIDs.isEmpty
            ? nil
            : allCalendars.filter { enabledIDs.contains($0.calendarIdentifier) }

        let ekEvents   = eventKitProvider.fetchEvents(from: start, to: end, calendars: calendarsToFetch)
        let userCals   = dataStore.userCalendars
        var normalised = ekEvents.map { CalendarSyncEngine.normalise(ekEvent: $0, userCalendars: userCals) }
        normalised     = CalendarSyncEngine.deduplicate(normalised)

        eventStore.syncExternalCalendarEvents(source: "apple", from: start, to: end, events: normalised)
    }

    // MARK: - Google sync implementation (all connected accounts)

    private func _googleSync(
        from start: Date,
        to end: Date,
        dataStore: CalendarDataStore,
        eventStore: EventStore
    ) async {
        let enabledIDs = Set(dataStore.userCalendars
            .filter { $0.source == .google && $0.isEnabled }
            .map { $0.calendarID })

        var allEvents: [OlanaEvent] = []

        for account in GoogleOAuthManager.shared.connectedAccounts {
            do {
                let calEntries = try await googleProvider.fetchCalendarList(for: account.id)
                for entry in calEntries {
                    if !enabledIDs.isEmpty && !enabledIDs.contains(entry.id) { continue }
                    do {
                        let gEvents = try await googleProvider.fetchEvents(
                            calendarID: entry.id, from: start, to: end, for: account.id
                        )
                        let normalised = gEvents.compactMap {
                            CalendarSyncEngine.normalise(
                                gEvent: $0, calendarEntry: entry, userCalendars: dataStore.userCalendars
                            )
                        }
                        allEvents.append(contentsOf: normalised)
                    } catch {
                        print("CalendarIntegrationManager: events fetch failed for \(entry.id) (\(account.email)) — \(error)")
                    }
                }
            } catch GoogleOAuthError.unauthorized {
                // Refresh token invalid — flag the account but don't sign it out automatically.
                print("CalendarIntegrationManager: token expired for \(account.email) — needs reconnect")
            } catch {
                syncError = error.localizedDescription
                print("CalendarIntegrationManager: Google sync failed for \(account.email) — \(error)")
            }
        }

        let deduplicated = CalendarSyncEngine.deduplicate(allEvents)
        eventStore.syncExternalCalendarEvents(
            source: "google", from: start, to: end, events: deduplicated
        )
    }

    // MARK: - Helpers

    private func hexColor(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let components = cgColor.components,
              components.count >= 3
        else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by CalendarView when the user taps "Connect my calendar" in the consent sheet.
    static let calendarAccessRequested = Notification.Name("olana.calendarAccessRequested")
}

// MARK: - Date helper

private extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
}
