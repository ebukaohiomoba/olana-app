import SwiftUI

struct CompletionCelebrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.olanaTheme) private var theme

    let xpEarned: Int
    let streakDays: Int
    let eventTitle: String
    let rewards: [String]
    let newBadges: [Badge]

    @State private var oluState: OluState = .celebrate
    @State private var confettiCounter = 0
    @State private var showContent = false
    @State private var scale: CGFloat = 0.85

    var body: some View {
        ZStack {
            // Confetti — clipped to modal, starts at top edge
            ForEach(0..<30, id: \.self) { _ in
                ConfettiPiece(counter: confettiCounter)
            }
            .drawingGroup()

            VStack(spacing: 20) {
                // Olu in celebrate state
                OluView(
                    state: $oluState,
                    size: 110,
                    onCelebrationComplete: {
                        oluState = .resting
                    }
                )
                .padding(.top, 8)

                // Title + event name
                VStack(spacing: 6) {
                    Text("Event Completed!")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(theme.colors.ink)

                    Text(eventTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .opacity(showContent ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.2), value: showContent)

                // XP
                HStack(spacing: 10) {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("+\(xpEarned) XP")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .opacity(showContent ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.3), value: showContent)

                // Streak
                if streakDays > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.body)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .red],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("\(streakDays) Day Streak!")
                            .font(.headline)
                            .foregroundStyle(theme.colors.ink)
                    }
                    .opacity(showContent ? 1 : 0)
                    .animation(.easeIn(duration: 0.3).delay(0.4), value: showContent)
                }

                // Rewards (compact)
                if !rewards.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(rewards, id: \.self) { reward in
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(theme.colors.ribbon)
                                Text(reward)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .opacity(showContent ? 1 : 0)
                    .animation(.easeIn(duration: 0.3).delay(0.5), value: showContent)
                }

                // New badges (compact)
                if !newBadges.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(newBadges) { badge in
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(theme.colors.ribbon.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: badge.icon)
                                        .font(.body)
                                        .foregroundStyle(theme.colors.ribbon)
                                }
                                Text(badge.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(theme.colors.ribbon.opacity(0.08))
                            )
                        }
                    }
                    .opacity(showContent ? 1 : 0)
                    .animation(.easeIn(duration: 0.3).delay(0.6), value: showContent)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .scaleEffect(scale)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.fraction(0.6)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            confettiCounter += 1
            withAnimation { showContent = true; scale = 1.0 }

            // Auto-dismiss after 3 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeInOut(duration: 0.25)) { scale = 0.9 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dismiss() }
            }
        }
    }
}

// MARK: - Confetti Piece

struct ConfettiPiece: View {
    let counter: Int

    @State private var yOffset: CGFloat = -150
    @State private var confettiOpacity: Double = 1.0
    @State private var rotation: Double = 0

    private let color = [Color.red, .blue, .green, .yellow, .orange, .pink, .purple, .cyan].randomElement()!
    private let shape = ["circle.fill", "square.fill", "triangle.fill"].randomElement()!
    private let size: CGFloat = CGFloat.random(in: 6...14)
    private let xPos: CGFloat = CGFloat.random(in: -180...180)
    private let duration: Double = Double.random(in: 1.8...3.2)
    private let finalRotation: Double = Double.random(in: 0...540)

    var body: some View {
        Image(systemName: shape)
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .opacity(confettiOpacity)
            .offset(x: xPos, y: yOffset)
            .onAppear { animate() }
            .onChange(of: counter) { _, _ in
                yOffset = -150
                confettiOpacity = 1.0
                rotation = 0
                animate()
            }
    }

    private func animate() {
        withAnimation(.linear(duration: duration)) {
            yOffset = 600
            rotation = finalRotation
            confettiOpacity = 0
        }
    }
}

#Preview {
    CompletionCelebrationView(
        xpEarned: 150,
        streakDays: 7,
        eventTitle: "Team Meeting",
        rewards: ["First of the Day!", "Critical Event Crushed!"],
        newBadges: []
    )
}
