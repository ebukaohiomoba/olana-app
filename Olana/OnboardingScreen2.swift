//
//  OnboardingScreen2.swift
//  Olana
//
//  The Problem — left-aligned copy, Olu resting top-right.
//

import SwiftUI

struct OnboardingScreen2: View {
    @Binding var currentPage: Int

    @State private var oluState: OluState = .resting

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "F5EDD8")
                .ignoresSafeArea()

            // Olu — small, top right
            OnboardingOluView(state: $oluState, size: 58)
                .padding(.top, 56)
                .padding(.trailing, 24)

            // Main content
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 108)

                Text("Sound familiar?")
                    .font(.system(size: 11, weight: .light))
                    .kerning(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(hex: "F0A500"))
                    .padding(.bottom, 14)

                Text("Some days, everything feels equally urgent.")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "3B1F0A"))
                    .lineSpacing(4)
                    .padding(.bottom, 20)

                Text("Your calendar is full but you can't figure out where to start. You know what matters. You just need help seeing it.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(6)

                Spacer()

                Text("That's what Olanna is for.")
                    .font(.system(size: 15, weight: .regular))
                    .italic()
                    .foregroundStyle(Color(hex: "F0A500"))
                    .padding(.bottom, 24)

                OnboardingPrimaryButton(title: "That's exactly it →") {
                    withAnimation(.easeInOut) { currentPage = 2 }
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 28)
        }
    }
}
