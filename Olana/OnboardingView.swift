//
//  OnboardingView.swift
//  Olana
//
//  Onboarding (PRD v3 §1.11, unchanged in v6). The goal: the user sees their
//  own next important event within 60 seconds, and nothing is asked before
//  it's needed. No account.
//
//    1. Promise: a five-second story on four sample events: a gray calendar,
//       Olana reading it, the card (OnboardingPromise).
//    2. Apple Intelligence check: silent when available, else one screen
//       (not eligible, turned off, downloading). Marked seen, so the home
//       screen doesn't show it again.
//    3. Connect calendar: Apple Calendar first, Google second; Outlook works
//       through iOS Calendar (OnboardingCalendar).
//    4. First value: the reveal (OnboardingReveal), where the user's own week
//       turns into their first "Next that matters" card. Skipped with the
//       calendar ("Not now"): straight to home.
//    5. Notifications, right after first value, with the user's own next
//       event as the example (OnboardingNotifications). Skipped when already
//       decided; home's just-in-time ask shares the "asked" flag.
//
//  One backdrop runs under every step: two soft glows that drift slowly and
//  move behind whatever the step is about. Between steps, one thing carries
//  the user across (OnboardingMotion): "Get started" floods the screen gold
//  and shrinks into Olana's circle; the circle flies to the reveal and
//  becomes its reading strip; the card flies into the heads-up banner. Otherwise steps rise
//  in and blur out.
//
//  Later, just in time (not here): AlarmKit at the first alarm-tier event
//  (Plus or preview), home and work at the first trip, and the calendar-alerts
//  tip after the first week.
//

import SwiftUI

/// Screenshot and recording fixtures: a fixed week instead of the real
/// loader, nothing asked of the system, and optionally every step playing
/// itself (`-homeFixture onboarding-flow`).
struct OnboardingFixture {
    var reveal: () async -> RevealSnapshot
    var autoplay = false
    /// Starting at the notifications ask: the card it uses as its example.
    var card: NextCard?
}

struct OnboardingView: View {
    var onDone: () -> Void

