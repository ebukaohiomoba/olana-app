//
//  OnboardingReveal.swift
//  Olana
//
//  The last onboarding step, after the calendar connects: the user's own week
//  becomes their next step (olana_design/reveal_compare.html, "Lens").
//
//  The gold circle from the calendar step lands over the list and stretches
//  into a reading strip as wide as it. The strip moves down the user's plain
//  events one at a time, at the model's pace: it rests on an event until that
//  event is judged. Inside the strip each event shows what the calendar
//  doesn't: "40 min prep · start 3:16", "matters · no prep needed", or
//  "doesn't need you". Events it has read keep their tier color, quietly.
//  Then it goes back to the one that matters most and grows into the exact
//  shape of the card; the card is what's inside it, and the list moves down.
//
//  Storyboard (s, once each thing is ready):
//    land      0      the circle is where the calendar step's flight lands
//    stretch   +0.55  circle → capsule over the first event
//    read      each   0.22 to move, then rests until judged, 0.25 at least;
//                     a light tap for each event that matters
//    return    +0.5   back to the card's event
//    grow      +0.75  capsule → card; the list slides down under it
//    button    +0.6   "Go to my day" (or "Continue")
//  No card: the strip fades and the title says so. Reduce Motion: no strip;
//  events take their color in place and the card fades in.
//
//  Ranking is HomeDayBuilder's, on the same inputs home uses, so the card here
//  is the card the user sees next on home.
//

import SwiftUI

// MARK: - What the reveal shows (pure)

struct RevealRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let start: Date
    let urgency: EventUrgency
    /// The model has judged it (or the user set it).
    let judged: Bool
    /// It gets help: the same rule as the home card.
    let matters: Bool
    /// How long to prep, when it matters and needs any.
    var prepMinutes: Int? = nil
}

struct RevealSnapshot: Equatable {
    var rows: [RevealRow] = []
    /// Set once reading is done: the card the reveal ends on.
    var card: NextCard?
    var done = false
}

enum OnboardingReveal {
    static let maxRows = 6
    static let horizon: TimeInterval = 7 * 24 * 3600

    /// The next few timed events this week, always including the card's event.
    static func snapshot(inputs: [HomeDayBuilder.Input], judged: Set<UUID>, now: Date, done: Bool) -> RevealSnapshot {
        let upcoming = inputs
            .filter { !$0.isAllDay && !$0.isTask && !$0.completed && $0.end > now
                      && $0.start.timeIntervalSince(now) < horizon }
            .sorted { $0.start < $1.start }
        let card = done ? HomeDayBuilder.ranked(upcoming, now: now).first
            .map { HomeDayBuilder.card($0.0, standing: $0.1, now: now) } : nil
        var shown = Array(upcoming.prefix(maxRows))
        if let card, !shown.contains(where: { $0.id == card.eventID }),
           let e = upcoming.first(where: { $0.id == card.eventID }) {
            shown = (Array(shown.prefix(maxRows - 1)) + [e]).sorted { $0.start < $1.start }
        }
        let rows = shown.map { e -> RevealRow in
            let prep = e.assisted ? e.prepHours.map { Int(($0 * 60).rounded()) }.flatMap { $0 > 0 ? $0 : nil } : nil
            return RevealRow(id: e.id, title: e.title, start: e.start, urgency: e.urgency,
                             judged: judged.contains(e.id), matters: e.assisted, prepMinutes: prep)
        }
        return RevealSnapshot(rows: rows, card: card, done: done)
    }

    /// What the strip shows under an event, as plain text plus the gold part:
    /// ("40 min prep · start ", "3:16"), ("2 h prep · prep by ", "tomorrow
    /// morning"), ("matters · no prep needed", ""), ("doesn't need you", "").
    /// Far-off starts read like home's card: by a part of a day, not a minute.
    static func line(_ r: RevealRow, now: Date, calendar: Calendar = .current) -> (text: String, gold: String) {
        guard r.matters else { return ("doesn't need you", "") }
        guard let m = r.prepMinutes else { return ("matters · no prep needed", "") }
        let dur = m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
        let startBy = r.start.addingTimeInterval(-Double(m) * 60)
        if startBy <= now { return ("\(dur) prep · start ", "now") }
        if startBy.timeIntervalSince(now) <= 12 * 3600 { return ("\(dur) prep · start ", HomeFormat.clock(startBy)) }
        let (lead, gold) = HomeFormat.prepLater(startBy, now: now, calendar: calendar)
        return ("\(dur) prep · " + lead.lowercased(), gold)
    }
}

// MARK: - View

struct OnboardingRevealView: View {
    /// Polled until `done`: the rows so far and, at the end, the card.
    let source: () async -> RevealSnapshot
    /// The last onboarding step: "Go to my day". Otherwise "Continue".
    var isLast = true
    /// Fixtures: continues by itself once the button shows.
    var autoplay = false
    /// With the card the reveal ended on, if any.
    var onDone: (NextCard?) -> Void

