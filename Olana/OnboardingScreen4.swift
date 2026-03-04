//
//  OnboardingScreen4.swift
//  Olana
//
//  Progress Layer — amber progress card preview, Olu goes idle on appear.
//

import SwiftUI

struct OnboardingScreen4: View {
    @Binding var currentPage: Int

    @State private var oluState: OluState = .resting
    @State private var cardOpacity: Double = 0
    @State private var cardScale: CGFloat = 0.92

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "F5EDD8")
                .ignoresSafeArea()

            // Olu — small, top right
            OnboardingOluView(state: $oluState, size: 58)
                .padding(.top, 56)
                .padding(.trailing, 24)

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 108)

                Text("Progress you can actually feel.")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                    .lineSpacing(4)
                    .padding(.bottom, 14)

                Text("Every task you complete earns XP. Streaks track your consistency.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(6)
                    .padding(.bottom, 24)

                // Preview card
                OnboardingProgressCardPreview()
                    .opacity(cardOpacity)
                    .scaleEffect(cardScale)
                    .padding(.bottom, 20)

                // Grace token info row
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hands.sparkles.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "F0A500"))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Grace Tokens protect your streak on hard days. You start with 3.")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color(hex: "5C3D1E"))
                            .lineSpacing(4)

                        Text("No shame — just grace.")
                            .font(.system(size: 13, weight: .regular))
                            .italic()
                            .foregroundStyle(Color(hex: "5C3D1E"))
                    }
                }
                .padding(.bottom, 28)

                Spacer()

                OnboardingPrimaryButton(title: "Love that →") {
                    withAnimation(.easeInOut) { currentPage = 4 }
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            oluState = .idle
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                cardOpacity = 1
                cardScale = 1.0
            }
        }
    }
}

// MARK: - Progress Card Preview (static, amber gradient, matches HomeView styling)

private struct OnboardingProgressCardPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your Progress")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 0) {
                PreviewStatColumn(
                    icon: "flame.fill",
                    iconColor: .orange,
                    value: "0",
                    label: "Streak Days"
                )

                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1, height: 60)
                    .padding(.horizontal, 8)

                PreviewStatColumn(
                    icon: "sparkles",
                    iconColor: .white,
                    value: "3",
                    label: "Grace Tokens"
                )

                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1, height: 60)
                    .padding(.horizontal, 8)

                PreviewStatColumn(
                    icon: "star.fill",
                    iconColor: .yellow,
                    value: "0",
                    label: "Total XP"
                )
            }
        }
        .padding(24)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "F5A800"), Color(hex: "D96F00")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 110, height: 110)
                    .offset(x: 28, y: -28)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        .shadow(color: Color(hex: "D96F00").opacity(0.35), radius: 16, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 12)
    }
}

private struct PreviewStatColumn: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)

            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
