//
//  OnboardingOluView.swift
//  Olana
//
//  Thin wrapper around OluView for onboarding positioning.
//  Large (120pt) and centred on screen 1; small (58pt) top-right on screens 2–6.
//

import SwiftUI

struct OnboardingOluView: View {
    @Binding var state: OluState
    var size: CGFloat = 58
    var onCelebrationComplete: (() -> Void)? = nil

    var body: some View {
        OluView(
            state: $state,
            size: size,
            onCelebrationComplete: onCelebrationComplete
        )
    }
}
