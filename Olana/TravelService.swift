//
//  TravelService.swift
//  Olana
//
//  The app side of getting there (spec v3 §7.4–7.6): resolving a synced event's
//  place, picking the origin, asking MapKit for an ETA arriving at the start,
//  and keeping the last good reading per event so a background run without
//  network still has one (padded, under 6 h old).
//
//  ExecContext turns an OlanaEvent into the planner's and the card's inputs,
//  using only what's already known: it never calls the model or the network.
//

import Foundation
import CoreLocation
import MapKit

// MARK: - Preferences (UserPlaces, spec §8; local until CloudKit at launch)

enum ExecPreferences {
    private static let d = UserDefaults.standard

    static var defaultMode: TravelMode {
        get { TravelMode(rawValue: d.string(forKey: "olanaTravelMode_v1") ?? "") ?? .driving }
        set { d.set(newValue.rawValue, forKey: "olanaTravelMode_v1") }
    }
    static var workHours: WorkHours? {
        get { d.data(forKey: "olanaWorkHours_v1").flatMap { try? JSONDecoder().decode(WorkHours.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "olanaWorkHours_v1") }
    }
    /// New toggles (spec §7.7 Settings): Prep, Get ready, Leave.
    static var prepAlerts: Bool {
        get { d.object(forKey: "olanaPrepAlerts_v1") as? Bool ?? true }
        set { d.set(newValue, forKey: "olanaPrepAlerts_v1") }
    }
    static var getReadyAlerts: Bool {
        get { d.object(forKey: "olanaGetReadyAlerts_v1") as? Bool ?? true }
        set { d.set(newValue, forKey: "olanaGetReadyAlerts_v1") }
    }
    static var leaveAlerts: Bool {
        get { d.object(forKey: "olanaLeaveAlerts_v1") as? Bool ?? true }
        set { d.set(newValue, forKey: "olanaLeaveAlerts_v1") }
    }
    /// PRD v3 §3.9 category toggle "Join".
    static var joinAlerts: Bool {
        get { d.object(forKey: "olanaJoinAlerts_v1") as? Bool ?? true }
        set { d.set(newValue, forKey: "olanaJoinAlerts_v1") }
    }
    /// Directions open here (spec §7.5 "maps app"). Google only when installed.
    static var mapsApp: String {
        get { d.string(forKey: "olanaMapsApp_v1") ?? "apple" }
        set { d.set(newValue, forKey: "olanaMapsApp_v1") }
    }
    /// "Where do you leave from?" is asked once on the card (spec §7.5); after
    /// "Not now" it lives on the sheet and in Settings.
    static var originAsked: Bool {
        get { d.bool(forKey: "olanaOriginAsked_v1") }
        set { d.set(newValue, forKey: "olanaOriginAsked_v1") }
    }
    static var hasSavedOrigin: Bool { SavedPlaces.home != nil || SavedPlaces.work != nil }

    /// Bumped on any change above, so planVersion changes and alerts are replaced.
    static var version: Int {
        [defaultMode.rawValue, "\(prepAlerts)\(getReadyAlerts)\(leaveAlerts)\(joinAlerts)",
         workHours.map { "\($0.startMinute)-\($0.endMinute)" } ?? "-"].joined().hashValueStable
    }
}

private extension String {
    var hashValueStable: Int { Int(FNV.hex(self).prefix(8), radix: 16) ?? 0 }
}

// MARK: - Last good ETA per event

final class ETAStore: @unchecked Sendable {
    struct Entry: Codable { var reading: ETAReading; var originName: String; var mode: String }
    static let shared = ETAStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("olana_eta.json"))
    private let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(url: URL) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func get(_ key: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }

