//
//  NextCardView.swift
//  Olana
//
//  "● NEXT THAT MATTERS": the one event worth attention, the time to act in
//  Literata gold, and the runway to it (spec_m0_m1_v2 §14.2, §14.3).
//
//  Replaces FocusCard and ImminentEventCard on home.
//

import SwiftUI

struct NextCardView: View {
    let card: NextCard
    var onTap: () -> Void = {}

    @Environment(\.homePalette) private var c
    @ScaledMetric(relativeTo: .title) private var l1Size: CGFloat = 30

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                Text("● NEXT THAT MATTERS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(c.tier(card.urgency))

                (Text(card.lead).foregroundStyle(c.text)
                 + Text(card.gold).foregroundStyle(c.goldText)
                 + Text(card.trail).foregroundStyle(c.muted))
                    .font(HomeType.serif(size: l1Size))
                    .tracking(-0.7)
                    .minimumScaleFactor(0.8)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(c.text)
                        .lineLimit(2)
                    Text(card.detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(c.muted)
                        .lineLimit(2)
                }
                .padding(.top, 12)

                if let r = card.runway {
                    RunwayView(runway: r)
                        // Ticks are placed by time, so large labels collide; they
                        // stop growing at XXL. The L1 line already says the time,
                        // and VoiceOver reads the runway's text equivalent.
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .padding(.top, 14)
                }

                if let next = card.secondary {
                    Text(next)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(c.muted)
                        .lineLimit(2)
                        .padding(.top, card.runway == nil ? 12 : 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(c.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(c.line, lineWidth: 1))
            .shadow(color: c.cardShadow, radius: 15, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityValue(card.runway?.accessibilityText ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Runway

struct RunwayView: View {
    let runway: NextCard.Runway
    @Environment(\.homePalette) private var c
    @ScaledMetric(relativeTo: .caption) private var tickHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                let x = { (d: Date) in CGFloat(runway.x(d)) * w }
                ZStack(alignment: .leading) {
                    Rectangle().fill(c.track)
                    // Elapsed
                    Rectangle().fill(c.elapsed)
                        .frame(width: x(runway.now))
                    // Prep window: prepStartBy to prepDeadline (spec §14.3).
                    if let p = runway.prepFrom {
                        let end = runway.prepTo ?? runway.start
                        HatchFill(color: c.gold)
                            .frame(width: max(0, x(end) - x(p)))
                            .offset(x: x(p))
                    }
                    // Get ready and travel: dotted, get-ready to start.
                    if let g = runway.travelFrom {
                        DottedFill(color: c.muted)
                            .frame(width: max(0, x(runway.start) - x(g)))
                            .offset(x: x(g))
                    }
                    // Start cap
                    Rectangle().fill(c.crit)
                        .frame(width: max(0, w - x(runway.start)))
                        .offset(x: x(runway.start))
                    // Now
                    Rectangle().fill(c.text)
                        .frame(width: 2)
                        .offset(x: min(x(runway.now), w - 2))
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)

            ticks
        }
        .accessibilityHidden(true)
    }

    private var ticks: some View {
        GeometryReader { g in
            let w = g.size.width
            let shown = visibleTicks
            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                let isFirst = i == 0, isLast = i == shown.count - 1
                VStack(alignment: isFirst ? .leading : isLast ? .trailing : .center, spacing: 1) {
                    Text(value(t))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(c.text)
                    Text(caption(t))
                        .font(.caption2)
                        .foregroundStyle(c.muted)
                }
                .fixedSize()
                .alignmentGuide(.leading) { d in
                    let px = CGFloat(runway.x(t.date)) * w
                    if isFirst { return -px }
                    if isLast { return -(px - d.width) }
                    return -(px - d.width / 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: tickHeight)
    }

    /// Drops labels that would sit on top of the next one: "now" gives way
    /// first, the start label always stays.
    private var visibleTicks: [NextCard.Tick] {
        var kept: [NextCard.Tick] = []
        for t in runway.ticks {
            if let last = kept.last, runway.x(t.date) - runway.x(last.date) < 0.16 {
                // Keep the later, more specific moment.
                kept.removeLast()
            }
            kept.append(t)
        }
        return kept
    }

    private func value(_ t: NextCard.Tick) -> String {
        t.kind == .now ? "now" : HomeFormat.clock(t.date)
    }

    private func caption(_ t: NextCard.Tick) -> String {
        switch t.kind {
        case .now:   return " "
        case .prep:  return "prep"
        case .leave: return "leave"
        case .join:  return "join"
        case .start: return "start"
        }
    }
}

/// Dots for the get-ready and travel segment of the runway.
private struct DottedFill: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 2
            while x < size.width {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: size.height / 2 - 1.5, width: 3, height: 3)), with: .color(color))
                x += 6
            }
        }
    }
}
