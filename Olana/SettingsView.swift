//
//  SettingsView.swift
//  Olana
//
//  Settings, in home's palette: Notifications, Getting there and Calendars;
//  Olana Plus; Appearance; Privacy; About. Notifications is one screen
//  (NotificationsSettingsView), organized around what Olana sends, not
//  urgency tiers: urgency decides which events get help, in the background.
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.homePalette) private var c
    @ThemePreference private var themeVariant: ThemeVariant
    @ObservedObject private var engine = NotificationEngine.shared
    @ObservedObject private var plus = PlusStore.shared
    @ObservedObject private var googleOAuth = GoogleOAuthManager.shared
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var calendarDataStore: CalendarDataStore
    @EnvironmentObject private var store: EventStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var privacyAction: PrivacyAction?
    @State private var privacyDone: String?
    @State private var shareUsage = OlanaAnalytics.sharing

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { NotificationsSettingsView() } label: {
                        row("Notifications", "bell", value: notificationsValue)
                    }
                    NavigationLink { TravelSettingsView() } label: {
                        row("Getting there", "figure.walk", value: SavedPlaces.home == nil ? "Set home" : nil)
                    }
                    NavigationLink {
                        CalendarSettingsView()
                            .environmentObject(calendarManager)
                            .environmentObject(calendarDataStore)
                    } label: {
                        row("Calendars", "calendar", value: calendarsValue)
                    }
                }
                .listRowBackground(c.card)

                Section {
                    Button { plus.showPaywall = true } label: {
                        row("Olana Plus", "sparkle", value: plusValue)
                    }
                    .foregroundStyle(c.text)
                }
                .listRowBackground(c.card)

                Section("Appearance") {
                    Picker("Appearance", selection: $themeVariant) {
                        ForEach(ThemeVariant.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .listRowBackground(c.card)

                Section {
                    Toggle("Share anonymous usage", isOn: $shareUsage)
                        .onChange(of: shareUsage) { _, on in OlanaAnalytics.setSharing(on) }
                    ForEach(PrivacyAction.allCases, id: \.self) { action in
                        Button(role: .destructive) { privacyAction = action } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title)
                                Text(action.subtitle).font(.caption).foregroundStyle(c.muted)
                            }
                        }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Usage is counts, like how often prep alerts are used. Never titles, notes, places or links. Everything Olana works out stays on this iPhone.")
                }
                .listRowBackground(c.card)

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    #if DEBUG
                    NavigationLink("Developer") { DeveloperSettingsView() }
                    #endif
                }
                .listRowBackground(c.card)
            }
            .settingsStyle()
            .navigationTitle("Settings")
            .confirmationDialog(privacyAction?.title ?? "", isPresented: Binding(
                get: { privacyAction != nil }, set: { if !$0 { privacyAction = nil } }),
                titleVisibility: .visible) {
                if let a = privacyAction {
                    Button(a.confirm, role: .destructive) { perform(a) }
                }
            } message: {
                Text(privacyAction?.warning ?? "")
            }
            .alert(privacyDone ?? "", isPresented: Binding(get: { privacyDone != nil },
                                                         set: { if !$0 { privacyDone = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task { await engine.checkAuthorizationStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await engine.checkAuthorizationStatus() } }
            }
        }
    }

    private func row(_ title: String, _ icon: String, value: String?) -> some View {
        LabeledContent {
            if let value { Text(value).foregroundStyle(c.muted) }
        } label: {
            Label { Text(title).foregroundStyle(c.text) } icon: {
                Image(systemName: icon).foregroundStyle(c.goldText)
            }
        }
    }

    // MARK: Values

    private var notificationsValue: String {
        switch engine.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Not set up"
        }
    }

    private var calendarsValue: String {
        var names: [String] = []
        if calendarManager.isAuthorized { names.append("Apple") }
        if !googleOAuth.connectedAccounts.isEmpty { names.append("Google") }
        return names.isEmpty ? "Not connected" : names.joined(separator: ", ")
    }

    private var plusValue: String {
        if !plus.gate.canSellPlus { return "Needs Apple Intelligence" }
        if plus.state.purchased || plus.state.fakeDoorAt != nil { return "On" }
        if plus.inPreview { return "Preview · \(plus.momentsLeft) left" }
        return "See what's included"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func perform(_ a: PrivacyAction) {
        switch a {
        case .places: SavedPlaces.home = nil; SavedPlaces.work = nil; privacyDone = "Saved places deleted"
        case .overrides: store.deleteAllOverrides(); privacyDone = "Event and series settings deleted"
        case .caches: AssistCache.shared.clear(); EventProgressStore.shared.clear(); privacyDone = "Caches cleared"
        }
    }
}