    @ObservedObject private var calendarManager = AppServices.shared.calendarManager
    @ObservedObject private var plus = PlusStore.shared
    /// Shared with ContentView, which shows the gate once per state.
    @AppStorage("olanaGateSeen_v1") private var gateSeen = ""
    /// Shared with HomeView: once asked here, home doesn't ask again.
    @AppStorage("olanaNotifAsked_v1") private var notifAsked = false
    @Environment(\.homePalette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Hashable { case promise, gate, calendar, reveal, notify }
    @State private var step: Step
    /// Whether step 5 comes after the reveal: notifications not yet decided.
    @State private var asksNotifications = true
    /// The reveal's card, the notifications ask's example.
    @State private var card: NextCard?
    /// One loader for the step, so its sync and judging run once.
    @State private var loader: RevealLoader?

    // Flights between steps (OnboardingMotion).
    @State private var anchors: [String: CGRect] = [:]
    @State private var hidden: Set<String> = []
    @State private var flight: OnbFlight?
    /// While a flight lands on the new step, it fades in without moving, so
    /// the place it lands holds still.
    @State private var landing = false
    @State private var size: CGSize = .zero

    private let fixture: OnboardingFixture?
    /// Developer replay: every step, the notifications ask included even
    /// when it's been answered.
    private let replay: Bool

    init(start: Step = .promise, replay: Bool = false, fixture: OnboardingFixture? = nil, onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.fixture = fixture
        self.replay = replay
        _step = State(initialValue: start)
        _card = State(initialValue: fixture?.card)
    }

    private var autoplay: Bool { fixture?.autoplay ?? false }

    private var revealSource: () async -> RevealSnapshot {
        if let fixture { return fixture.reveal }
        return {
            if loader == nil {
                loader = RevealLoader(store: AppServices.shared.store, calendarManager: calendarManager)
            }
            return await loader!.snapshot()
        }
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop(step: step)
            VStack(spacing: 0) {
                header
                ZStack { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.onbHidden, hidden)
            .disabled(flight != nil)
        }
        .overlay {
            if let flight {
                OnbFlightView(flight: flight, card: card, banner: HeadsUpBanner.lines(for: card))
                    .transition(.identity)
            }
        }
        .coordinateSpace(.named(OnbSpace.name))
        .onPreferenceChange(OnbAnchors.self) { anchors = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.9), value: step)
        .sensoryFeedback(.selection, trigger: step)
        .task {
            guard fixture == nil, !replay else { return }
            await NotificationEngine.shared.checkAuthorizationStatus()
            asksNotifications = NotificationEngine.shared.authorizationStatus == .notDetermined && !notifAsked
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Olana")
                .font(.footnote.weight(.semibold))
                .tracking(2.5)
                .textCase(.uppercase)
                .foregroundStyle(c.goldText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            StepDots(count: dotSteps.count, current: dotIndex)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    private var dotSteps: [Step] {
        asksNotifications ? [.promise, .calendar, .reveal, .notify] : [.promise, .calendar, .reveal]
    }

    /// The gate counts as part of connecting.
    private var dotIndex: Int { dotSteps.firstIndex(of: step == .gate ? .calendar : step) ?? 0 }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .promise:
            OnboardingPromise(autoplay: autoplay) { advance(from: .promise) }
                .transition(stepTransition)
        case .gate:
            IntelligenceGateView(gate: plus.gate) {
                gateSeen = "\(plus.gate)"
                advance(from: .gate)
            }
            .transition(stepTransition)
        case .calendar:
            OnboardingCalendar(calendarManager: calendarManager, simulate: fixture != nil, autoplay: autoplay) { connected in
                if connected { advance(from: .calendar) } else { onDone() }
            }
            .transition(stepTransition)
        case .reveal:
            OnboardingRevealView(source: revealSource, isLast: !asksNotifications, autoplay: autoplay) { card in
                self.card = card
                advance(from: .reveal)
            }
            .transition(stepTransition)
        case .notify:
            OnboardingNotifications(card: card, arrived: hidden.contains("banner"), simulate: fixture != nil,
                                    autoplay: autoplay, onDone: onDone)
                .transition(stepTransition)
        }
    }

    /// The old step blurs away quickly; the new one rises in just behind it,
    /// so the two never sit on top of each other at full strength.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        if landing {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.3).delay(0.12)),
                               removal: AnyTransition(.blurReplace).animation(.easeIn(duration: 0.22)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.35).delay(0.12))
                .combined(with: .offset(y: 28))
                .combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: AnyTransition(.blurReplace).animation(.easeIn(duration: 0.22))
                .combined(with: .offset(y: -18)))
    }

    private func advance(from s: Step) {
        switch s {
        case .promise:
            if plus.gate == .available || fixture != nil { Task { await floodToCalendar() } } else { step = .gate }
        case .gate: step = .calendar
        case .calendar: Task { await flyToReveal() }
        case .reveal: if asksNotifications { Task { await flyToHeadsUp() } } else { onDone() }
        case .notify: onDone()
        }
    }

    // MARK: Flights

    /// "Get started" swells into a gold wash over everything; the calendar
    /// step is put in place under it; the wash shrinks into Olana's circle.
    private func floodToCalendar() async {
        guard !reduceMotion, let from = anchors["cta"], size != .zero else { step = .calendar; return }
        let side = max(size.width, size.height) * 2.4
        let cover = CGRect(x: from.midX - side / 2, y: from.midY - side / 2, width: side, height: side)
        guard await takeOff(OnbFlight(kind: .gold, rect: from, radius: from.height / 2), hiding: []) else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.easeIn(duration: 0.36)) { flight?.rect = cover; flight?.radius = side / 2 }
        guard await pause(0.34) else { return }

        landing = true
        hidden = ["hub"]
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { step = .calendar }
        guard await pause(0.08), let hub = anchors["hub"] else { return land() }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { flight?.rect = hub; flight?.radius = hub.width / 2 }
        guard await pause(0.62) else { return }
        land()
    }

    /// The circle, check and all, flies to where the reveal's reading strip
    /// starts (a gold circle over the first event) while the calendar step
    /// blurs away under it.
    private func flyToReveal() async {
        guard !reduceMotion, let hub = anchors["hub"] else { step = .reveal; return }
        guard await takeOff(OnbFlight(kind: .check, rect: hub, radius: hub.width / 2), hiding: ["hub", "strip"]) else { return }
        landing = true
        step = .reveal
        guard await pause(0.1), let strip = anchors["strip"] else { return land() }
        withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) {
            flight?.rect = strip
            flight?.radius = strip.width / 2
            flight?.morph = 1
        }
        guard await pause(0.55) else { return }
        land()
    }

    /// The card lifts off the reveal and shrinks into the heads-up banner on
    /// the lock screen.
    private func flyToHeadsUp() async {
        guard !reduceMotion, let from = anchors["card"] else { step = .notify; return }
        guard await takeOff(OnbFlight(kind: .card, rect: from, radius: 24), hiding: ["card", "banner"]) else { return }
        landing = true
        step = .notify
        guard await pause(0.1), let to = anchors["banner"] else { return land() }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) {
            flight?.rect = to
            flight?.radius = 20
            flight?.morph = 1
        }
        guard await pause(0.7) else { return }
        land()
    }

    /// Puts the flight exactly over what it leaves from and hides that, a
    /// frame before anything else moves: the step about to leave is frozen
    /// as it last drew, so it has to have hidden its part already.
    private func takeOff(_ f: OnbFlight, hiding parts: Set<String>) async -> Bool {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            flight = f
            hidden = parts
        }
        return await pause(0.03)
    }

    /// Hands back to what the flight landed on.
    private func land() {
        hidden = []
        landing = false
        withAnimation(.easeOut(duration: 0.18)) { flight?.opacity = 0 }
        Task {
            _ = await pause(0.18)
            flight = nil
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return false }
        return true
    }
}

