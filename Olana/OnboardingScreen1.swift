//
//  OnboardingScreen1.swift
//  Olana
//
//  Welcome screen — deep warm brown, large centred Olu, tap-to-advance.
//

import SwiftUI

struct OnboardingScreen1: View {
    @Binding var currentPage: Int

    @State private var oluState: OluState = .celebrate
    @State private var bodyOpacity: Double = 0
    @State private var hintOpacity: Double = 0

    var body: some View {
        ZStack {
            Color(hex: "3B1F0A")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                OnboardingOluView(state: $oluState, size: 120)
                    .padding(.bottom, 36)

                VStack(spacing: 10) {
                    Text("Olanna")
                        .font(.system(size: 44, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    Text("Clear enough to move.")
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(.white.opacity(0.7))

                    Text("Meet Olu. She'll keep you company.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 10)
                        .opacity(bodyOpacity)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

                Spacer()

                Text("Tap anywhere to continue")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                    .opacity(hintOpacity)
                    .padding(.bottom, 64)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut) { currentPage = 1 }
        }
        .onAppear {
            // Settle Olu + reveal body text after 2.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                oluState = .resting
                withAnimation(.easeIn(duration: 0.5)) { bodyOpacity = 1 }
            }
            // Reveal tap hint at 3s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeIn(duration: 0.6)) { hintOpacity = 1 }
            }
        }
    }
}
