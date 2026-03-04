//
//  ContentView.swift
//  Olana
//
//  UPDATED: Removed showingProfile binding (now using NavigationLink)
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store           = EventStore()
    @StateObject private var calendarManager = CalendarIntegrationManager()
    @StateObject private var calendarDataStore = CalendarDataStore()
    @State private var selectedTab = 0

    private let tabMap: [Int: OlanaAnalytics.AppTab] = [
        0: .home, 1: .calendar, 2: .friends, 3: .settings
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            CalendarView()
                .environmentObject(store)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(1)

            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.3.fill") }
                .tag(2)

            SettingsView()
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .onChange(of: selectedTab) { _, newTab in
            if let tab = tabMap[newTab] {
                OlanaAnalytics.tabViewed(tab)
            }
        }
        .onAppear {
            OlanaAnalytics.tabViewed(.home)
            // Wire calendar manager to its dependencies
            calendarManager.setup(dataStore: calendarDataStore, eventStore: store)
        }
        .onDisappear {
            calendarManager.teardown()
        }
    }
}

#Preview {
    ContentView()
}
