//
//  OnboardingPromise.swift
//  Olana
//
//  Onboarding step 1: the promise, told as a short story on four sample
//  events instead of a before/after picture.
//
//  Storyboard (s from appear):
//    0.15   "Every event looks the same." rises in a letter at a time; four
//           gray rows drop in, 90 ms apart
//    1.9    "Olana finds what matters." A gold scan line sweeps down the list;
//           as it passes each row, the row takes its tier color and tag, or
//           fades back. A tap when Client review lights. "Get started" appears.
//    +0.6   Client review lifts; the others dim
//    +0.45  "And tells you when to start." The real card slides in above
//           the list, on the sample day at 1:52
//  Tapping the story after it ends plays it again. Reduce Motion: the end
//  state, no movement.
//

import SwiftUI

struct OnboardingPromise: View {
    var autoplay = false
    var onContinue: () -> Void

    @Environment(\.homePalette) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// -1 before anything, then one beat per headline.
    @State private var beat = -1
    @State private var rowsIn = 0
    @State private var scanning = false
    @State private var scan: CGFloat = -0.1
    @State private var lit: Set<Int> = []
    @State private var lifted = false
    @State private var showCard = false
    @State private var showButton = false
    @State private var run = 0

    private static let lines = ["Every event looks the same.", "Olana finds what matters.", "And tells you when to start."]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headline
                        .padding(.top, 22)
                    stage
                        .padding(.top, 24)
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
            .buttonStyle(OnbPressStyle())
            // What swells into the next step.
            .onbPart("cta")
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton || reduceMotion ? 0 : 12)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .task(id: run) { await play() }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: lit.contains(Self.critical)) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: showCard) { _, new in new }
    }

    // MARK: Headline

    /// The three lines share one spot, sized to the tallest, so nothing below
    /// moves when they change.
    private var headline: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.lines.indices, id: \.self) { i in
                Text(Self.lines[i])
                    .font(HomeType.serif(size: 32))
                    .foregroundStyle(c.text)
                    .fixedSize(horizontal: false, vertical: true)
                    // Letters rise in on the way in; the old line just fades.
                    .textRenderer(RiseInRenderer(progress: reduceMotion || i <= beat ? 1 : 0))
                    .animation(i == beat && !reduceMotion ? .easeOut(duration: 0.9) : nil, value: beat)
                    .opacity(i == max(beat, 0) ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: beat)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Know what matters next, and when to start on it.")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Stage

    private var stage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showCard, let card = Self.sampleDay.card {
                NextCardView(card: card)
                    .allowsHitTesting(false)
                    .zIndex(1)
                    .transition(reduceMotion ? .opacity
                                : .opacity.animation(.easeOut(duration: 0.3).delay(0.12))
                                    .combined(with: .offset(y: 22))
                                    .combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            list
            Text("Tap to watch again")
                .font(.caption)
                .foregroundStyle(c.faint)
                .frame(maxWidth: .infinity)
                .opacity(showCard && !reduceMotion ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { if showCard && !reduceMotion { run += 1 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A calendar of four events: standup, lunch with Sam, client review, and picking up a prescription. Olana marks client review as critical and tells you to start prepping by 2:20.")
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows.indices, id: \.self) { i in
                row(i)
                    .opacity(i < rowsIn ? rowOpacity(i) : 0)
                    .offset(y: i < rowsIn || reduceMotion ? 0 : -14)
                    .scaleEffect(lifted && i == Self.critical && !showCard ? 1.04 : 1, anchor: .leading)
                if i < Self.rows.count - 1 { Divider().opacity(i < rowsIn ? 1 : 0) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.card2))
        .overlay { scanLine }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ i: Int) -> some View {
        let r = Self.rows[i]
        let on = lit.contains(i) && r.urgency != nil
        return HStack(spacing: 12) {
            Text(r.time)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(c.muted)
                .frame(width: 44, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(on ? c.tier(r.urgency!) : c.line)
                .frame(width: 4, height: 26)
            Text(r.title)
                .font(.subheadline)
                .foregroundStyle(c.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if on {
                Text(HomeFormat.tierName(r.urgency!))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(c.tier(r.urgency!))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(c.tier(r.urgency!).opacity(0.14)))
                    .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
        }
        .padding(.vertical, 9)
    }

    private func rowOpacity(_ i: Int) -> Double {
        if showCard { return i == Self.critical ? 0.7 : 0.4 }
        if lifted { return i == Self.critical ? 1 : 0.35 }
        return lit.contains(i) && Self.rows[i].urgency == nil ? 0.4 : 1
    }

    /// A thin gold line with a soft wash around it.
    private var scanLine: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [c.gold.opacity(0), c.gold.opacity(0.22), c.gold.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 56)
                Rectangle()
                    .fill(c.gold.opacity(0.85))
                    .frame(height: 1.5)
                    .shadow(color: c.gold.opacity(0.6), radius: 4)
            }
            .position(x: g.size.width / 2, y: scan * g.size.height)
        }
        .opacity(scanning ? 1 : 0)
        .allowsHitTesting(false)
    }

    // MARK: Sequence

    private func play() async {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            beat = -1; rowsIn = 0; scanning = false; scan = -0.1
            lit = []; lifted = false; showCard = false
        }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) {
                beat = 2; rowsIn = Self.rows.count; lit = Set(Self.rows.indices); showCard = true; showButton = true
            }
            return
        }

        guard await pause(0.15) else { return }
        withAnimation { beat = 0 }
        for i in Self.rows.indices {
            guard await pause(0.09) else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { rowsIn = i + 1 }
        }

        // Read: the line sweeps down at an even pace; each row lights as it passes.
        guard await pause(1.3) else { return }
        let sweep = 1.4, from: CGFloat = -0.1, to: CGFloat = 1.1
        withAnimation { beat = 1 }
        withAnimation(.easeOut(duration: 0.2)) { scanning = true; showButton = true }
        withAnimation(.linear(duration: sweep)) { scan = to }
        var elapsed = 0.0
        for i in Self.rows.indices {
            let at = (CGFloat(i) + 0.5) / CGFloat(Self.rows.count)
            let when = sweep * Double((at - from) / (to - from))
            guard await pause(when - elapsed) else { return }
            elapsed = when
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { _ = lit.insert(i) }
        }
        guard await pause(sweep - elapsed) else { return }
        withAnimation(.easeOut(duration: 0.3)) { scanning = false }

        // Lift, then the card.
        guard await pause(0.35) else { return }
        withAnimation(.easeInOut(duration: 0.35)) { lifted = true }
        guard await pause(0.5) else { return }
        withAnimation { beat = 2 }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { showCard = true }

        if autoplay {
            guard await pause(2.2) else { return }
            onContinue()
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return false }
        return true
    }

    // MARK: Sample

    /// nil urgency: doesn't matter.
    private static let rows: [(time: String, title: String, urgency: EventUrgency?)] = [
        ("9:30", "Standup", nil), ("12:00", "Lunch with Sam", nil),
        ("3:00", "Client review", .high), ("5:30", "Pick up prescription", .medium),
    ]
    private static let critical = 2

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

// MARK: - Letters rising in

/// Draws a Text one glyph at a time: each rises 8 pt out of a slight blur as
/// `progress` goes 0 → 1, left to right, overlapping like a wave.
struct RiseInRenderer: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run } }
        let n = Double(max(slices.count, 1))
        for (i, slice) in slices.enumerated() {
            // Each glyph starts a little after the one before and takes 40% of the run.
            let start = Double(i) / n * 0.6
            let p = min(max((progress - start) / 0.4, 0), 1)
            guard p > 0 else { continue }
            var g = ctx
            g.opacity = p
            g.translateBy(x: 0, y: (1 - p) * 8)
            if p < 1 { g.addFilter(.blur(radius: (1 - p) * 3)) }
            g.draw(slice)
        }
    }
}