// MARK: - Notifications (one screen)

/// Everything Olana sends, on one screen, organized by what it does: the
/// reminder every event gets (free), help getting it done (Plus, Join free),
/// alarms, quiet hours. An example event at the top shows what each switch
/// changes. Urgency isn't a setting: it decides which events get help.
struct NotificationsSettingsView: View {
    @Environment(\.homePalette) private var c
    @Environment(\.openURL) private var openURL
    @ObservedObject private var settings = NotificationSettings.shared
    @ObservedObject private var engine = NotificationEngine.shared
    @ObservedObject private var plus = PlusStore.shared
    @ObservedObject private var alarmKit = AlarmKitManager.shared

    @State private var prep = ExecPreferences.prepAlerts
    @State private var getReady = ExecPreferences.getReadyAlerts
    @State private var leave = ExecPreferences.leaveAlerts
    @State private var join = ExecPreferences.joinAlerts

    var body: some View {
        Form {
            permissionSection

            Section {
                NotificationExample(lead: settings.reminderLeadMinutes, prep: prep, getReady: getReady, leave: leave)
            } header: {
                Text("What Olana sends")
            } footer: {
                Text("An example: an important meeting across town at 3:00. It changes as you change the settings below.")
            }
            .listRowBackground(c.card)

            Section {
                Picker("Remind me before events", selection: $settings.reminderLeadMinutes) {
                    ForEach(ReminderSchedule.leadOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Every event gets one. Important events also get one the evening before and an hour before.")
            }
            .listRowBackground(c.card)

            Section {
                helpToggle("Prep", "Start prepping for Client review", $prep) { ExecPreferences.prepAlerts = $0 }
                helpToggle("Get ready", "Get ready · leave at 2:31", $getReady) { ExecPreferences.getReadyAlerts = $0 }
                helpToggle("Leave", "Leave now · 14 min walk", $leave) { ExecPreferences.leaveAlerts = $0 }
                helpToggle("Join", "Client sync starts in 1 min", $join) { ExecPreferences.joinAlerts = $0 }
            } header: {
                HStack {
                    Text("Help getting it done")
                    Spacer()
                    if !plus.hasPlus { Text("Plus").foregroundStyle(c.goldText) }
                }
            } footer: {
                Text(plus.hasPlus
                     ? "Only for events that matter, timed from your prep and travel."
                     : "Only for events that matter. Join is free; Prep, Get ready and Leave are part of Olana Plus.")
            }
            .listRowBackground(c.card)

            Section {
                Toggle("Ring for what can't be missed", isOn: alarms)
                if settings.urgentAlarmsEnabled, alarmKit.authorizationState == .denied {
                    Button("Alarms are off in iOS Settings") { openSettings() }
                }
            } header: {
                Text("Alarms")
            } footer: {
                Text("A full-screen alarm, even on silent, when it's time to start. Only for events with serious consequences.")
            }
            .listRowBackground(c.card)

            Section {
                Toggle("Quiet hours", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    DatePicker("From", selection: $settings.quietHoursStart, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $settings.quietHoursEnd, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Reminders and prep alerts wait until quiet hours end. Leave and join alerts for important events, and alarms, still come through.")
            }
            .listRowBackground(c.card)

            Section {
                Toggle("Break through Focus for important events", isOn: $settings.allowTimeSensitiveHigh)
                Toggle("Countdown on the Lock Screen", isOn: $settings.countdownTimerEnabled)
                if settings.countdownTimerEnabled {
                    Picker("Starts", selection: $settings.liveActivityLeadMinutes) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min before").tag($0) }
                    }
                }
                Toggle("Sound", isOn: $settings.enableAudioReminders)
            } header: {
                Text("More")
            } footer: {
                Text("The countdown is for important events.")
            }
            .listRowBackground(c.card)
        }
        .settingsStyle()
        .navigationTitle("Notifications")
        .onChange(of: settings.reminderLeadMinutes) { replan() }
        .onChange(of: settings.quietHoursEnabled) { replan() }
        .onChange(of: settings.quietHoursStart) { replan() }
        .onChange(of: settings.quietHoursEnd) { replan() }
        .onChange(of: settings.allowTimeSensitiveHigh) { replan() }
        .onChange(of: settings.enableAudioReminders) { replan() }
        .task { await engine.checkAuthorizationStatus(); alarmKit.refreshState() }
    }

    @ViewBuilder private var permissionSection: some View {
        switch engine.authorizationStatus {
        case .denied:
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are off for Olana").font(.headline).foregroundStyle(c.text)
                    Text("Olana can't remind you until they're on in iOS Settings.")
                        .font(.subheadline).foregroundStyle(c.muted)
                }
                Button("Open Settings") { openSettings() }
            }
            .listRowBackground(c.card)
        case .notDetermined:
            Section {
                Button("Turn on notifications") {
                    Task {
                        if await engine.requestAuthorization() { engine.requestReplan("notifications allowed") }
                    }
                }
            }
            .listRowBackground(c.card)
        default:
            EmptyView()
        }
    }

    private func helpToggle(_ title: String, _ example: String, _ isOn: Binding<Bool>,
                            save: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(c.text)
                Text("“\(example)”").font(.caption).foregroundStyle(c.muted)
            }
        }
        .onChange(of: isOn.wrappedValue) { _, v in
            save(v)
            replan()
        }
    }

    /// The permission is asked the first time it's turned on.
    private var alarms: Binding<Bool> {
        Binding(get: { settings.urgentAlarmsEnabled }, set: { on in
            settings.urgentAlarmsEnabled = on
            if on, alarmKit.authorizationState == .notDetermined {
                Task { await alarmKit.requestAuthorization(); replan() }
            } else {
                replan()
            }
        })
    }

    private func replan() { NotificationEngine.shared.requestReplan("notification settings") }

    private func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
    }
}

