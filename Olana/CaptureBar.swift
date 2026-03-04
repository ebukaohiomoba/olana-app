import SwiftUI

struct CaptureBar: View {
    @Environment(\.olanaTheme) private var theme: OlanaTheme
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var accessibilityContrast: Bool
    
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(theme.colors.ribbon)

                Text("Add new event...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            // True Liquid Glass with fallback for Reduce Transparency
            .glassEffect(.regular.interactive(), in: .capsule)
            .background(
                Group {
                    if reduceTransparency {
                        Capsule().fill(theme.colors.paper)
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        reduceTransparency
                        ? theme.colors.slate.opacity(0.20)
                        : (colorScheme == .dark
                            ? Color.white.opacity(accessibilityContrast ? 0.24 : 0.14)
                            : Color.black.opacity(accessibilityContrast ? 0.14 : 0.08)
                          ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(
                    colorScheme == .dark
                        ? (accessibilityContrast ? 0.55 : 0.35)
                        : (accessibilityContrast ? 0.20 : 0.12)
                ),
                radius: 16, x: 0, y: 8
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}

#Preview {
    CaptureBar(onTap: {})
        .environment(\.olanaTheme, OlanaTheme.light)
}
