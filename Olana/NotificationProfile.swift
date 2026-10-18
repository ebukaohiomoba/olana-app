//
//  NotificationEngine.swift
//  Olana
//
//  Fixes applied:
//  ✅ scheduledRecords persisted to disk — cancel survives app restarts
//  ✅ Day-before reminder (6 pm) added for medium and high urgency
//  ✅ Event time included in notification body copy
//  ✅ Low urgency events before 10 am now fall back to 30 min before
//

import Foundation
import UserNotifications
import ActivityKit
import UIKit
@preconcurrency import EventKit
import Combine

// MARK: - Notification Profile

struct NotificationProfile: @unchecked Sendable {
    let urgency: EventUrgency
    let timings: [NotificationTiming]
    let interruptionLevel: UNNotificationInterruptionLevel
    let sound: UNNotificationSound?
    let enableLiveActivity: Bool
    let maxNotificationsPerEvent: Int
    let snoozeDefaultMinutes: Int
    let actions: [NotificationActionType]

    enum NotificationActionType: Sendable {
        case markDone
        case snooze(minutes: Int)
    }

    struct NotificationTiming: Sendable {
        /// Minutes before the event to fire. Ignored when specificTime + daysBefore are used.
        let minutesBefore: Int
        /// If set with minutesBefore == 0, fires at this clock time on the target day.
        let specificTime: (hour: Int, minute: Int)?
        /// 0 = day of event, 1 = day before, etc.
        let daysBefore: Int

        init(minutesBefore: Int, specificTime: (Int, Int)? = nil, daysBefore: Int = 0) {
            self.minutesBefore = minutesBefore
            self.specificTime = specificTime
            self.daysBefore = daysBefore
        }
    }

    // MARK: - Profile Definitions

    /// Later (low) — single morning reminder day-of. Shows a banner but plays no sound,
    /// so the user is informed without being interrupted.
    /// If the event starts before 10 am, falls back to 30 min before instead.
    static let low = NotificationProfile(
        urgency: .low,
        timings: [
            NotificationTiming(minutesBefore: 0, specificTime: (8, 0)),  // 8 am day-of
            NotificationTiming(minutesBefore: 30)                         // 30 min before
        ],
        interruptionLevel: .active,    // shows banner, no sound
        sound: nil,
        enableLiveActivity: false,
        maxNotificationsPerEvent: 2,
        snoozeDefaultMinutes: 30,
        actions: [.markDone, .snooze(minutes: 30)]
    )

    /// Soon (medium) — evening-before reminder + 1 hour + 15 min before.
    /// Standard interruption with the default notification sound.
    static let medium = NotificationProfile(
        urgency: .medium,
        timings: [
            NotificationTiming(minutesBefore: 0, specificTime: (18, 0), daysBefore: 1),
            NotificationTiming(minutesBefore: 60),
            NotificationTiming(minutesBefore: 15)
        ],
        interruptionLevel: .active,    // normal banner, respects Focus
        sound: .default,
        enableLiveActivity: true,
        maxNotificationsPerEvent: 3,
        snoozeDefaultMinutes: 15,
        actions: [.markDone, .snooze(minutes: 15)]
    )

    /// Critical (high) — evening-before + 1 hour + 30 min + 10 min before.
    /// Always time-sensitive so it breaks through Focus modes. Uses the ringtone
    /// sound to be clearly distinct from lower-urgency alerts.
    static let high = NotificationProfile(
        urgency: .high,
        timings: [
            NotificationTiming(minutesBefore: 0, specificTime: (18, 0), daysBefore: 1),
            NotificationTiming(minutesBefore: 60),
            NotificationTiming(minutesBefore: 30),
            NotificationTiming(minutesBefore: 10)
        ],
        interruptionLevel: .timeSensitive,  // breaks through Focus mode — this IS the audio difference
        sound: .default,                    // same chime as Soon; .timeSensitive level is what makes it distinct
        enableLiveActivity: true,
        maxNotificationsPerEvent: 4,
        snoozeDefaultMinutes: 10,
        actions: [.markDone, .snooze(minutes: 10)]
    )

    static func profile(for urgency: EventUrgency) -> NotificationProfile {
        switch urgency {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }
}

// MARK: - Notification Settings
//
// Storage strategy:
//   Primary   — NSUbiquitousKeyValueStore (iCloud KV store)
//               Syncs automatically across all devices on the same Apple ID.
//   Secondary — UserDefaults (local cache)
//               Written on every change so values are available instantly on
//               next launch even before iCloud KV store has synced.
//   Read priority: iCloud KV → UserDefaults → hardcoded default
//
// This means notification preferences survive device switches with no
// additional code required on the caller side.

class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()

    private let kv = NSUbiquitousKeyValueStore.default

    // MARK: Published properties — write to both stores on change

