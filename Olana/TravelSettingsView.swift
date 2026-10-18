//
//  TravelSettingsView.swift
//  Olana
//
//  Settings › Getting there (spec v3 §7.5, §7.7): home and work (found with
//  MapKit), work hours, the default way of getting around and the maps app.
//  The Prep / Get ready / Leave / Join toggles live in Notifications. Also
//  opened just in time from the card and the sheet.
//

import SwiftUI
import UIKit

struct TravelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.homePalette) private var c
    @State private var home = SavedPlaces.home
    @State private var work = SavedPlaces.work
    @State private var mode = ExecPreferences.defaultMode
    @State private var hasHours = ExecPreferences.workHours != nil
    @State private var hoursStart = Self.time(ExecPreferences.workHours?.startMinute ?? 9 * 60)
    @State private var hoursEnd = Self.time(ExecPreferences.workHours?.endMinute ?? 17 * 60)
    @State private var mapsApp = ExecPreferences.mapsApp
    @State private var searching: Which?
    @State private var query = ""
    @State private var results: [ResolvedPlace] = []
    @State private var busy = false
    @State private var notFound = false

    enum Which: String, Identifiable { case home, work; var id: String { rawValue } }

    var body: some View {
        Form {
            Section {
                placeRow("Home", home) { searching = .home }
                placeRow("Work", work) { searching = .work }
            } header: { Text("Where you leave from") } footer: {
                Text("Leave-by starts from your last event's place, then work during work hours, then home. Places stay on this iPhone; Apple Maps sees where you are and where you're going.")
            }

            Section("Work hours") {
                Toggle("Set work hours", isOn: $hasHours)
                if hasHours {
                    DatePicker("Start", selection: $hoursStart, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $hoursEnd, displayedComponents: .hourAndMinute)
                }
            }

            Section("Getting around") {
                Picker("Usually", selection: $mode) {
                    Text("Drive").tag(TravelMode.driving)
                    Text("Walk").tag(TravelMode.walking)
                    Text("Transit").tag(TravelMode.transit)
                }
                if UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!) {
                    Picker("Directions in", selection: $mapsApp) {
                        Text("Apple Maps").tag("apple")
                        Text("Google Maps").tag("google")
                    }
                }
            }
        }
        .listRowBackground(c.card)
        .settingsStyle()
        .navigationTitle("Getting there")
        .onChange(of: mode) { _, v in ExecPreferences.defaultMode = v; changed() }
        .onChange(of: mapsApp) { _, v in ExecPreferences.mapsApp = v }
        .onChange(of: hasHours) { _, _ in saveHours() }
        .onChange(of: hoursStart) { _, _ in saveHours() }
        .onChange(of: hoursEnd) { _, _ in saveHours() }
        .sheet(item: $searching) { which in search(which) }
    }

    private func placeRow(_ title: String, _ place: ResolvedPlace?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(c.text)
                Spacer()
                Text(place?.name ?? "Set").foregroundStyle(place == nil ? c.goldText : c.muted).lineLimit(1)
            }
        }
    }

    private func search(_ which: Which) -> some View {
        NavigationStack {
            List {
                HStack {
                    TextField(which == .home ? "Your home address" : "Your work address", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await find() } }
                    if busy { ProgressView() }
                }
                ForEach(results, id: \.self) { p in
                    Button {
                        if which == .home { SavedPlaces.home = p; home = p } else { SavedPlaces.work = p; work = p }
                        searching = nil
                        changed()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            if let a = p.address { Text(a).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if notFound { Text("Nothing found. Try the street and city.").foregroundStyle(.secondary) }
                if (which == .home ? home : work) != nil {
                    Button("Remove", role: .destructive) {
                        if which == .home { SavedPlaces.home = nil; home = nil } else { SavedPlaces.work = nil; work = nil }
                        searching = nil
                        changed()
                    }
                }
            }
            .navigationTitle(which == .home ? "Home" : "Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { searching = nil } } }
        }
        .onAppear { query = ""; results = []; notFound = false }
    }

    private func find() async {
        busy = true
        defer { busy = false }
        switch await PlaceResolver.shared.resolve(query) {
        case .resolved(let p): results = [p]; notFound = false
        case .choose(let ps): results = ps; notFound = false
        case .none, .personal: results = []; notFound = true
        }
    }

    private func saveHours() {
        let cal = Calendar.current
        func minutes(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
        ExecPreferences.workHours = hasHours ? WorkHours(startMinute: minutes(hoursStart), endMinute: minutes(hoursEnd)) : nil
        changed()
    }

    private func changed() {
        // Origins or mode may have changed: old ETAs no longer apply.
        ETAStore.shared.clear()
        NotificationEngine.shared.requestReplan("travel settings")
        Task { @MainActor in
            _ = await ExecRefresher.refreshETAs(store: AppServices.shared.store, horizon: 24 * 3600)
            NotificationEngine.shared.requestReplan("travel settings eta")
        }
    }

    private static func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
}