    func set(_ key: String, _ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = e
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        entries = entries.filter { $0.value.reading.fetchedAt > cutoff }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() { lock.lock(); entries = [:]; lock.unlock(); try? FileManager.default.removeItem(at: url) }
}

// MARK: - Context

@MainActor
enum ExecContext {
    /// Everything the planner, card and sheet need for one event, from what's known.
    static func trip(for e: OlanaEvent, overrides: EffectiveOverrides, now: Date) -> TripFacts {
        let facts = NotesCleaner.clean(notes: e.isFromExternalCalendar ? e.notes : nil, location: e.location,
                                       conferenceURL: e.meetingURL)
        let assist = cachedAssist(for: e, facts: facts, overrides: overrides)
        let eta = ETAStore.shared.get(e.overrideEventKey).flatMap { ETAFreshness.effective($0.reading, start: e.start, now: now) }
        let prep = e.cachedSemantics?.effectivePrep.hours ?? 0
        // "Not needed" turns travel help off for the series (spec §7.9).
        let noTravel = overrides.travelNotNeeded
        return TripResolver.resolve(TripInputs(
            title: e.title, start: e.start, end: e.end, isTask: e.isTask, isAllDay: e.isAllDay, location: noTravel ? nil : e.location,
            meetingURL: e.meetingURL ?? facts.meetingURL, assist: assist,
            attendanceAnswer: overrides.attendance,
            attendanceTyped: e.attendanceRaw.flatMap(AssistAttendance.init(rawValue:)),
            place: noTravel ? nil : (overrides.place ?? e.resolvedPlace), actBy: prep > 0 ? e.start.addingTimeInterval(-prep * 3600) : nil, eta: eta,
            arriveEarlyOverride: overrides.arriveEarlyMinutes, arriveEarlyTyped: e.arriveEarlyMinutes))
    }

    static func cachedAssist(for e: OlanaEvent, facts: EventFacts, overrides: EffectiveOverrides) -> AssistResult? {
        let input = AssistInput(title: e.title, calendar: e.calendarName, location: e.location, facts: facts,
                                savedSteps: overrides.steps ?? [], overrideVersions: overrides.versions)
        return AssistCache.shared.get(AssistPrompt.cacheKey(input))
    }

    static func assistInput(for e: OlanaEvent, overrides: EffectiveOverrides) -> AssistInput {
        let facts = NotesCleaner.clean(notes: e.isFromExternalCalendar ? e.notes : nil, location: e.location,
                                       conferenceURL: e.meetingURL)
        return AssistInput(title: e.title, calendar: e.calendarName, location: e.location, facts: facts,
                           savedSteps: overrides.steps ?? [], overrideVersions: overrides.versions)
    }

    /// Critical = score at the moment of acting ≥ 6.5, or the user set Critical.
    static func isCritical(_ e: OlanaEvent, now: Date) -> Bool {
        if e.urgencyOverrideRaw.flatMap(EventUrgency.init(rawValue:)) == .high { return true }
        guard let sem = e.cachedSemantics, let r = UrgencyCombiner.score(semantics: sem, start: e.start, now: now) else { return false }
        let atActing = UrgencyCombiner.score(semantics: sem, start: e.start, now: max(r.actBy, now)) ?? r
        return atActing.score >= 6.5
    }

    /// Moderate+ consequence, or the user said it matters (PRD v3 §1.6).
    static func isModeratePlus(_ e: OlanaEvent) -> Bool {
        if let o = e.urgencyOverrideRaw.flatMap(EventUrgency.init(rawValue:)) { return o != .low }
        guard let c = e.cachedSemantics?.consequence else { return false }
        return c != .minor
    }

    static func execEvent(for e: OlanaEvent, overrides: EffectiveOverrides, now: Date) -> ExecEvent {
        let trip = trip(for: e, overrides: overrides, now: now)
        let stored = ETAStore.shared.get(e.overrideEventKey)
        let eta = stored.flatMap { ETAFreshness.effective($0.reading, start: e.start, now: now) }
        return ExecEvent(id: e.id, title: e.title, times: trip.times, isAllDay: e.isAllDay, completed: e.completed,
                         urgencyRaw: e.urgency.rawValue, critical: isCritical(e, now: now), moderatePlus: isModeratePlus(e),
                         mode: overrides.assistMode, unranked: e.isUnrankable && overrides.versions == [0, 0],
                         outTheDoorMinutes: trip.outTheDoorMinutes, etaSeconds: eta?.seconds, etaApproximate: eta?.approximate ?? false,
                         travelMode: (overrides.travelMode.flatMap(TravelMode.init(rawValue:)) ?? ExecPreferences.defaultMode),
                         bring: overrides.bring ?? e.bringItems, isFlight: trip.isFlight,
                         arriveEarlyMinutes: trip.arriveEarlyMinutes, progress: EventProgressStore.shared.get(e.overrideEventKey),
                         overrideVersions: overrides.versions)
    }