    @Environment(\.homePalette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot = RevealSnapshot()
    @State private var shown: Set<UUID> = []
    /// Events the strip has read: they keep their color.
    @State private var seen: Set<UUID> = []
    @State private var revealed = false
    @State private var showButton = false
    @State private var glow = 0.0

    // The strip, in the "reveal" coordinate space.
    @State private var strip: CGRect = .zero
    @State private var stripRadius: CGFloat = 38
    /// 1 while it's the solid gold circle the flight landed as; 0 once hollow.
    @State private var stripFill = 1.0
    @State private var stripShown = true
    /// The card shows inside the strip (from the grow on), then fully (no mask).
    @State private var cardInStrip = false
    @State private var cardOpen = false
    @State private var readOpacity = 1.0

    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var listFrame: CGRect = .zero
    @State private var cardFrame: CGRect = .zero
    @State private var cardHeight: CGFloat = 0

    private static let rowHeight: CGFloat = 52
    private static let stripHeight: CGFloat = 58
    private static let space = "reveal"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(HomeType.serif(size: 32))
                .foregroundStyle(c.text)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: revealed)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .staggerIn(0)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(c.muted)
                .contentTransition(revealed ? .opacity : .numericText())
                .animation(.snappy, value: subtitle)
                .padding(.top, 10)

            stage
                .padding(.top, 22)

            Spacer(minLength: 16)

