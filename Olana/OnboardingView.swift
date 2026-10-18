//
//  OnboardingView.swift
//  Olana
//
//  Onboarding (PRD v3 §1.11, unchanged in v6). The goal: the user sees their
//  own next important event within 60 seconds, and nothing is asked before
//  it's needed. No account.
//
//    1. Promise: one line and the before/after.
//    2. Apple Intelligence check: silent when available, else one screen
//       (not eligible, turned off, downloading). Marked seen, so the home
//       screen doesn't show it again.
//    3. Connect calendar: Apple Calendar first, Google second; Outlook works
//       through iOS Calendar.
//    4. First value: home, straight away.
//
//  Later, just in time (not here): notifications on home after first value,
//  AlarmKit at the first alarm-tier event (Plus or preview), home and work at
//  the first trip, and the calendar-alerts tip after the first week.
//

import SwiftUI

struct OnboardingView: View {
    var onDone: () -> Void

    @ObservedObject private var calendarManager = AppServices.shared.calendarManager
    @ObservedObject private var plus = PlusStore.shared
    /// Shared with ContentView, which shows the gate once per state.
    @AppStorage("olanaGateSeen_v1") private var gateSeen = ""
    @Environment(\.homePalette) private var c

    enum Step { case promise, gate, calendar }
    @State private var step: Step

    init(start: Step = .promise, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _step = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()
            switch step {
            case .promise:
                OnboardingPromise { next(from: .promise) }
                    .transition(.opacity)
            case .gate:
                IntelligenceGateView(gate: plus.gate) {
                    gateSeen = "\(plus.gate)"
                    next(from: .gate)
                }
                .transition(.opacity)
            case .calendar:
                OnboardingCalendar(calendarManager: calendarManager, onDone: onDone)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private func next(from s: Step) {
        switch s {
        case .promise: step = plus.gate == .available ? .calendar : .gate
        case .gate, .calendar: step = .calendar
        }
    }
}

// MARK: - 1 · Promise

private struct OnboardingPromise: View {
    var onContinue: () -> Void
    @Environment(\.homePalette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Olana")
                        .font(.footnote.weight(.semibold))
                        .tracking(2.5)
                        .textCase(.uppercase)
                        .foregroundStyle(c.goldText)
                        .padding(.top, 24)

                    Text("Know what matters next, and when to start on it.")
                        .font(HomeType.serif(size: 32))
                        .foregroundStyle(c.text)
                        .fixedSize(horizontal: false, vertical: true)

                    before
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(c.muted)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    after
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button(action: onContinue) {
                Text("Get started")
                    .font(.headline)
                    .foregroundStyle(c.onGold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.gold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
    }

    /// Before: a calendar where everything looks the same.
    private var before: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Your calendar")
            VStack(spacing: 0) {
                ForEach(Self.sample, id: \.title) { e in
                    HStack(spacing: 12) {
                        Text(e.time).font(.subheadline.monospacedDigit()).foregroundStyle(c.muted)
                            .frame(width: 44, alignment: .leading)
                        Text(e.title).font(.subheadline).foregroundStyle(c.text)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    if e.title != Self.sample.last?.title { Divider() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 16).fill(c.card2))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your calendar: four events that all look the same")
    }

    /// After: the real next card, on the same four events.
    private var after: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("With Olana")
            if let card = Self.sampleDay.card {
                NextCardView(card: card)
                    .allowsHitTesting(false)
            }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(c.muted).textCase(.uppercase).tracking(1.2)
    }

    private static let sample: [(time: String, title: String)] = [
        ("9:30", "Standup"), ("12:00", "Lunch with Sam"), ("3:00", "Client review"), ("5:30", "Pick up prescription"),
    ]

    /// The four sample events at 1:52, client review with 40 minutes of prep.
    private static let sampleDay: HomeDay = {
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        func input(_ title: String, _ start: Date, _ mins: Int, _ u: EventUrgency, prep: Double? = nil, place: String? = nil) -> HomeDayBuilder.Input {
            .init(id: UUID(), title: title, start: start, end: start.addingTimeInterval(TimeInterval(mins * 60)), isAllDay: false,
                  isTask: false, completed: false, completedAt: nil, isRecurring: false, location: place, urgency: u,
                  scored: nil, prepHours: prep, assisted: u != .low)
        }
        return HomeDayBuilder.build(inputs: [
            input("Standup", at(9, 30), 15, .low),
            input("Lunch with Sam", at(12, 0), 60, .low),
            input("Client review", at(15, 0), 60, .high, prep: 40.0 / 60, place: "Room 2"),
            input("Pick up prescription", at(17, 30), 15, .medium),
        ], now: at(13, 52), bed: at(22, 0))
    }()
}

// MARK: - 3 · Connect calendar

private struct OnboardingCalendar: View {
    @ObservedObject var calendarManager: CalendarIntegrationManager
    var onDone: () -> Void
    @Environment(\.homePalette) private var c
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "calendar")
                .font(.system(size: 40)).foregroundStyle(c.goldText)
                .accessibilityHidden(true)
            Text("Bring in your calendar")
                .font(HomeType.serif(size: 30)).foregroundStyle(c.text)
            Text("Olana reads your events to find what matters and when to start. It never changes them.")
                .font(.body).foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Outlook works when your account is added to iOS Calendar.")
                .font(.footnote).foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()

            Button { connect(google: false) } label: {
                Label("Use Apple Calendar", systemImage: "apple.logo")
                    .font(.headline).foregroundStyle(c.onGold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.gold))
            }
            .buttonStyle(.plain)

            Button { connect(google: true) } label: {
                Text("Connect Google Calendar")
                    .font(.headline).foregroundStyle(c.text)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.card2))
            }
            .buttonStyle(.plain)

            Button("Not now", action: onDone)
                .font(.subheadline).foregroundStyle(c.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
    }

    private func connect(google: Bool) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            if google {
                do {
                    try await calendarManager.addGoogleAccount()
                    onDone()
                } catch {
                    self.error = "Google didn't connect. Try again, or use Apple Calendar."
                }
            } else if await calendarManager.requestAccess() {
                onDone()
            } else {
                error = "Calendar access is off. Turn it on in Settings › Olana › Calendars."
            }
        }
    }
}