    static func settings() -> ExecSettings {
        let n = NotificationSettings.shared
        let cal = Calendar.current
        let quiet = n.quietHoursEnabled
            ? QuietHours(startHour: cal.component(.hour, from: n.quietHoursStart), endHour: cal.component(.hour, from: n.quietHoursEnd))
            : nil
        return ExecSettings(prep: ExecPreferences.prepAlerts, getReady: ExecPreferences.getReadyAlerts,
                            leave: ExecPreferences.leaveAlerts, join: ExecPreferences.joinAlerts, quiet: quiet, hasPlus: PlusAccess.hasPlus,
                            settingsVersion: ExecPreferences.version)
    }
}

// MARK: - MapKit

@MainActor
final class TravelService {
    static let shared = TravelService()
    /// Spec S7: the same (origin, place, mode) isn't asked twice in 10 minutes.
    private var recent: [String: ETAReading] = [:]

    /// Resolve a synced event's location text to a place once (PlaceCache:
    /// the result is saved on the event). Several matches are left for the
    /// sheet's "Which one?"; personal places are never searched.
    func ensurePlace(_ e: OlanaEvent, kind: AssistLocationKind?) async {
        guard !e.hasResolvedPlace, let text = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              kind == .streetAddress || kind == .namedPlace, !RoomPatterns.isRoom(text) else { return }
        if case .resolved(let p) = await PlaceResolver.shared.resolve(text) {
            e.applyPlace(p)
            if e.placeSource == nil { e.placeSource = "calendar" }
        }
    }

    /// Fetch an ETA when the reading is stale for its tier; keep the last good one otherwise.
    @discardableResult
    func refresh(_ e: OlanaEvent, events: [OlanaEvent], overrides: EffectiveOverrides, now: Date = Date(),
                 force: Bool = false) async -> ETAReading? {
        guard let place = overrides.place ?? e.resolvedPlace, !overrides.travelNotNeeded, !e.isTask, !e.isAllDay, e.start > now
        else { return nil }
        let key = e.overrideEventKey
        let stored = ETAStore.shared.get(key)
        let trip = ExecContext.trip(for: e, overrides: overrides, now: now)
        guard trip.needsTravel else { return nil }
        guard force || ETAFreshness.needsRefresh(stored?.reading, leaveBy: trip.times.leaveBy, now: now) else { return stored?.reading }
        guard let origin = await origin(for: e, events: events, overrides: overrides) else { return stored?.reading }
        let mode = overrides.travelMode.flatMap(TravelMode.init(rawValue:)) ?? ExecPreferences.defaultMode
        let cacheKey = ETAFreshness.cacheKey(from: origin.coordinate, to: place.coordinate, mode: mode)
        if let r = recent[cacheKey], now.timeIntervalSince(r.fetchedAt) < 600 {
            ETAStore.shared.set(key, .init(reading: r, originName: origin.name, mode: mode.rawValue))
            return r
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude), address: nil)
        request.transportType = mode == .walking ? .walking : (mode == .transit ? .transit : .automobile)
        request.arrivalDate = e.start
        guard let eta = try? await MKDirections(request: request).calculateETA() else {
            // ETA failed: the last good reading stays (padded if stale); the floor is untouched.
            return stored?.reading
        }
        let reading = ETAReading(seconds: eta.expectedTravelTime, fetchedAt: now)
        recent[cacheKey] = reading
        ETAStore.shared.set(key, .init(reading: reading, originName: origin.name, mode: mode.rawValue))
        return reading
    }

