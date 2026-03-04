//
//  CalendarSettingsView.swift
//  Olana
//
//  Four sections:
//  1. Connected Accounts — Apple Calendar + multiple Google accounts
//  2. Calendars — per-calendar enable toggle + urgency override
//  3. Home Screen — ImminentEventCard toggle + imminent window picker
//  4. Sync — last sync timestamp + manual sync button + inline error banner
//

import SwiftUI

struct CalendarSettingsView: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var dataStore: CalendarDataStore
    @ObservedObject private var googleOAuth = GoogleOAuthManager.shared

    @State private var googleAddError: String?
    @State private var showGoogleAddError = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {

                    // MARK: — Consent sheet hint (shown if not yet authorized)
                    if !calendarManager.isAuthorized {
                        CalendarPermissionBanner()
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    // MARK: — 1. Connected Accounts
                    // ── Apple ──────────────────────────────────────────
                    CalSettingsSection(title: "Apple Calendar") {
                        AppleCalendarConnectionRow()
                            .environmentObject(calendarManager)
                    }

                    // ── Google ─────────────────────────────────────────
                    CalSettingsSection(title: "Google Accounts") {
                        if googleOAuth.connectedAccounts.isEmpty {
                            // Empty state — shown before any account is added
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.white)
                                    Text("G")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(
                                            LinearGradient(colors: [.blue, .red, .yellow, .green],
                                                           startPoint: .topLeading,
                                                           endPoint: .bottomTrailing)
                                        )
                                }
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                                Text("No Google accounts connected")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                            Divider().padding(.leading, 66)
                        } else {
                            ForEach(googleOAuth.connectedAccounts) { account in
                                GoogleAccountRow(account: account) {
                                    calendarManager.removeGoogleAccount(id: account.id)
                                }
                                if account.id != googleOAuth.connectedAccounts.last?.id {
                                    Divider().padding(.leading, 66)
                                }
                            }
                            Divider().padding(.leading, 66)
                        }

                        // Add Google Account button
                        Button {
                            Task {
                                do {
                                    try await calendarManager.addGoogleAccount()
                                } catch GoogleOAuthError.cancelled {
                                    // user dismissed — not an error
                                } catch {
                                    googleAddError  = error.localizedDescription
                                    showGoogleAddError = true
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(theme.colors.ribbon)

                                Text("Add Google Account")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(theme.colors.ribbon)

                                Spacer()

                                if googleOAuth.isConnecting {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .disabled(googleOAuth.isConnecting)
                    }
                    .alert("Couldn't Connect Account", isPresented: $showGoogleAddError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(googleAddError ?? "An unknown error occurred.")
                    }

                    // MARK: — 2. Calendars
                    if !dataStore.userCalendars.isEmpty {
                        CalSettingsSection(title: "Calendars") {
                            ForEach(dataStore.userCalendars) { calendar in
                                CalendarRow(calendar: calendar, dataStore: dataStore)

                                if calendar.calendarID != dataStore.userCalendars.last?.calendarID {
                                    Divider().padding(.leading, 66)
                                }
                            }
                        }
                    }

                    // MARK: — 3. Home Screen
                    CalSettingsSection(title: "Home Screen") {
                        Toggle("Show day summary bar", isOn: Binding(
                            get: { dataStore.preferences.showDayContextBar },
                            set: { dataStore.setShowDayContextBar($0) }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: theme.colors.ribbon))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        Divider().padding(.leading, 16)

                        Toggle("Show imminent event card", isOn: Binding(
                            get: { dataStore.preferences.showImminentCard },
                            set: { dataStore.setShowImminentCard($0) }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: theme.colors.ribbon))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        Divider().padding(.leading, 16)

                        ImminentWindowPicker(preferences: dataStore.preferences) { minutes in
                            dataStore.setImminentWindow(minutes)
                        }
                    }

                    // MARK: — 4. Sync
                    CalSettingsSection(title: "Sync") {
                        VStack(spacing: 12) {
                            HStack {
                                Text(lastSyncText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)

                            if case .error(let msg) = calendarManager.syncState {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 16)
                            }

                            Button {
                                Task { await calendarManager.performFullSync() }
                            } label: {
                                HStack {
                                    if calendarManager.syncState == .syncing {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .padding(.trailing, 4)
                                    }
                                    Text(calendarManager.syncState == .syncing ? "Syncing…" : "Sync Now")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.colors.ribbon)
                                }
                            }
                            .disabled(calendarManager.syncState == .syncing)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        }
                    }

                    Spacer().frame(height: 40)
                }
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            Task {
                await calendarManager.refreshCalendarList()
                dataStore.load()
            }
        }
    }

    private var lastSyncText: String {
        guard let date = calendarManager.lastSyncDate else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Permission Banner

private struct CalendarPermissionBanner: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @State private var showingConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(theme.colors.ribbon)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect Apple Calendar")
                        .font(.headline)
                        .foregroundStyle(theme.colors.ink)
                    Text("See your full day in one place")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button("Connect my calendar") {
                showingConsent = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.colors.ribbon))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.colors.paper)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.cardBorder, lineWidth: 1))
        )
        .shadow(color: theme.colors.pillShadow, radius: 10, x: 0, y: 4)
        .sheet(isPresented: $showingConsent) {
            CalendarConsentSheet(onConnect: {
                Task { await calendarManager.requestAccess() }
                showingConsent = false
            }, onDismiss: {
                showingConsent = false
            })
            .presentationDetents([.fraction(0.55)])
        }
    }
}

