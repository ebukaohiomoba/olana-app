//
//  OnboardingScreen5.swift
//  Olana
//
//  The Circle — friend placeholder avatars, two-button layout.
//

import SwiftUI

struct OnboardingScreen5: View {
    @Binding var currentPage: Int

    @State private var oluState: OluState = .idle
    @State private var avatarsVisible: [Bool] = [false, false, false]
    @State private var avatarOffsets: [CGFloat] = [20, 20, 20]

    private let avatarColors: [Color] = [
        Color(hex: "F4845F"),
        Color(hex: "5BA8A0"),
        Color(hex: "9B8EC4"),
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

                Text("Your circle keeps you moving.")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                    .lineSpacing(4)
                    .padding(.bottom, 14)

                Text("Add friends to share progress, send nudges, and celebrate wins. They won't see your schedule — just that you showed up.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(6)
                    .padding(.bottom, 36)

                // Avatar placeholders
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 20) {
                        ForEach(0..<3) { i in
                            VStack(spacing: 10) {
                                Circle()
                                    .fill(avatarColors[i])
                                    .frame(width: 64, height: 64)
                                    .shadow(color: avatarColors[i].opacity(0.3), radius: 12, x: 0, y: 0)

                                // Skeleton label
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(hex: "C4B5A5").opacity(0.6))
                                    .frame(width: 40, height: 8)
                            }
                            .opacity(avatarsVisible[i] ? 1 : 0)
                            .offset(y: avatarOffsets[i])
                        }
                    }

                    Text("and more...")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "C4B5A5"))
                        .padding(.leading, 16)
                }
                .padding(.bottom, 20)

                Text("You can add friends whenever you're ready.")
                    .font(.system(size: 13, weight: .regular))
                    .italic()
                    .foregroundStyle(Color(hex: "C4B5A5"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 36)

                Spacer()

                VStack(spacing: 12) {
                    OnboardingPrimaryButton(title: "Add someone →") {
                        withAnimation(.easeInOut) { currentPage = 5 }
                    }

                    Button {
                        withAnimation(.easeInOut) { currentPage = 5 }
                    } label: {
                        Text("I'll do this later")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(hex: "5C3D1E"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        avatarsVisible[i] = true
                        avatarOffsets[i] = 0
                    }
                }
            }
        }
    }
}
