//
//  HomeFixtures.swift
//  Olana
//
//  DEBUG only. Launch with `-homeFixture full` (or `empty`, or `rail` for the
//  rail alone) to open the new
//  home on fixed data at 1:52 PM, skipping login, so it can be checked against
//  home_literata.html on any simulator. Set light or dark with
//  `xcrun simctl ui booted appearance`.
//

#if DEBUG
import SwiftUI

enum HomeFixtures {

    static var requested: String? {
        UserDefaults.standard.string(forKey: "homeFixture")
            ?? UserDefaults.standard.string(forKey: "spikes").map { "spikes-" + $0 }
    }

    static func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: Date())!
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
    }

    static func input(_ title: String, _ start: Date, _ end: Date, _ urgency: EventUrgency,
                      prepHours: Double? = nil, place: String? = nil,
                      isTask: Bool = false, completed: Bool = false,
                      assisted: Bool? = nil) -> HomeDayBuilder.Input {
        .init(id: UUID(), title: title, start: start, end: end, isAllDay: false,
              isTask: isTask, completed: completed, completedAt: nil, isRecurring: false,
              location: place, urgency: urgency, scored: nil, prepHours: prepHours,
              assisted: assisted ?? (urgency != .low))
    }

    /// The mockup's Tuesday: two things done, client review at 3 with 40 min prep.
    static func fullDay() -> HomeDay {
        let review = input("Client review", at(15, 0), at(16, 0), .high, prepHours: 40.0 / 60, place: "Room 2")
        let inputs = [
            input("Standup", at(9, 30), at(9, 45), .low),
            input("Send invoice", at(11, 0), at(11, 0), .medium, isTask: true, completed: true),
            review,
            input("Pick up prescription", at(17, 30), at(17, 45), .medium, prepHours: 10.0 / 60),
            input("Gym", at(19, 0), at(20, 0), .low),
            input("Call mom", at(20, 30), at(21, 0), .low),
        ]
        return HomeDayBuilder.build(inputs: inputs, now: at(13, 52), bed: at(22, 0))
    }

    /// Client review in 90 minutes at an address, with an invite, a deck link,
    /// a Teams link and things the user typed.
    static func sheetEvent() -> OlanaEvent {
        let start = Calendar.current.date(byAdding: .minute, value: 90, to: Date())!
        let e = OlanaEvent(title: "Client review", start: start, end: start.addingTimeInterval(3600), urgency: .high,
                           externalCalendarId: "google", externalEventId: "fixture-1",
                           notes: """
                           Walk through the Q3 numbers and agree next steps.
                           Deck: https://docs.google.com/presentation/d/abc/edit
                           Pricing sheet: https://docs.google.com/spreadsheets/d/def/edit
                           """,
                           location: "Acme HQ, 500 Market St, San Francisco", calendarName: "Work")
        e.prepItemsText = "Review the pricing sheet"
        e.bringItemsText = "Laptop"
        e.applyPlace(ResolvedPlace(name: "Acme HQ", address: "500 Market St, San Francisco", latitude: 37.79,
                                   longitude: -122.40, phone: "(415) 555-0100", website: "https://acme.example.com"))
        return e
    }

    static let sheetAssist = AssistOutcome.full(AssistResult(
        source: .model, locationKind: .streetAddress, kind: .inPersonMeeting, needsTravel: true, attendance: .inPerson,
        arriveEarlyMinutes: 10, outTheDoorMinutes: 5, effortMinutes: 30, helpers: [.leave, .prep, .materials, .bring, .place],
        steps: ["Skim the deck"], bring: ["Printed agenda"], linkLabels: ["L1": "Client deck", "L2": "Pricing"],
        dropped: [], version: 1))

    /// Saturday with nothing on it; the next thing that matters is Thursday.
    static func emptyDay() -> HomeDay {
        let review = input("Quarterly review", at(9, 0, dayOffset: 2), at(10, 0, dayOffset: 2), .high, prepHours: 2)
        return HomeDayBuilder.build(inputs: [review], now: at(10, 15), bed: at(22, 0))
    }
}

struct HomeFixtureScreen: View {
    let which: String
    @State private var tab: OlanaTab = .home
    @StateObject private var store = EventStore()

    var body: some View {
        if which == "sheet" || which == "sheet-free" {
            // `-homeFixture sheet`: the event sheet on a fixed event, Plus on
            // (or off with `sheet-free`), with a fixed EventAssist answer.
            Color.clear
                .sheet(isPresented: .constant(true)) {
                    EventSheetView(event: HomeFixtures.sheetEvent(), fixtureOutcome: HomeFixtures.sheetAssist)
                        .environmentObject(store)
                        .homePalette()
                        .presentationDetents([.large])
                }
                .onAppear { PlusAccess.setDebug(which == "sheet") }
        } else if which.hasPrefix("spikes-") {
            // `-spikes open` or `-spikes autorun`: the Spikes screen, no login.
            NavigationStack { SpikesView(autorun: which == "spikes-autorun") }
                .environmentObject(store)
        } else {
            home
        }
    }

    @ViewBuilder
    private var home: some View {
        let day = which == "empty" ? HomeFixtures.emptyDay() : HomeFixtures.fullDay()
        ScreenBody(day: day, tab: $tab)
            .homePalette()
    }

    private struct ScreenBody: View {
        let day: HomeDay
        @Binding var tab: OlanaTab
        @Environment(\.homePalette) private var c

        var body: some View {
            ScrollView {
                if HomeFixtures.requested == "rail" {
                    DayRailView(day: day).padding(.horizontal, 22)
                } else {
                    HomeScreenContent(day: day, syncText: day.isOpen
                                      ? .init(text: "Apple Calendar and Google synced 2 min ago", fresh: true) : nil)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: OlanaTabBar.height - 20) }
            .background(c.bg.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                OlanaTabBar(selection: $tab) {}.padding(.bottom, 4)
            }
        }
    }
}
#endif
