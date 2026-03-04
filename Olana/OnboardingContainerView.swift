//
//  OnboardingContainerView.swift
//  Olana
//
//  Root container for the 7-screen onboarding flow.
//  Owns the amber progress bar and the EventStore used to save the first task.
//

import SwiftUI

struct OnboardingContainerView: View {
    @State private var currentPage: Int = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // EventStore backed by Persistence.shared.container — same store as ContentView.
    // The task saved here will be visible on HomeView immediately after onboarding ends.
    @StateObject private var store = EventStore()

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $currentPage) {

                OnboardingScreen1(currentPage: $currentPage)
                    .tag(0)

                OnboardingScreen2(currentPage: $currentPage)
                    .tag(1)

                OnboardingScreen3(currentPage: $currentPage)
                    .tag(2)

                OnboardingScreen4(currentPage: $currentPage)
                    .tag(3)

                OnboardingScreen5(currentPage: $currentPage)
                    .tag(4)

                OnboardingCalendarScreen(currentPage: $currentPage)
                    .tag(5)

                OnboardingScreen6(onComplete: {
                    hasCompletedOnboarding = true
                })
                .environmentObject(store)
                .tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Progress bar — floats above all screens
            OnboardingProgressBar(currentPage: currentPage, totalPages: 7)
                .padding(.top, 56)
                .padding(.horizontal, 24)
        }
    }
}
