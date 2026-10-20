//
//  OnboardingSteps.swift
//  Olana
//
//  Onboarding steps 3 and 5: connect a calendar, and the notifications ask.
//
//  Calendar: Apple, Google and Outlook tiles feed a stream of events into
//  Olana; the events start gray and take a tier color as they arrive. While
//  connecting, the stream speeds up; once connected, a check draws in the
//  middle and the flow moves on.
//
//  Notifications: a lock screen with a heads-up for the user's own next
//  event (the reveal's card) dropping in, every few seconds, over the ask.
//

import SwiftUI

// MARK: - 3 · Connect calendar

struct OnboardingCalendar: View {
    @ObservedObject var calendarManager: CalendarIntegrationManager
    /// Fixtures: no system prompt; connecting succeeds after a moment.
    var simulate = false
    var autoplay = false
    /// true when a calendar connected; false for "Not now".
    var onDone: (Bool) -> Void

    @Environment(\.homePalette) private var c
    @State private var connecting: Source?
    @State private var connected = false
    @State private var error: String?

    enum Source { case apple, google }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalendarFlow(speed: connected ? 2.2 : connecting != nil ? 1.4 : 0.35, connected: connected)
                .frame(height: 250)
                .padding(.top, 8)

            Text("Bring in your calendar")
                .font(HomeType.serif(size: 30))
                .foregroundStyle(c.text)
                .padding(.top, 8)
                .staggerIn(1)
            Text("Olana reads your events to find what matters and when to start. It never changes them.")
                .font(.body)
                .foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .staggerIn(2)
            Text("Outlook works when your account is added to iOS Calendar.")
                .font(.footnote)
                .foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .staggerIn(3)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(c.crit)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button { connect(.apple) } label: {
                    buttonLabel(.apple, "Use Apple Calendar", systemImage: "apple.logo")
                        .foregroundStyle(c.onGold)
                        .background(Capsule().fill(c.gold))
                }
                .buttonStyle(OnbPressStyle())

                Button { connect(.google) } label: {
                    buttonLabel(.google, "Connect Google Calendar", systemImage: nil)
                        .foregroundStyle(c.text)
                        .background(Capsule().fill(c.card2))
                }
                .buttonStyle(OnbPressStyle())

