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
    /// The inline action (spec v3 §14.8); the String carries "Where is this?" text.
    var onAction: (CardAction, String?) -> Void = { _, _ in }

    @Environment(\.homePalette) private var c
    @ScaledMetric(relativeTo: .title) private var l1Size: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // "Up next" when nothing matters enough: no dot, no tier color.
                Text(card.quiet ? "UP NEXT" : "● NEXT THAT MATTERS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(card.quiet ? c.muted : c.tier(card.urgency))

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
            .padding(EdgeInsets(top: 16, leading: 16, bottom: card.action == nil ? 14 : 8, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityValue(card.runway?.accessibilityText ?? "")
        .accessibilityAddTraits(.isButton)

            // Outside the card's button, so its own buttons work.
            if let action = card.action {
                CardActionRow(action: action, title: card.title, onAction: onAction)
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            }
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(c.card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(c.line, lineWidth: 1))
        .shadow(color: c.cardShadow, radius: 15, x: 0, y: 10)
    }
}

/// One inline action (spec v3 §14.8). No mockup yet: plain, quiet controls
/// that match the card until the design lands.
struct CardActionRow: View {
    let action: CardAction
    let title: String
    var onAction: (CardAction, String?) -> Void
    @Environment(\.homePalette) private var c
    @State private var whereText = ""

    var body: some View {
        switch action {
        case .imLeaving: pill("I'm leaving") { onAction(.imLeaving, nil) }
        case .imHere: pill("I'm here") { onAction(.imHere, nil) }
        case .prepDone: pill("Prep done") { onAction(.prepDone, nil) }
        case .join: pill("Join", gold: true) { onAction(.join, nil) }
        case .inPersonOrOnline:
            HStack(spacing: 8) {
                Text("In person or online?").font(.footnote).foregroundStyle(c.muted)
                Spacer()
                pill("In person") { onAction(.inPersonOrOnline, "inPerson") }
                pill("Online") { onAction(.inPersonOrOnline, "virtual") }
            }
        case .isImportant:
            HStack(spacing: 8) {
                Text("Is this important?").font(.footnote).foregroundStyle(c.muted)
                Spacer()
                pill("Yes") { onAction(.isImportant, "yes") }
                pill("No") { onAction(.isImportant, "no") }
            }
        case .whereFrom:
            HStack(spacing: 8) {
                Text("Where do you leave from?").font(.footnote).foregroundStyle(c.muted)
                Spacer()
                pill("Set up") { onAction(.whereFrom, "setup") }
                pill("Not now") { onAction(.whereFrom, "later") }
            }
        case .whereIsThis:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.footnote).foregroundStyle(c.muted)
                    TextField("Where is this?", text: $whereText)
                        .font(.subheadline)
                        .submitLabel(.done)
                        .onSubmit {
                            let t = whereText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { onAction(.whereIsThis, t); whereText = "" }
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(c.card2))
                HStack(spacing: 8) {
                    pill("Online") { onAction(.whereIsThis, "online") }
                    pill("Not needed") { onAction(.whereIsThis, "not needed") }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where is \(title)?")
        }
    }

    private func pill(_ t: String, gold: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.subheadline.weight(.semibold))
                .foregroundStyle(gold ? c.onGold : c.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(gold ? c.gold : c.card2))
        }
        .buttonStyle(.plain)
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