            Button { onDone(snapshot.card) } label: {
                Text(isLast ? "Go to my day" : "Continue")
                    .font(.headline)
                    .foregroundStyle(c.onGold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.gold))
            }
            .buttonStyle(OnbPressStyle())
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton || reduceMotion ? 0 : 10)
            .disabled(!showButton)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
        .task { await load() }
        .task { await read() }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: seenMatters) { old, new in new > old }
        .sensoryFeedback(.success, trigger: revealed) { _, new in new && snapshot.card != nil }
    }

    // MARK: Copy

    private var title: String {
        guard revealed else { return "Reading your calendar" }
        if snapshot.card != nil { return "Here's what matters." }
        return snapshot.rows.isEmpty ? "Your week is clear." : "You're all set."
    }

    private var subtitle: String {
        guard revealed else {
            return snapshot.rows.isEmpty ? "Finding this week's events…"
                : "Finding what matters · \(seen.count) of \(snapshot.rows.count)"
        }
        if snapshot.card != nil { return "Olana will tell you when to start, every day." }
        if snapshot.rows.isEmpty { return "When something important lands on your calendar, it shows up here." }
        return "Nothing this week needs you to start early yet."
    }

    private var seenMatters: Int { snapshot.rows.filter { seen.contains($0.id) && $0.matters }.count }

    // MARK: Stage

    /// The card at the top, the list under it (pushed down once the card is
    /// revealed), the read-out copy of the list masked to the strip, and the strip.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            list(reading: false)
            list(reading: true)
                .mask(alignment: .topLeading) { stripShape(inset: 3) }
                .opacity(readOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if let card = snapshot.card {
                NextCardView(card: card)
                    .allowsHitTesting(false)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(c.gold)
                            .blur(radius: 26)
                            .opacity(glow)
                            .scaleEffect(0.92 + glow * 0.2)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { cardFrame = $0 }
                    .mask(alignment: .topLeading) {
                        if cardOpen { Rectangle().padding(-40) } else if cardInStrip { stripShape(inset: 3) }
                    }
                    .onbPart("card")
            }
        }
        // An overlay, so the strip (wider than the list) never widens the layout.
        .overlay(alignment: .topLeading) { stripView }
        .coordinateSpace(.named(Self.space))
    }

    private func stripShape(inset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: max(0, stripRadius - inset), style: .continuous)
            .frame(width: max(0, strip.width - inset * 2), height: max(0, strip.height - inset * 2))
            .offset(x: strip.minX + inset, y: strip.minY + inset)
    }

    private var stripView: some View {
        RoundedRectangle(cornerRadius: stripRadius, style: .continuous)
            .fill(LinearGradient(colors: [c.gold, c.goldText], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(stripFill))
            .overlay {
                RoundedRectangle(cornerRadius: stripRadius, style: .continuous)
                    .stroke(c.gold, lineWidth: 3)
            }
            .shadow(color: c.gold.opacity(stripFill > 0.5 ? 0.45 : 0.2), radius: 12, y: 6)
            .frame(width: strip.width, height: strip.height)
            // Where the calendar step's circle lands.
            .onbPart("strip")
            .offset(x: strip.minX, y: strip.minY)
            .opacity(stripShown && strip != .zero && !reduceMotion ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Rows

    private func list(reading: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(snapshot.rows) { row in
                rowView(row, reading: reading)
                    .opacity(shown.contains(row.id) ? rowOpacity(row, reading: reading) : 0)
                    .offset(y: shown.contains(row.id) || reduceMotion ? 0 : 14)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { f in
                        if !reading { rowFrames[row.id] = f }
                    }
                if row.id != snapshot.rows.last?.id { Divider().opacity(shown.contains(row.id) ? 1 : 0) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        // Full width even before any events arrive, so the landing circle is centered.
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(reading ? c.card : c.card2)
                        .opacity(snapshot.rows.isEmpty ? 0 : 1))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { f in
            guard !reading else { return }
            listFrame = f
            // Before anything else, the strip is the circle the flight lands on.
            if strip == .zero { strip = Self.landing(in: f) }
        }
        .padding(.top, revealed && snapshot.card != nil ? cardFrame.height + 16 : 0)
    }

    private static func landing(in list: CGRect) -> CGRect {
        CGRect(x: list.midX - 38, y: list.minY + 4 + rowHeight / 2 - 38, width: 76, height: 76)
    }

    private func rowOpacity(_ row: RevealRow, reading: Bool) -> Double {
        if reading { return 1 }
        if revealed { return 0.45 }
        return seen.contains(row.id) && !row.matters ? 0.45 : 1
    }

    private func rowView(_ row: RevealRow, reading: Bool) -> some View {
        let lit = row.matters && (reading || seen.contains(row.id) || (reduceMotion && row.judged))
        return HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(HomeFormat.dayName(row.start, now: Date()).capitalizedFirst)
                    .font(.caption2)
                    .foregroundStyle(c.faint)
                Text(HomeFormat.clock(row.start))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(c.muted)
            }
            .frame(width: 64, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(lit ? c.tier(row.urgency) : c.line)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(reading ? .semibold : .regular))
                    .foregroundStyle(c.text)
                    .lineLimit(1)
                if reading {
                    let l = OnboardingReveal.line(row, now: Date())
                    (Text(l.text).foregroundStyle(row.matters ? c.muted : c.faint)
                     + Text(l.gold).foregroundStyle(c.goldText).fontWeight(.semibold))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sequence

    /// Keeps the snapshot fresh until the source is done.
    private func load() async {
        while !Task.isCancelled {
            let next = await source()
            let newRows = next.rows.map(\.id).filter { !shown.contains($0) }
            withAnimation(.easeInOut(duration: 0.35)) { snapshot = next }
            for (i, id) in newRows.enumerated() {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 70_000_000)
                    withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.85)) {
                        _ = shown.insert(id)
                    }
                }
            }
            if next.done { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// The strip's walk: down the events at the model's pace, back to the
    /// one that matters, and open into the card.
    private func read() async {
        // Wait for the first events (or for an empty week).
        while snapshot.rows.isEmpty && !snapshot.done {
            guard await pause(0.1) else { return }
        }
        guard await pause(0.35) else { return }

        var i = 0
        while i < snapshot.rows.count {
            let row = snapshot.rows[i]
            if let target = stripRect(for: row.id) {
                if !reduceMotion {
                    withAnimation(i == 0 ? .spring(response: 0.55, dampingFraction: 0.82) : .easeInOut(duration: 0.22)) {
                        strip = target
                        stripRadius = Self.stripHeight / 2
                        stripFill = 0
                    }
                }
                guard await pause(i == 0 ? 0.45 : 0.22) else { return }
            }
            // Rest until the model has judged it.
            while !(snapshot.rows.first { $0.id == row.id }?.judged ?? true) && !snapshot.done {
                guard await pause(0.1) else { return }
            }
            withAnimation(.easeInOut(duration: 0.25)) { _ = seen.insert(row.id) }
            guard await pause(0.25) else { return }
            i += 1
        }
        while !snapshot.done { guard await pause(0.1) else { return } }
        // Rows can change when the card's event joins at the end.
        withAnimation(.easeInOut(duration: 0.25)) { seen.formUnion(snapshot.rows.map(\.id)) }

        guard let card = snapshot.card else {
            withAnimation(.easeOut(duration: 0.3)) { stripShown = false }
            withAnimation(.easeInOut(duration: 0.4)) { revealed = true }
            guard await pause(0.6) else { return }
            return finish()
        }

        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) { cardOpen = true; revealed = true; readOpacity = 0 }
            guard await pause(0.5) else { return }
            return finish()
        }

        // Back to the one that matters.
        if let target = stripRect(for: card.eventID) {
            withAnimation(.easeInOut(duration: 0.45)) { strip = target }
            guard await pause(0.55) else { return }
        }
        // Grow into the card: the list moves down under it.
        if cardFrame == .zero { guard await pause(0.05) else { return } }
        let landing = cardFrame.insetBy(dx: -3, dy: -3)
        cardInStrip = true
        withAnimation(.easeOut(duration: 0.2)) { readOpacity = 0 }
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.75)) {
            strip = landing
            stripRadius = 27
            revealed = true
        }
        guard await pause(0.75) else { return }
        cardOpen = true
        withAnimation(.easeOut(duration: 0.25)) { stripShown = false }
        withAnimation(.easeOut(duration: 0.45)) { glow = 0.45 }
        guard await pause(0.45) else { return }
        withAnimation(.easeInOut(duration: 1.2)) { glow = 0.12 }
        finish()
    }

    private func finish() {
        Task {
            _ = await pause(0.15)
            withAnimation(.easeOut(duration: 0.35)) { showButton = true }
            if autoplay {
                _ = await pause(2.0)
                onDone(snapshot.card)
            }
        }
    }

    /// A capsule a little wider than the list, centered on the event.
    private func stripRect(for id: UUID) -> CGRect? {
        guard let f = rowFrames[id], listFrame != .zero else { return nil }
        return CGRect(x: listFrame.minX - 6, y: f.midY - Self.stripHeight / 2,
                      width: listFrame.width + 12, height: Self.stripHeight)
    }

    private func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return false }
        return true
    }
}

