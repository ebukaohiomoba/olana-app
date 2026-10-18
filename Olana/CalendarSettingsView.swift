//
//  CalendarSettingsView.swift
//  Olana
//
//  Settings › Calendars, in home's palette: the accounts Olana reads (Apple
//  Calendar, Google), which calendars count and how important each one is,
//  and sync.
//

import SwiftUI
import EventKit

struct CalendarSettingsView: View {
    @Environment(\.homePalette) private var c
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var dataStore: CalendarDataStore
    @ObservedObject private var googleOAuth = GoogleOAuthManager.shared

    @State private var googleAddError: String?
    @State private var disconnecting: GoogleOAuthAccount?

    var body: some View {
        Form {
            Section {
                appleRow
                ForEach(googleOAuth.connectedAccounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google").foregroundStyle(c.text)
                            Text(account.email).font(.caption).foregroundStyle(c.muted).lineLimit(1)
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive) { disconnecting = account }
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                    }
                }
                Button {
                    Task {
                        do { try await calendarManager.addGoogleAccount() }
                        catch GoogleOAuthError.cancelled {}
                        catch { googleAddError = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Text(googleOAuth.connectedAccounts.isEmpty ? "Connect Google Calendar" : "Add another Google account")
                        Spacer()
                        if googleOAuth.isConnecting { ProgressView() }
                    }
                }
                .disabled(googleOAuth.isConnecting)
            } header: {
                Text("Accounts")
            } footer: {
                Text("Outlook works when your account is added to iOS Calendar. Olana reads your events and never changes them.")
            }
            .listRowBackground(c.card)

            if !dataStore.userCalendars.isEmpty {
                Section {
                    ForEach(dataStore.userCalendars) { calendar in
                        CalendarToggleRow(calendar: calendar, dataStore: dataStore)
                    }
                } header: {
                    Text("Calendars")
                } footer: {
                    Text("Turn off calendars Olana should ignore. Importance is decided per event unless you set it for a whole calendar.")
                }
                .listRowBackground(c.card)
            }

            Section("Sync") {
                LabeledContent("Last synced", value: lastSyncText)
                if case .error(let msg) = calendarManager.syncState {
                    Text(msg).font(.caption).foregroundStyle(c.crit)
                }
                Button {
                    Task { await calendarManager.performFullSync() }
                } label: {
                    HStack {
                        Text(calendarManager.syncState == .syncing ? "Syncing…" : "Sync now")
                        Spacer()
                        if calendarManager.syncState == .syncing { ProgressView() }
                    }
                }
                .disabled(calendarManager.syncState == .syncing)
            }
            .listRowBackground(c.card)
        }
        .settingsStyle()
        .navigationTitle("Calendars")
        .alert("Couldn't connect Google", isPresented: Binding(get: { googleAddError != nil },
                                                              set: { if !$0 { googleAddError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(googleAddError ?? "")
        }
        .confirmationDialog("Disconnect \(disconnecting?.email ?? "")?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let a = disconnecting { calendarManager.removeGoogleAccount(id: a.id) }
            }
        } message: {
            Text("Its events leave Olana. Your Google Calendar isn't changed.")
        }
        .task {
            await calendarManager.refreshCalendarList()
            dataStore.load()
        }
    }

    @ViewBuilder private var appleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Calendar").foregroundStyle(c.text)
                Text(appleStatus).font(.caption).foregroundStyle(c.muted)
            }
            Spacer()
            switch calendarManager.authorizationStatus {
            case .fullAccess, .authorized:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(c.synced)
                    .accessibilityLabel("Connected")
            case .denied, .restricted:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderless)
            default:
                Button("Connect") { Task { await calendarManager.requestAccess() } }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var appleStatus: String {
        switch calendarManager.authorizationStatus {
        case .fullAccess, .authorized: return "Connected"
        case .denied, .restricted: return "Access is off in iOS Settings"
        default: return "Not connected"
        }
    }

    private var lastSyncText: String {
        guard let date = calendarManager.lastSyncDate else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Calendar row

/// One calendar: on or off for Olana, and its importance (Auto, or always
/// one level, for a calendar like "Court dates").
private struct CalendarToggleRow: View {
    @Environment(\.homePalette) private var c
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    let calendar: UserCalendar
    let dataStore: CalendarDataStore

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(calendar.displayColor).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { calendar.isEnabled },
                                 set: { dataStore.setEnabled($0, forCalendarID: calendar.calendarID) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendar.name).foregroundStyle(c.text)
                    Menu {
                        Button("Auto") { setOverride(nil) }
                        ForEach([EventUrgency.high, .medium, .low], id: \.self) { u in
                            Button("Always \(u.displayName)") { setOverride(u) }
                        }
                    } label: {
                        Text("\(calendar.source.displayName) · \(calendar.urgencyOverride.map { "Always \($0.displayName)" } ?? "Auto")")
                            .font(.caption).foregroundStyle(c.muted)
                    }
                    .accessibilityLabel("Importance: \(calendar.urgencyOverride?.displayName ?? "Auto")")
                }
            }
        }
    }

    /// Re-syncs so events already imported pick the change up now.
    private func setOverride(_ urgency: EventUrgency?) {
        dataStore.setUrgencyOverride(urgency, forCalendarID: calendar.calendarID)
        Task { await calendarManager.performFullSync() }
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

