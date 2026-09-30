//
//  SyncMergeTests.swift
//  OlanaTests
//
//  EventStore.syncExternalCalendarEvents updates synced events in place. These
//  pin down the matching rules, because a wrong match either duplicates events
//  or silently deletes what Olana knows about them.
//

import Foundation
import Testing
@testable import Olana

@MainActor
struct SyncMergeTests {

    let day: TimeInterval = 86_400
    let window: (start: Date, end: Date)
    let store: EventStore

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        window = (today, today.addingTimeInterval(90 * 86_400))
        store = EventStore(container: Persistence(inMemory: true).container)
    }

    private func synced(_ xid: String, _ title: String, at offset: TimeInterval) -> OlanaEvent {
        let start = window.start.addingTimeInterval(offset)
        return OlanaEvent(title: title, start: start, end: start.addingTimeInterval(3600),
                          urgency: .medium, externalCalendarId: "apple", externalEventId: xid)
    }

    private func sync(_ events: [OlanaEvent]) {
        store.syncExternalCalendarEvents(source: "apple", from: window.start,
                                         to: window.end, events: events)
    }

    private let judged = EventSemantics(consequence: .severe, movability: .fixed,
                                        requiresPreparation: false, prepNeed: .none,
                                        category: .travel)

    @Test func resyncKeepsIdentityCompletionAndSemantics() {
        sync([synced("a", "Flight to Lagos", at: 3 * day)])
        let original = store.events[0]
        original.applySemantics(judged)
        original.completed = true

        sync([synced("a", "Flight to Lagos", at: 3 * day)])

        #expect(store.events.count == 1)
        #expect(store.events[0].id == original.id)
        #expect(store.events[0].completed)
        #expect(store.events[0].cachedSemantics == judged)
    }

    @Test func movedEventIsUpdatedNotDuplicated() {
        sync([synced("a", "Dentist", at: 3 * day)])
        let id = store.events[0].id

        sync([synced("a", "Dentist", at: 5 * day)])

        #expect(store.events.count == 1)
        #expect(store.events[0].id == id)
        #expect(store.events[0].start == window.start.addingTimeInterval(5 * day))
    }

    @Test func renamedEventLosesSemanticsSoItIsJudgedAgain() {
        sync([synced("a", "Dentist", at: 3 * day)])
        store.events[0].applySemantics(judged)

        sync([synced("a", "Dentist cancelled", at: 3 * day)])

        #expect(store.events.count == 1)
        #expect(store.events[0].cachedSemantics == nil)
    }

    @Test func recurringOccurrencesSharingAnIdStaySeparate() {
        // EventKit gives every occurrence of a series the same identifier.
        let series = (0..<3).map { synced("weekly", "Standup review", at: Double($0) * 7 * day + day) }
        sync(series)
        let ids = Set(store.events.map(\.id))

        sync((0..<3).map { synced("weekly", "Standup review", at: Double($0) * 7 * day + day) })

        #expect(store.events.count == 3)
        #expect(Set(store.events.map(\.id)) == ids)
    }

    @Test func newOccurrenceDoesNotTakeOverLastYearsCompletedOne() {
        // A yearly event: last year's occurrence sits before the window.
        sync([])
        let lastYear = synced("bday", "Mum's birthday", at: -365 * day)
        lastYear.completed = true
        store.syncExternalCalendarEvents(source: "apple",
                                         from: lastYear.start.addingTimeInterval(-day),
                                         to: lastYear.start.addingTimeInterval(day),
                                         events: [lastYear])

        sync([synced("bday", "Mum's birthday", at: 10 * day)])

        #expect(store.events.count == 2)
        let upcoming = store.events.first { $0.start > Date() }
        #expect(upcoming?.completed == false)
    }

    @Test func removedFromSourceIsDeletedButOnlyInsideWindow() {
        sync([synced("a", "Dentist", at: 3 * day), synced("b", "Flight", at: 4 * day)])

        // A quick sync only covers the next two days: nothing outside it may go.
        store.syncExternalCalendarEvents(source: "apple", from: window.start,
                                         to: window.start.addingTimeInterval(2 * day), events: [])
        #expect(store.events.count == 2)

        sync([synced("b", "Flight", at: 4 * day)])
        #expect(store.events.map(\.externalEventId) == ["b"])
    }

    @Test func otherSourcesAreUntouched() {
        store.syncExternalCalendarEvents(source: "google", from: window.start, to: window.end,
                                         events: [OlanaEvent(title: "Retro planning",
                                                             start: window.start.addingTimeInterval(day),
                                                             end: window.start.addingTimeInterval(day + 3600),
                                                             urgency: .medium,
                                                             externalCalendarId: "google",
                                                             externalEventId: "g1")])
        sync([])
        #expect(store.events.count == 1)
    }
}
