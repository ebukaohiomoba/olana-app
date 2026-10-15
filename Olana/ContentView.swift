//
//  ContentView.swift
//  Olana
//
//  Tabs with Olana's own bar (OlanaTabBar): the system bar is hidden on every
//  tab, and the raised + replaces home's floating add button.
//

import SwiftUI

struct ContentView: View {
    // Shared with the background run (AppServices).
    @ObservedObject private var store             = AppServices.shared.store
    @ObservedObject private var calendarManager   = AppServices.shared.calendarManager
    @ObservedObject private var calendarDataStore = AppServices.shared.calendarDataStore
    @State private var selectedTab: OlanaTab = .home
    @State private var showingAdd = false

    private let tabMap: [OlanaTab: OlanaAnalytics.AppTab] = [
        .home: .home, .calendar: .calendar, .circles: .friends, .settings: .settings
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
                .modifier(CustomTabBarSpace())
                .tag(OlanaTab.home)

            CalendarView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .modifier(CustomTabBarSpace())
                .tag(OlanaTab.calendar)

            FriendsView()
                .modifier(CustomTabBarSpace())
                .tag(OlanaTab.circles)

            SettingsView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
                .modifier(CustomTabBarSpace())
                .tag(OlanaTab.settings)
        }
        .overlay(alignment: .bottom) {
            OlanaTabBar(selection: $selectedTab) { showingAdd = true }
                .padding(.bottom, 4)
                .ignoresSafeArea(.keyboard)
        }
        .homePalette()
        .sheet(isPresented: $showingAdd) {
            AddEventView()
                .environmentObject(store)
                .presentationDetents([.fraction(0.75), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .onChange(of: selectedTab) { _, newTab in
            if let tab = tabMap[newTab] {
                OlanaAnalytics.tabViewed(tab)
            }
        }
        .onAppear {
            OlanaAnalytics.tabViewed(.home)
        }
    }
}

/// Hides the system tab bar and reserves room for OlanaTabBar, so scrolling
/// content ends above it rather than under it.
private struct CustomTabBarSpace: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: OlanaTabBar.height - 20)
            }
    }
}

#Preview {
    ContentView()
}
