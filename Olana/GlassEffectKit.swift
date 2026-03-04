import SwiftUI

/// A style describing the appearance and behavior of a glass effect.
public struct GlassEffectStyle {
    /// The amount of blur to apply.
    public var blur: CGFloat
    /// An optional tint color overlay.
    public var tint: Color?
    /// Whether the effect is interactive (adds press effects).
    public var interactive: Bool

    /// A default glass effect style with blur 12, no tint, and non-interactive.
    public static var regular: GlassEffectStyle {
        GlassEffectStyle(blur: 12, tint: nil, interactive: false)
    }

    /// Returns a copy of this style with the tint set to the given color.
    /// - Parameter color: The tint color.
    /// - Returns: A new `GlassEffectStyle` with the tint color applied.
    public func tint(_ color: Color) -> GlassEffectStyle {
        var copy = self
        copy.tint = color
        return copy
    }

    /// Returns a copy of this style marked as interactive.
    /// - Returns: A new `GlassEffectStyle` with `interactive` set to true.
    public func interactiveEnabled() -> GlassEffectStyle {
        var copy = self
        copy.interactive = true
        return copy
    }
}

/// Shapes available for the glass effect container.
public enum GlassEffectShape {
    /// A capsule shape.
    case capsule
    /// A circle shape.
    case circle
    /// A rectangle shape with rounded corners.
    case rect(cornerRadius: CGFloat)
}

fileprivate struct PressableModifier: ViewModifier {
    @GestureState private var isPressed = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isPressed ? 0.85 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
    }
}

fileprivate extension View {
    @ViewBuilder
    func pressable(_ enabled: Bool) -> some View {
        if enabled {
            self.modifier(PressableModifier())
        } else {
            self
        }
    }
}

public extension View {
    /// Applies a glass effect background with blur, tint, shape, and optional interactive press effects.
    /// - Parameters:
    ///   - style: The glass effect style to apply (blur, tint, interactive).
    ///   - shape: The shape to clip the effect to.
    /// - Returns: A view with the glass effect applied.
    @ViewBuilder
    func glassEffect(_ style: GlassEffectStyle = .regular, in shape: GlassEffectShape = .rect(cornerRadius: 0)) -> some View {
        switch shape {
        case .capsule:
            self
                .background(.thinMaterial)
                .overlay {
                    if let tint = style.tint {
                        Capsule()
                            .fill(tint.opacity(0.2))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .pressable(style.interactive)
        case .circle:
            self
                .background(.thinMaterial)
                .overlay {
                    if let tint = style.tint {
                        Circle()
                            .fill(tint.opacity(0.2))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .pressable(style.interactive)
        case .rect(let cornerRadius):
            self
                .background(.thinMaterial)
                .overlay {
                    if let tint = style.tint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.2))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .pressable(style.interactive)
        }
    }
}

/// A container view that arranges its content vertically with a translucent glass background,
/// rounded top corners, a top divider, and a subtle shadow.
public struct GlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    /// Creates a new glass effect container.
    /// - Parameters:
    ///   - spacing: The spacing between contained views.
    ///   - content: The content builder.
    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: spacing) {
            content
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.08))
                .padding(.horizontal, 16),
            alignment: .top
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
    }
}

/// A button style that applies a frosted glass background with subtle stroke and interactive feedback.
public struct GlassButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
            .background(
                ZStack {
                    // Frosted background
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemBackground).opacity(0.3))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    // Stroke border
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                }
            )
            .foregroundStyle(.tint)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A prominent button style that applies a filled tint background with white foreground and interactive feedback.
public struct GlassProminentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.tint)
                    .opacity(configuration.isPressed ? 0.7 : 0.85)
                    .shadow(color: Color.black.opacity(0.25), radius: configuration.isPressed ? 5 : 8, x: 0, y: configuration.isPressed ? 2 : 4)
            )
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Provides `.glass` button style shorthand.
public extension ButtonStyle where Self == GlassButtonStyle {
    /// A frosted glass button style with subtle stroke and interactive effects.
    static var glass: GlassButtonStyle { .init() }
}

/// Provides `.glassProminent` button style shorthand.
public extension ButtonStyle where Self == GlassProminentButtonStyle {
    /// A prominent filled glass button style with white foreground and interactive effects.
    static var glassProminent: GlassProminentButtonStyle { .init() }
}
