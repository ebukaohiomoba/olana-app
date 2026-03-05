//
//  NotificationHubView.swift
//  Olana
//
//  Notification settings hub: main screen + Critical / Soon / Later / Audio & Quiet
//

import SwiftUI
import AVFoundation

// MARK: - Hub

struct NotificationHubView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var s = NotificationSettings.shared
    @ObservedObject private var engine = NotificationEngine.shared
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    var body: some View {
        NHPage {
            // Header
            HStack(spacing: 14) {
                OluView(state: .constant(.resting), size: 52)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How Olu reaches you")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(theme.colors.ink)
                    Text("Different tasks, different urgency.")
                        .font(.subheadline)
                        .foregroundStyle(theme.colors.slate)
                }
                Spacer()
            }
            .padding(.top, 4)

            // Master switch
            NHSectionLabel("MASTER SWITCH")
            NHCard {
                NHRow(icon: "bell.fill", iconColor: theme.colors.ribbon,
                      title: "All notifications", subtitle: "Turn off to silence everything") {
                    Toggle("", isOn: $s.allNotificationsEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // By urgency tier
            NHSectionLabel("BY URGENCY TIER")
            NHCard {
                NavigationLink { CriticalDetailView() } label: {
                    UrgencyTierRow(
                        dot: Color(hex: "E5534B"), name: "Critical",
                        desc: "Up to 5 alerts per day · bypasses Focus · Live Activity",
                        pills: [
                            s.countdownTimerEnabled  ? ("Dynamic Island ✓", Color.green)    : ("Dynamic Island", Color(.systemGray4)),
                            s.urgentAlarmsEnabled    ? ("Alarm ✓", Color.green)             : ("Alarm", Color(.systemGray4)),
                            s.allowTimeSensitiveHigh ? ("Bypass Focus", theme.colors.ribbon) : ("Bypass Focus", Color(.systemGray4))
                        ]
                    )
                }.buttonStyle(.plain)

                Divider().padding(.leading, 54)

                NavigationLink { SoonDetailView() } label: {
                    UrgencyTierRow(
                        dot: theme.colors.urgencyMedium, name: "Soon",
                        desc: "Nudges before due · snooze available",
                        pills: [
                            s.soonLiveActivityEnabled ? ("Dynamic Island ✓", Color.green)    : ("Dynamic Island", Color(.systemGray4)),
                            s.soonAlarmsEnabled       ? ("Alarm ✓", Color.green)             : ("Alarm", Color(.systemGray4)),
                            s.soonBypassFocusEnabled  ? ("Bypass Focus", theme.colors.ribbon) : ("Bypass Focus", Color(.systemGray4))
                        ]
                    )
                }.buttonStyle(.plain)

                Divider().padding(.leading, 54)

                NavigationLink { LaterDetailView() } label: {
                    UrgencyTierRow(
                        dot: Color(hex: "4A90D9"), name: "Later",
                        desc: "Advance notice · auto-escalation available",
                        pills: [
                            s.laterLiveActivityEnabled ? ("Dynamic Island ✓", Color.green)    : ("Dynamic Island", Color(.systemGray4)),
                            s.laterAlarmsEnabled       ? ("Alarm ✓", Color.green)             : ("Alarm", Color(.systemGray4)),
                            s.escalateToSoonEnabled    ? ("Auto-escalate", theme.colors.ribbon) : ("Auto-escalate", Color(.systemGray4))
                        ]
                    )
                }.buttonStyle(.plain)
            }

            // Global
            NHSectionLabel("GLOBAL")
            NHCard {
                NavigationLink { AudioAndQuietView() } label: {
                    HStack(spacing: 14) {
                        NHIcon("moon.fill", color: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quiet hours").font(.subheadline.weight(.semibold)).foregroundStyle(theme.colors.ink)
                            Text("\(timeFmt.string(from: s.quietHoursStart)) – \(timeFmt.string(from: s.quietHoursEnd))")
                                .font(.caption).foregroundStyle(theme.colors.slate)
                        }
                        Spacer()
                        Toggle("", isOn: $s.quietHoursEnabled).labelsHidden().tint(theme.colors.ribbon)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 15)
                }.buttonStyle(.plain)

                Divider().padding(.leading, 54)

                NavigationLink { AudioAndQuietView() } label: {
                    HStack(spacing: 14) {
                        NHIcon("music.note", color: .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio & sounds").font(.subheadline.weight(.semibold)).foregroundStyle(theme.colors.ink)
                            Text("\(soundLabel(s.notificationSound)) · medium")
                                .font(.caption).foregroundStyle(theme.colors.slate)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 15)
                }.buttonStyle(.plain)
            }

            Spacer().frame(height: 40)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
    }

    private func soundLabel(_ key: String) -> String {
        switch key {
        case "olu_chime": return "Olu chime"
        case "warm_bell": return "Warm bell"
        case "soft_pop":  return "Soft pop"
        case "ripple":    return "Ripple"
        default:          return "None"
        }
    }
}

// MARK: - Critical Detail

struct CriticalDetailView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var s = NotificationSettings.shared
    @State private var cadence: Int = NotificationSettings.shared.criticalEscalationCadence

    private let escalationNodes: [NHNode] = [
        .init("1×", "At time"), .init("+30", "30 min"),
        .init("+2h", "2 hr"),   .init("+4h", "4 hr"), .init("8pm", "Evening")
    ]

    private func leadLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m == 60 ? "1 hr" : "\(m / 60) hrs"
    }

    var body: some View {
        NHPage {
            // Live Activity
            NHCard {
                NHRow(icon: "timer", iconColor: Color(hex: "4ABCD4"),
                      title: "Countdown timer",
                      subtitle: "Starts \(leadLabel(s.liveActivityLeadMinutes)) before the event") {
                    Toggle("", isOn: $s.countdownTimerEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
                if s.countdownTimerEnabled {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 50)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How far in advance")
                                .font(.caption)
                                .foregroundStyle(theme.colors.slate)
                            SnoozePicker(minutes: $s.liveActivityLeadMinutes, options: [15, 30, 60, 120])
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }

            // Alarm
            NHSectionLabel("ALARM")
            NHCard {
                NHRow(icon: "alarm.fill", iconColor: .red,
                      title: "Set a real alarm", subtitle: "Plays even if your phone is silenced") {
                    Toggle("", isOn: $s.urgentAlarmsEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
                Divider().padding(.leading, 54)
                NHRow(icon: "arrow.clockwise", iconColor: Color(.systemBlue),
                      title: "Re-alarm if snoozed", subtitle: "After 15 min if not acknowledged") {
                    Toggle("", isOn: $s.reAlarmEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Escalation cadence
            NHSectionLabel("ESCALATION CADENCE")
            NHCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How many times Olu alerts you throughout the day for a Critical task.")
                        .font(.subheadline).foregroundStyle(theme.colors.slate)
                    NotificationTimelineView(
                        nodes: escalationNodes,
                        activeCount: $cadence,
                        leadingLabel: "Fewer", trailingLabel: "More"
                    )
                }
                .padding(16)
            }
            .onChange(of: cadence) { s.criticalEscalationCadence = cadence }

            // Focus mode
            NHSectionLabel("FOCUS MODE")
            NHCard {
                NHRow(icon: "target", iconColor: Color(hex: "E5534B"),
                      title: "Bypass Focus", subtitle: "Critical tasks always break through") {
                    Toggle("", isOn: $s.allowTimeSensitiveHigh).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Snooze
            NHSectionLabel("SNOOZE")
            NHCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        NHIcon("zzz", color: .purple)
                        Text("Snooze duration")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.colors.ink)
                    }
                    SnoozePicker(minutes: $s.highUrgencySnoozeMinutes, options: [5, 10, 15, 30])
                }
                .padding(.horizontal, 16).padding(.vertical, 15)
            }

            Spacer().frame(height: 40)
        }
        .navigationTitle("Critical")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { cadence = s.criticalEscalationCadence }
    }
}

// MARK: - Soon Detail

struct SoonDetailView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var s = NotificationSettings.shared
    @State private var cadence: Int = NotificationSettings.shared.soonEventCadence
    @State private var showMorningPicker = false
    @State private var showAfternoonPicker = false

    private let eventNodes: [NHNode] = [
        .init("-1d", "Day before"), .init("-2h", "2 hrs"),
        .init("-30",  "30 min"),   .init("-10",  "10 min"), .init("Due", "At time")
    ]

    private func leadLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m == 60 ? "1 hr" : "\(m / 60) hrs"
    }

    var body: some View {
        NHPage {
            // Countdown timer (Dynamic Island)
            NHCard {
                NHRow(icon: "timer", iconColor: Color(hex: "4ABCD4"),
                      title: "Countdown timer",
                      subtitle: "Starts \(leadLabel(s.liveActivityLeadMinutes)) before the event") {
                    Toggle("", isOn: $s.soonLiveActivityEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
                if s.soonLiveActivityEnabled {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 50)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How far in advance")
                                .font(.caption).foregroundStyle(theme.colors.slate)
                            SnoozePicker(minutes: $s.liveActivityLeadMinutes, options: [15, 30, 60, 120])
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }

            // Alarm
            NHSectionLabel("ALARM")
            NHCard {
                NHRow(icon: "alarm.fill", iconColor: .red,
                      title: "Set a real alarm", subtitle: "Plays even if your phone is silenced") {
                    Toggle("", isOn: $s.soonAlarmsEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Before the event
            NHSectionLabel("BEFORE THE EVENT")
            NHCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Olu nudges you before a Soon task is due. Pick how early.")
                        .font(.subheadline).foregroundStyle(theme.colors.slate)
                    NotificationTimelineView(
                        nodes: eventNodes,
                        activeCount: $cadence,
                        leadingLabel: "Fewer", trailingLabel: "More"
                    )
                }
                .padding(16)
            }
            .onChange(of: cadence) { s.soonEventCadence = cadence }

            // Daily nudges
            NHSectionLabel("DAILY NUDGES")
            NHCard {
                VStack(spacing: 0) {
                    NHRow(icon: "sunrise.fill", iconColor: Color.orange,
                          title: "Morning nudge", subtitle: "A gentle reminder to start your day") {
                        Toggle("", isOn: $s.morningNudgeEnabled).labelsHidden().tint(theme.colors.ribbon)
                    }
                    if s.morningNudgeEnabled {
                        TimePickerButton(date: $s.morningNudgeTime, showSheet: $showMorningPicker)
                            .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                    Divider().padding(.leading, 54)
                    NHRow(icon: "cloud.sun.fill", iconColor: Color.yellow,
                          title: "Afternoon nudge", subtitle: "Mid-day check-in") {
                        Toggle("", isOn: $s.afternoonNudgeEnabled).labelsHidden().tint(theme.colors.ribbon)
                    }
                    if s.afternoonNudgeEnabled {
                        TimePickerButton(date: $s.afternoonNudgeTime, showSheet: $showAfternoonPicker)
                            .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
            }

            // Focus mode
            NHSectionLabel("FOCUS MODE")
            NHCard {
                NHRow(icon: "target", iconColor: theme.colors.urgencyMedium,
                      title: "Bypass Focus", subtitle: "Soon tasks break through Focus filters") {
                    Toggle("", isOn: $s.soonBypassFocusEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Snooze
            NHSectionLabel("SNOOZE")
            NHCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        NHIcon("zzz", color: Color(.systemBlue))
                        Text("Snooze duration")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.colors.ink)
                    }
                    SnoozePicker(minutes: $s.mediumUrgencySnoozeMinutes, options: [15, 60, 120])
                }
                .padding(.horizontal, 16).padding(.vertical, 15)
            }

            Spacer().frame(height: 40)
        }
        .navigationTitle("Soon")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { cadence = s.soonEventCadence }
        .sheet(isPresented: $showMorningPicker) {
            TimeSelectorSheet(date: $s.morningNudgeTime, label: "Morning nudge")
        }
        .sheet(isPresented: $showAfternoonPicker) {
            TimeSelectorSheet(date: $s.afternoonNudgeTime, label: "Afternoon nudge")
        }
    }
}

// MARK: - Later Detail

struct LaterDetailView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var s = NotificationSettings.shared
    @State private var cadence: Int = NotificationSettings.shared.laterCadence

    private let laterNodes: [NHNode] = [
        .init("-1w", "1 week"), .init("-3d", "3 days"),
        .init("-1d", "Day before"), .init("-2h", "2 hrs"), .init("Due", "At time")
    ]

    private func leadLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m == 60 ? "1 hr" : "\(m / 60) hrs"
    }

    var body: some View {
        NHPage {
            // Countdown timer (Dynamic Island)
            NHCard {
                NHRow(icon: "timer", iconColor: Color(hex: "4ABCD4"),
                      title: "Countdown timer",
                      subtitle: "Starts \(leadLabel(s.liveActivityLeadMinutes)) before the event") {
                    Toggle("", isOn: $s.laterLiveActivityEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
                if s.laterLiveActivityEnabled {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 50)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How far in advance")
                                .font(.caption).foregroundStyle(theme.colors.slate)
                            SnoozePicker(minutes: $s.liveActivityLeadMinutes, options: [15, 30, 60, 120])
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }

            // Alarm
            NHSectionLabel("ALARM")
            NHCard {
                NHRow(icon: "alarm.fill", iconColor: .red,
                      title: "Set a real alarm", subtitle: "Plays even if your phone is silenced") {
                    Toggle("", isOn: $s.laterAlarmsEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Advance notice cadence
            NHSectionLabel("ADVANCE NOTICE")
            NHCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How early Olu starts reminding you about a Later task.")
                        .font(.subheadline).foregroundStyle(theme.colors.slate)
                    NotificationTimelineView(
                        nodes: laterNodes,
                        activeCount: $cadence,
                        leadingLabel: "Earlier", trailingLabel: "Closer"
                    )
                }
                .padding(16)
            }
            .onChange(of: cadence) { s.laterCadence = cadence }

            // Focus mode
            NHSectionLabel("FOCUS MODE")
            NHCard {
                NHRow(icon: "target", iconColor: Color(hex: "4A90D9"),
                      title: "Bypass Focus", subtitle: "Later tasks break through Focus filters") {
                    Toggle("", isOn: $s.laterBypassFocusEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Auto-escalation
            NHSectionLabel("AUTO-ESCALATION")
            NHCard {
                NHRow(icon: "arrow.up.square.fill", iconColor: Color(.systemBlue),
                      title: "Escalate to Soon",
                      subtitle: "When a Later task is 7 days from due") {
                    Toggle("", isOn: $s.escalateToSoonEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
                Divider().padding(.leading, 54)
                NHRow(icon: "arrow.up.square.fill", iconColor: Color(.systemBlue),
                      title: "Escalate to Critical",
                      subtitle: "When a Soon task is overdue by 24 hrs") {
                    Toggle("", isOn: $s.escalateToCriticalEnabled).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Visibility
            NHSectionLabel("VISIBILITY")
            NHCard {
                NHRow(icon: "hand.raised.fill", iconColor: Color.orange,
                      title: "Silent until escalated",
                      subtitle: "No alerts until this task becomes Soon") {
                    Toggle("", isOn: $s.silentUntilEscalated).labelsHidden().tint(theme.colors.ribbon)
                }
            }

            // Snooze
            NHSectionLabel("SNOOZE")
            NHCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        NHIcon("zzz", color: Color(.systemBlue))
                        Text("Snooze duration")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.colors.ink)
                    }
                    SnoozePicker(minutes: $s.lowUrgencySnoozeMinutes, options: [30, 60, 120])
                }
                .padding(.horizontal, 16).padding(.vertical, 15)
            }

            Spacer().frame(height: 40)
        }
        .navigationTitle("Later")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { cadence = s.laterCadence }
    }
}

// MARK: - Audio & Quiet

struct AudioAndQuietView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var s = NotificationSettings.shared
    @State private var showFromPicker = false
    @State private var showUntilPicker = false
    @State private var notifPlayer: AVAudioPlayer?

    private func play(_ key: String, player: inout AVAudioPlayer?) {
        guard key != "none" else { return }
        if let url = Bundle.main.url(forResource: key, withExtension: "m4a") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        }
    }

    var body: some View {
        NHPage {
            // Quiet hours
            NHSectionLabel("QUIET HOURS")
            NHCard {
                NHRow(icon: "moon.fill", iconColor: .indigo,
                      title: "Quiet hours", subtitle: "No Soon or Later notifications") {
                    Toggle("", isOn: $s.quietHoursEnabled).labelsHidden().tint(theme.colors.ribbon)
                }

                if s.quietHoursEnabled {
                    HStack(spacing: 12) {
                        TimeDisplayButton(label: "FROM", date: $s.quietHoursStart, showSheet: $showFromPicker)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        TimeDisplayButton(label: "UNTIL", date: $s.quietHoursEnd, showSheet: $showUntilPicker)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)

                    Divider().padding(.leading, 54)

                    NHRow(icon: "circle.fill", iconColor: .red,
                          title: "Critical exempt", subtitle: "Critical alarms still fire at night") {
                        Toggle("", isOn: $s.criticalExemptFromQuietHours).labelsHidden().tint(theme.colors.ribbon)
                    }
                    Divider().padding(.leading, 54)
                    NHRow(icon: "alarm.fill", iconColor: Color(hex: "E5534B"),
                          title: "Alarm exempt", subtitle: "Alarms always wake you regardless") {
                        Toggle("", isOn: $s.alarmKitExemptFromQuietHours).labelsHidden().tint(theme.colors.ribbon)
                    }
                }
            }

            // Olu's voice
            NHSectionLabel("OLU'S VOICE")
            NHCard {
                VStack(spacing: 14) {
                    HStack {
                        NHIcon("music.note", color: .primary)
                        Text("Notification sound")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.colors.ink)
                        Spacer()
                        Button { play(s.notificationSound, player: &notifPlayer) } label: {
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(theme.colors.ribbon)
                                .clipShape(Circle())
                        }
                    }
                    SoundPicker(
                        selection: $s.notificationSound,
                        options: [("olu_chime","Olu chime"),("warm_bell","Warm bell"),
                                  ("soft_pop","Soft pop"),("ripple","Ripple"),("none","None")]
                    )
                }
                .padding(16)

            }

            Spacer().frame(height: 40)
        }
        .navigationTitle("Audio & Quiet")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showFromPicker) {
            TimeSelectorSheet(date: $s.quietHoursStart, label: "Quiet from")
        }
        .sheet(isPresented: $showUntilPicker) {
            TimeSelectorSheet(date: $s.quietHoursEnd, label: "Quiet until")
        }
    }
}

// MARK: - Shared Components

// Page scaffold
private struct NHPage<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content() }
                    .padding(.horizontal, 16).padding(.top, 8)
            }
        }
    }
}

// Card
private struct NHCard<Content: View>: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(theme.colors.paper)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 8, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.4 : 0), lineWidth: 0.5)
            )
    }
}

