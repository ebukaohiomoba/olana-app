//
//  AlarmPlanTests.swift
//  OlanaTests
//
//  Whether an event earns an alarm must not depend on how far away it is when
//  the alarm gets scheduled. These pin that down, and when it rings.
//

import Foundation
import Testing
@testable import Olana

struct AlarmPlanTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    private func sem(_ c: Consequence, _ m: Movability, prep: PrepNeed = .none,
                     category: EventCategory = .work) -> EventSemantics {
        EventSemantics(consequence: c, movability: m, requiresPreparation: prep != .none,
                       prepNeed: prep, category: category)
    }

    @Test func flightFiveDaysOutGetsItsAlarm() {
        let start = now.addingTimeInterval(5 * 24 * hour)
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed, category: .travel),
                                             start: start, now: now)
        #expect(plan?.tier == .alarm)
        #expect(plan?.fireDate == start)
        #expect(plan?.advancedByPrep == false)

        // The old check, scored against now, said no.
        #expect(UrgencyCombiner.score(semantics: sem(.severe, .fixed, category: .travel),
                                      start: start, now: now)?.tier != .alarm)
    }

    @Test func moderateAndMinorNeverAlarm() {
        let start = now.addingTimeInterval(hour)
        #expect(UrgencyCombiner.alarmPlan(semantics: sem(.moderate, .fixed), start: start, now: now) == nil)
        #expect(UrgencyCombiner.alarmPlan(semantics: sem(.minor, .flexible), start: start, now: now) == nil)
    }

    @Test func prepWorkRingsWhenWorkMustStart() {
        let start = now.addingTimeInterval(10 * 24 * hour)
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed, prep: .long),
                                             start: start, now: now)
        #expect(plan?.fireDate == start.addingTimeInterval(-48 * hour))
        #expect(plan?.advancedByPrep == true)
    }

    @Test func tooLateToPrepRingsForTheEventInstead() {
        let start = now.addingTimeInterval(10 * hour)   // 48h of prep no longer fits
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed, prep: .long),
                                             start: start, now: now)
        #expect(plan?.fireDate == start)
        #expect(plan?.advancedByPrep == false)
    }

    @Test func prepGateStillApplies() {
        // Health never has prep, even if the model claims it.
        let start = now.addingTimeInterval(10 * 24 * hour)
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .difficult, prep: .long, category: .health),
                                             start: start, now: now)
        #expect(plan?.fireDate == start)
    }

    @Test func prepAlarmRingsAtPrepStartBy() {
        // B16: prep has to finish before leaving, so start-by is earlier than start − lead.
        let start = now.addingTimeInterval(10 * 24 * hour)
        let startBy = start.addingTimeInterval(-50 * hour)
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed, prep: .long),
                                             start: start, now: now, prepStartBy: startBy)
        #expect(plan?.fireDate == startBy)
        #expect(plan?.advancedByPrep == true)
    }

    @Test func pastPrepStartByRingsForTheEvent() {
        let start = now.addingTimeInterval(10 * hour)
        let plan = UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed, prep: .long),
                                             start: start, now: now, prepStartBy: now.addingTimeInterval(-hour))
        #expect(plan?.fireDate == start)
    }

    @Test func pastEventsGetNoPlan() {
        #expect(UrgencyCombiner.alarmPlan(semantics: sem(.severe, .fixed),
                                          start: now.addingTimeInterval(-hour), now: now) == nil)
    }
}

@MainActor
struct UrgencyRefreshTests {

    @Test func urgencyRisesAsEventApproaches() {
        let store = EventStore(container: Persistence(inMemory: true).container)
        let start = Date().addingTimeInterval(30 * 86_400)
        store.addEvent(title: "Flight to Lagos", start: start, end: start.addingTimeInterval(3600),
                       urgency: .medium,
                       semantics: EventSemantics(consequence: .severe, movability: .fixed,
                                                 requiresPreparation: false, prepNeed: .none,
                                                 category: .travel))
        #expect(store.events[0].urgency == .low)

        let changed = store.refreshUrgencies(now: start.addingTimeInterval(-20 * 3600))
        #expect(changed.count == 1)
        #expect(store.events[0].urgency == .high)
    }

    @Test func overrideIsNotRescored() {
        let store = EventStore(container: Persistence(inMemory: true).container)
        let start = Date().addingTimeInterval(30 * 86_400)
        store.addEvent(title: "Flight to Lagos", start: start, end: start.addingTimeInterval(3600),
                       urgency: .low,
                       semantics: EventSemantics(consequence: .severe, movability: .fixed,
                                                 requiresPreparation: false, prepNeed: .none,
                                                 category: .travel),
                       userPickedUrgency: true)

        let changed = store.refreshUrgencies(now: start.addingTimeInterval(-3600))
        #expect(changed.isEmpty)
        #expect(store.events[0].urgency == .low)
    }
}