// MARK: - The example

/// "What Olana sends" for one important in-person meeting at 3:00 with an
/// hour of prep and a 14 min walk. Reminder times come from ReminderSchedule,
/// the same code the planner uses; lines for switched-off alerts fade.
private struct NotificationExample: View {
    let lead: Int
    let prep: Bool, getReady: Bool, leave: Bool
    @Environment(\.homePalette) private var c

    private struct Line: Identifiable {
        let id = UUID()
        let minutesFrom3: Int
        let time: String
        let text: String
        let on: Bool
    }

    private var lines: [Line] {
        let cal = Calendar.current
        let three = cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        func at(_ minutesBefore: Int) -> String { ExecFormat.clock(three.addingTimeInterval(-Double(minutesBefore) * 60), cal) }
        var out = [
            Line(minutesFrom3: -90, time: at(90), text: "Start prepping for Client review", on: prep),
            Line(minutesFrom3: -39, time: at(39), text: "Get ready · leave at 2:31", on: getReady),
            Line(minutesFrom3: -29, time: at(29), text: "Leave now · 14 min walk", on: leave),
        ]
        for m in ReminderSchedule.moments(important: true, lead: lead) {
            switch m {
            case .before(let mins):
                out.append(Line(minutesFrom3: -mins, time: at(mins), text: "Client review at 3:00", on: true))
            case .clock(let h, _, _):
                out.append(Line(minutesFrom3: -(24 * 60), time: "\(h > 12 ? h - 12 : h):00 PM",
                                text: "Tomorrow at 3:00: Client review", on: true))
            }
        }
        return out.sorted { $0.minutesFrom3 < $1.minutesFrom3 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.time)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(c.muted)
                        .frame(width: 92, alignment: .leading)
                    Text(line.text)
                        .font(.subheadline)
                        .foregroundStyle(c.text)
                        .strikethrough(!line.on, color: c.muted)
                }
                .opacity(line.on ? 1 : 0.4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(line.time): \(line.text)\(line.on ? "" : ", off")")
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: [prep, getReady, leave])
    }
}

// MARK: - Shared

/// Settings › Privacy (PRD v3 §3.16).
enum PrivacyAction: CaseIterable {
    case places, overrides, caches

    var title: String {
        switch self {
        case .places: return "Delete saved places"
        case .overrides: return "Delete event and series settings"
        case .caches: return "Clear caches"
        }
    }
    var subtitle: String {
        switch self {
        case .places: return "Home and work"
        case .overrides: return "Steps, bring lists and help levels you set"
        case .caches: return "Olana's on-device suggestions and prep progress"
        }
    }
    var confirm: String { self == .caches ? "Clear" : "Delete" }
    var warning: String {
        switch self {
        case .places: return "Leave-by times will need home and work again."
        case .overrides: return "This removes them on all your devices. Your events stay."
        case .caches: return "Suggestions are worked out again on this phone, which takes a little time."
        }
    }
}

extension View {
    /// Settings screens in home's palette: grouped rows on the page color.
    func settingsStyle() -> some View { modifier(SettingsStyle()) }
}

private struct SettingsStyle: ViewModifier {
    @Environment(\.homePalette) private var c
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(c.bg.ignoresSafeArea())
            .tint(c.goldText)
    }
}
