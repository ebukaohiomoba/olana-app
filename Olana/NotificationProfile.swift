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
import BackgroundTasks
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
    @Published var laterAlarmsEnabled: Bool {
        didSet { save(laterAlarmsEnabled, forKey: "laterAlarmsEnabled") }
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
    @Published var escalateToSoonEnabled: Bool {
        didSet { save(escalateToSoonEnabled, forKey: "escalateToSoonEnabled") }
    }
    @Published var escalateToCriticalEnabled: Bool {
        didSet { save(escalateToCriticalEnabled, forKey: "escalateToCriticalEnabled") }
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
        self.laterAlarmsEnabled         = kv.bool(  "laterAlarmsEnabled")          ?? UserDefaults.standard.object(forKey: "laterAlarmsEnabled")         as? Bool ?? false
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
        self.escalateToSoonEnabled      = kv.bool("escalateToSoonEnabled")      ?? UserDefaults.standard.object(forKey: "escalateToSoonEnabled")      as? Bool ?? true
        self.escalateToCriticalEnabled  = kv.bool("escalateToCriticalEnabled")  ?? UserDefaults.standard.object(forKey: "escalateToCriticalEnabled")  as? Bool ?? true
        self.silentUntilEscalated       = kv.bool("silentUntilEscalated")       ?? UserDefaults.standard.object(forKey: "silentUntilEscalated")       as? Bool ?? true
        self.criticalExemptFromQuietHours  = kv.bool("criticalExemptFromQuietHours")  ?? UserDefaults.standard.object(forKey: "criticalExemptFromQuietHours")  as? Bool ?? true
        self.alarmKitExemptFromQuietHours  = kv.bool("alarmKitExemptFromQuietHours")  ?? UserDefaults.standard.object(forKey: "alarmKitExemptFromQuietHours")  as? Bool ?? true
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
                case "laterAlarmsEnabled":
                    if let v = self.kv.bool("laterAlarmsEnabled")         { self.laterAlarmsEnabled = v }
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
                case "escalateToSoonEnabled":
                    if let v = self.kv.bool("escalateToSoonEnabled")           { self.escalateToSoonEnabled = v }
                case "escalateToCriticalEnabled":
                    if let v = self.kv.bool("escalateToCriticalEnabled")       { self.escalateToCriticalEnabled = v }
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

// MARK: - Cached Event Record (persists across app restarts for background Live Activity)

struct CachedEventRecord: Codable {
    let id: UUID
    let title: String
    let start: Date
    let urgencyRaw: Int   // 0=low, 1=medium, 2=high — mirrors EventUrgency.rawValue
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
    private var dailyNotificationCount = 0
    private var lastCountResetDate: Date?
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

        center.setNotificationCategories([
            UNNotificationCategory(identifier: "EVENT_LOW",    actions: [markDone, snoozeLow],    intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_MEDIUM", actions: [markDone, snoozeMedium], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_HIGH",   actions: [markDone, snoozeHigh],   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Schedule Notifications

    func scheduleNotifications(for event: OlanaEvent, confidence: Double = 1.0) async {
        // Re-register categories so snooze button labels always reflect current settings.
        setupNotificationCategories()
        guard isAuthorized, settings.allNotificationsEnabled else { return }

        // Later tasks with "silent until escalated" skip scheduling entirely.
        if event.urgency == .low && settings.silentUntilEscalated { return }

        await cancelNotifications(for: event.id)

        let profile = NotificationProfile.profile(for: event.urgency)

        // Use cadence/nudge settings to build timings instead of static profile arrays.
        let timingsToUse = timingsForEvent(event, profile: profile)
        var candidatePairs: [(date: Date, timing: NotificationProfile.NotificationTiming)] = []

        for timing in timingsToUse {
            var candidateDate: Date?

            if timing.daysBefore > 0, let specificTime = timing.specificTime {
                // ── Evening-before (or N-days-before) at a fixed clock time ──────
                let targetDay = calendar.date(byAdding: .day, value: -timing.daysBefore, to: event.start) ?? event.start
                candidateDate = calendar.date(
                    bySettingHour: specificTime.hour, minute: specificTime.minute, second: 0, of: targetDay
                )

            } else if let specificTime = timing.specificTime, timing.minutesBefore == 0 {
                // ── Same-day at a fixed clock time (e.g. 8 am) ──────────────────
                let startOfDay = calendar.startOfDay(for: event.start)
                let proposedDate = calendar.date(
                    bySettingHour: specificTime.hour, minute: specificTime.minute, second: 0, of: startOfDay
                )
                let eventHour = calendar.component(.hour, from: event.start)

                if eventHour < 10 {
                    // FIX: event starts before 10 am — fall back to 30 min before
                    candidateDate = calendar.date(byAdding: .minute, value: -30, to: event.start)
                } else {
                    candidateDate = proposedDate
                }

            } else {
                // ── Relative: N minutes before the event ────────────────────────
                candidateDate = calendar.date(byAdding: .minute, value: -timing.minutesBefore, to: event.start)
            }

            if let date = candidateDate {
                candidatePairs.append((date: date, timing: timing))
            }
        }

        // Filter past, respect quiet hours, deduplicate, cap
        let now = Date()
        candidatePairs = candidatePairs.filter { $0.date > now }

        // Last-resort fallback: if every pre-event window has already passed
        // (e.g. event created seconds before it starts), fire one immediate
        // notification so the user is never left in silence.
        // Use a 30-second grace window so events set to "now" also match.
        if candidatePairs.isEmpty && event.start >= now.addingTimeInterval(-30) {
            let immediateDate = now.addingTimeInterval(5)
            candidatePairs = [(date: immediateDate,
                               timing: NotificationProfile.NotificationTiming(minutesBefore: 0))]
        }

        // Respect quiet hours unless the urgency tier is configured to be exempt.
        let exemptFromQuiet: Bool
        switch profile.urgency {
        case .high:        exemptFromQuiet = settings.criticalExemptFromQuietHours
        case .medium, .low: exemptFromQuiet = false
        }
        if !exemptFromQuiet {
            candidatePairs = candidatePairs.map { (normalizeForQuietHours($0.date), $0.timing) }
        }
        candidatePairs = deduplicatePairs(candidatePairs, tolerance: 60)

        if candidatePairs.count > profile.maxNotificationsPerEvent {
            candidatePairs = Array(candidatePairs.prefix(profile.maxNotificationsPerEvent))
        }

        resetDailyCountIfNeeded()
        let remaining = settings.dailyNotificationCap - dailyNotificationCount
        if candidatePairs.count > remaining {
            candidatePairs = Array(candidatePairs.prefix(remaining))
        }

        // Schedule each notification
        var notificationIds: [String] = []
        for (index, pair) in candidatePairs.enumerated() {
            let notificationId = "olana:\(event.id.uuidString):\(index)"

            let content = UNMutableNotificationContent()
            content.title               = event.title
            content.subtitle            = subtitleForTiming(pair.timing)
            content.body                = bodyForUrgency(event.urgency, eventStart: event.start, timing: pair.timing)
            content.sound               = resolvedSound(for: profile)
            content.threadIdentifier    = event.id.uuidString
            content.categoryIdentifier  = "EVENT_\(urgencyString(event.urgency).uppercased())"
            content.interruptionLevel   = resolvedInterruptionLevel(for: profile)
            content.userInfo            = [
                "eventId":           event.id.uuidString,
                "urgency":           event.urgency.rawValue,
                "notificationIndex": index
            ]

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: pair.date)
            let trigger    = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request    = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

            do {
                try await center.add(request)
                notificationIds.append(notificationId)
                dailyNotificationCount += 1
                print("✅ NotificationEngine: Scheduled '\(event.title)' at \(pair.date)")
            } catch {
                print("❌ NotificationEngine: Failed to schedule: \(error)")
            }
        }

        let record = ScheduledNotificationRecord(
            eventId:         event.id,
            urgency:         event.urgency,
            notificationIds: notificationIds,
            scheduledAt:     Date(),
            eventStartTime:  event.start
        )
        scheduledRecords[event.id] = record
        saveRecords()
        updateUpcomingCache(add: event)
        // Schedule a background wakeup so Live Activity can start even if the app is suspended.
        if event.start.timeIntervalSinceNow < 24 * 3600 {
            NotificationEngine.scheduleLiveActivityCheck()
        }

        if profile.enableLiveActivity {
            await scheduleLiveActivity(for: event)
        }

        if settings.enableCalendarRedundancy {
            await addCalendarAlarm(for: event)
        }

        // AlarmKit: schedule a full-screen alarm based on per-urgency setting.
        let alarmKitEnabled: Bool
        switch event.urgency {
        case .high:   alarmKitEnabled = settings.urgentAlarmsEnabled
        case .medium: alarmKitEnabled = settings.soonAlarmsEnabled
        case .low:    alarmKitEnabled = settings.laterAlarmsEnabled
        }
        // Skip alarm if event falls in quiet hours and the user hasn't exempted alarms.
        let alarmBlockedByQuiet = settings.quietHoursEnabled
            && isInQuietHours(event.start)
            && !settings.alarmKitExemptFromQuietHours
        if alarmKitEnabled && !alarmBlockedByQuiet {
            await AlarmKitManager.shared.scheduleAlarm(for: event)
        }
    }

    // MARK: - Cancel Notifications

    func cancelNotifications(for eventId: UUID) async {
        guard let record = scheduledRecords[eventId] else { return }
        center.removePendingNotificationRequests(withIdentifiers: record.notificationIds)
        scheduledRecords.removeValue(forKey: eventId)
        saveRecords()
        removeFromUpcomingCache(eventId: eventId)
        await endLiveActivity(for: eventId)
        await AlarmKitManager.shared.cancelAlarm(for: eventId)
    }

    func cancelAllNotifications() async {
        center.removeAllPendingNotificationRequests()
        scheduledRecords.removeAll()
        saveRecords()
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

    func handleNotificationAction(actionIdentifier: String, eventId: UUID) async {
        if actionIdentifier == "MARK_DONE" {
            await handleMarkDone(eventId: eventId)
        } else if actionIdentifier.hasPrefix("SNOOZE") {
            let part     = actionIdentifier.replacingOccurrences(of: "SNOOZE_", with: "").lowercased()
            let urgency: EventUrgency = part == "low" ? .low : (part == "medium" ? .medium : .high)
            await handleSnooze(eventId: eventId, urgency: urgency)
        }
    }

    private func handleMarkDone(eventId: UUID) async {
        await cancelNotifications(for: eventId)
        NotificationCenter.default.post(name: .eventMarkedDone, object: nil, userInfo: ["eventId": eventId])
    }

    private func handleSnooze(eventId: UUID, urgency: EventUrgency) async {
        await cancelNotifications(for: eventId)
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

    // MARK: - Upcoming Event Cache (for background Live Activity)

    private let upcomingCacheKey = "olana_upcoming_events_v1"

    private func loadUpcomingCache() -> [String: CachedEventRecord] {
        guard let data    = UserDefaults.standard.data(forKey: upcomingCacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedEventRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveUpcomingCache(_ cache: [String: CachedEventRecord]) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: upcomingCacheKey)
        }
    }

    private func updateUpcomingCache(add event: OlanaEvent) {
        var cache = loadUpcomingCache()
        cache[event.id.uuidString] = CachedEventRecord(
            id: event.id, title: event.title,
            start: event.start, urgencyRaw: event.urgency.rawValue
        )
        // Prune events that have already passed
        let now = Date()
        cache = cache.filter { $0.value.start > now }
        saveUpcomingCache(cache)
    }

    private func removeFromUpcomingCache(eventId: UUID) {
        var cache = loadUpcomingCache()
        cache.removeValue(forKey: eventId.uuidString)
        saveUpcomingCache(cache)
    }

    /// Start Live Activities for cached upcoming events that are inside the lead window.
    /// Called by the BGAppRefreshTask so the countdown starts even when the app is suspended.
    func startLiveActivitiesFromCache() {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now        = Date()
        let leadWindow = Double(settings.liveActivityLeadMinutes) * 60
        for (_, record) in loadUpcomingCache() {
            let timeUntil = record.start.timeIntervalSince(now)
            guard timeUntil > 0 && timeUntil <= leadWindow else { continue }

            // Respect per-urgency Live Activity toggle
            let enabled: Bool
            switch record.urgencyRaw {
            case 2:  enabled = settings.countdownTimerEnabled
            case 1:  enabled = settings.soonLiveActivityEnabled
            default: enabled = settings.laterLiveActivityEnabled
            }
            guard enabled else { continue }

            // Skip if already running for this event
            if Activity<OlanaEventAttributes>.activities.contains(where: { $0.attributes.eventId == record.id.uuidString }) {
                continue
            }

            let attributes = OlanaEventAttributes(
                eventId: record.id.uuidString, eventTitle: record.title, urgencyRaw: record.urgencyRaw
            )
            let state = OlanaEventAttributes.ContentState(
                eventStart: record.start,
                minutesRemaining: max(0, Int(timeUntil / 60)),
                status: "upcoming"
            )
            do {
                let activity = try Activity<OlanaEventAttributes>.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: record.start.addingTimeInterval(300)),
                    pushType: nil
                )
                liveActivityIds[record.id] = activity.id
                print("✅ NotificationEngine: Background Live Activity started for '\(record.title)'")
            } catch {
                print("❌ NotificationEngine: Background Live Activity failed — \(error.localizedDescription)")
            }
        }
    }

    /// Schedule a BGAppRefreshTask to wake the app before the next imminent event.
    /// Safe to call repeatedly — submitting a duplicate identifier replaces the previous request.
    static func scheduleLiveActivityCheck() {
        let request = BGAppRefreshTaskRequest(identifier: "com.olana.liveActivityCheck")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // no sooner than 5 min
        try? BGTaskScheduler.shared.submit(request)
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

    private func deduplicatePairs(
        _ pairs: [(date: Date, timing: NotificationProfile.NotificationTiming)],
        tolerance: TimeInterval
    ) -> [(date: Date, timing: NotificationProfile.NotificationTiming)] {
        var result: [(date: Date, timing: NotificationProfile.NotificationTiming)] = []
        for pair in pairs {
            let isDuplicate = result.contains { abs($0.date.timeIntervalSince(pair.date)) < tolerance }
            if !isDuplicate { result.append(pair) }
        }
        return result
    }

    private func resetDailyCountIfNeeded() {
        let today = calendar.startOfDay(for: Date())
        if let last = lastCountResetDate, !calendar.isDate(last, inSameDayAs: today) {
            dailyNotificationCount = 0
            lastCountResetDate     = today
        } else if lastCountResetDate == nil {
            lastCountResetDate = today
        }
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

