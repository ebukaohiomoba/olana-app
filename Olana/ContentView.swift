//
//  ContentView.swift
//  Olana
//
//  The system tab bar (OlanaTabView): four screens and Add, the trailing
//  glass button that opens the add sheet.
//

import SwiftUI

struct ContentView: View {
    // Shared with the background run (AppServices).
    @ObservedObject private var store             = AppServices.shared.store
    @ObservedObject private var calendarManager   = AppServices.shared.calendarManager
    @ObservedObject private var calendarDataStore = AppServices.shared.calendarDataStore
    @State private var selectedTab: OlanaTab = .home
    @State private var showingAdd = false
    @ObservedObject private var plus = PlusStore.shared
    @ObservedObject private var ai = AIAssistant.shared
    /// The Apple Intelligence gate is shown once per state (PRD v3 §1.11 step 2).
    @AppStorage("olanaGateSeen_v1") private var gateSeen = ""

    private let tabMap: [OlanaTab: OlanaAnalytics.AppTab] = [
        .home: .home, .calendar: .calendar, .settings: .settings
    ]

    var body: some View {
        OlanaTabView(selection: $selectedTab, onAdd: { showingAdd = true }) {
            HomeView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
        } calendar: {
            CalendarView()
                .environmentObject(store)
                .environmentObject(calendarManager)
        } settings: {
            SettingsView()
                .environmentObject(store)
                .environmentObject(calendarManager)
                .environmentObject(calendarDataStore)
        }
        .homePalette()
        .sheet(isPresented: $showingAdd) {
            // AddEventView sizes its own sheet to its content.
            AddEventView()
                .environmentObject(store)
                .homePalette()
        }
        .sheet(isPresented: $plus.showPaywall) { PlusPaywallView().homePalette() }
        .sheet(isPresented: $plus.showSummary, onDismiss: { plus.markSummaryShown() }) {
            // After the 5th moment: what Plus did, with the price (PRD v6 §1.10).
            PlusPaywallView().homePalette()
        }
        .fullScreenCover(isPresented: Binding(
            get: { plus.gate != .available && gateSeen != "\(plus.gate)" },
            set: { if !$0 { gateSeen = "\(plus.gate)" } })) {
            IntelligenceGateView(gate: plus.gate) { gateSeen = "\(plus.gate)" }.homePalette()
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

#Preview {
    ContentView()
}