// MARK: - Consent Sheet

struct CalendarConsentSheet: View {
    @Environment(\.olanaTheme) private var theme
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "calendar")
                .font(.system(size: 52))
                .foregroundStyle(theme.colors.ribbon)
                .padding(.top, 32)

            VStack(spacing: 10) {
                Text("See your full day, in one place.")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.colors.ink)
                    .multilineTextAlignment(.center)

                Text("Olana reads your calendar so you always know what's coming — without switching apps.\n\nYour calendar data stays on your device and is never shared with anyone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 12) {
                Button(action: onConnect) {
                    Text("Connect my calendar")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.colors.ribbon))
                }

                Button(action: onDismiss) {
                    Text("Not right now")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Calendar Row

private struct CalendarRow: View {
    @Environment(\.olanaTheme) private var theme
    let calendar: UserCalendar
    let dataStore: CalendarDataStore

    @State private var showingOverridePicker = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(calendar.displayColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.name)
                    .font(.body)
                    .foregroundStyle(theme.colors.ink)

                Text(calendar.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Urgency override menu
            Menu {
                Button("Auto-assign") {
                    dataStore.setUrgencyOverride(nil, forCalendarID: calendar.calendarID)
                }
                Divider()
                ForEach([EventUrgency.high, .medium, .low], id: \.self) { urgency in
                    Button("Always \(urgency.displayName)") {
                        dataStore.setUrgencyOverride(urgency, forCalendarID: calendar.calendarID)
                    }
                }
            } label: {
                Text(calendar.urgencyOverride?.displayName ?? "Auto")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.colors.ribbon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.colors.ribbon.opacity(0.1)))
            }

            Toggle("", isOn: Binding(
                get: { calendar.isEnabled },
                set: { dataStore.setEnabled($0, forCalendarID: calendar.calendarID) }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: theme.colors.ribbon))
            .scaleEffect(0.85)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Imminent Window Picker

private struct ImminentWindowPicker: View {
    @Environment(\.olanaTheme) private var theme
    let preferences: CalendarPreferences
    let onSelect: (Int) -> Void

    private let options = [30, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alert me when an event is")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                ForEach(options, id: \.self) { mins in
                    Button { onSelect(mins) } label: {
                        Text("\(mins) min")
                            .font(.caption.weight(preferences.imminentWindowMinutes == mins ? .bold : .regular))
                            .foregroundStyle(preferences.imminentWindowMinutes == mins ? .white : theme.colors.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(preferences.imminentWindowMinutes == mins
                                          ? theme.colors.ribbon
                                          : theme.colors.slate.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - Shared Settings Section

private struct CalSettingsSection<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.colors.ink)
                .padding(.horizontal)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.colors.cardBorder, lineWidth: 0.5))
            )
            .shadow(color: theme.colors.pillShadow, radius: 16, x: 0, y: 8)
            .padding(.horizontal)
        }
    }
}

