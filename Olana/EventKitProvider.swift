//
//  EventKitProvider.swift
//  Olana
//
//  Thin wrapper around EKEventStore. Handles permission requests, event fetches,
//  and real-time change observation. All methods run on the MainActor.
//

import Foundation
import Combine
import EventKit

@MainActor
final class EventKitProvider: ObservableObject {

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    deinit {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .fullAccess
    }

    func checkStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    @discardableResult
    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(iOS 17, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            print("❌ EventKitProvider: access request failed: \(error)")
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    // MARK: - Fetch

    func fetchCalendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
    }

    /// Fetches events from `start` to `end`. Pass `nil` for `calendars` to fetch all.
    func fetchEvents(from start: Date, to end: Date, calendars: [EKCalendar]? = nil) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Change Observer

    /// Starts listening for EKEventStoreChanged. Fires `onChange` on the main queue.
    func startObserving(onChange: @escaping () -> Void) {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in onChange() }
    }

    func stopObserving() {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
            changeObserver = nil
        }
    }
}
