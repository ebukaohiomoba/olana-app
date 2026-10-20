//
//  DeveloperSettingsView.swift
//  Olana
//
//  DEBUG only: Settings › Developer. Plus testing, the M0 spikes, onboarding
//  reset and the notification test buttons, moved off the main screen.
//

#if DEBUG
import SwiftUI
import ActivityKit
import UserNotifications

struct DeveloperSettingsView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var plus = PlusStore.shared
    @State private var onboarding: OnboardingReplay?

    /// How to replay onboarding from here, without touching the saved state.
    enum OnboardingReplay: String, Identifiable {
        case real, sample, autoplay
        var id: String { rawValue }
    }

    var body: some View {
        content
            .fullScreenCover(item: $onboarding) { mode in
                OnboardingView(
                    replay: true,
                    fixture: mode == .real ? nil
                        : .init(reveal: RevealFixture.source(), autoplay: mode == .autoplay)
                ) { onboarding = nil }
                .homePalette()
            }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                DevSection(title: "Developer") {
                    Menu {
                        Button("Plus: real (preview, fake door)") { PlusAccess.setDebug(nil) }
                        Button("Plus: force on") { PlusAccess.setDebug(true) }
                        Button("Plus: force off") { PlusAccess.setDebug(false) }
                        Button("Reset the Plus preview", role: .destructive) { plus.resetForTesting() }
                    } label: {
                        Label("Plus testing", systemImage: "sparkle")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    NavigationLink {
                        SpikesView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "testtube.2")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.purple.opacity(0.12)))

                            Text("M0 spikes")
                                .font(.body)
                                .foregroundStyle(theme.colors.ink)

                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 66)

                    Menu {
                        Button("Show with my calendar") { onboarding = .real }
                        Button("Show with a sample week") { onboarding = .sample }
                        Button("Play itself (sample week)") { onboarding = .autoplay }
                        Button("Reset: show as the app's start", role: .destructive) {
                            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.orange.opacity(0.12)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show onboarding")
                                    .font(.body)
                                    .foregroundStyle(theme.colors.ink)
                                Text("Every step, notifications ask included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

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

                    Divider().padding(.leading, 66)

                    // MARK: End-to-end pipeline test — schedules a real event 2 min out
                    // This triggers: notification fallback (5s) + Live Activity + AlarmKit alarm
                    Button {
                        let mockEvent = OlanaEvent(
                            title: "⚡ End-to-End Test",
                            start: Date().addingTimeInterval(2 * 60),
                            end:   Date().addingTimeInterval(5 * 60),
                            urgency: .high
                        )
                        Task {
                            await NotificationEngine.shared.scheduleNotifications(for: mockEvent)
                            print("✅ End-to-end test: notification in ~5s · Live Activity now · Alarm in 2min")
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "bolt.fill")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.purple.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Test Full Pipeline")
                                    .font(.body)
                                    .foregroundStyle(theme.colors.ink)
                                Text("Notification now · Live Activity · Alarm in 2 min")
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

                    // MARK: AlarmKit test — fires a real alarm 30 seconds from now
                    Button {
                        Task {
                            let granted = await AlarmKitManager.shared.requestAuthorization()
                            guard granted else {
                                print("⚠️ AlarmKit: permission not granted")
                                return
                            }
                            let mockEvent = OlanaEvent(
                                title: "Test AlarmKit Alarm",
                                start: Date().addingTimeInterval(30),
                                end:   Date().addingTimeInterval(90),
                                urgency: .high
                            )
                            await AlarmKitManager.shared.scheduleAlarm(for: mockEvent)
                            print("✅ AlarmKit test alarm set — fires in 30 seconds")
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "alarm.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.red.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Test AlarmKit Alarm")
                                    .font(.body)
                                    .foregroundStyle(theme.colors.ink)
                                Text("Fires in 30 seconds · requires real device + iOS 26")
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
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DevSection<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(theme.colors.ink).padding(.horizontal)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                .padding(.horizontal)
        }
    }
}
#endif
