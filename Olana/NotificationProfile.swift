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
    /// How many minutes before an event the Live Activity countdown starts.
    /// Stored in iCloud KV so the value syncs across devices.
    @Published var liveActivityLeadMinutes: Int {
        didSet { save(liveActivityLeadMinutes, forKey: "liveActivityLeadMinutes") }
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
        self.liveActivityLeadMinutes    = kv.int(   "liveActivityLeadMinutes")     ?? UserDefaults.standard.object(forKey: "liveActivityLeadMinutes")    as? Int  ?? 15

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
                case "liveActivityLeadMinutes":
                    if let v = self.kv.int("liveActivityLeadMinutes")     { self.liveActivityLeadMinutes = v }
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
        let markDone     = UNNotificationAction(identifier: "MARK_DONE",     title: "Mark Done",  options: [.foreground])
        let snoozeLow    = UNNotificationAction(identifier: "SNOOZE_LOW",    title: "Snooze 30m", options: [])
        let snoozeMedium = UNNotificationAction(identifier: "SNOOZE_MEDIUM", title: "Snooze 15m", options: [])
        let snoozeHigh   = UNNotificationAction(identifier: "SNOOZE_HIGH",   title: "Snooze 10m", options: [])

        center.setNotificationCategories([
            UNNotificationCategory(identifier: "EVENT_LOW",    actions: [markDone, snoozeLow],    intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_MEDIUM", actions: [markDone, snoozeMedium], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "EVENT_HIGH",   actions: [markDone, snoozeHigh],   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Schedule Notifications

    func scheduleNotifications(for event: OlanaEvent, confidence: Double = 1.0) async {
        guard isAuthorized else { return }

        await cancelNotifications(for: event.id)

        let profile = NotificationProfile.profile(for: event.urgency)
        var candidatePairs: [(date: Date, timing: NotificationProfile.NotificationTiming)] = []

        for timing in profile.timings {
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

        // Critical events always break through — quiet hours don't delay them.
        // Medium and low urgency events respect the user's quiet window.
        if profile.urgency != .high {
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
            content.sound               = settings.enableAudioReminders ? profile.sound : nil
            content.threadIdentifier    = event.id.uuidString
            content.categoryIdentifier  = "EVENT_\(urgencyString(event.urgency).uppercased())"
            content.interruptionLevel   = profile.interruptionLevel
            // Critical (.high) events always use .timeSensitive — set directly in the profile.
            // Requires the "Time Sensitive Notifications" entitlement in Xcode Signing & Capabilities.
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

        if profile.enableLiveActivity {
            await scheduleLiveActivity(for: event)
        }

        if settings.enableCalendarRedundancy {
            await addCalendarAlarm(for: event)
        }
    }

    // MARK: - Cancel Notifications

    func cancelNotifications(for eventId: UUID) async {
        guard let record = scheduledRecords[eventId] else { return }
        center.removePendingNotificationRequests(withIdentifiers: record.notificationIds)
        scheduledRecords.removeValue(forKey: eventId)
        saveRecords()
        await endLiveActivity(for: eventId)
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
        content.sound              = settings.enableAudioReminders ? profile.sound : nil
        content.threadIdentifier   = event.id.uuidString
        content.categoryIdentifier = "EVENT_\(urgencyString(event.urgency).uppercased())"
        content.interruptionLevel  = profile.interruptionLevel
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

    // MARK: - Live Activity

    /// Called by HomeView's imminent timer when an event enters the 15-minute window
    /// while the app is in the foreground. Safe to call multiple times — duplicate
    /// activity requests are silently ignored.
    func startLiveActivityNow(for event: OlanaEvent) async {
        guard NotificationProfile.profile(for: event.urgency).enableLiveActivity else { return }
        await scheduleLiveActivity(for: event)
    }

    private func scheduleLiveActivity(for event: OlanaEvent) async {
        guard #available(iOS 16.2, *) else { return }

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
        guard let activityId = liveActivityIds[eventId] else { return }

        if let activity = Activity<OlanaEventAttributes>.activities.first(where: { $0.id == activityId }) {
            let doneState = OlanaEventAttributes.ContentState(
                eventStart:       Date(),
                minutesRemaining: 0,
                status:           "done"
            )
            await activity.end(
                ActivityContent(state: doneState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            print("✅ NotificationEngine: Ended Live Activity \(activityId)")
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