// Section label
private struct NHSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(1.1)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

// Icon cell
private struct NHIcon: View {
    let name: String
    let color: Color
    init(_ name: String, color: Color) { self.name = name; self.color = color }
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// Generic row with icon + text + trailing
private struct NHRow<Trailing: View>: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String; let iconColor: Color
    let title: String; let subtitle: String
    let trailing: () -> Trailing
    init(icon: String, iconColor: Color, title: String, subtitle: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon; self.iconColor = iconColor
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: 14) {
            NHIcon(icon, color: iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.colors.ink)
                Text(subtitle).font(.caption).foregroundStyle(theme.colors.slate)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }
}

// Urgency tier row (hub screen)
private struct UrgencyTierRow: View {
    @Environment(\.olanaTheme) private var theme
    let dot: Color; let name: String; let desc: String
    let pills: [(String, Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 10, height: 10)
                Text(name).font(.subheadline.weight(.bold)).foregroundStyle(theme.colors.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text(desc).font(.caption).foregroundStyle(theme.colors.slate)
            PillFlow {
                ForEach(pills, id: \.0) { label, color in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(color.opacity(0.15))
                        .foregroundStyle(color)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

// MARK: - Notification Timeline

struct NHNode {
    let label: String; let sublabel: String
    init(_ label: String, _ sublabel: String) { self.label = label; self.sublabel = sublabel }
}

private struct NotificationTimelineView: View {
    @Environment(\.olanaTheme) private var theme
    let nodes: [NHNode]
    @Binding var activeCount: Int
    let leadingLabel: String; let trailingLabel: String

    var body: some View {
        VStack(spacing: 10) {
            // Nodes + connectors
            HStack(spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                    let active = i < activeCount
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(active ? theme.colors.ribbon : Color(.systemGray5))
                                .frame(width: 42, height: 42)
                            Text(node.label)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(active ? .white : Color(.systemGray2))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                        Text(node.sublabel)
                            .font(.system(size: 9))
                            .foregroundStyle(Color(.systemGray2))
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                    }
                    if i < nodes.count - 1 {
                        Rectangle()
                            .fill(i < activeCount - 1 ? theme.colors.ribbon : Color(.systemGray5))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 20) // align with node center
                    }
                }
            }
            // Slider
            Slider(value: Binding(
                get: { Double(activeCount - 1) },
                set: { activeCount = max(1, min(nodes.count, Int(round($0)) + 1)) }
            ), in: 0...Double(nodes.count - 1), step: 1)
            .tint(theme.colors.ribbon)
            // Labels
            HStack {
                Text(leadingLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(trailingLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Snooze Picker

private struct SnoozePicker: View {
    @Environment(\.olanaTheme) private var theme
    @Binding var minutes: Int
    let options: [Int] // e.g. [15, 60, 120]

    private func label(_ m: Int) -> String {
        m < 60 ? "\(m)m" : "\(m/60)h"
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { opt in
                let selected = minutes == opt
                Button { minutes = opt } label: {
                    Text(label(opt))
                        .font(.subheadline.weight(selected ? .bold : .regular))
                        .foregroundStyle(selected ? .white : theme.colors.ink)
                        .frame(width: 52, height: 36)
                        .background(selected ? theme.colors.ribbon : Color(.secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Sound Picker

private struct SoundPicker: View {
    @Environment(\.olanaTheme) private var theme
    @Binding var selection: String
    let options: [(String, String)] // (key, label)

    var body: some View {
        PillFlow {
            ForEach(options, id: \.0) { key, label in
                let selected = selection == key
                Button { selection = key } label: {
                    Text(label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.colors.ribbon : theme.colors.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(selected ? theme.colors.ribbon : Color(.systemGray4), lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Time Picker Helpers

private struct TimePickerButton: View {
    @Environment(\.olanaTheme) private var theme
    @Binding var date: Date
    @Binding var showSheet: Bool
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    var body: some View {
        Button { showSheet = true } label: {
            Text(fmt.string(from: date))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.colors.ink)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TimeDisplayButton: View {
    @Environment(\.olanaTheme) private var theme
    let label: String
    @Binding var date: Date
    @Binding var showSheet: Bool
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    var body: some View {
        Button { showSheet = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.colors.slate)
                    .tracking(0.8)
                Text(fmt.string(from: date))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.colors.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.colors.canvasEnd)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.colors.ribbon.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TimeSelectorSheet: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let label: String

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.canvasStart.ignoresSafeArea())
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.colors.ribbon)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Pill Flow Layout (iOS 16+)

private struct PillFlow<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        _PillLayout(spacing: 6) { content() }
    }
}

private struct _PillLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { y += lineH + spacing; x = 0; lineH = 0 }
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { y += lineH + spacing; x = bounds.minX; lineH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
    }
}
