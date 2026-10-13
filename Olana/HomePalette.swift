//
//  HomePalette.swift
//  Olana
//
//  Colors and type for the redesigned home and tab bar (home_literata.html,
//  spec_m0_m1_v2 §14.7). Kept apart from OlanaTheme so the screens that haven't
//  been redesigned yet don't shift underneath their own layouts.
//

import SwiftUI
import UIKit

struct HomePalette {
    let bg: Color, card: Color, card2: Color, line: Color
    let text: Color, muted: Color, faint: Color, track: Color
    /// Gold for large text and fills.
    let gold: Color
    /// Gold for small text: darker in light mode so thin strokes pass contrast.
    let goldText: Color
    let crit: Color, soon: Color, later: Color
    let synced: Color
    let tabIdle: Color
    let elapsed: Color
    let onGold: Color
    let cardShadow: Color

    static let dark = HomePalette(
        bg: Color(hex: "13111C"), card: Color(hex: "1E1A2C"), card2: Color(hex: "262137"),
        line: Color(hex: "2F2945"), text: Color(hex: "EFEAF7"), muted: Color(hex: "8E86A6"),
        faint: Color(hex: "5B5470"), track: Color(hex: "2A2540"),
        gold: Color(hex: "D9A64E"), goldText: Color(hex: "D9A64E"),
        crit: Color(hex: "E5534B"), soon: Color(hex: "F0A500"), later: Color(hex: "4A90D9"),
        synced: Color(hex: "5FAF8A"), tabIdle: Color(hex: "C3BCD6"),
        elapsed: Color(hex: "EFEAF7").opacity(0.22), onGold: Color(hex: "1B1408"),
        cardShadow: .clear)

    static let light = HomePalette(
        bg: Color(hex: "FBF7F0"), card: .white, card2: Color(hex: "F3ECDF"),
        line: Color(hex: "E8DCC8"), text: Color(hex: "2A1F14"), muted: Color(hex: "857158"),
        faint: Color(hex: "B5A48A"), track: Color(hex: "EFE6D6"),
        gold: Color(hex: "B47A17"), goldText: Color(hex: "8F5F0E"),
        crit: Color(hex: "D2433B"), soon: Color(hex: "D98A00"), later: Color(hex: "3B7CC4"),
        synced: Color(hex: "2F8A5F"), tabIdle: Color(hex: "6E5B45"),
        elapsed: Color(hex: "2A1F14").opacity(0.14), onGold: .white,
        cardShadow: Color(hex: "785A28").opacity(0.10))

    static func of(_ scheme: ColorScheme) -> HomePalette { scheme == .dark ? dark : light }

    func tier(_ u: EventUrgency) -> Color {
        switch u {
        case .high:   return crit
        case .medium: return soon
        case .low:    return later
        }
    }
}

private struct HomePaletteKey: EnvironmentKey { static let defaultValue = HomePalette.light }

extension EnvironmentValues {
    var homePalette: HomePalette {
        get { self[HomePaletteKey.self] }
        set { self[HomePaletteKey.self] = newValue }
    }
}

/// Sets `homePalette` from the effective color scheme, which already reflects
/// the user's theme choice (ThemeProviderModifier sets preferredColorScheme).
struct HomePaletteProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.homePalette, .of(scheme))
    }
}

extension View {
    func homePalette() -> some View { modifier(HomePaletteProvider()) }
}

// MARK: - Type

enum HomeType {
    /// Literata at the 72 pt optical size, regular weight, for the L1 line only.
    /// Never bold (§14.7). Falls back to the system serif if the font is missing.
    static let serifName = "Literata-72pt"

    static func serif(size: CGFloat) -> Font {
        if UIFont(name: serifName, size: size) != nil {
            return .custom(serifName, size: size, relativeTo: .title)
        }
        return .system(size: size, weight: .regular, design: .serif)
    }
}

// MARK: - Hatch

/// Diagonal stripes for the prep window, as in the mockup's `.hatch`.
struct HatchFill: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.18)))
            var p = Path()
            let step: CGFloat = 7
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(p, with: .color(color.opacity(0.7)), lineWidth: 3)
        }
    }
}
