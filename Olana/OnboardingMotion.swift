//
//  OnboardingMotion.swift
//  Olana
//
//  The pieces onboarding's motion is built from.
//
//  Between steps, one thing carries the user across (the "flight"), drawn
//  above both steps by OnboardingView:
//    promise → calendar   "Get started" swells into a gold wash over the
//                         screen, then shrinks into Olana's gold circle
//    calendar → reveal    the circle, check and all, flies to the reveal
//                         and becomes its reading strip
//    reveal → heads-up    the card shrinks into the heads-up banner on the
//                         lock screen
//  Steps mark what a flight leaves from or lands on with `onbPart(_:)`: its
//  frame goes up to OnboardingView, and the step hides it while the flight
//  stands in for it.
//
//  Inside a step, text and buttons rise in a beat apart (`staggerIn`), and
//  buttons sink a little under the finger (OnbPressStyle).
//

import SwiftUI

// MARK: - Parts a flight leaves from or lands on

struct OnbAnchors: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension EnvironmentValues {
    /// Parts a flight is standing in for right now.
    @Entry var onbHidden: Set<String> = []
}

private struct OnbPart: ViewModifier {
    let id: String
    @Environment(\.onbHidden) private var hidden

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: OnbAnchors.self, value: [id: g.frame(in: .named(OnbSpace.name))])
                }
            }
            .opacity(hidden.contains(id) ? 0 : 1)
    }
}

enum OnbSpace { static let name = "onboarding" }

extension View {
    /// Reports this view's frame for flights, and hides it while one stands in.
    func onbPart(_ id: String) -> some View { modifier(OnbPart(id: id)) }

    /// Rises in from 14 pt below out of a slight blur, `order` beats after the step appears.
    func staggerIn(_ order: Int) -> some View { modifier(StaggerIn(order: order)) }
}

// MARK: - Staggered entrance

private struct StaggerIn: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 14)
            .blur(radius: on || reduceMotion ? 0 : 3)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.3)
                              : .spring(response: 0.5, dampingFraction: 0.85).delay(0.14 + Double(order) * 0.07)) {
                    on = true
                }
            }
    }
}

// MARK: - Buttons

/// Sinks to 97% and darkens a touch while held; springs back on release.
struct OnbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - The flight

struct OnbFlight: Equatable {
    enum Kind: Equatable { case gold, check, card }
    var kind: Kind
    /// Where it is, in the onboarding coordinate space.
    var rect: CGRect
    var radius: CGFloat
    /// 0 → 1 as it turns into what it lands on (check fades, card becomes the banner).
    var morph: Double = 0
    var opacity: Double = 1
}

struct OnbFlightView: View {
    let flight: OnbFlight
    let card: NextCard?
    let banner: (title: String, body: String)

    @Environment(\.homePalette) private var c

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: flight.radius, style: .continuous)
        ZStack(alignment: .top) {
            switch flight.kind {
            case .gold, .check:
                shape.fill(LinearGradient(colors: [c.gold, c.goldText], startPoint: .topLeading, endPoint: .bottomTrailing))
                if flight.kind == .check {
                    OnbCheck()
                        .stroke(c.onGold, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 30, height: 24)
                        .scaleEffect(min(1, flight.rect.width / 76))
                        .frame(maxHeight: .infinity)
                        .opacity(1 - flight.morph * 1.6)
                }
            case .card:
                shape.fill(c.card)
                if let card {
                    NextCardView(card: card)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(1 - flight.morph * 1.6)
                }
                // Overlapping fades, so it's never an empty box halfway.
                HeadsUpBanner(title: banner.title, message: banner.body)
                    .opacity(flight.morph * 1.8 - 0.45)
            }
        }
        .frame(width: flight.rect.width, height: flight.rect.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(flight.kind == .card ? 0.14 : 0), radius: 16, y: 8)
        .opacity(flight.opacity)
        .position(x: flight.rect.midX, y: flight.rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct OnbCheck: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// A notification as it looks on the lock screen: Olana's tile, the event,
/// "now", and the line it would say.
struct HeadsUpBanner: View {
    let title: String
    let message: String
    @Environment(\.homePalette) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(c.gold)
                .frame(width: 38, height: 38)
                .overlay(Text("O").font(HomeType.serif(size: 20)).foregroundStyle(c.onGold))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(c.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("now").font(.caption).foregroundStyle(c.muted)
                }
                Text(message).font(.subheadline).foregroundStyle(c.text.opacity(0.85)).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(c.card.opacity(0.6)))
    }
}
