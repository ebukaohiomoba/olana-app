//
//  OnboardingPrimaryButton.swift
//  Olana
//
//  Full-width amber CTA button reused across onboarding screens.
//

import SwiftUI

struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: "F0A500"))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
    }
}