// MARK: - Step dots

/// Where the user is: the current step is a gold capsule, the ones done are
/// faded gold.
private struct StepDots: View {
    let count: Int
    let current: Int
    @Environment(\.homePalette) private var c

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? c.gold : i < current ? c.gold.opacity(0.4) : c.line)
                    .frame(width: i == current ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Backdrop

/// Two soft glows on the page color: gold, and a tint that changes with the
/// step. They drift slowly and glide to sit behind each step's focus.
/// Reduce Motion: they hold still, and only move between steps.
private struct OnboardingBackdrop: View {
    let step: OnboardingView.Step
    @Environment(\.homePalette) private var c
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    glow(c.gold, size: g.size.width * 1.25, at: goldAt, in: g.size)
                        .opacity(scheme == .dark ? 0.16 : 0.2)
                        .offset(x: sin(t / 7) * 28, y: cos(t / 9) * 22)
                    glow(tint, size: g.size.width * 1.1, at: tintAt, in: g.size)
                        .opacity(scheme == .dark ? 0.12 : 0.1)
                        .offset(x: cos(t / 8 + 2) * 32, y: sin(t / 6 + 1) * 26)
                }
            }
        }
        .background(c.bg)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The step's position goes through its own slow animation; the drift is
    /// a separate offset, so the per-frame drift never cuts the glide short.
    private func glow(_ color: Color, size: CGFloat, at p: UnitPoint, in s: CGSize) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(x: p.x * s.width, y: p.y * s.height)
            .animation(.easeInOut(duration: 1.2), value: step)
    }

    private var goldAt: UnitPoint {
        switch step {
        case .promise: return UnitPoint(x: 0.9, y: 0.12)
        case .gate, .calendar: return UnitPoint(x: 0.5, y: 0.28)
        case .reveal: return UnitPoint(x: 0.25, y: 0.3)
        case .notify: return UnitPoint(x: 0.6, y: 0.22)
        }
    }

    private var tintAt: UnitPoint {
        switch step {
        case .promise: return UnitPoint(x: 0.05, y: 0.78)
        case .gate, .calendar: return UnitPoint(x: 0.95, y: 0.7)
        case .reveal: return UnitPoint(x: 0.9, y: 0.85)
        case .notify: return UnitPoint(x: 0.1, y: 0.75)
        }
    }

    private var tint: Color {
        switch step {
        case .promise: return c.crit
        case .gate, .calendar: return c.later
        case .reveal: return c.soon
        case .notify: return c.crit
        }
    }
}