                Button("Not now") { onDone(false) }
                    .font(.subheadline)
                    .foregroundStyle(c.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(connecting != nil || connected)
            .staggerIn(4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.25), value: error)
        .sensoryFeedback(.success, trigger: connected) { _, new in new }
        .task {
            guard autoplay else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            connect(.apple)
        }
    }

    /// The label swaps to a spinner, then a check, without the button resizing.
    private func buttonLabel(_ s: Source, _ title: String, systemImage: String?) -> some View {
        ZStack {
            if connecting == s && !connected {
                HStack(spacing: 8) {
                    ProgressView().tint(s == .apple ? c.onGold : c.text)
                    Text("Connecting…")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if connected && connecting == s {
                Label("Connected", systemImage: "checkmark")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if let systemImage {
                Label(title, systemImage: systemImage).transition(.opacity)
            } else {
                Text(title).transition(.opacity)
            }
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 54)
        .animation(.easeInOut(duration: 0.2), value: connecting)
        .animation(.easeInOut(duration: 0.2), value: connected)
    }

    private func connect(_ s: Source) {
        connecting = s
        error = nil
        Task {
            let ok: Bool
            if simulate {
                try? await Task.sleep(nanoseconds: 900_000_000)
                ok = true
            } else if s == .google {
                do {
                    try await calendarManager.addGoogleAccount()
                    ok = true
                } catch {
                    self.error = "Google didn't connect. Try again, or use Apple Calendar."
                    ok = false
                }
            } else {
                ok = await calendarManager.requestAccess()
                if !ok { error = "Calendar access is off. Turn it on in Settings › Olana › Calendars." }
            }
            guard ok else { connecting = nil; return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { connected = true }
            // Let the check land before moving on.
            try? await Task.sleep(nanoseconds: 900_000_000)
            onDone(true)
        }
    }
}

/// Three calendar tiles over Olana, joined by dotted paths with events
/// flowing down them. Each event is gray until it nears Olana, then takes a
/// tier color. Olana breathes; once connected, a check draws inside it.
/// Reduce Motion: the stream holds still.
private struct CalendarFlow: View {
    /// Trips per second along a path, roughly.
    let speed: Double
    let connected: Bool

    @Environment(\.homePalette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Phase accumulated across speed changes, so speeding up doesn't jump the
    /// dots. A plain object: advancing it each frame doesn't redraw anything.
    @State private var clock = FlowClock()

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let sources = [CGPoint(x: w * 0.14, y: h * 0.2), CGPoint(x: w * 0.5, y: h * 0.1), CGPoint(x: w * 0.86, y: h * 0.2)]
            let hub = CGPoint(x: w * 0.5, y: h * 0.74)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { tl in
                let p = advance(to: tl.date)
                ZStack {
                    Canvas { ctx, _ in
                        for (i, s) in sources.enumerated() {
                            let ctrl = CGPoint(x: (s.x + hub.x) / 2, y: s.y + (hub.y - s.y) * 0.75)
                            var path = Path()
                            path.move(to: s)
                            path.addQuadCurve(to: hub, control: ctrl)
                            ctx.stroke(path, with: .color(c.line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 6]))
                            for k in 0..<3 {
                                let f = (p + Double(i) * 0.21 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                                drawDot(&ctx, at: point(s, ctrl, hub, f), progress: f, tier: Self.tiers[(i + k) % 3])
                            }
                        }
                    }
                    ForEach(Self.tiles.indices, id: \.self) { i in
                        tile(Self.tiles[i])
                            .modifier(PopIn(order: i))
                            .position(sources[i])
                            .offset(y: reduceMotion ? 0 : sin(p * 2 * .pi / 3 + Double(i) * 2) * 3)
                    }
                    hubView(breath: reduceMotion ? 0 : sin(p * 2 * .pi))
                        .position(hub)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func advance(to now: Date) -> Double {
        let dt = clock.last.map { min(now.timeIntervalSince($0), 0.1) } ?? 0
        clock.phase += dt * speed * 0.5
        clock.last = now
        return clock.phase
    }

    private func point(_ a: CGPoint, _ ctrl: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * ctrl.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * ctrl.y + t * t * b.y)
    }

    private func drawDot(_ ctx: inout GraphicsContext, at pt: CGPoint, progress f: Double, tier: EventUrgency) {
        // Fade in leaving the tile, out entering Olana; color from 45% to 80% of the way.
        let alpha = min(f / 0.12, 1) * min((1 - f) / 0.1, 1)
        let colored = min(max((f - 0.45) / 0.35, 0), 1)
        let r = 3.5 + colored * 1.5
        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(c.faint.opacity(alpha * (1 - colored))))
        ctx.fill(Path(ellipseIn: rect), with: .color(c.tier(tier).opacity(alpha * colored)))
    }

    private func tile(_ t: (symbol: String?, letter: String?)) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(c.card)
                .shadow(color: c.cardShadow, radius: 6, y: 3)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.line, lineWidth: 1))
            if let symbol = t.symbol {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(c.text)
            } else if let letter = t.letter {
                Text(letter).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(c.text)
            }
        }
        .frame(width: 50, height: 50)
    }

    private func hubView(breath: Double) -> some View {
        ZStack {
            Circle()
                .fill(c.gold.opacity(0.18))
                .frame(width: 112, height: 112)
                .scaleEffect(1 + breath * 0.06 + (connected ? 0.12 : 0))
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [c.gold, c.goldText], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: c.gold.opacity(0.45), radius: 14, y: 4)
                Text("O")
                .font(HomeType.serif(size: 38))
                .foregroundStyle(c.onGold)
                    .opacity(connected ? 0 : 1)
                    .scaleEffect(connected ? 0.6 : 1)
                OnbCheck()
                    .trim(from: 0, to: connected ? 1 : 0)
                    .stroke(c.onGold, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 30, height: 24)
            }
            .frame(width: 76, height: 76)
            // Where "Get started" lands, and what flies on to the reveal.
            .onbPart("hub")
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: connected)
    }

    private static let tiles: [(symbol: String?, letter: String?)] = [("apple.logo", nil), (nil, "G"), ("envelope.fill", nil)]
    private static let tiers: [EventUrgency] = [.high, .low, .medium]
}

