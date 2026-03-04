//
//  SettingsView.swift
//  Olana
//
//  Created by Chukwuebuka Ohiomoba on 9/23/25.
//
//  UPDATED: Notifications as navigation item leading to dedicated settings
//

import SwiftUI
import UserNotifications
import ActivityKit
import FirebaseAuth

struct SettingsView: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var authManager: AuthenticationManager
    @ThemePreference private var themeVariant: ThemeVariant
    @AppStorage("literaryFlavor") private var literaryFlavor: Bool = true
    @State private var isViewVisible = false

    // Notification state
    @ObservedObject private var notificationEngine = NotificationEngine.shared

    // Calendar integration
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var calendarDataStore: CalendarDataStore

    // Navigation
    @State private var showingNotificationSettings = false
    @State private var showingCalendarSettings = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Profile Card
                        ProfileCard(
                            displayName: authManager.appUser?.displayName ?? authManager.currentUser?.displayName ?? "—",
                            email: authManager.appUser?.email ?? authManager.currentUser?.email ?? "—",
                            profileEmoji: authManager.appUser?.profileEmoji ?? "👤"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        // MARK: - General Settings
                        SettingsSection(title: "General Settings") {
                            // Notifications Navigation
                            SettingsNavigationRow(
                                icon: "bell.fill",
                                iconColor: theme.colors.ribbon,
                                title: "Notifications",
                                subtitle: notificationEngine.isAuthorized ? "Enabled" : "Tap to enable",
                                action: { showingNotificationSettings = true }
                            )
                        }
                        
                        // MARK: - Appearance
                        SettingsSection(title: "Appearance") {
                            ThemePickerView(selectedTheme: $themeVariant)
                            
                            SettingsNavigationRow(
                                icon: "globe",
                                iconColor: theme.colors.ribbon,
                                title: "Language",
                                action: {}
                            )
                        }
                        
                        // MARK: - Account & Security
                        SettingsSection(title: "Account & Security") {
                            SettingsNavigationRow(
                                icon: "envelope.fill",
                                iconColor: .cyan,
                                title: "Change Email",
                                action: {}
                            )
                            
                            SettingsNavigationRow(
                                icon: "lock.fill",
                                iconColor: theme.colors.ribbon,
                                title: "Change Password",
                                action: {}
                            )
                            
                            SettingsNavigationRow(
                                icon: "shield.fill",
                                iconColor: .blue,
                                title: "Privacy Settings",
                                action: {}
                            )
                        }
                        
                        // MARK: - Calendar Integrations
                        SettingsSection(title: "Calendar Integrations") {
                            SettingsNavigationRow(
                                icon: "calendar",
                                iconColor: .red,
                                title: "Calendar",
                                subtitle: calendarManager.isAuthorized ? "Apple Calendar connected" : "Connect your calendar",
                                action: { showingCalendarSettings = true }
                            )
                        }
                        
                        // MARK: - About Olana
                        SettingsSection(title: "About Olana") {
                            SettingsNavigationRow(
                                icon: "doc.text.fill",
                                iconColor: theme.colors.ribbon,
                                title: "Terms of Service",
                                action: {}
                            )
                            
                            SettingsNavigationRow(
                                icon: "hand.raised.fill",
                                iconColor: theme.colors.ribbon,
                                title: "Privacy Policy",
                                action: {}
                            )
                        }
                        
                        // Log Out Button
                        Button {
                            try? authManager.signOut()
                        } label: {
                            Text("Log Out")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    LinearGradient(
                                        colors: [Color.red.opacity(0.8), Color.red],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: Color.red.opacity(0.4), radius: 12, x: 0, y: 6)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)

                        #if DEBUG
                        SettingsSection(title: "Developer") {
                            Button {
                                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.orange.opacity(0.12)))

                                    Text("Reset Onboarding")
                                        .font(.body)
                                        .foregroundStyle(theme.colors.ink)

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 66)

                            // MARK: Critical (high) — timeSensitive + ringtone sound
                            Button {
                                let content = UNMutableNotificationContent()
                                content.title              = "Test Event (Critical)"
                                content.subtitle           = "in 5 seconds"
                                content.body               = "Starts at \(Date(timeIntervalSinceNow: 5).formatted(date: .omitted, time: .shortened)). Don't miss this one."
                                content.sound              = .default
                                content.categoryIdentifier = "EVENT_HIGH"
                                content.interruptionLevel  = .timeSensitive
                                content.userInfo           = ["eventId": UUID().uuidString, "urgency": 2, "notificationIndex": 0]
                                let request = UNNotificationRequest(
                                    identifier: "debug-critical-\(UUID().uuidString)",
                                    content: content,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                                )
                                UNUserNotificationCenter.current().add(request) { error in
                                    if let error { print("❌ Debug notification failed: \(error)") }
                                    else { print("✅ Critical test scheduled — fires in 5s") }
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "bell.badge.fill")
                                        .font(.title3)
                                        .foregroundStyle(.red)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.red.opacity(0.12)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Test Critical Notification")
                                            .font(.body)
                                            .foregroundStyle(theme.colors.ink)
                                        Text("Breaks Focus mode · timeSensitive · fires in 5s")
                                            .font(.caption)
                                            .foregroundStyle(theme.colors.slate)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 66)

                            // MARK: Soon (medium) — active + default sound
                            Button {
                                let content = UNMutableNotificationContent()
                                content.title              = "Test Event (Soon)"
                                content.subtitle           = "in 5 seconds"
                                content.body               = "Starts at \(Date(timeIntervalSinceNow: 5).formatted(date: .omitted, time: .shortened)). Worth a heads up."
                                content.sound              = .default
                                content.categoryIdentifier = "EVENT_MEDIUM"
                                content.interruptionLevel  = .active
                                content.userInfo           = ["eventId": UUID().uuidString, "urgency": 1, "notificationIndex": 0]
                                let request = UNNotificationRequest(
                                    identifier: "debug-soon-\(UUID().uuidString)",
                                    content: content,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                                )
                                UNUserNotificationCenter.current().add(request) { error in
                                    if let error { print("❌ Debug notification failed: \(error)") }
                                    else { print("✅ Soon test scheduled — fires in 5s") }
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "bell.fill")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.orange.opacity(0.12)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Test Soon Notification")
                                            .font(.body)
                                            .foregroundStyle(theme.colors.ink)
                                        Text("Default sound · respects Focus · fires in 5s")
                                            .font(.caption)
                                            .foregroundStyle(theme.colors.slate)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 66)

                            // MARK: Later (low) — passive, no sound, lands silently in Notification Center
                            Button {
                                let content = UNMutableNotificationContent()
                                content.title              = "Test Event (Later)"
                                content.subtitle           = "in 5 seconds"
                                content.body               = "Starts at \(Date(timeIntervalSinceNow: 5).formatted(date: .omitted, time: .shortened)). It's on your list."
                                content.sound              = nil
                                content.categoryIdentifier = "EVENT_LOW"
                                content.interruptionLevel  = .passive
                                content.userInfo           = ["eventId": UUID().uuidString, "urgency": 0, "notificationIndex": 0]
                                let request = UNNotificationRequest(
                                    identifier: "debug-later-\(UUID().uuidString)",
                                    content: content,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                                )
                                UNUserNotificationCenter.current().add(request) { error in
                                    if let error { print("❌ Debug notification failed: \(error)") }
                                    else { print("✅ Later test scheduled — fires in 5s (check Notification Center, no banner)") }
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "bell.slash.fill")
                                        .font(.title3)
                                        .foregroundStyle(.gray)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.gray.opacity(0.12)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Test Later Notification")
                                            .font(.body)
                                            .foregroundStyle(theme.colors.ink)
                                        Text("No sound · silent banner · fires in 5s")
                                            .font(.caption)
                                            .foregroundStyle(theme.colors.slate)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 66)

                            // MARK: Live Activity test — starts a mock Critical event 5 min from now
                            Button {
                                Task { await NotificationEngine.shared.debugStartTestLiveActivity() }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "livephoto")
                                        .font(.title3)
                                        .foregroundStyle(.cyan)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.cyan.opacity(0.12)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Test Live Activity")
                                            .font(.body)
                                            .foregroundStyle(theme.colors.ink)
                                        Text("Critical · starts in 5 min · check Lock Screen & Dynamic Island")
                                            .font(.caption)
                                            .foregroundStyle(theme.colors.slate)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)
                        #endif

                        Spacer()
                            .frame(height: 40)
                    }
                }
            }
            .navigationTitle("My Account")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
            }
            .navigationDestination(isPresented: $showingCalendarSettings) {
                CalendarSettingsView()
                    .environmentObject(calendarManager)
                    .environmentObject(calendarDataStore)
            }
            .onAppear {
                isViewVisible = true
                Task {
                    await notificationEngine.checkAuthorizationStatus()
                }
            }
            .onDisappear {
                isViewVisible = false
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Task {
                        await notificationEngine.checkAuthorizationStatus()
                    }
                case .background, .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

// MARK: - Notification Settings View
struct NotificationSettingsView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var settings = NotificationSettings.shared
    @ObservedObject private var engine = NotificationEngine.shared
    
    @State private var showingQuietHoursPicker = false
    
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
                    // MARK: - Enable/Status Card
                    if engine.isAuthorized {
                        StatusCard(status: "Notifications Enabled", color: .green)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    } else {
                        EnableCard {
                            Task {
                                _ = await engine.requestAuthorization()
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    
                    if engine.isAuthorized {
                        // MARK: - Quiet Hours
                        SettingCard(
                            icon: "moon.fill",
                            iconColor: .indigo,
                            title: "Quiet Hours",
                            description: "Silence notifications during sleep"
                        ) {
                            VStack(spacing: 16) {
                                Toggle("Enable Quiet Hours", isOn: $settings.quietHoursEnabled)
                                    .tint(theme.colors.ribbon)
                                
                                if settings.quietHoursEnabled {
                                    Divider()
                                    
                                    Button(action: { showingQuietHoursPicker = true }) {
                                        HStack {
                                            Text("Schedule")
                                                .foregroundStyle(.secondary)
                                            
                                            Spacer()
                                            
                                            Text(quietHoursTimeString)
                                                .foregroundStyle(theme.colors.ribbon)
                                            
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                        
                        // MARK: - Urgency Settings
                        VStack(spacing: 16) {
                            UrgencyCard(
                                urgency: .low,
                                label: "Later",
                                color: theme.colors.urgencyLow,
                                snoozeMinutes: $settings.lowUrgencySnoozeMinutes
                            )
                            
                            UrgencyCard(
                                urgency: .medium,
                                label: "Soon",
                                color: theme.colors.urgencyMedium,
                                snoozeMinutes: $settings.mediumUrgencySnoozeMinutes
                            )
                            
                            UrgencyCard(
                                urgency: .high,
                                label: "Critical",
                                color: theme.colors.urgencyHigh,
                                snoozeMinutes: $settings.highUrgencySnoozeMinutes
                            )
                        }
                        .padding(.horizontal)
                        
                        // MARK: - Daily Limit
                        SettingCard(
                            icon: "bell.badge.fill",
                            iconColor: theme.colors.ribbon,
                            title: "Daily Limit",
                            description: "Maximum notifications per day"
                        ) {
                            DailyLimitPicker(dailyCap: $settings.dailyNotificationCap)
                        }
                        .padding(.horizontal)
                        
                        // MARK: - Audio Reminders
                        SettingCard(
                            icon: "speaker.wave.2.fill",
                            iconColor: .orange,
                            title: "Audio Reminders",
                            description: "Play a sound when notifications arrive"
                        ) {
                            Toggle("Enable sounds", isOn: $settings.enableAudioReminders)
                                .tint(theme.colors.ribbon)
                        }
                        .padding(.horizontal)

                        // MARK: - Advanced
                        SettingCard(
                            icon: "gearshape.fill",
                            iconColor: .gray,
                            title: "Advanced",
                            description: "Additional options"
                        ) {
                            VStack(spacing: 12) {
                                Toggle("Time-Sensitive (Critical only)", isOn: $settings.allowTimeSensitiveHigh)
                                    .tint(theme.colors.ribbon)

                                Divider()

                                Toggle("Calendar Backup Alarms", isOn: $settings.enableCalendarRedundancy)
                                    .tint(theme.colors.ribbon)
                            }
                        }
                        .padding(.horizontal)

                        // MARK: - Live Activity
                        SettingCard(
                            icon: "livephoto",
                            iconColor: .cyan,
                            title: "Live Activity",
                            description: "Dynamic Island & Lock Screen countdown"
                        ) {
                            VStack(spacing: 14) {
                                HStack {
                                    Text("Show countdown")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(settings.liveActivityLeadMinutes) min before")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.colors.ribbon)
                                }

                                Divider()

                                HStack(spacing: 8) {
                                    ForEach([5, 10, 15, 20, 30], id: \.self) { minutes in
                                        Button {
                                            withAnimation(.spring(response: 0.3)) {
                                                settings.liveActivityLeadMinutes = minutes
                                            }
                                        } label: {
                                            Text("\(minutes)m")
                                                .font(.subheadline.weight(settings.liveActivityLeadMinutes == minutes ? .bold : .regular))
                                                .foregroundStyle(settings.liveActivityLeadMinutes == minutes ? .white : theme.colors.ink)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .fill(settings.liveActivityLeadMinutes == minutes ? theme.colors.ribbon : theme.colors.slate.opacity(0.1))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .stroke(
                                                            settings.liveActivityLeadMinutes == minutes ? theme.colors.ribbon : theme.colors.slate.opacity(0.2),
                                                            lineWidth: settings.liveActivityLeadMinutes == minutes ? 2 : 1
                                                        )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                        .frame(height: 40)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showingQuietHoursPicker) {
            QuietHoursPickerSheet(
                quietHoursStart: $settings.quietHoursStart,
                quietHoursEnd: $settings.quietHoursEnd
            )
            .presentationDetents([.medium])
        }
    }
    
    private var quietHoursTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let start = formatter.string(from: settings.quietHoursStart)
        let end = formatter.string(from: settings.quietHoursEnd)
        return "\(start) - \(end)"
    }
}

// MARK: - Status Card
private struct StatusCard: View {
    @Environment(\.olanaTheme) private var theme
    let status: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(status)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)
                
                Text("You'll receive smart reminders")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(20)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Enable Card
private struct EnableCard: View {
    @Environment(\.olanaTheme) private var theme
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "bell.badge.fill")
                    .font(.title)
                    .foregroundStyle(theme.colors.ribbon)
                    .frame(width: 60, height: 60)
                    .background(
                        Circle()
                            .fill(theme.colors.ribbon.opacity(0.15))
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Notifications")
                        .font(.headline)
                        .foregroundStyle(theme.colors.ink)
                    
                    Text("Tap to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(theme.colors.ribbon)
            }
            .padding(20)
            .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(theme.colors.ribbon.opacity(0.3), lineWidth: 2)
            )
            .shadow(color: theme.colors.ribbon.opacity(0.2), radius: 20, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setting Card
private struct SettingCard<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let content: Content
    
    init(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(iconColor.opacity(0.15))
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.colors.ink)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
                .background(theme.colors.slate.opacity(0.2))
            
            // Content
            content
        }
        .padding(20)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(theme.colors.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: theme.colors.pillShadow, radius: 16, x: 0, y: 8)
    }
}

// MARK: - Urgency Card
private struct UrgencyCard: View {
    @Environment(\.olanaTheme) private var theme
    let urgency: EventUrgency
    let label: String
    let color: Color
    @Binding var snoozeMinutes: Int
    
    private var notificationCount: String {
        switch urgency {
        case .low: return "2"
        case .medium: return "3"
        case .high: return "4"
        }
    }

    private var timing: String {
        switch urgency {
        case .low: return "8 am + 30 min before"
        case .medium: return "6 pm day before + 1h + 15m"
        case .high: return "6 pm day before + 1h + 30m + 10m"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(theme.colors.ink)
                    
                    Text(timing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text("\(notificationCount) max")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(color.opacity(0.15))
                    )
            }
            
            Divider()
                .background(theme.colors.slate.opacity(0.2))
            
            // Snooze Picker
            HStack {
                Text("Snooze Duration")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        if snoozeMinutes > 5 {
                            withAnimation(.spring(response: 0.3)) {
                                snoozeMinutes = max(5, snoozeMinutes - 5)
                            }
                        }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(snoozeMinutes > 5 ? color : .gray.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    
                    Text("\(snoozeMinutes) min")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(color)
                        .frame(minWidth: 60)
                    
                    Button(action: {
                        if snoozeMinutes < 60 {
                            withAnimation(.spring(response: 0.3)) {
                                snoozeMinutes = min(60, snoozeMinutes + 5)
                            }
                        }
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(snoozeMinutes < 60 ? color : .gray.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: color.opacity(0.1), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Daily Limit Picker
private struct DailyLimitPicker: View {
    @Environment(\.olanaTheme) private var theme
    @Binding var dailyCap: Int
    
    private let options = [3, 6, 9, 12, 20]
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        dailyCap = option
                    }
                }) {
                    VStack(spacing: 4) {
                        Text("\(option)")
                            .font(.body.weight(dailyCap == option ? .bold : .regular))
                        
                        if option == 20 {
                            Text("Max")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(dailyCap == option ? .white : theme.colors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(dailyCap == option ? theme.colors.ribbon : theme.colors.slate.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                dailyCap == option ? theme.colors.ribbon : theme.colors.slate.opacity(0.2),
                                lineWidth: dailyCap == option ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Quiet Hours Picker Sheet
private struct QuietHoursPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.olanaTheme) private var theme
    @Binding var quietHoursStart: Date
    @Binding var quietHoursEnd: Date
    
    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.canvasStart.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            DatePicker("", selection: $quietHoursStart, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 8) {
                            Text("End")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            DatePicker("", selection: $quietHoursEnd, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        }
                    }
                    .padding(20)
                    .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 16))
                    
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Quiet Hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.colors.ribbon)
                }
            }
        }
    }
}

// MARK: - Profile Card
private struct ProfileCard: View {
    @Environment(\.olanaTheme) private var theme
    let displayName: String
    let email: String
    let profileEmoji: String

    var body: some View {
        VStack(spacing: 16) {
            Text(profileEmoji)
                .font(.system(size: 60))
                .frame(width: 100, height: 100)
                .glassEffect(.regular.tint(theme.colors.ribbon.opacity(0.1)), in: .circle)
                .overlay(
                    Circle()
                        .stroke(theme.colors.cardBorder, lineWidth: 2)
                )
                .shadow(color: theme.colors.pillShadow.opacity(0.2), radius: 16, x: 0, y: 8)

            VStack(spacing: 6) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.colors.ink)

                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(theme.colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.2), radius: 24, x: 0, y: 12)
    }
}

// MARK: - Settings Section (Unchanged)
private struct SettingsSection<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.colors.ink)
                .padding(.horizontal)
            
            VStack(spacing: 0) {
                content
            }
            .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(theme.colors.cardBorder, lineWidth: 0.5)
            )
            .shadow(color: theme.colors.pillShadow, radius: 16, x: 0, y: 8)
            .padding(.horizontal)
        }
    }
}

// MARK: - Settings Navigation Row (Updated with subtitle)
private struct SettingsNavigationRow: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(iconColor.opacity(0.12))
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(theme.colors.ink)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar Toggle Row (Unchanged)
private struct CalendarToggleRow: View {
    @Environment(\.olanaTheme) private var theme
    let title: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(theme.colors.ink)
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(theme.colors.ribbon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthenticationManager())
        .environmentObject(CalendarIntegrationManager())
        .environmentObject(CalendarDataStore())
}
