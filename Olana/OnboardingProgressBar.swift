//
//  OnboardingProgressBar.swift
//  Olana
//
//  Thin amber progress bar shown at the top of every onboarding screen.
//

import SwiftUI

struct OnboardingProgressBar: View {
    let currentPage: Int
    let totalPages: Int

    private var progress: CGFloat {
        CGFloat(currentPage + 1) / CGFloat(totalPages)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 3)

                Capsule()
                    .fill(Color(hex: "F0A500"))
                    .frame(width: geo.size.width * progress, height: 3)
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
            }
        }
        .frame(height: 3)
    }
}