private final class FlowClock {
    var phase = 0.0
    var last: Date?
}

/// The source tiles pop up out of nothing, a beat apart.
private struct PopIn: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on || reduceMotion ? 1 : 0.4)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.35 + Double(order) * 0.09)) { on = true }
            }
    }
}

// MARK: - 5 · Notifications

struct OnboardingNotifications: View {
    /// The reveal's card: the heads-up is for the user's own event.
    let card: NextCard?
    /// The card flew in and became the banner: it starts in place.
    var arrived = false
    var simulate = false
    var autoplay = false
    var onDone: () -> Void

    @AppStorage("olanaNotifAsked_v1") private var notifAsked = false
    @Environment(\.homePalette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropped: Bool
    @State private var busy = false

    init(card: NextCard?, arrived: Bool = false, simulate: Bool = false, autoplay: Bool = false, onDone: @escaping () -> Void) {
        self.card = card
        self.arrived = arrived
        self.simulate = simulate
        self.autoplay = autoplay
        self.onDone = onDone
        _dropped = State(initialValue: arrived)
    }

    private var ask: JustInTimeAsk { .notifications(eventTitle: card?.title) }
    private var lines: (title: String, body: String) { HeadsUpBanner.lines(for: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lockScreen
                .padding(.top, 14)

            Text(ask.title)
                .font(HomeType.serif(size: 30))
                .foregroundStyle(c.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .staggerIn(2)
            Text(ask.message)
                .font(.body)
                .foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .staggerIn(3)
            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button { answer(true) } label: {
                    ZStack {
                        if busy { ProgressView().tint(c.onGold) } else { Text("Turn on heads-ups") }
                    }
                    .font(.headline)
                    .foregroundStyle(c.onGold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.gold))
                }
                .buttonStyle(OnbPressStyle())

                Button("Not now") { answer(false) }
                    .font(.subheadline)
                    .foregroundStyle(c.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .staggerIn(4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .disabled(busy)
        .sensoryFeedback(.impact(weight: .light), trigger: dropped) { _, new in new }
        .task { await loop() }
    }

    /// A slab of lock screen: the date and time, and the heads-up landing on
    /// it. It holds still on the way in: the card's flight lands on it.
    private var lockScreen: some View {
        let now = Date()
        return VStack(spacing: 2) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(c.muted)
                .staggerIn(0)
            Text(HomeFormat.clock(now))
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(c.text.opacity(0.85))
                .staggerIn(1)
            Spacer(minLength: 0)
            HeadsUpBanner(title: lines.title, message: lines.body)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .onbPart("banner")
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .opacity(dropped ? 1 : 0)
                .offset(y: dropped || reduceMotion ? 0 : -70)
                .scaleEffect(dropped || reduceMotion ? 1 : 0.92, anchor: .top)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 236)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(c.card2))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(c.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: a heads-up from Olana, \(lines.title), \(lines.body)")
    }

    /// Drops in, rests, lifts away, and comes back, so it reads as a heads-up.
    private func loop() async {
        if reduceMotion { dropped = true; return }
        try? await Task.sleep(nanoseconds: arrived ? 300_000_000 : 450_000_000)
        while !Task.isCancelled {
            if !dropped {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { dropped = true }
            }
            if autoplay {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                answer(false)
                return
            }
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            withAnimation(.easeIn(duration: 0.3)) { dropped = false }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }

    private func answer(_ yes: Bool) {
        guard !simulate else { onDone(); return }
        notifAsked = true
        guard yes else { onDone(); return }
        busy = true
        Task {
            if await NotificationEngine.shared.requestAuthorization() {
                NotificationEngine.shared.requestReplan("notifications allowed")
            }
            busy = false
            onDone()
        }
    }
}

extension HeadsUpBanner {
    /// The event and the card's own line ("Start prepping by 2:20"), so the
    /// example is real.
    static func lines(for card: NextCard?) -> (title: String, body: String) {
        guard let card else { return ("Olana", "Time to start on what matters next.") }
        return (card.title, (card.lead + card.gold + card.trail).trimmingCharacters(in: .whitespaces))
    }
}