    func origin(for e: OlanaEvent, events: [OlanaEvent], overrides: EffectiveOverrides) async -> Origin? {
        var override: Origin?
        switch overrides.origin {
        case "home"?: override = SavedPlaces.home.map { Origin(source: .override, name: $0.name, coordinate: $0.coordinate) }
        case "work"?: override = SavedPlaces.work.map { Origin(source: .override, name: $0.name, coordinate: $0.coordinate) }
        case "current"?:
            if let c = await PlaceResolver.shared.origin(askIfNeeded: false) { override = Origin(source: .current, name: "Current location", coordinate: c) }
        default: break
        }
        let earlier = events.compactMap { o -> OriginPicker.Earlier? in
            guard o.id != e.id, !o.isAllDay, o.end <= e.start, let p = o.resolvedPlace else { return nil }
            return .init(name: p.name, end: o.end, coordinate: p.coordinate)
        }
        return OriginPicker.pick(start: e.start, earlier: earlier, home: SavedPlaces.home, work: SavedPlaces.work,
                                 workHours: ExecPreferences.workHours, override: override)
    }
}

// MARK: - Refresh (PRD v6 §3.2 steps 3 and 5; spec v3 §6.4)

@MainActor
enum ExecRefresher {
    /// Step 3: ETAs for travel events whose leave-by is within `horizon`
    /// (background: 3 h; foreground: the next 24 h). Returns how many changed.
    static func refreshETAs(store: EventStore, horizon: TimeInterval, until deadline: Date? = nil) async -> Int {
        let now = Date()
        var changed = 0
        for e in store.events where e.start > now && e.start.timeIntervalSince(now) <= horizon + 6 * 3600 && !e.completed {
            if let deadline, Date() > deadline { break }
            let ov = store.effectiveOverrides(for: e)
            let trip = ExecContext.trip(for: e, overrides: ov, now: now)
            guard trip.needsTravel else { continue }
            let leaveBy = trip.times.leaveBy ?? e.start
            guard leaveBy.timeIntervalSince(now) <= horizon else { continue }
            let before = ETAStore.shared.get(e.overrideEventKey)?.reading
            let after = await TravelService.shared.refresh(e, events: store.events, overrides: ov, now: now)
            if after != before { changed += 1 }
        }
        return changed
    }

    /// EventAssist jobs in ModelQueue order (spec §6.4): Always Assist and
    /// Critical in 24 h, then unranked in 24 h (fallback), then Moderate+ in
    /// 24 h, then the same in 7 days. Skips events with a cached answer.
    /// A real place from the answer is resolved right after.
    static func assistJobs(store: EventStore, limit: Int, until deadline: Date? = nil) async -> Int {
        let now = Date()
        let candidates = store.events.filter { e in
            !e.completed && !e.isAllDay && e.start > now && e.start.timeIntervalSince(now) <= 7 * 24 * 3600
        }
        func rank(_ e: OlanaEvent) -> Int? {
            let ov = store.effectiveOverrides(for: e)
            if ov.assistMode == .noAlerts { return nil }
            let in24 = e.start.timeIntervalSince(now) <= 24 * 3600
            if in24 && (ov.assistMode == .always || ExecContext.isCritical(e, now: now)) { return 2 }
            if in24 && e.isUnrankable { return 3 }
            if ExecContext.isModeratePlus(e) { return in24 ? 4 : 5 }
            return nil
        }
        let queue = candidates.compactMap { e in rank(e).map { (e, $0) } }
            .sorted { ($0.1, $0.0.start) < ($1.1, $1.0.start) }
        var done = 0
        for (e, _) in queue {
            if done >= limit { break }
            if let deadline, Date() > deadline { break }
            let ov = store.effectiveOverrides(for: e)
            let input = ExecContext.assistInput(for: e, overrides: ov)
            if let cached = AssistCache.shared.get(AssistPrompt.cacheKey(input)) {
                await TravelService.shared.ensurePlace(e, kind: cached.locationKind)
                continue
            }
            let outcome = await EventAssistService.shared.assist(input)
            done += 1
            switch outcome {
            case .full(let r), .basic(let r): await TravelService.shared.ensurePlace(e, kind: r.locationKind)
            case .unavailable: return done
            case .none: break
            }
        }
        return done
    }
}
