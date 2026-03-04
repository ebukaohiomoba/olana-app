//
//  OnboardingScreen3.swift
//  Olana
//
//  Urgency System — animated urgency cards, Olu resting top-right.
//

import SwiftUI

struct OnboardingScreen3: View {
    @Binding var currentPage: Int

    @State private var oluState: OluState = .resting
    @State private var cardsVisible: [Bool] = [false, false, false]

    private struct UrgencyInfo {
        let emoji: String
        let title: String
        let subtitle: String
        let accentColor: Color
    }

    private let cards: [UrgencyInfo] = [
        .init(emoji: "🔴", title: "Now",   subtitle: "Needs you today",              accentColor: Color(hex: "E05252")),
        .init(emoji: "🟡", title: "Soon",  subtitle: "Needs progress this week",     accentColor: Color(hex: "F0A500")),
        .init(emoji: "🔵", title: "Later", subtitle: "Important, not urgent",        accentColor: Color(hex: "6B9FD4")),
    ]

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

                Text("Not everything deserves the same weight.")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                    .lineSpacing(4)
                    .padding(.bottom, 14)

                Text("Olana sorts your tasks by urgency — so you always know what's actually asking for you right now.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(6)
                    .padding(.bottom, 28)

                VStack(spacing: 10) {
                    ForEach(0..<cards.count, id: \.self) { i in
                        if cardsVisible[i] {
                            UrgencyOnboardingCard(
                                emoji: cards[i].emoji,
                                title: cards[i].title,
                                subtitle: cards[i].subtitle,
                                accentColor: cards[i].accentColor
                            )
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                        }
                    }
                }

                Spacer()

                OnboardingPrimaryButton(title: "Got it →") {
                    withAnimation(.easeInOut) { currentPage = 3 }
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            for i in cards.indices {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        cardsVisible[i] = true
                    }
                }
            }
        }
    }
}

// MARK: - Urgency Card

private struct UrgencyOnboardingCard: View {
    let emoji: String
    let title: String
    let subtitle: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            // Colour accent bar
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 0, topTrailingRadius: 0
                    )
                )

            HStack(spacing: 12) {
                Text(emoji)
                    .font(.body)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(hex: "1A0F00"))

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "5C3D1E"))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}