    @Published var quietHoursEnabled: Bool {
        didSet { save(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    @Published var quietHoursStart: Date {
        didSet { save(quietHoursStart as NSDate, forKey: "quietHoursStart") }
    }
    @Published var quietHoursEnd: Date {
        didSet { save(quietHoursEnd as NSDate, forKey: "quietHoursEnd") }
    }
    @Published var allowTimeSensitiveHigh: Bool {
        didSet { save(allowTimeSensitiveHigh, forKey: "allowTimeSensitiveHigh") }
    }
    @Published var lowUrgencySnoozeMinutes: Int {
        didSet { save(lowUrgencySnoozeMinutes, forKey: "lowUrgencySnoozeMinutes") }
    }
    @Published var mediumUrgencySnoozeMinutes: Int {
        didSet { save(mediumUrgencySnoozeMinutes, forKey: "mediumUrgencySnoozeMinutes") }
    }
    @Published var highUrgencySnoozeMinutes: Int {
        didSet { save(highUrgencySnoozeMinutes, forKey: "highUrgencySnoozeMinutes") }
    }
    @Published var dailyNotificationCap: Int {
        didSet { save(dailyNotificationCap, forKey: "dailyNotificationCap") }
    }
    @Published var enableCalendarRedundancy: Bool {
        didSet { save(enableCalendarRedundancy, forKey: "enableCalendarRedundancy") }
    }
    @Published var enableAudioReminders: Bool {
        didSet { save(enableAudioReminders, forKey: "enableAudioReminders") }
    }
    @Published var urgentAlarmsEnabled: Bool {
        didSet { save(urgentAlarmsEnabled, forKey: "urgentAlarmsEnabled") }
    }
    @Published var soonAlarmsEnabled: Bool {
        didSet { save(soonAlarmsEnabled, forKey: "soonAlarmsEnabled") }
    }
    @Published var soonLiveActivityEnabled: Bool {
        didSet { save(soonLiveActivityEnabled, forKey: "soonLiveActivityEnabled") }
    }
    @Published var laterLiveActivityEnabled: Bool {
        didSet { save(laterLiveActivityEnabled, forKey: "laterLiveActivityEnabled") }
    }
    @Published var soonBypassFocusEnabled: Bool {
        didSet { save(soonBypassFocusEnabled, forKey: "soonBypassFocusEnabled") }
    }
    @Published var laterBypassFocusEnabled: Bool {
        didSet { save(laterBypassFocusEnabled, forKey: "laterBypassFocusEnabled") }
    }
    /// How many minutes before an event the Live Activity countdown starts.
    /// Stored in iCloud KV so the value syncs across devices.
    @Published var liveActivityLeadMinutes: Int {
        didSet { save(liveActivityLeadMinutes, forKey: "liveActivityLeadMinutes") }
    }

    // MARK: New hub settings

    @Published var allNotificationsEnabled: Bool {
        didSet { save(allNotificationsEnabled, forKey: "allNotificationsEnabled") }
    }
    // Critical
    @Published var countdownTimerEnabled: Bool {
        didSet { save(countdownTimerEnabled, forKey: "countdownTimerEnabled") }
    }
    @Published var reAlarmEnabled: Bool {
        didSet { save(reAlarmEnabled, forKey: "reAlarmEnabled") }
    }
    @Published var criticalEscalationCadence: Int {
        didSet { save(criticalEscalationCadence, forKey: "criticalEscalationCadence") }
    }
    // Soon
    @Published var morningNudgeEnabled: Bool {
        didSet { save(morningNudgeEnabled, forKey: "morningNudgeEnabled") }
    }
    @Published var morningNudgeTime: Date {
        didSet { save(morningNudgeTime as NSDate, forKey: "morningNudgeTime") }
    }
    @Published var afternoonNudgeEnabled: Bool {
        didSet { save(afternoonNudgeEnabled, forKey: "afternoonNudgeEnabled") }
    }
    @Published var afternoonNudgeTime: Date {
        didSet { save(afternoonNudgeTime as NSDate, forKey: "afternoonNudgeTime") }
    }
    @Published var soonEventCadence: Int {
        didSet { save(soonEventCadence, forKey: "soonEventCadence") }
    }
    // Later
    @Published var laterCadence: Int {
        didSet { save(laterCadence, forKey: "laterCadence") }
    }
    @Published var silentUntilEscalated: Bool {
        didSet { save(silentUntilEscalated, forKey: "silentUntilEscalated") }
    }
    // Audio & Quiet
    @Published var criticalExemptFromQuietHours: Bool {
        didSet { save(criticalExemptFromQuietHours, forKey: "criticalExemptFromQuietHours") }
    }
    @Published var alarmKitExemptFromQuietHours: Bool {
        didSet { save(alarmKitExemptFromQuietHours, forKey: "alarmKitExemptFromQuietHours") }
    }
    @Published var notificationSound: String {
        didSet { save(notificationSound, forKey: "notificationSound") }
    }
    @Published var alarmKitSound: String {
        didSet { save(alarmKitSound, forKey: "alarmKitSound") }
    }

    // MARK: Init

    private init() {
        // Pull latest values from iCloud KV store before reading.
        kv.synchronize()

        let cal          = Calendar.current
        let defaultStart = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
        let defaultEnd   = cal.date(bySettingHour:  7, minute: 0, second: 0, of: Date()) ?? Date()

        // Read order: iCloud KV → UserDefaults → hardcoded default
        self.quietHoursEnabled          = kv.bool(  "quietHoursEnabled")          ?? UserDefaults.standard.object(forKey: "quietHoursEnabled")          as? Bool ?? true
        self.quietHoursStart            = kv.date(  "quietHoursStart")             ?? UserDefaults.standard.object(forKey: "quietHoursStart")            as? Date ?? defaultStart
        self.quietHoursEnd              = kv.date(  "quietHoursEnd")               ?? UserDefaults.standard.object(forKey: "quietHoursEnd")              as? Date ?? defaultEnd
        self.allowTimeSensitiveHigh     = kv.bool(  "allowTimeSensitiveHigh")      ?? UserDefaults.standard.object(forKey: "allowTimeSensitiveHigh")     as? Bool ?? false
        self.lowUrgencySnoozeMinutes    = kv.int(   "lowUrgencySnoozeMinutes")     ?? UserDefaults.standard.object(forKey: "lowUrgencySnoozeMinutes")    as? Int  ?? 30
        self.mediumUrgencySnoozeMinutes = kv.int(   "mediumUrgencySnoozeMinutes")  ?? UserDefaults.standard.object(forKey: "mediumUrgencySnoozeMinutes") as? Int  ?? 15
        self.highUrgencySnoozeMinutes   = kv.int(   "highUrgencySnoozeMinutes")    ?? UserDefaults.standard.object(forKey: "highUrgencySnoozeMinutes")   as? Int  ?? 10
        self.dailyNotificationCap       = kv.int(   "dailyNotificationCap")        ?? UserDefaults.standard.object(forKey: "dailyNotificationCap")       as? Int  ?? 15
        self.enableCalendarRedundancy   = kv.bool(  "enableCalendarRedundancy")    ?? UserDefaults.standard.object(forKey: "enableCalendarRedundancy")   as? Bool ?? false
        self.enableAudioReminders       = kv.bool(  "enableAudioReminders")        ?? UserDefaults.standard.object(forKey: "enableAudioReminders")       as? Bool ?? true
        self.urgentAlarmsEnabled        = kv.bool(  "urgentAlarmsEnabled")         ?? UserDefaults.standard.object(forKey: "urgentAlarmsEnabled")        as? Bool ?? false
        self.soonAlarmsEnabled          = kv.bool(  "soonAlarmsEnabled")           ?? UserDefaults.standard.object(forKey: "soonAlarmsEnabled")          as? Bool ?? false
        self.soonLiveActivityEnabled    = kv.bool(  "soonLiveActivityEnabled")     ?? UserDefaults.standard.object(forKey: "soonLiveActivityEnabled")    as? Bool ?? true
        self.laterLiveActivityEnabled   = kv.bool(  "laterLiveActivityEnabled")    ?? UserDefaults.standard.object(forKey: "laterLiveActivityEnabled")   as? Bool ?? false
        self.soonBypassFocusEnabled     = kv.bool(  "soonBypassFocusEnabled")      ?? UserDefaults.standard.object(forKey: "soonBypassFocusEnabled")     as? Bool ?? false
        self.laterBypassFocusEnabled    = kv.bool(  "laterBypassFocusEnabled")     ?? UserDefaults.standard.object(forKey: "laterBypassFocusEnabled")    as? Bool ?? false
        self.liveActivityLeadMinutes    = kv.int(   "liveActivityLeadMinutes")     ?? UserDefaults.standard.object(forKey: "liveActivityLeadMinutes")    as? Int  ?? 15

        let defaultMorning   = cal.date(bySettingHour: 9,  minute: 0, second: 0, of: Date()) ?? Date()
        let defaultAfternoon = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()

        self.allNotificationsEnabled    = kv.bool("allNotificationsEnabled")    ?? UserDefaults.standard.object(forKey: "allNotificationsEnabled")    as? Bool ?? true
        self.countdownTimerEnabled      = kv.bool("countdownTimerEnabled")      ?? UserDefaults.standard.object(forKey: "countdownTimerEnabled")      as? Bool ?? true
        self.reAlarmEnabled             = kv.bool("reAlarmEnabled")             ?? UserDefaults.standard.object(forKey: "reAlarmEnabled")             as? Bool ?? true
        self.criticalEscalationCadence  = kv.int( "criticalEscalationCadence") ?? UserDefaults.standard.object(forKey: "criticalEscalationCadence")  as? Int  ?? 3
        self.morningNudgeEnabled        = kv.bool("morningNudgeEnabled")        ?? UserDefaults.standard.object(forKey: "morningNudgeEnabled")        as? Bool ?? true
        self.morningNudgeTime           = kv.date("morningNudgeTime")           ?? UserDefaults.standard.object(forKey: "morningNudgeTime")           as? Date ?? defaultMorning
        self.afternoonNudgeEnabled      = kv.bool("afternoonNudgeEnabled")      ?? UserDefaults.standard.object(forKey: "afternoonNudgeEnabled")      as? Bool ?? true
        self.afternoonNudgeTime         = kv.date("afternoonNudgeTime")         ?? UserDefaults.standard.object(forKey: "afternoonNudgeTime")         as? Date ?? defaultAfternoon
        self.soonEventCadence           = kv.int( "soonEventCadence")           ?? UserDefaults.standard.object(forKey: "soonEventCadence")           as? Int  ?? 3
        self.laterCadence               = kv.int( "laterCadence")               ?? UserDefaults.standard.object(forKey: "laterCadence")               as? Int  ?? 2
        self.silentUntilEscalated       = kv.bool("silentUntilEscalated")       ?? UserDefaults.standard.object(forKey: "silentUntilEscalated")       as? Bool ?? true
        self.criticalExemptFromQuietHours  = kv.bool("criticalExemptFromQuietHours")  ?? UserDefaults.standard.object(forKey: "criticalExemptFromQuietHours")  as? Bool ?? false
        self.alarmKitExemptFromQuietHours  = kv.bool("alarmKitExemptFromQuietHours")  ?? UserDefaults.standard.object(forKey: "alarmKitExemptFromQuietHours")  as? Bool ?? false
        self.notificationSound          = kv.object(forKey: "notificationSound") as? String ?? UserDefaults.standard.string(forKey: "notificationSound") ?? "olu_chime"
        self.alarmKitSound              = kv.object(forKey: "alarmKitSound")     as? String ?? UserDefaults.standard.string(forKey: "alarmKitSound")     ?? "gentle_rise"

        // Observe external changes pushed from other devices via iCloud.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvStoreDidChangeExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv
        )
    }

    // MARK: Helpers

    func snoozeMinutes(for urgency: EventUrgency) -> Int {
        switch urgency {
        case .low:    return lowUrgencySnoozeMinutes
        case .medium: return mediumUrgencySnoozeMinutes
        case .high:   return highUrgencySnoozeMinutes
        }
    }

    // MARK: Private — storage

    /// Writes a value to both iCloud KV store and UserDefaults.
    private func save(_ value: Any, forKey key: String) {
        kv.set(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Called by iCloud when another device updates a key.
    /// Updates the relevant @Published property so the UI and engine stay in sync.
    @objc private func kvStoreDidChangeExternally(_ notification: Notification) {
        guard let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for key in keys {
                switch key {
                case "quietHoursEnabled":
                    if let v = self.kv.bool("quietHoursEnabled")          { self.quietHoursEnabled = v }
                case "quietHoursStart":
                    if let v = self.kv.date("quietHoursStart")            { self.quietHoursStart = v }
                case "quietHoursEnd":
                    if let v = self.kv.date("quietHoursEnd")              { self.quietHoursEnd = v }
                case "allowTimeSensitiveHigh":
                    if let v = self.kv.bool("allowTimeSensitiveHigh")     { self.allowTimeSensitiveHigh = v }
                case "lowUrgencySnoozeMinutes":
                    if let v = self.kv.int("lowUrgencySnoozeMinutes")     { self.lowUrgencySnoozeMinutes = v }
                case "mediumUrgencySnoozeMinutes":
                    if let v = self.kv.int("mediumUrgencySnoozeMinutes")  { self.mediumUrgencySnoozeMinutes = v }
                case "highUrgencySnoozeMinutes":
                    if let v = self.kv.int("highUrgencySnoozeMinutes")    { self.highUrgencySnoozeMinutes = v }
                case "dailyNotificationCap":
                    if let v = self.kv.int("dailyNotificationCap")        { self.dailyNotificationCap = v }
                case "enableCalendarRedundancy":
                    if let v = self.kv.bool("enableCalendarRedundancy")   { self.enableCalendarRedundancy = v }
                case "enableAudioReminders":
                    if let v = self.kv.bool("enableAudioReminders")       { self.enableAudioReminders = v }
                case "urgentAlarmsEnabled":
                    if let v = self.kv.bool("urgentAlarmsEnabled")        { self.urgentAlarmsEnabled = v }
                case "soonAlarmsEnabled":
                    if let v = self.kv.bool("soonAlarmsEnabled")          { self.soonAlarmsEnabled = v }
                case "soonLiveActivityEnabled":
                    if let v = self.kv.bool("soonLiveActivityEnabled")    { self.soonLiveActivityEnabled = v }
                case "laterLiveActivityEnabled":
                    if let v = self.kv.bool("laterLiveActivityEnabled")   { self.laterLiveActivityEnabled = v }
                case "soonBypassFocusEnabled":
                    if let v = self.kv.bool("soonBypassFocusEnabled")     { self.soonBypassFocusEnabled = v }
                case "laterBypassFocusEnabled":
                    if let v = self.kv.bool("laterBypassFocusEnabled")    { self.laterBypassFocusEnabled = v }
                case "liveActivityLeadMinutes":
                    if let v = self.kv.int("liveActivityLeadMinutes")          { self.liveActivityLeadMinutes = v }
                case "allNotificationsEnabled":
                    if let v = self.kv.bool("allNotificationsEnabled")         { self.allNotificationsEnabled = v }
                case "countdownTimerEnabled":
                    if let v = self.kv.bool("countdownTimerEnabled")           { self.countdownTimerEnabled = v }
                case "reAlarmEnabled":
                    if let v = self.kv.bool("reAlarmEnabled")                  { self.reAlarmEnabled = v }
                case "criticalEscalationCadence":
                    if let v = self.kv.int("criticalEscalationCadence")        { self.criticalEscalationCadence = v }
                case "morningNudgeEnabled":
                    if let v = self.kv.bool("morningNudgeEnabled")             { self.morningNudgeEnabled = v }
                case "morningNudgeTime":
                    if let v = self.kv.date("morningNudgeTime")                { self.morningNudgeTime = v }
                case "afternoonNudgeEnabled":
                    if let v = self.kv.bool("afternoonNudgeEnabled")           { self.afternoonNudgeEnabled = v }
                case "afternoonNudgeTime":
                    if let v = self.kv.date("afternoonNudgeTime")              { self.afternoonNudgeTime = v }
                case "soonEventCadence":
                    if let v = self.kv.int("soonEventCadence")                 { self.soonEventCadence = v }
                case "laterCadence":
                    if let v = self.kv.int("laterCadence")                     { self.laterCadence = v }
                case "silentUntilEscalated":
                    if let v = self.kv.bool("silentUntilEscalated")            { self.silentUntilEscalated = v }
                case "criticalExemptFromQuietHours":
                    if let v = self.kv.bool("criticalExemptFromQuietHours")    { self.criticalExemptFromQuietHours = v }
                case "alarmKitExemptFromQuietHours":
                    if let v = self.kv.bool("alarmKitExemptFromQuietHours")    { self.alarmKitExemptFromQuietHours = v }
                case "notificationSound":
                    if let v = self.kv.object(forKey: "notificationSound") as? String { self.notificationSound = v }
                case "alarmKitSound":
                    if let v = self.kv.object(forKey: "alarmKitSound") as? String     { self.alarmKitSound = v }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - NSUbiquitousKeyValueStore typed accessors

private extension NSUbiquitousKeyValueStore {
    /// Returns a Bool only if the key has been explicitly set; nil means "not set".
    func bool(_ key: String) -> Bool? {
        object(forKey: key) as? Bool
    }
    /// Returns a Date only if the key has been explicitly set.
    func date(_ key: String) -> Date? {
        object(forKey: key) as? Date
    }
    /// Returns an Int only if the key has been explicitly set.
    func int(_ key: String) -> Int? {
        guard let n = object(forKey: key) else { return nil }
        if let i = n as? Int    { return i }
        if let d = n as? Double { return Int(d) }  // KV store may round-trip Int as Double
        return nil
    }
}

// MARK: - Scheduled Notification Record

struct ScheduledNotificationRecord: Codable {
    let eventId: UUID
    let urgency: EventUrgency
    let notificationIds: [String]
    let scheduledAt: Date
    let eventStartTime: Date
    let engineVersion: String

    init(eventId: UUID, urgency: EventUrgency, notificationIds: [String],
         scheduledAt: Date, eventStartTime: Date) {
        self.eventId         = eventId
        self.urgency         = urgency
        self.notificationIds = notificationIds
        self.scheduledAt     = scheduledAt
        self.eventStartTime  = eventStartTime
        self.engineVersion   = "2.0"
    }
}

// MARK: - Notification Engine

@MainActor
class NotificationEngine: ObservableObject {
    static let shared = NotificationEngine()

    private let center   = UNUserNotificationCenter.current()
    private let settings = NotificationSettings.shared
    private let calendar = Calendar.current

    @Published var isAuthorized        = false
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var scheduledRecords: [UUID: ScheduledNotificationRecord] = [:]
    /// Maps event UUID → Live Activity ID so we can update/end it later.
    private var liveActivityIds: [UUID: String] = [:]

    private let recordsKey = "scheduledNotificationRecords_v2"

    private init() {
        loadRecords()
        Task { await checkAuthorizationStatus() }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound, .timeSensitive])
            isAuthorized = granted
            await checkAuthorizationStatus()
            return granted
        } catch {
            print("❌ NotificationEngine: Authorization error: \(error)")
            return false
        }
    }

    func checkAuthorizationStatus() async {
        let s = await center.notificationSettings()
        authorizationStatus = s.authorizationStatus
        isAuthorized        = s.authorizationStatus == .authorized
    }

    // MARK: - Notification Categories

    func setupNotificationCategories() {
        func snoozeLabel(_ m: Int) -> String { m < 60 ? "Snooze \(m)m" : "Snooze \(m / 60)h" }
        let markDone     = UNNotificationAction(identifier: "MARK_DONE",     title: "Mark Done",  options: [.foreground])
        let snoozeLow    = UNNotificationAction(identifier: "SNOOZE_LOW",    title: snoozeLabel(settings.lowUrgencySnoozeMinutes),    options: [])
        let snoozeMedium = UNNotificationAction(identifier: "SNOOZE_MEDIUM", title: snoozeLabel(settings.mediumUrgencySnoozeMinutes), options: [])
        let snoozeHigh   = UNNotificationAction(identifier: "SNOOZE_HIGH",   title: snoozeLabel(settings.highUrgencySnoozeMinutes),   options: [])

        // Execution alerts (spec v3 §7.7). Directions, Open and Join open the app;
        // the rest run in the background so state updates without opening it.
        let open       = UNNotificationAction(identifier: "EXEC_OPEN",       title: "Open",         options: [.foreground])
        let prepDone   = UNNotificationAction(identifier: "EXEC_PREP_DONE",  title: "Prep done",    options: [])
        let prepSnooze = UNNotificationAction(identifier: "EXEC_PREP_SNOOZE", title: "Snooze 10m",  options: [])
        let ok         = UNNotificationAction(identifier: "EXEC_OK",         title: "OK",           options: [])
        let directions = UNNotificationAction(identifier: "EXEC_DIRECTIONS", title: "Directions",   options: [.foreground])
        let leaving    = UNNotificationAction(identifier: "EXEC_LEAVING",    title: "I'm leaving",  options: [])
        let fiveMin    = UNNotificationAction(identifier: "EXEC_LEAVE_SNOOZE", title: "5 min",      options: [])
        let join       = UNNotificationAction(identifier: "EXEC_JOIN",       title: "Join",         options: [.foreground])

        center.setNotificationCategories([
            UNNotificationCategory(identifier: "EXEC_PREP",     actions: [open, prepDone, prepSnooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EXEC_GETREADY", actions: [ok],                         intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EXEC_LEAVE",    actions: [directions, leaving, fiveMin], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EXEC_JOIN",     actions: [join],                       intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_LOW",    actions: [markDone, snoozeLow],    intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_MEDIUM", actions: [markDone, snoozeMedium], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_HIGH",   actions: [markDone, snoozeHigh],   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Schedule Notifications

    /// An event was added, edited, re-judged or escalated. Refreshes its alarm,
    /// Live Activity and calendar backup as before, then asks the planner to
    /// bring every event's reminders up to date (PRD v6 §3.9).
    func scheduleNotifications(for event: OlanaEvent, confidence: Double = 1.0) async {
        // Re-register categories so snooze button labels always reflect current settings.
        setupNotificationCategories()
        guard isAuthorized, settings.allNotificationsEnabled else { return }

        // The alarm and Live Activity were built for the event's old time or
        // urgency. Rebuild them.
        await endLiveActivity(for: event.id)
        await AlarmKitManager.shared.cancelAlarm(for: event.id)

        // Later events with "silent until escalated" get no notifications yet.
        // The alarm is decided separately: a severe event far enough out to be
        // Later today still needs its alarm.
        if !(event.urgency == .low && settings.silentUntilEscalated) {
            let profile = NotificationProfile.profile(for: event.urgency)
            if profile.enableLiveActivity {
                await scheduleLiveActivity(for: event)
            }
            // Synced events already live in a calendar with its own alerts. Copying
            // one into the default calendar would sync back in as a new event, get
            // scheduled, and be copied again.
            if settings.enableCalendarRedundancy && !event.isFromExternalCalendar {
                await addCalendarAlarm(for: event)
            }
        }

        // AlarmKit: a full-screen alarm cuts through Silent and Focus, and one
        // wrong one gets the permission revoked in a single tap. So the gate is
        // deliberately narrow and everything about it fails closed.
        await scheduleAlarmIfEarned(for: event)

        // An event the store doesn't hold yet (or a debug mock) still gets its
        // one-shot "starting now" reminder.
        if floorPlan(for: event, now: Date()).immediate {
            await postImmediate(for: event)
        }
        requestReplan("event changed")
    }

    // MARK: - The floor, per event

    /// How far ahead synced events still showing the placeholder get their
    /// basic reminder. Unchanged: a work calendar can hold hundreds of events.
    static let syncedReminderHorizon: TimeInterval = 48 * 3600

    /// Minutes before a synced event that its basic reminder fires.
    static let basicReminderLeadMinutes = 15

    /// The floor for one event: exactly the reminders this engine has always
    /// planned for it, with execution features off (PRD §1.4 principle 7).
    /// Changes from before, both from the PRD: the daily cap no longer applies
    /// (the floor is "not counted", v3 §3.9), and indices follow the timing's
    /// place in the profile so a reminder keeps its id as earlier ones fire.
    ///
    /// `immediate`: every reminder time has passed but the event hasn't
    /// started. Posted once, outside the plan, so a replan can't repeat it.
    func floorPlan(for event: OlanaEvent, now: Date) -> (slots: [AlertSlot], immediate: Bool) {
        guard isAuthorized, settings.allNotificationsEnabled, !event.completed else { return ([], false) }
        if event.isFromExternalCalendar && event.isAllDay { return ([], false) }

        // Later events with "silent until escalated" have no floor (A10).
        if event.urgency == .low && settings.silentUntilEscalated { return ([], false) }

        if event.hasPlaceholderUrgency {
            return basicSlot(for: event, now: now)
        }

        let profile = NotificationProfile.profile(for: event.urgency)
        var candidates: [(index: Int, date: Date, timing: NotificationProfile.NotificationTiming)] = []
        for (index, timing) in timingsForEvent(event, profile: profile).enumerated() {
            if let date = fireDate(for: timing, event: event) {
                candidates.append((index, date, timing))
            }
        }

        candidates = candidates.filter { $0.date > now }
        if candidates.isEmpty {
            // Every pre-event window has passed (e.g. created seconds before it
            // starts): one immediate reminder so the user is never left in silence.
            return ([], event.start >= now.addingTimeInterval(-30))
        }

        // Respect quiet hours unless the urgency tier is configured to be exempt.
        let exemptFromQuiet = profile.urgency == .high && settings.criticalExemptFromQuietHours
        if !exemptFromQuiet {
            candidates = candidates.map { ($0.index, normalizeForQuietHours($0.date), $0.timing) }
        }
        // Drop reminders within a minute of an earlier-listed one.
        var deduped: [(index: Int, date: Date, timing: NotificationProfile.NotificationTiming)] = []
        for c in candidates where !deduped.contains(where: { abs($0.date.timeIntervalSince(c.date)) < 60 }) {
            deduped.append(c)
        }
        let kept = deduped.prefix(profile.maxNotificationsPerEvent)

        let slots = kept.map { c in
            AlertSlot(
                id: AlertID.floor(event.id, c.index), kind: .floor,
                eventID: event.id, eventStart: event.start, fireDate: c.date,
                priority: false,
                title: event.title,
                subtitle: subtitleForTiming(c.timing),
                body: bodyForUrgency(event.urgency, eventStart: event.start, timing: c.timing),
                category: "EVENT_\(urgencyString(event.urgency).uppercased())",
                urgencyRaw: event.urgency.rawValue, index: c.index
            )
        }
        return (slots, false)
    }

    private func fireDate(for timing: NotificationProfile.NotificationTiming, event: OlanaEvent) -> Date? {
        if timing.daysBefore > 0, let specificTime = timing.specificTime {
            // Evening-before (or N-days-before) at a fixed clock time
            let targetDay = calendar.date(byAdding: .day, value: -timing.daysBefore, to: event.start) ?? event.start
            return calendar.date(bySettingHour: specificTime.hour, minute: specificTime.minute, second: 0, of: targetDay)
        }
        if let specificTime = timing.specificTime, timing.minutesBefore == 0 {
            // Same-day at a fixed clock time (e.g. 8 am); events before 10 am
            // fall back to 30 min before.
            if calendar.component(.hour, from: event.start) < 10 {
                return calendar.date(byAdding: .minute, value: -30, to: event.start)
            }
            return calendar.date(bySettingHour: specificTime.hour, minute: specificTime.minute, second: 0,
                                 of: calendar.startOfDay(for: event.start))
        }
        // Relative: N minutes before the event
        return calendar.date(byAdding: .minute, value: -timing.minutesBefore, to: event.start)
    }

    /// Synced events still showing the placeholder: one plain reminder shortly
    /// before, the way a calendar app would, within the 48 h horizon.
    private func basicSlot(for event: OlanaEvent, now: Date) -> (slots: [AlertSlot], immediate: Bool) {
        guard !event.isAllDay, event.start > now,
              event.start.timeIntervalSince(now) < Self.syncedReminderHorizon else { return ([], false) }
        let lead = Self.basicReminderLeadMinutes
        let fire = event.start.addingTimeInterval(-Double(lead) * 60)
        if fire <= now {
            // Already inside the lead window: tell them now, unless it's about to start anyway.
            return ([], event.start.timeIntervalSince(now) > 60)
        }
        // Moving a 15-minute reminder to the end of quiet hours would land it
        // after the event. Skip it instead.
        if settings.quietHoursEnabled && isInQuietHours(fire) { return ([], false) }

        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let slot = AlertSlot(
            id: AlertID.floor(event.id, 0), kind: .floor,
            eventID: event.id, eventStart: event.start, fireDate: fire, priority: false,
            title: event.title, subtitle: "in \(lead) minutes",
            body: "Starts at \(fmt.string(from: event.start)).",
            category: "EVENT_\(urgencyString(event.urgency).uppercased())",
            urgencyRaw: event.urgency.rawValue, index: 0
        )
        return ([slot], false)
    }

    // MARK: - Replan (PRD §3.9) and integrity check (PRD §1.9, v3 §3.10)

    /// Set by EventStore so the planner can see every event at once. nil (no
    /// store yet, or it's gone) means "unknown", never "no events": planning
    /// from an empty list would remove every reminder.
    var eventsProvider: (() -> [OlanaEvent]?)?

    private var replanTask: Task<Void, Never>?
    private var replanDirty = false

    /// Coalesces bursts (a sync touching 40 events asks once, not 40 times).
    func requestReplan(_ reason: String) {
        replanDirty = true
        guard replanTask == nil else { return }
        replanTask = Task { @MainActor in
            while replanDirty {
                replanDirty = false
                try? await Task.sleep(nanoseconds: 300_000_000)
                await replan(reason)
            }
            replanTask = nil
        }
    }

    struct IntegrityResult: Codable {
        let at: Date
        let reason: String
        let planned: Int
        let added: Int
        let removed: Int
        let overflow: Int
        /// Planned floor reminders still not pending after the replan. The gate is zero.
        let missing: Int
        let missingReason: String?
        /// Execution alerts (M1-C): planned, and planned but not pending. A
        /// separate metric from the floor, reported, not gated. Optional so
        /// history saved before M1-A's execution store still decodes.
        var execPlanned: Int? = nil
        var execMissing: Int? = nil
        /// Not pending after the diff and added again (spec §5.6 step 2).
        var readded: Int? = nil
        /// The last add error, kept with "unknown" so the cause isn't lost.
        var addError: String? = nil
        /// Observable delivery since the last check (step 3), reported only.
        var deliveryDue: Int? = nil
        var deliveryObserved: Int? = nil
    }

    /// Bring pending reminders in line with the plan, then check nothing
    /// planned is missing. Idempotent: running it twice changes nothing.
    @discardableResult
    func replan(_ reason: String) async -> IntegrityResult? {
        await checkAuthorizationStatus()
        guard isAuthorized else {
            return record(IntegrityResult(at: Date(), reason: reason, planned: 0, added: 0, removed: 0,
                                          overflow: 0, missing: 0, missingReason: "notAuthorized"))
        }
        guard let events = eventsProvider?() ?? nil else {
            print("⏭️ AlertPlanner: no event store yet; replan skipped (\(reason))")
            return nil
        }
        let now = Date()

        var slots: [AlertSlot] = []
        var immediates: [OlanaEvent] = []
        for event in events {
            let p = floorPlan(for: event, now: now)
            slots += p.slots
            slots += executionPlan(for: event, now: now)
            if p.immediate { immediates.append(event) }
        }

        let pending = await center.pendingNotificationRequests()
        // Snoozes, immediates and debug tests count against iOS's limit too.
        let others = pending.filter { !AlertID.isPlannedFloor($0.identifier) && !AlertID.isPlannedExec($0.identifier) }.count
        let plan = AlertPlanner.plan(slots, now: now, limit: max(0, AlertPlanner.pendingLimit - others))
        // Floor and execution are diffed separately, so neither can remove the other's.
        let keys = pending.map(Self.pendingKey)
        let floorDiff = AlertPlanner.diff(desired: plan.keep, pending: keys, in: AlertID.isPlannedFloor)
        let execDiff = AlertPlanner.diff(desired: plan.keep, pending: keys, in: AlertID.isPlannedExec)
        let diff = AlertPlanner.Diff(add: floorDiff.add + execDiff.add, remove: floorDiff.remove + execDiff.remove)

        if !diff.remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: diff.remove)
        }
        var addFailure: String?
        for slot in diff.add {
            do { try await center.add(request(for: slot)) }
            catch { addFailure = "\(error)" }
        }
        for event in immediates { await postImmediate(for: event) }

        // Records follow the plan, keeping any snoozes the user asked for.
        ExecutionAlertStore.shared.replace(with: plan.keep)
        var records: [UUID: ScheduledNotificationRecord] = [:]
        for (eventID, group) in Dictionary(grouping: plan.keep.filter { $0.kind == .floor }, by: \.eventID) {
            let snoozes = scheduledRecords[eventID]?.notificationIds.filter { !AlertID.isPlannedFloor($0) } ?? []
            records[eventID] = ScheduledNotificationRecord(
                eventId: eventID, urgency: EventUrgency(rawValue: group[0].urgencyRaw) ?? .low,
                notificationIds: group.map(\.id) + snoozes, scheduledAt: now, eventStartTime: group[0].eventStart)
        }
        for (eventID, rec) in scheduledRecords where records[eventID] == nil {
            let snoozes = rec.notificationIds.filter { !AlertID.isPlannedFloor($0) }
            if !snoozes.isEmpty, rec.eventStartTime > now.addingTimeInterval(-3600) {
                records[eventID] = ScheduledNotificationRecord(eventId: eventID, urgency: rec.urgency,
                    notificationIds: snoozes, scheduledAt: rec.scheduledAt, eventStartTime: rec.eventStartTime)
            }
        }
        scheduledRecords = records
        saveRecords()

        // Integrity (spec §5.6): everything planned should now be pending.
        // Re-add what isn't, once, then count what's still missing.
        let execKept = plan.keep.filter { $0.kind == .exec }
        func notPending(_ ids: Set<String>) -> [AlertSlot] {
            AlertPlanner.missingFloor(planned: plan.keep, pendingIDs: ids, now: Date())
                + execKept.filter { $0.fireDate > Date() && !ids.contains($0.id) }
        }
        var after = Set(await center.pendingNotificationRequests().map(\.identifier))
        let retry = notPending(after)
        if !retry.isEmpty {
            for slot in retry {
                do { try await center.add(request(for: slot)) }
                catch { addFailure = "\(error)" }
            }
            after = Set(await center.pendingNotificationRequests().map(\.identifier))
        }
        let floorCheck = AlertPlanner.floorCheck(plan, pendingIDs: after, now: Date())
        let execMissing = execKept.filter { $0.fireDate > Date() && !after.contains($0.id) }.count
        if !plan.overflow.isEmpty {
            print("⚠️ AlertPlanner: \(plan.overflow.count) reminders over capacity (\(plan.overflow.filter { $0.kind == .floor }.count) floor)")
        }

        // Observable delivery (step 3): what came due since the last check.
        let delivered = await center.deliveredNotifications()
        let delivery = DeliveryLedger.shared.check(
            kept: plan.keep,
            delivered: Dictionary(delivered.map { ($0.request.identifier, $0.date) }, uniquingKeysWith: max),
            now: now)

        return record(IntegrityResult(
            at: now, reason: reason, planned: plan.keep.count,
            added: diff.add.count, removed: diff.remove.count, overflow: plan.overflow.count,
            missing: floorCheck.missing, missingReason: floorCheck.reason,
            execPlanned: execKept.count, execMissing: execMissing,
            readded: retry.count, addError: floorCheck.missing + execMissing > 0 ? addFailure : nil,
            deliveryDue: delivery.due, deliveryObserved: delivery.observed))
    }

    /// Execution alerts an event wants (prep, get-ready, leave, join). Empty
    /// until M1-C; the namespace, diff and store are in place for it.
    func executionPlan(for event: OlanaEvent, now: Date) -> [AlertSlot] {
        guard isAuthorized, settings.allNotificationsEnabled else { return [] }
        let overrides = overridesProvider?(event) ?? OverrideResolver.resolve(event: nil, series: nil)
        let e = ExecContext.execEvent(for: event, overrides: overrides, now: now)
        return ExecutionPlanner.slots(e, settings: ExecContext.settings(), now: now, calendar: calendar)
    }

    /// The store's overrides for an event (set by AppServices, like eventsProvider).
    var overridesProvider: ((OlanaEvent) -> EffectiveOverrides)?

    private static func pendingKey(_ r: UNNotificationRequest) -> AlertPlanner.Pending {
        let fire = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            ?? (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
        let c = r.content
        let key = "\(Int(fire?.timeIntervalSince1970 ?? 0))|\(c.title)|\(c.subtitle)|\(c.body)|\(c.categoryIdentifier)"
        return .init(id: r.identifier, contentKey: key)
    }

    private func request(for slot: AlertSlot) -> UNNotificationRequest {
        let urgency = EventUrgency(rawValue: slot.urgencyRaw) ?? .low
        let profile = NotificationProfile.profile(for: urgency)
        let content = UNMutableNotificationContent()
        content.title              = slot.title
        content.subtitle           = slot.subtitle
        content.body               = slot.body
        content.sound              = resolvedSound(for: profile)
        content.threadIdentifier   = slot.eventID.uuidString
        content.categoryIdentifier = slot.category
        content.interruptionLevel  = resolvedInterruptionLevel(for: profile)
        if slot.kind == .exec {
            // Leave, get-ready, prep and join are about a moment, not the event:
            // time-sensitive so Focus doesn't hold them past it.
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        }
        content.userInfo           = [
            "eventId":           slot.eventID.uuidString,
            "urgency":           slot.urgencyRaw,
            "notificationIndex": slot.index
        ]
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot.fireDate)
        return UNNotificationRequest(identifier: slot.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    /// "Starting now", at most once per event and start time.
    private func postImmediate(for event: OlanaEvent) async {
        let key = "\(event.id.uuidString)|\(Int(event.start.timeIntervalSince1970))"
        var sent = Set(UserDefaults.standard.stringArray(forKey: immediateKey) ?? [])
        guard !sent.contains(key) else { return }

        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let profile = NotificationProfile.profile(for: event.urgency)
        let content = UNMutableNotificationContent()
        content.title              = event.title
        content.subtitle           = "starting soon"
        content.body               = "Starts at \(fmt.string(from: event.start))."
        content.sound              = event.hasPlaceholderUrgency ? .default : resolvedSound(for: profile)
        content.threadIdentifier   = event.id.uuidString
        content.categoryIdentifier = "EVENT_\(urgencyString(event.urgency).uppercased())"
        content.interruptionLevel  = event.hasPlaceholderUrgency ? .active : resolvedInterruptionLevel(for: profile)
        content.userInfo           = ["eventId": event.id.uuidString, "urgency": event.urgency.rawValue, "notificationIndex": 0]
        let request = UNNotificationRequest(
            identifier: "\(AlertID.floorPrefix)\(event.id.uuidString):immediate",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        do {
            try await center.add(request)
            sent.insert(key)
            // Keep the set small: drop keys for events that started over a day ago.
            let cutoff = Date().addingTimeInterval(-86400).timeIntervalSince1970
            sent = sent.filter { k in (Double(k.split(separator: "|").last ?? "") ?? 0) > cutoff }
            UserDefaults.standard.set(Array(sent), forKey: immediateKey)
        } catch {
            print("❌ NotificationEngine: Failed to post immediate reminder: \(error)")
        }
    }

    private let immediateKey = "olanaImmediateSent_v1"
    private let integrityKey = "olanaFloorIntegrity_v1"
    private let summaryKey = "olanaIntegritySummary_v1"

    /// The last 200 integrity results, for debugging. The gate reads
    /// `integritySummary`, which never rolls.
    var integrityHistory: [IntegrityResult] {
        guard let data = UserDefaults.standard.data(forKey: integrityKey) else { return [] }
        return (try? JSONDecoder().decode([IntegrityResult].self, from: data)) ?? []
    }

    /// Running totals for the M1-A gate (one week, zero missing).
    var integritySummary: IntegritySummary {
        guard let data = UserDefaults.standard.data(forKey: summaryKey) else { return IntegritySummary() }
        return (try? JSONDecoder().decode(IntegritySummary.self, from: data)) ?? IntegritySummary()
    }

    @discardableResult
    private func record(_ r: IntegrityResult) -> IntegrityResult {
        var summary = integritySummary
        summary.add(at: r.at, missing: r.missing, reason: r.missingReason, execMissing: r.execMissing ?? 0,
                    deliveryDue: r.deliveryDue ?? 0, deliveryObserved: r.deliveryObserved ?? 0)
        if let data = try? JSONEncoder().encode(summary) { UserDefaults.standard.set(data, forKey: summaryKey) }

        var all = integrityHistory
        all.append(r)
        if all.count > 200 { all.removeFirst(all.count - 200) }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: integrityKey) }
        if r.missing > 0 {
            print("❌ Floor integrity: \(r.missing) missing (\(r.missingReason ?? "unknown")) after \(r.reason)"
                  + (r.addError.map { ": \($0)" } ?? ""))
        }
        if let due = r.deliveryDue, due > 0 {
            print("📬 Delivery: \(r.deliveryObserved ?? 0)/\(due) observed since the last check")
        }
        return r
    }

    /// Kept for callers from before the planner: one replan covers every event.
    func topUpSyncedReminders(for events: [OlanaEvent]) async {
        requestReplan("sync")
    }

    // MARK: - AlarmKit gate

    /// Rebuild one event's alarm after its urgency or judgment changed, without
    /// touching its reminders (the replan owns those) or its Live Activity
    /// (which can't be started from the background).
    func refreshAlarm(for event: OlanaEvent) async {
        await AlarmKitManager.shared.cancelAlarm(for: event.id)
        await scheduleAlarmIfEarned(for: event)
    }

    /// Decide whether an event has earned the right to interrupt, and when.
    ///
    /// Three rules, all of which must hold:
    ///   1. Semantics exist. Without them we have no view on the event, and
    ///      guessing loudly is worse than staying quiet.
    ///   2. The combiner's alarm plan says it earns one, judged as of when it
    ///      would ring rather than now. .alarm requires severe consequence, so
    ///      a high score alone is never enough.
    ///   3. The user has left the matching toggle on.
    ///
    /// Rings when preparation has to start, which for anything needing it is
    /// earlier than the event itself. That is the whole point.
    private func scheduleAlarmIfEarned(for event: OlanaEvent) async {
        guard !event.completed,
              let semantics = event.cachedSemantics,
              let plan = UrgencyCombiner.alarmPlan(semantics: semantics, start: event.start)
        else { return }

        let allowed: Bool
        switch plan.tier {
        case .alarm:         allowed = settings.urgentAlarmsEnabled
        case .timeSensitive: allowed = settings.soonAlarmsEnabled
        case .notification, .silent: return   // never an alarm
        }
        guard allowed else { return }

        // Quiet hours are checked against the moment it would actually ring.
        let blockedByQuiet = settings.quietHoursEnabled
            && isInQuietHours(plan.fireDate)
            && !settings.alarmKitExemptFromQuietHours
        guard !blockedByQuiet else { return }

        // A prep-advanced alarm rings at a time the event itself does not explain,
        // so the label has to carry the reason or it reads as a malfunction.
        let label = plan.advancedByPrep ? "Start: \(event.title)" : event.title

        await AlarmKitManager.shared.scheduleAlarm(for: event, at: plan.fireDate, label: label)
    }

    // MARK: - Cancel Notifications

    /// Everything for one event. Only for user actions (Mark done) and events
    /// that are gone (deleted, or removed from the source calendar): PRD §3.9
    /// lets nothing else remove a floor reminder.
    func cancelNotifications(for eventId: UUID) async {
        let prefix = "\(AlertID.floorPrefix)\(eventId.uuidString):"
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let ids = Set(pending.filter { $0.hasPrefix(prefix) || AlertID.parseExec($0)?.event == eventId }
                      + (scheduledRecords[eventId]?.notificationIds ?? [])
                      + ExecutionAlertStore.shared.ids(for: eventId))
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
        scheduledRecords.removeValue(forKey: eventId)
        saveRecords()
        ExecutionAlertStore.shared.remove(eventId)
        DeliveryLedger.shared.forget { $0.contains(eventId.uuidString) }
        // Not gated on a notification record: an alarm or Live Activity can
        // exist without one, and must not outlive its event.
        await endLiveActivity(for: eventId)
        await AlarmKitManager.shared.cancelAlarm(for: eventId)
    }

    func cancelAllNotifications() async {
        center.removeAllPendingNotificationRequests()
        scheduledRecords.removeAll()
        saveRecords()
        ExecutionAlertStore.shared.replace(with: [])
        DeliveryLedger.shared.forget { _ in true }
    }

    // MARK: - Snooze Reschedule

    /// Schedules a single follow-up notification `snoozeMinutes` from now.
    /// Called by EventStore when the user taps a Snooze action on a delivered notification.
    func scheduleSnoozeNotification(for event: OlanaEvent, snoozeMinutes: Int) async {
        guard isAuthorized else { return }

        let snoozeDate = Date().addingTimeInterval(Double(snoozeMinutes) * 60)
        let profile    = NotificationProfile.profile(for: event.urgency)

        // Unique ID — timestamp suffix prevents collision with prior snoozes
        let notificationId = "olana:\(event.id.uuidString):snooze:\(Int(Date().timeIntervalSince1970))"

        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let startTime = fmt.string(from: event.start)

        let content = UNMutableNotificationContent()
        content.title              = event.title
        content.subtitle           = "Snoozed reminder"
        content.body               = "Starts at \(startTime). You asked for a nudge."
        content.sound              = resolvedSound(for: profile)
        content.threadIdentifier   = event.id.uuidString
        content.categoryIdentifier = "EVENT_\(urgencyString(event.urgency).uppercased())"
        content.interruptionLevel  = resolvedInterruptionLevel(for: profile)
        content.userInfo           = [
            "eventId": event.id.uuidString,
            "urgency": event.urgency.rawValue,
            "notificationIndex": 99  // sentinel: marks this as a snooze notification
        ]

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: snoozeDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

        do {
            try await center.add(request)
            // Append the snooze ID to the record so a later cancel() removes it too
            let existingIds = scheduledRecords[event.id]?.notificationIds ?? []
            scheduledRecords[event.id] = ScheduledNotificationRecord(
                eventId:         event.id,
                urgency:         event.urgency,
                notificationIds: existingIds + [notificationId],
                scheduledAt:     Date(),
                eventStartTime:  event.start
            )
            saveRecords()
            print("✅ NotificationEngine: Snoozed '\(event.title)' for \(snoozeMinutes)m → fires at \(snoozeDate)")

            // Re-alarm: schedule an AlarmKit alarm at snooze wake time for Critical events.
            if event.urgency == .high && settings.reAlarmEnabled {
                await AlarmKitManager.shared.scheduleReAlarm(
                    eventId: event.id,
                    title:   event.title,
                    at:      snoozeDate
                )
            }
        } catch {
            print("❌ NotificationEngine: Failed to schedule snooze: \(error)")
        }
    }

    // MARK: - Handle Actions

    func handleNotificationAction(actionIdentifier: String, eventId: UUID, requestID: String = "") async {
        if let kind = AlertID.parseExec(requestID)?.kind {
            await handleExecAction(actionIdentifier, kind: kind, eventId: eventId)
            return
        }
        if actionIdentifier == "MARK_DONE" {
            await handleMarkDone(eventId: eventId)
        } else if actionIdentifier.hasPrefix("SNOOZE") {
            let part     = actionIdentifier.replacingOccurrences(of: "SNOOZE_", with: "").lowercased()
            let urgency: EventUrgency = part == "low" ? .low : (part == "medium" ? .medium : .high)
            await handleSnooze(eventId: eventId, urgency: urgency)
        }
    }

    // MARK: - Execution actions (spec v3 §7.3, §7.7; PRD v6 §3.9)

    private func handleExecAction(_ action: String, kind: ExecKind, eventId: UUID) async {
        guard let event = eventsProvider?()?.first(where: { $0.id == eventId }) else { return }
        let key = event.overrideEventKey
        let overrides = overridesProvider?(event) ?? OverrideResolver.resolve(event: nil, series: nil)
        let now = Date()
        func progress(_ change: (inout EventProgress) -> Void) {
            EventProgressStore.shared.update(key, eventStart: event.start, change)
        }
        switch action {
        case "EXEC_PREP_DONE":
            progress { $0.prepDone = true }
            PlusStore.shared.record(.prepStarted, eventKey: key)
        case "EXEC_PREP_SNOOZE":
            await scheduleSnoozeNotification(for: event, snoozeMinutes: 10)
        case "EXEC_OK":
            PlusStore.shared.record(.gotReady, eventKey: key)
        case "EXEC_LEAVING", "EXEC_DIRECTIONS":
            await markLeaving(event, overrides: overrides, now: now)
            if action == "EXEC_DIRECTIONS" { openDirections(event, overrides: overrides) }
        case "EXEC_LEAVE_SNOOZE":
            let e = ExecContext.execEvent(for: event, overrides: overrides, now: now)
            let so = EventProgressStore.shared.get(key).leaveSnoozes ?? 0
            if let slot = ExecutionPlanner.leaveSnooze(e, snoozesSoFar: so, now: now, calendar: calendar) {
                try? await center.add(request(for: slot))
                progress { $0.leaveSnoozes = so + 1 }
            }
        case "EXEC_JOIN":
            progress { $0.joinedAt = now }
            if let url = ExecContext.trip(for: event, overrides: overrides, now: now).times.isVirtual
                ? (event.meetingURL ?? NotesCleaner.clean(notes: event.notes, location: event.location).meetingURL) : nil {
                await UIApplication.shared.open(url)
            }
            // Join tapped: the rest of the floor goes (PRD v6 §1.4, principle 7).
            await cancelNotifications(for: eventId)
        case UNNotificationDefaultActionIdentifier:
            // Tapping the alert is acting on it (a Plus moment, PRD v6 §1.10).
            switch kind {
            case .leave, .leaveSnooze: PlusStore.shared.record(.leftOnTime, eventKey: key)
            case .getReady: PlusStore.shared.record(.gotReady, eventKey: key)
            case .prep: PlusStore.shared.record(.prepStarted, eventKey: key)
            case .join: break
            }
        default: break
        }
        requestReplan("exec action")
    }

    /// "I'm leaving": on the way, departure metrics, and only the floor
    /// reminders before the start and the leave snoozes are removed (PRD v6 §3.9).
    func markLeaving(_ event: OlanaEvent, overrides: EffectiveOverrides, now: Date = Date()) async {
        let key = event.overrideEventKey
        let trip = ExecContext.trip(for: event, overrides: overrides, now: now)
        let eta = ETAStore.shared.get(key)?.reading.seconds
        EventProgressStore.shared.update(key, eventStart: event.start) { p in
            p.leftAt = now
            p.leaveByAtDeparture = trip.times.leaveBy
            p.etaAtDeparture = eta
        }
        PlusStore.shared.record(.leftOnTime, eventKey: key)
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { r in
            guard r.content.userInfo["eventId"] as? String == event.id.uuidString else { return false }
            if AlertID.parseExec(r.identifier)?.kind == .leaveSnooze { return true }
            guard AlertID.isPlannedFloor(r.identifier) || r.identifier.hasPrefix(AlertID.floorPrefix) else { return false }
            let fire = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return (fire ?? .distantFuture) < event.start
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        DeliveryLedger.shared.forget { ids.contains($0) }
    }

    func openDirections(_ event: OlanaEvent, overrides: EffectiveOverrides) {
        guard let place = overrides.place ?? event.resolvedPlace else { return }
        var a = URLComponents(string: "https://maps.apple.com/")!
        a.queryItems = [URLQueryItem(name: "daddr", value: "\(place.latitude),\(place.longitude)"),
                        URLQueryItem(name: "q", value: place.name)]
        if let url = a.url { UIApplication.shared.open(url) }
    }

    private func handleMarkDone(eventId: UUID) async {
        await cancelNotifications(for: eventId)
        NotificationCenter.default.post(name: .eventMarkedDone, object: nil, userInfo: ["eventId": eventId])
    }

    /// Snooze adds a reminder. It doesn't remove the event's other reminders:
    /// PRD §3.9 lists the user actions that do, and snooze isn't one of them.
    private func handleSnooze(eventId: UUID, urgency: EventUrgency) async {
        NotificationCenter.default.post(
            name: .eventSnoozed, object: nil,
            userInfo: ["eventId": eventId, "snoozeMinutes": settings.snoozeMinutes(for: urgency)]
        )
    }

    // MARK: - Persistence (FIX: survive app restarts)

    private func saveRecords() {
        let stringKeyed = Dictionary(
            uniqueKeysWithValues: scheduledRecords.map { ($0.key.uuidString, $0.value) }
        )
        if let data = try? JSONEncoder().encode(stringKeyed) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    private func loadRecords() {
        guard
            let data    = UserDefaults.standard.data(forKey: recordsKey),
            let decoded = try? JSONDecoder().decode([String: ScheduledNotificationRecord].self, from: data)
        else { return }

        scheduledRecords = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { pair -> (UUID, ScheduledNotificationRecord)? in
                guard let uuid = UUID(uuidString: pair.key) else { return nil }
                return (uuid, pair.value)
            }
        )
    }

    // MARK: - Live Activity

    /// Called by HomeView's imminent timer when an event enters the lead window.
    /// Idempotent — skips if a Live Activity for this event is already running.
    func startLiveActivityNow(for event: OlanaEvent) async {
        guard #available(iOS 16.2, *) else { return }
        // If a Live Activity for this event is already running, leave it alone.
        // Check both by cached ID and by event ID directly (survives app restart).
        let alreadyRunning = Activity<OlanaEventAttributes>.activities.contains(where: {
            $0.attributes.eventId == event.id.uuidString ||
            $0.id == liveActivityIds[event.id]
        })
        if alreadyRunning { return }
        guard NotificationProfile.profile(for: event.urgency).enableLiveActivity else { return }
        await scheduleLiveActivity(for: event)
    }

    /// Sweeps all supplied events and starts a Live Activity for every one that is
    /// currently within the user-configured lead window and doesn't already have one
    /// running. Call on foreground / appear so the app catches up after being suspended.
    func startLiveActivitiesIfNeeded(for events: [OlanaEvent]) async {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now        = Date()
        let leadWindow = Double(settings.liveActivityLeadMinutes) * 60
        for event in events where !event.completed {
            let timeUntil = event.start.timeIntervalSince(now)
            guard timeUntil > 0 && timeUntil <= leadWindow else { continue }
            await startLiveActivityNow(for: event)
        }
    }

    private func scheduleLiveActivity(for event: OlanaEvent) async {
        guard #available(iOS 16.2, *) else { return }
        let liveActivityEnabled: Bool
        switch event.urgency {
        case .high:   liveActivityEnabled = settings.countdownTimerEnabled
        case .medium: liveActivityEnabled = settings.soonLiveActivityEnabled
        case .low:    liveActivityEnabled = settings.laterLiveActivityEnabled
        }
        guard liveActivityEnabled else { return }

        let timeUntilEvent = event.start.timeIntervalSince(Date())
        let leadWindow     = Double(settings.liveActivityLeadMinutes) * 60
        // Only start within the user-configured lead window (default 15 min).
        guard timeUntilEvent > 0 && timeUntilEvent <= leadWindow else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("⚠️ NotificationEngine: Live Activities are disabled in system settings")
            return
        }

        // End any existing Live Activity for this event before starting a new one.
        await endLiveActivity(for: event.id)

        let attributes = OlanaEventAttributes(
            eventId:      event.id.uuidString,
            eventTitle:   event.title,
            urgencyRaw:   event.urgency.rawValue
        )
        let initialState = OlanaEventAttributes.ContentState(
            eventStart:       event.start,
            minutesRemaining: max(0, Int(timeUntilEvent / 60)),
            status:           "upcoming"
        )

        do {
            let activity = try Activity<OlanaEventAttributes>.request(
                attributes: attributes,
                content: ActivityContent(
                    state:     initialState,
                    staleDate: event.start.addingTimeInterval(300)
                ),
                pushType: nil
            )
            liveActivityIds[event.id] = activity.id
            print("✅ NotificationEngine: Started Live Activity \(activity.id) for '\(event.title)'")
        } catch {
            // Most common reason: NSSupportsLiveActivities not in Info.plist, or widget
            // extension not yet added. Add the key and a WidgetKit extension to resolve.
            print("❌ NotificationEngine: Live Activity failed — \(error.localizedDescription)")
        }
    }

    private func endLiveActivity(for eventId: UUID) async {
        guard #available(iOS 16.2, *) else { return }
        // Find by event ID directly — works even after app restart when liveActivityIds is empty.
        let activity = Activity<OlanaEventAttributes>.activities.first(where: {
            $0.attributes.eventId == eventId.uuidString
        }) ?? Activity<OlanaEventAttributes>.activities.first(where: {
            $0.id == liveActivityIds[eventId]
        })
        if let activity {
            let doneState = OlanaEventAttributes.ContentState(
                eventStart:       Date(),
                minutesRemaining: 0,
                status:           "done"
            )
            await activity.end(
                ActivityContent(state: doneState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            print("✅ NotificationEngine: Ended Live Activity \(activity.id)")
        }
        liveActivityIds.removeValue(forKey: eventId)
    }

    // MARK: - Calendar Integration

    nonisolated private func addCalendarAlarm(for event: OlanaEvent) async {
        let store      = EKEventStore()
        let title      = event.title
        let start      = event.start
        let end        = event.end

        if #available(iOS 17.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                if granted { await createCalendarEvent(in: store, title: title, start: start, end: end) }
            } catch {
                print("❌ NotificationEngine: Calendar access error: \(error)")
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                if granted {
                    Task { await self.createCalendarEvent(in: store, title: title, start: start, end: end) }
                }
            }
        }
    }

    nonisolated private func createCalendarEvent(in store: EKEventStore, title: String, start: Date, end: Date) async {
        let calEvent       = EKEvent(eventStore: store)
        calEvent.title     = title
        calEvent.startDate = start
        calEvent.endDate   = end
        calEvent.calendar  = store.defaultCalendarForNewEvents
        calEvent.addAlarm(EKAlarm(relativeOffset: -3600))
        do {
            try store.save(calEvent, span: .thisEvent)
        } catch {
            print("❌ NotificationEngine: Failed to save calendar event: \(error)")
        }
    }

    // MARK: - Helpers

    private func isInQuietHours(_ date: Date) -> Bool {
        guard settings.quietHoursEnabled else { return false }
        let hour           = calendar.component(.hour, from: date)
        let quietStartHour = calendar.component(.hour, from: settings.quietHoursStart)
        let quietEndHour   = calendar.component(.hour, from: settings.quietHoursEnd)
        return quietStartHour > quietEndHour
            ? (hour >= quietStartHour || hour < quietEndHour)
            : (hour >= quietStartHour && hour < quietEndHour)
    }

    private func normalizeForQuietHours(_ date: Date) -> Date {
        guard settings.quietHoursEnabled else { return date }
        let hour            = calendar.component(.hour, from: date)
        let quietStartHour  = calendar.component(.hour, from: settings.quietHoursStart)
        let quietEndHour    = calendar.component(.hour, from: settings.quietHoursEnd)
        let inQuiet: Bool   = quietStartHour > quietEndHour
            ? (hour >= quietStartHour || hour < quietEndHour)
            : (hour >= quietStartHour && hour < quietEndHour)
        guard inQuiet else { return date }
        return calendar.date(bySettingHour: quietEndHour, minute: 0, second: 0, of: date) ?? date
    }

    /// Subtitle line — shows timing relative to the event.
    private func subtitleForTiming(_ timing: NotificationProfile.NotificationTiming) -> String {
        if timing.daysBefore > 0 {
            return timing.daysBefore == 1 ? "tomorrow" : "in \(timing.daysBefore) days"
        }
        if timing.specificTime != nil  && timing.minutesBefore == 0 { return "today" }
        if timing.specificTime == nil  && timing.minutesBefore == 0 { return "starting soon" }
        switch timing.minutesBefore {
        case 60:  return "in 1 hour"
        case 30:  return "in 30 minutes"
        case 15:  return "in 15 minutes"
        case 10:  return "in 10 minutes"
        default:  return "in \(timing.minutesBefore) minutes"
        }
    }

    /// Body line — always includes the event's start time so users know exactly when.
    private func bodyForUrgency(
        _ urgency: EventUrgency,
        eventStart: Date,
        timing: NotificationProfile.NotificationTiming
    ) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        let time = fmt.string(from: eventStart)

        if timing.daysBefore > 0 {
            switch urgency {
            case .low:    return "Starts at \(time) tomorrow. It's on your list."
            case .medium: return "Starts at \(time) tomorrow. Good time to prepare."
            case .high:   return "Starts at \(time) tomorrow. Get ready tonight."
            }
        }

        switch urgency {
        case .low:    return "Starts at \(time). It's on your list."
        case .medium: return "Starts at \(time). Worth a heads up."
        case .high:   return "Starts at \(time). Don't miss this one."
        }
    }

    // MARK: - Debug

#if DEBUG
    /// Starts a test Live Activity for a mock Critical event 5 minutes from now.
    /// Use this from the Developer section in Settings to verify Live Activity + Dynamic Island UI.
    func debugStartTestLiveActivity() async {
        guard #available(iOS 16.2, *) else {
            print("⚠️ Live Activities require iOS 16.2+")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("⚠️ Live Activities are disabled — enable them in Settings → [App Name] → Live Activities")
            return
        }
        let eventStart = Date().addingTimeInterval(300) // 5 min from now
        let attributes = OlanaEventAttributes(
            eventId:      UUID().uuidString,
            eventTitle:   "Test Critical Event",
            urgencyRaw:   2
        )
        let state = OlanaEventAttributes.ContentState(
            eventStart:       eventStart,
            minutesRemaining: 5,
            status:           "upcoming"
        )
        do {
            let activity = try Activity<OlanaEventAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: eventStart.addingTimeInterval(600)),
                pushType: nil
            )
            print("✅ Debug Live Activity started: \(activity.id)")
        } catch {
            print("❌ Live Activity failed: \(error.localizedDescription)")
        }
    }
#endif

    // MARK: - Settings-Driven Scheduling Helpers

    /// Build notification timings from user cadence/nudge settings instead of static profile arrays.
    private func timingsForEvent(_ event: OlanaEvent, profile: NotificationProfile) -> [NotificationProfile.NotificationTiming] {
        switch event.urgency {
        case .high:   return criticalTimings(cadence: settings.criticalEscalationCadence)
        case .medium: return soonTimings(event: event, cadence: settings.soonEventCadence)
        case .low:    return laterTimings(cadence: settings.laterCadence)
        }
    }

    /// Critical: cadence 1 = only 10 min before; each step adds an earlier reminder.
    private func criticalTimings(cadence: Int) -> [NotificationProfile.NotificationTiming] {
        let all: [NotificationProfile.NotificationTiming] = [
            .init(minutesBefore: 0, specificTime: (18, 0), daysBefore: 1), // evening before
            .init(minutesBefore: 240),  // 4 hrs
            .init(minutesBefore: 120),  // 2 hrs
            .init(minutesBefore: 30),   // 30 min
            .init(minutesBefore: 10)    // 10 min (always included at cadence 1)
        ]
        return Array(all.suffix(min(max(cadence, 1), all.count)))
    }

    /// Soon: cadence 1 = day-before only; each step adds a closer reminder.
    /// Morning/afternoon nudges are appended based on user toggles.
    private func soonTimings(event: OlanaEvent, cadence: Int) -> [NotificationProfile.NotificationTiming] {
        let all: [NotificationProfile.NotificationTiming] = [
            .init(minutesBefore: 0, specificTime: (18, 0), daysBefore: 1), // evening before
            .init(minutesBefore: 120),  // 2 hrs
            .init(minutesBefore: 30),   // 30 min
            .init(minutesBefore: 15),   // 15 min
            .init(minutesBefore: 0)     // at time
        ]
        var timings = Array(all.suffix(min(max(cadence, 1), all.count)))

        // Morning nudge fires at the user's configured time on the event's day.
        if settings.morningNudgeEnabled {
            let h = calendar.component(.hour,   from: settings.morningNudgeTime)
            let m = calendar.component(.minute, from: settings.morningNudgeTime)
            timings.append(.init(minutesBefore: 0, specificTime: (h, m)))
        }
        // Afternoon nudge fires at the user's configured time on the event's day.
        if settings.afternoonNudgeEnabled {
            let h = calendar.component(.hour,   from: settings.afternoonNudgeTime)
            let m = calendar.component(.minute, from: settings.afternoonNudgeTime)
            timings.append(.init(minutesBefore: 0, specificTime: (h, m)))
        }
        return timings
    }

    /// Later: cadence 1 = farthest reminder only; each step adds a closer one.
    private func laterTimings(cadence: Int) -> [NotificationProfile.NotificationTiming] {
        let all: [NotificationProfile.NotificationTiming] = [
            .init(minutesBefore: 0, specificTime: (8, 0), daysBefore: 7),  // 1 week before
            .init(minutesBefore: 0, specificTime: (8, 0), daysBefore: 3),  // 3 days before
            .init(minutesBefore: 0, specificTime: (8, 0), daysBefore: 1),  // day before
            .init(minutesBefore: 120),  // 2 hrs before
            .init(minutesBefore: 0)     // at time
        ]
        return Array(all.suffix(min(max(cadence, 1), all.count)))
    }

    /// Notification sound from user's selection. Later (low urgency) stays silent regardless.
    private func resolvedSound(for profile: NotificationProfile) -> UNNotificationSound? {
        guard profile.sound != nil else { return nil }
        switch settings.notificationSound {
        case "none": return nil
        default:
            let name = UNNotificationSoundName(rawValue: "\(settings.notificationSound).m4a")
            return UNNotificationSound(named: name)
        }
    }

    /// Interruption level — respects each tier's "Bypass Focus" toggle.
    private func resolvedInterruptionLevel(for profile: NotificationProfile) -> UNNotificationInterruptionLevel {
        switch profile.urgency {
        case .high:   return settings.allowTimeSensitiveHigh    ? .timeSensitive : .active
        case .medium: return settings.soonBypassFocusEnabled    ? .timeSensitive : .active
        case .low:    return settings.laterBypassFocusEnabled   ? .timeSensitive : .active
        }
    }

    private func urgencyString(_ urgency: EventUrgency) -> String {
        switch urgency {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        }
    }

}

// MARK: - Notification Names

extension Notification.Name {
    static let eventMarkedDone = Notification.Name("eventMarkedDone")
    static let eventSnoozed    = Notification.Name("eventSnoozed")
}

// MARK: - Placeholder urgency

extension OlanaEvent {
    /// True while `urgency` is only the value sync assigned on import: nobody,
    /// neither the model nor the user nor their calendar setting, has said how
    /// urgent this is. Such events get a basic reminder, not an urgency profile.
    var hasPlaceholderUrgency: Bool {
        isFromExternalCalendar && cachedSemantics == nil && urgencyOverrideRaw == nil
    }
}