// MARK: - Sources

/// The real one: syncs, judges the nearest events, and reports as it goes.
/// Done when judging finishes, or after 15 s so nobody waits on a slow model.
@MainActor
final class RevealLoader {
    private let store: EventStore
    private let calendarManager: CalendarIntegrationManager
    private var started: Date?
    private var finished = false

    init(store: EventStore, calendarManager: CalendarIntegrationManager) {
        self.store = store
        self.calendarManager = calendarManager
    }

    func snapshot() async -> RevealSnapshot {
        if started == nil {
            started = Date()
            Task {
                await calendarManager.performQuickSync()
                await store.backfillSemantics(limit: 12)
                finished = true
            }
        }
        let now = Date()
        let events = store.events.filter { $0.end > now && !$0.completed }
        let inputs = events.map { HomeView.input($0, now: now, store: store) }
        let judged = Set(events.filter { $0.cachedSemantics != nil || $0.isUnrankable || $0.urgencyOverrideRaw != nil }
                            .map(\.id))
        let timedOut = Date().timeIntervalSince(started ?? now) > 15
        return OnboardingReveal.snapshot(inputs: inputs, judged: judged, now: now, done: finished || timedOut)
    }
}

#if DEBUG
/// `-homeFixture reveal`: a week that loads, gets judged one by one, then reveals.
enum RevealFixture {
    /// The card the fixed week ends on.
    static func card() -> NextCard? {
        OnboardingReveal.snapshot(inputs: inputs(from: Date()), judged: [], now: Date(), done: true).card
    }

    /// The clock starts at the first call, so the flow fixture can reach the
    /// reveal later and still see it load.
    static func source() -> () async -> RevealSnapshot {
        final class Clock { var start: Date?; var inputs: [HomeDayBuilder.Input] = [] }
        let clock = Clock()
        return {
            if clock.start == nil { clock.start = Date(); clock.inputs = inputs(from: Date()) }
            let inputs = clock.inputs
            let t = Date().timeIntervalSince(clock.start!)
            // Rows arrive at 0.4 s; each is judged 0.35 s after the one before.
            guard t > 0.4 else { return RevealSnapshot() }
            let judged = Set(inputs.enumerated().filter { t > 0.9 + Double($0.offset) * 0.35 }.map(\.element.id))
            return OnboardingReveal.snapshot(inputs: inputs, judged: judged, now: Date(), done: t > 3.2)
        }
    }

    private static func inputs(from start: Date) -> [HomeDayBuilder.Input] {
        let cal = Calendar.current
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        func tomorrow(_ h: Int, _ m: Int = 0, days: Int = 1) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: days, to: start)!)!
        }
        func input(_ title: String, _ s: Date, _ mins: Double, _ u: EventUrgency, prep: Double? = nil,
                   assisted: Bool) -> HomeDayBuilder.Input {
            .init(id: UUID(), title: title, start: s, end: s.addingTimeInterval(mins * 60), isAllDay: false, isTask: false,
                  completed: false, completedAt: nil, isRecurring: false, location: nil, urgency: u, scored: nil,
                  prepHours: prep, assisted: assisted)
        }
        return [
            input("Standup", at(40), 15, .low, assisted: false),
            input("Client review", at(170), 60, .high, prep: 40.0 / 60, assisted: true),
            input("Pick up prescription", at(240), 15, .low, assisted: false),
            input("Dentist", tomorrow(15), 60, .medium, assisted: true),
            input("Gym", tomorrow(19), 60, .low, assisted: false),
            input("Quarterly review", tomorrow(9, days: 3), 60, .high, prep: 2, assisted: true),
        ]
    }
}
#endif
