//
//  OlanaTabBar.swift
//  Olana
//
//  Home, Calendar, raised +, Circles, Settings (spec_m0_m1_v2 §14.6).
//  Replaces the system TabView bar and the floating add button.
//

import SwiftUI

enum OlanaTab: Int, CaseIterable {
    case home, calendar, circles, settings

    var title: String {
        switch self {
        case .home:     return "Home"
        case .calendar: return "Calendar"
        case .circles:  return "Circles"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home:     return "house.fill"
        case .calendar: return "calendar"
        case .circles:  return "person.3"
        case .settings: return "gearshape"
        }
    }
}

struct OlanaTabBar: View {
    @Binding var selection: OlanaTab
    var onAdd: () -> Void

    @Environment(\.homePalette) private var c
    @Environment(\.colorScheme) private var scheme

    /// Bar height including the bump; the plus sits in the bump.
    static let height: CGFloat = 82

    var body: some View {
        ZStack(alignment: .top) {
            TabBarShape()
                .fill(scheme == .dark ? c.card2.opacity(0.96) : c.card)
                .overlay(TabBarShape().stroke(c.line, lineWidth: 1))
                .shadow(color: scheme == .dark ? .clear : Color(hex: "503C1E").opacity(0.12), radius: 12, y: 6)

            HStack(alignment: .bottom, spacing: 0) {
                item(.home)
                item(.calendar)
                Color.clear.frame(width: 84)
                item(.circles)
                item(.settings)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(c.onGold)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(c.gold))
                    .shadow(color: c.gold.opacity(0.35), radius: 9, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 5)
            .accessibilityLabel("Add event")
        }
        .frame(height: Self.height)
        .padding(.horizontal, 18)
    }

    private func item(_ tab: OlanaTab) -> some View {
        let on = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20, weight: on ? .semibold : .regular))
                    .frame(height: 24)
                Text(tab.title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(on ? c.goldText : c.tabIdle)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The bar with a curved bump in the middle for the plus, from the mockup's
/// 354 × 82 path, stretched horizontally to the available width.
struct TabBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let sy = h / 82
        let mid = w / 2
        // Bump spans 65 pt either side of center, as in the 354-wide original.
        var p = Path()
        p.move(to: CGPoint(x: 30, y: 18 * sy))
        p.addLine(to: CGPoint(x: mid - 65, y: 18 * sy))
        p.addCurve(to: CGPoint(x: mid, y: 0),
                   control1: CGPoint(x: mid - 43, y: 18 * sy),
                   control2: CGPoint(x: mid - 35, y: 0))
        p.addCurve(to: CGPoint(x: mid + 65, y: 18 * sy),
                   control1: CGPoint(x: mid + 35, y: 0),
                   control2: CGPoint(x: mid + 43, y: 18 * sy))
        p.addLine(to: CGPoint(x: w - 30, y: 18 * sy))
        p.addArc(center: CGPoint(x: w - 30, y: 48 * sy), radius: 30,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: w, y: 52 * sy))
        p.addArc(center: CGPoint(x: w - 30, y: 52 * sy), radius: 30,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: 30, y: h))
        p.addArc(center: CGPoint(x: 30, y: 52 * sy), radius: 30,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: 48 * sy))
        p.addArc(center: CGPoint(x: 30, y: 48 * sy), radius: 30,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
