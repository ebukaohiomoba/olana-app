import SwiftUI
import Combine

// Semantic tokens for the app's design system
struct OlanaColors {
    // Surfaces & text
    let canvasStart: Color, canvasEnd: Color // background gradient stops
    let paper: Color, ink: Color, slate: Color
    let ribbon: Color, success: Color

    // Hero card gradient (progress card, today card)
    let heroStart: Color, heroEnd: Color

    // Urgency accents
    let urgencyHigh: Color, urgencyMedium: Color, urgencyLow: Color

    // Utility
    let pillShadow: Color
    let cardBorder: Color  // stroke around cards — clear in dark mode to remove visible lines
}

struct OlanaRadii { let sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }
struct OlanaSpacing { let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }

struct OlanaTheme {
    let colors: OlanaColors
    let radii = OlanaRadii()
    let spacing = OlanaSpacing()

    // Current theme (computed property that adapts to system)
    @MainActor
    static var current: OlanaTheme {
        return system(colorScheme: .light) // Default fallback
    }

    // Light theme - warm cream + gold palette
    static let light = OlanaTheme(colors: OlanaColors(
        canvasStart: Color(hex: "FFFAF2"), // warm cream
        canvasEnd:   Color(hex: "F5EDD8"), // golden cream
        paper:       Color.white,
        ink:         Color(hex: "1A0F00"), // deep warm black
        slate:       Color(hex: "A07850"), // warm brown mid
        ribbon:      Color(hex: "F0A500"), // gold
        success:     Color(hex: "34C759"),
        heroStart:   Color(hex: "F5A800"), // amber — hero card gradient start
        heroEnd:     Color(hex: "D96F00"), // deep orange — hero card gradient end
        urgencyHigh: Color(hex: "FF8060"), // coral
        urgencyMedium: Color(hex: "F0A500"), // gold
        urgencyLow:  Color(hex: "8FC98A"), // soft green
        pillShadow:  Color(hex: "1A0F00").opacity(0.07),
        cardBorder:  Color(hex: "F0E6CC") // subtle warm stroke in light mode
    ))

    // Dark theme - deep purple + warm amber palette
    static let dark = OlanaTheme(colors: OlanaColors(
        canvasStart: Color(hex: "14101E"), // deep purple-black
        canvasEnd:   Color(hex: "1A1428"), // dark plum
        paper:       Color(hex: "1E1830"), // elevated card surface
        ink:         Color(hex: "EDE6FF"), // soft lavender text
        slate:       Color(hex: "7A6898"), // muted purple secondary
        ribbon:      Color(hex: "C8A060"), // warm amber accent
        success:     Color(hex: "4CAF78"), // muted green
        heroStart:   Color(hex: "2E2448"), // deep purple — hero card gradient start
        heroEnd:     Color(hex: "1A1230"), // near-black plum — hero card gradient end
        urgencyHigh: Color(hex: "C05040"), // muted red
        urgencyMedium: Color(hex: "A07830"), // muted amber
        urgencyLow:  Color(hex: "508050"), // muted green
        pillShadow:  Color.black.opacity(0.6),
        cardBorder:  Color.clear             // no card borders in dark mode
    ))
    
    // System theme that adapts to user's system preference
    static func system(colorScheme: ColorScheme) -> OlanaTheme {
        colorScheme == .dark ? dark : light
    }
}

// Environment injection
private struct OlanaThemeKey: EnvironmentKey { static let defaultValue = OlanaTheme.light }
extension EnvironmentValues {
    var olanaTheme: OlanaTheme {
        get { self[OlanaThemeKey.self] }
        set { self[OlanaThemeKey.self] = newValue }
    }
}

// Persisted theme choice
enum ThemeVariant: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// AppStorage for theme persistence
@propertyWrapper
struct ThemePreference: DynamicProperty {
    @AppStorage("themeVariant") private var stored: String = ThemeVariant.system.rawValue
    
    var wrappedValue: ThemeVariant {
        get { ThemeVariant(rawValue: stored) ?? .system }
        nonmutating set { stored = newValue.rawValue }
    }
    
    var projectedValue: Binding<ThemeVariant> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

// Theme provider view modifier
struct ThemeProviderModifier: ViewModifier {
    @Environment(\.colorScheme) private var systemColorScheme
    let themeVariant: ThemeVariant
    
    private var activeTheme: OlanaTheme {
        switch themeVariant {
        case .system:
            return OlanaTheme.system(colorScheme: systemColorScheme)
        case .light:
            return OlanaTheme.light
        case .dark:
            return OlanaTheme.dark
        }
    }
    
    func body(content: Content) -> some View {
        content
            .environment(\.olanaTheme, activeTheme)
            .tint(activeTheme.colors.ribbon)
            .preferredColorScheme(themeVariant == .system ? nil : (themeVariant == .dark ? .dark : .light))
    }
}

extension View {
    func olanaThemeProvider(variant: ThemeVariant) -> some View {
        modifier(ThemeProviderModifier(themeVariant: variant))
    }
}

// MARK: - Color helpers
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Theme Picker Component (Optional)
struct ThemePickerView: View {
    @Binding var selectedTheme: ThemeVariant
    @Environment(\.olanaTheme) private var theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
            
            HStack(spacing: 12) {
                ForEach(ThemeVariant.allCases) { variant in
                    ThemeOptionButton(
                        variant: variant,
                        isSelected: selectedTheme == variant,
                        action: { selectedTheme = variant }
                    )
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.colors.paper)
                .shadow(color: theme.colors.pillShadow, radius: 8, x: 0, y: 4)
        )
    }
}

private struct ThemeOptionButton: View {
    @Environment(\.olanaTheme) private var theme
    let variant: ThemeVariant
    let isSelected: Bool
    let action: () -> Void
    
    private var icon: String {
        switch variant {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? theme.colors.ribbon : theme.colors.slate)
                
                Text(variant.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.colors.ink : theme.colors.slate)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? theme.colors.ribbon.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.colors.ribbon : theme.colors.slate.opacity(0.3), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
