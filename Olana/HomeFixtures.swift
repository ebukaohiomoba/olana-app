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

    /// The mockup's Tuesday: two things done, client review at 3 with 40 min prep,
    /// and the rest of the week for the ribbon (week_ribbon.html).
    static func fullDay() -> HomeDay {
        HomeDayBuilder.build(inputs: fullWeek(), now: at(13, 52), bed: at(22, 0))
    }

    /// The ribbon's next day picked: tomorrow's rail, with the dentist's leave-by.
    static func tomorrow() -> HomeDay {
        HomeDayBuilder.build(inputs: fullWeek(), day: at(0, 0, dayOffset: 1), now: at(13, 52))
    }

    static func fullWeek() -> [HomeDayBuilder.Input] {
        var dentist = input("Dentist", at(15, 0, dayOffset: 1), at(16, 0, dayOffset: 1), .medium, place: "Smile Dental")
        dentist.exec = ExecTimes(.init(start: at(15, 0, dayOffset: 1), end: at(16, 0, dayOffset: 1), actBy: nil,
                                       attendance: .inPerson, needsTravel: true, eta: 18 * 60,
                                       arriveEarly: 10 * 60, outTheDoor: 5 * 60))
        dentist.tripPhrase = "18 min drive"
        return fullDayInputs() + [
            input("Standup", at(9, 30, dayOffset: 1), at(9, 45, dayOffset: 1), .low),
            dentist,
            input("Submit expenses", at(18, 0, dayOffset: 1), at(18, 0, dayOffset: 1), .medium, isTask: true, assisted: false),
            input("Call mom", at(19, 30, dayOffset: 1), at(20, 0, dayOffset: 1), .low),
            input("Quarterly review", at(9, 0, dayOffset: 3), at(10, 0, dayOffset: 3), .high, prepHours: 2),
            input("Design crit", at(13, 0, dayOffset: 3), at(14, 0, dayOffset: 3), .medium),
            input("Dinner with Jo", at(19, 0, dayOffset: 3), at(21, 0, dayOffset: 3), .medium),
            input("Haircut", at(11, 0, dayOffset: 4), at(11, 45, dayOffset: 4), .low, assisted: true),
        ]
    }

    static func fullDayInputs() -> [HomeDayBuilder.Input] {
        let review = input("Client review", at(15, 0), at(16, 0), .high, prepHours: 40.0 / 60, place: "Room 2")
        return [
            input("Standup", at(9, 30), at(9, 45), .low),
            input("Send invoice", at(11, 0), at(11, 0), .medium, isTask: true, completed: true),
            review,
            input("Pick up prescription", at(17, 30), at(17, 45), .medium, prepHours: 10.0 / 60),
            input("Gym", at(19, 0), at(20, 0), .low),
            input("Call mom", at(20, 30), at(21, 0), .low),
        ]
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

    /// M1-C: client review at an address, 14 min walk, now in GET READY.
    static func leaveDay() -> HomeDay {
        let now = at(14, 27)
        var review = input("Client review", at(15, 0), at(16, 0), .high, place: "Acme HQ")
        review.exec = ExecTimes(.init(start: at(15, 0), end: at(16, 0), actBy: at(13, 0), effort: .thirty,
                                      attendance: .inPerson, needsTravel: true, eta: 14 * 60,
                                      arriveEarly: 15 * 60, outTheDoor: 10 * 60))
        review.tripPhrase = "14 min walk from Home"
        review.etaSeconds = 14 * 60
        let later = input("Pick up prescription", at(17, 30), at(17, 45), .medium)
        return HomeDayBuilder.build(inputs: [review, later], now: now, bed: at(22, 0))
    }

    /// M1-C: a synced Moderate event tomorrow morning with no place.
    static func whereDay() -> HomeDay {
        var dentist = input("Dentist", at(9, 0, dayOffset: 1), at(10, 0, dayOffset: 1), .medium)
        dentist.question = .whereIsThis
        return HomeDayBuilder.build(inputs: [dentist, input("Gym", at(19, 0), at(20, 0), .low)], now: at(18, 0), bed: at(22, 0))
    }

    /// M1-C: the first trip with a place, and no home or work saved yet.
    static func fromDay() -> HomeDay {
        var dentist = input("Dentist", at(9, 0, dayOffset: 1), at(10, 0, dayOffset: 1), .medium)
        dentist.question = .whereFrom
        return HomeDayBuilder.build(inputs: [dentist, input("Gym", at(19, 0), at(20, 0), .low)], now: at(18, 0), bed: at(22, 0))
    }

    /// A light day where nothing matters enough for the card: "Up next".
    static func quietDay() -> HomeDay {
        HomeDayBuilder.build(inputs: [
            input("Standup", at(9, 30), at(9, 45), .low),
            input("Coffee with Jo", at(15, 0), at(15, 30), .low, place: "Blue Bottle"),
            input("Gym", at(19, 0), at(20, 0), .low),
        ], now: at(13, 52), bed: at(22, 0))
    }

    /// The night before an exam with nothing else today: the full card on the open day.
    static func examEve() -> HomeDay {
        let exam = input("Organic chemistry exam", at(9, 0, dayOffset: 1), at(11, 0, dayOffset: 1), .high, prepHours: 12)
        return HomeDayBuilder.build(inputs: [exam], now: at(19, 30), bed: at(22, 0))
    }

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
    /// `onboarding-flow`: the last step hands off to home, like the app does.
    @State private var onboarded = false

    var body: some View {
        if which == "paywall" {
            PlusPaywallView().homePalette()
        } else if which.hasPrefix("gate-") {
            // `-homeFixture gate-off`, `gate-none`, `gate-downloading`
            let gate: IntelligenceGate = which == "gate-off" ? .turnedOff : (which == "gate-none" ? .notEligible : .downloading)
            IntelligenceGateView(gate: gate) {}.homePalette()
        } else if which == "sheet" || which == "sheet-free" {
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
        } else if which.hasPrefix("settings") {
            // `-homeFixture settings`, `settings-notifications`, `settings-calendar`, `settings-travel`.
            Group {
                switch which {
                case "settings-notifications": NavigationStack { NotificationsSettingsView() }
                case "settings-calendar": NavigationStack { CalendarSettingsView() }
                case "settings-travel": NavigationStack { TravelSettingsView() }
                default: SettingsView()
                }
            }
            .environmentObject(store)
            .environmentObject(AppServices.shared.calendarManager)
            .environmentObject(AppServices.shared.calendarDataStore)
            .homePalette()
        } else if which == "reveal" || which == "reveal-empty" {
            // `-homeFixture reveal`: the onboarding reveal on a fixed week, judged
            // one event at a time; `reveal-empty` has no events.
            OnboardingView(start: .reveal,
                           fixture: .init(reveal: which == "reveal" ? RevealFixture.source() : { RevealSnapshot(done: true) })) {}
                .homePalette()
        } else if which.hasPrefix("onboarding") {
            // `-homeFixture onboarding` (promise), `onboarding-calendar`, `onboarding-notify`,
            // or `onboarding-flow`: every step playing itself, for recordings.
            // Nothing is asked of the system; the reveal runs on the fixed week.
            let start: OnboardingView.Step = which == "onboarding-calendar" ? .calendar
                : which == "onboarding-notify" ? .notify : .promise
            Group {
                if onboarded {
                    home.transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    OnboardingView(start: start, fixture: .init(reveal: RevealFixture.source(), autoplay: which == "onboarding-flow",
                                                                card: which == "onboarding-notify" ? RevealFixture.card() : nil)) {
                        guard which == "onboarding-flow" else { return }
                        withAnimation(.easeInOut(duration: 0.45)) { onboarded = true }
                    }
                    .homePalette()
                    .transition(.opacity)
                }
            }
        } else if which.hasPrefix("add") {
            // `-homeFixture add` (typing, place chip), `add-task` (no end time),
            // `add-review` (after Next, judged), `add-tiers` (tier chip opened),
            // `add-unjudged` (the model couldn't judge), `add-analyzing` (still reading).
            // `add-deadline` (a task) and `add-nodate` (nothing read: "When?").
            Color.clear.sheet(isPresented: .constant(true)) {
                AddEventView(fixtureText: which == "add" ? "Dentist tomorrow 3pm to 4pm at Smile Dental, bring insurance card"
                                        : which == "add-deadline" ? "Submit expenses tomorrow by 5pm"
                                        : which == "add-nodate" ? "Call the bank"
                                        : "Dentist tomorrow 3pm at Smile Dental, bring insurance card",
                             fixtureNext: !["add", "add-task", "add-deadline", "add-nodate"].contains(which),
                             fixtureTiers: which == "add-tiers")
                    .environmentObject(store)
                    .homePalette()
                    .onAppear {
                        CaptureParser.fixtureOutput = CaptureModelOutput(placeText: "at Smile Dental", prepItems: ["bring insurance card"],
                                                                         attendance: .inPerson, likelyNeedsTravel: true)
                        CaptureParser.fixtureDelay = which == "add-analyzing" ? 30 : 0
                        AIAssistant.fixtureSemantics = which == "add-unjudged" ? nil
                            : EventSemantics(consequence: .moderate, movability: .difficult,
                                             requiresPreparation: false, prepNeed: .none, category: .health)
                    }
            }
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
        let day = which == "empty" ? HomeFixtures.emptyDay()
            : which == "quiet" ? HomeFixtures.quietDay()
            : which == "tomorrow" ? HomeFixtures.tomorrow()
            : which == "exam-eve" ? HomeFixtures.examEve()
            : which == "leave" ? HomeFixtures.leaveDay()
            : which == "where" ? HomeFixtures.whereDay()
            : which == "from" ? HomeFixtures.fromDay() : HomeFixtures.fullDay()
        ScreenBody(day: day, tab: $tab)
            .homePalette()
    }

    private struct ScreenBody: View {
        let day: HomeDay
        @Binding var tab: OlanaTab
        @Environment(\.homePalette) private var c

        var body: some View {
            OlanaTabView(selection: $tab, onAdd: {}) {
                content
            } calendar: { c.bg } settings: { c.bg }
        }

        private var content: some View {
            ScrollView {
                if HomeFixtures.requested == "glass" {
                    // `-homeFixture glass`: long, colorful content, so at rest
                    // something is always sliding under the bar.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<14, id: \.self) { i in
                            HStack(spacing: 12) {
                                [Color.red, .blue, .green, .orange, .purple, .black][i % 6]
                                    .frame(width: 60, height: 44).clipShape(.rect(cornerRadius: 8))
                                Text(["Gym · until 8:00", "Call mom · until 9:00", "1h free, then wind down", "Read · until 10:00"][i % 4])
                                    .font(.title3)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                } else if HomeFixtures.requested == "rail" {
                    DayRailView(day: day).padding(.horizontal, 22)
                } else {
                    HomeScreenContent(day: day, syncText: day.isOpen
                                      ? .init(text: "Apple Calendar and Google synced 2 min ago", fresh: true) : nil)
                }
            }
            .background(c.bg.ignoresSafeArea())
        }
    }
}
#endif
