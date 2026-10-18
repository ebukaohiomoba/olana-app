import Foundation
import SwiftUI
import Combine
import SwiftData

@MainActor
final class EventStore: ObservableObject {
    /// Every event the user sees. Hidden iOS Calendar copies of events synced
    /// directly from Google (`duplicateOf`) are left out (PRD §3.12).
    @Published private(set) var events: [OlanaEvent] = []
    /// Everything stored, hidden duplicates included. Sync matches against this.
    private(set) var allEvents: [OlanaEvent] = []
    /// Deduplicated list for HomeView — updated once per load(), not on every render.
    @Published private(set) var homeDisplayEvents: [OlanaEvent] = []

    private let container: ModelContainer
    private let context: ModelContext

    /// Stored tokens so observers can be removed when this instance is deallocated.
    private var notificationObservers: [NSObjectProtocol] = []

    init(container: ModelContainer = Persistence.shared.container) {
        self.container = container
        self.context = ModelContext(container)
        load()
        setupNotificationActionObservers()
    }

    deinit {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Rebuilds `homeDisplayEvents` from the current `events` snapshot.
    /// Non-recurring events appear once; recurring series appear once (the next
    /// upcoming incomplete occurrence, or the latest if all are past/done).
    private func rebuildHomeDisplayEvents() {
        let now = Date()
        var nonRecurring: [OlanaEvent] = []
        var seriesGroups: [String: [OlanaEvent]] = [:]

        for event in events {
            if event.recurrenceRule == RecurrenceRule.none {
                nonRecurring.append(event)
            } else {
                let key = "\(event.title)|\(event.recurrenceRule.rawValue)"
                seriesGroups[key, default: []].append(event)
            }
        }

        var representatives: [OlanaEvent] = []
        for (_, occurrences) in seriesGroups {
            let sorted = occurrences.sorted { $0.start < $1.start }
            // Only show a series if it has an actual upcoming incomplete occurrence.
            // If all remaining occurrences are past or completed the series is done
            // and should not appear on the home view.
            if let next = sorted.first(where: { $0.start >= now && !$0.completed }) {
                representatives.append(next)
            }
        }

        // Rank by urgency score, falling back to chronological.
        //
        // Two deliberate choices. Events without cached semantics keep their
        // chronological position rather than being guessed at, because a guess
        // that outranks a real commitment is worse than no ranking. And ties
        // break on start time so the order stays stable as scores change.
        let candidates = nonRecurring + representatives
        let scored: [(event: OlanaEvent, score: Double?)] = candidates.map {
            ($0, UrgencyManager.shared.cachedScore(for: $0, now: now)?.score)
        }

        homeDisplayEvents = scored.sorted { a, b in
            switch (a.score, b.score) {
            case let (x?, y?):
                if abs(x - y) > 0.001 { return x > y }
                return a.event.start < b.event.start
            case (_?, nil): return true          // ranked events lead
            case (nil, _?): return false
            case (nil, nil): return a.event.start < b.event.start
            }
        }.map(\.event)
    }

    /// Re-score judged upcoming events against the clock and store the result.
    ///
    /// Urgency rises as an event approaches, but it was only written when the
    /// event was judged (and, for synced events, when a sync touched it). So a
    /// flight judged a month out stayed Later on the screen and in its reminders.
    /// Runs on every foreground through `backfillSemantics`. Returns events whose
    /// urgency changed, so their reminders can be rebuilt for the new level.
    @discardableResult
    func refreshUrgencies(now: Date = Date()) -> [OlanaEvent] {
        var changed: [OlanaEvent] = []
        for event in events where !event.completed && event.start > now
            && event.cachedSemantics != nil {
            let old = event.urgency
            event.refreshUrgency(now: now)
            if event.urgency != old { changed.append(event) }
        }
        if !changed.isEmpty { try? context.save() }
        return changed
    }

    /// The single thing most worth attention right now, or nil when nothing is.
    /// A ranked list is still a list; for the people this app is for, the list is
    /// itself the overwhelm. This is what the home view should lead with.
    var focusEvent: OlanaEvent? {
        let now = Date()
        return homeDisplayEvents.first {
            !$0.completed && $0.start > now
                && (UrgencyManager.shared.cachedScore(for: $0, now: now)?.urgency ?? .low) != .low
        }
    }

    // MARK: - Semantics backfill

    /// The background run's model step (PRD §3.2 step 5): a few jobs, stopping
    /// at the deadline or when the model says it's rate-limited. Returns the
    /// events it judged; the caller replans.
    func backgroundBackfill(limit: Int, deadline: Date) async -> [OlanaEvent] {
        UrgencyManager.shared.refresh()
        let judged = await UrgencyManager.shared.backfill(events: events, context: context,
                                                          limit: limit, deadline: deadline)
        if !judged.isEmpty {
            _ = refreshUrgencies()
            rebuildHomeDisplayEvents()
        }
        return judged
    }

    /// Extract semantics for upcoming events that do not have them, then re-rank.
    ///
    /// Safe to call often: `backfill` skips anything already cached, so after the
    /// first pass this is close to free. Bounded per call so a freshly connected
    /// calendar warms up over a few invocations rather than in one battery spike.
    func backfillSemantics(limit: Int = 25) async {
        // Apple Intelligence may have been turned on, or finished downloading,
        // since the last pass. Events skipped while it was unavailable wait for this.
        UrgencyManager.shared.refresh()
        let populated = await UrgencyManager.shared.backfill(events: events, context: context, limit: limit)
        let escalated = refreshUrgencies().filter { e in !populated.contains { $0.id == e.id } }
        rebuildHomeDisplayEvents()

        // Escalated events were scheduled under their old urgency's profile.
        for event in escalated {
            await NotificationEngine.shared.scheduleNotifications(for: event)
        }

        // Notifications were scheduled when these events arrived, before any
        // semantics existed, so the alarm gate saw nothing and declined. Now that
        // they can be judged, schedule again.
        for event in populated {
            await NotificationEngine.shared.scheduleNotifications(for: event)
        }
    }

    func load(predicate: Predicate<OlanaEvent>? = nil, sort: [SortDescriptor<OlanaEvent>] = [SortDescriptor(\OlanaEvent.start, order: .forward)]) {
        do {
            var descriptor = FetchDescriptor<OlanaEvent>(predicate: predicate, sortBy: sort)
            descriptor.fetchLimit = 0
            allEvents = try context.fetch(descriptor)
        } catch {
            print("Failed to fetch events: \(error)")
            allEvents = []
        }
        events = allEvents.filter { $0.duplicateOf == nil }
        rebuildHomeDisplayEvents()
    }

    /// `semantics` carries the model's judgement from the capture screen, where it
    /// was already computed. Without it the event lands with an empty cache: it
    /// cannot be ranked until backfill re-extracts the identical answer, and the
    /// alarm gate, which requires cached semantics, silently declines to schedule.
    /// So the one path where the user explicitly said something matters was the one
    /// path that could never alarm them.
    ///
    /// `userPickedUrgency` records whether they overrode the suggestion, so their
    /// choice is stored as an override rather than being overwritten by the combiner.
    func addEvent(title: String, start: Date, end: Date, urgency: EventUrgency,
                  recurrenceRule: RecurrenceRule = .none, isTask: Bool = false,
                  semantics: EventSemantics? = nil,
                  userPickedUrgency: Bool = false,
                  capture: CaptureResult? = nil, message: String? = nil,
                  place: ResolvedPlace? = nil) {
        let new = OlanaEvent(title: title, start: start, end: end, urgency: urgency, recurrenceRule: recurrenceRule, isTask: isTask)
        // What the message said besides the time (PRD v6 §3.11). Tasks never
        // take a place or travel (§1.7a).
        func applyInput(_ e: OlanaEvent) {
            if let capture, let message {
                e.applyCapture(capture, message: message)
                if isTask { e.location = nil; e.placeSource = nil; e.likelyNeedsTravel = false }
            } else if let message {
                e.notes = message
            }
            if let place, !isTask { e.applyPlace(place) }
        }
        applyInput(new)

        // If the user chose an urgency, that is the answer. Stored as an override
        // before semantics are applied, so neither this nor a later backfill can
        // replace it with the model's judgement.
        if userPickedUrgency { new.urgencyOverrideRaw = urgency.rawValue }
        if let semantics { new.applySemantics(semantics) }

        context.insert(new)
        if recurrenceRule != .none {
            for occurrence in generateOccurrences(from: new, rule: recurrenceRule) {
                applyInput(occurrence)
                if userPickedUrgency { occurrence.urgencyOverrideRaw = urgency.rawValue }
                if let semantics { occurrence.applySemantics(semantics) }
                context.insert(occurrence)
            }
        }
        saveAndRefresh()
        Task { await NotificationEngine.shared.scheduleNotifications(for: new) }
        let wordCount = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        OlanaAnalytics.eventCreated(urgency: urgency, recurrenceRule: recurrenceRule, titleWordCount: wordCount)
    }

    /// Deletes a single event by id (no effect on siblings).
    func removeEvent(id: UUID) {
        if let event = events.first(where: { $0.id == id }) {
            let eventId = event.id
            let urgency = event.urgency
            let isRecurring = event.recurrenceRule != .none
            context.delete(event)
            saveAndRefresh()
            Task { await NotificationEngine.shared.cancelNotifications(for: eventId) }
            OlanaAnalytics.eventDeleted(urgency: urgency, isRecurring: isRecurring)
        }
    }

    /// Deletes the event with `id` plus all upcoming incomplete occurrences of the
    /// same recurring series (matched by title + recurrenceRule, start >= event.start).
    func removeSeriesFromEvent(id: UUID) {
        guard let event = events.first(where: { $0.id == id }) else { return }

        guard event.recurrenceRule != RecurrenceRule.none else {
            removeEvent(id: id)
            return
        }

        let seriesTitle = event.title
        let seriesRule  = event.recurrenceRule
        let cutoff      = event.start

        // Delete all occurrences from the cutoff onward — including completed ones.
        // Not filtering by !completed was the root cause of needing multiple taps:
        // a completed occurrence at the cutoff would survive, get surfaced again
        // by rebuildHomeDisplayEvents, and force the user to delete a second time.
        let toDelete = events.filter {
            $0.title == seriesTitle &&
            $0.recurrenceRule == seriesRule &&
            $0.start >= cutoff
        }
        let urgency = event.urgency
        for e in toDelete {
            let eid = e.id
            context.delete(e)
            Task { await NotificationEngine.shared.cancelNotifications(for: eid) }
        }
        saveAndRefresh()
        OlanaAnalytics.seriesDeleted(urgency: urgency, recurrenceRule: seriesRule)
    }

    func updateEvent(id: UUID, title: String, start: Date, end: Date,
                     urgency: EventUrgency, recurrenceRule: RecurrenceRule = RecurrenceRule.none) {
        guard let event = events.first(where: { $0.id == id }) else { return }

        let oldTitle  = event.title
        let oldRule   = event.recurrenceRule
        let oldUrgency = event.urgency

        event.title          = title
        event.start          = start
        event.end            = end
        event.urgency        = urgency
        event.recurrenceRule = recurrenceRule

        // Changing urgency in the editor is the user overriding it. Record that,
        // or the next sync or backfill puts the model's answer back.
        if urgency != oldUrgency {
            event.urgencyOverrideRaw = urgency.rawValue
            event.urgencyOverrideFromCalendar = nil
        }

        // If the recurrence rule changed, tear down the old series and rebuild.
        if recurrenceRule != oldRule {
            let futureSiblings = events.filter {
                $0.id != id &&
                $0.title == oldTitle &&
                $0.recurrenceRule == oldRule &&
                $0.start >= start &&
                !$0.completed
            }
            for sibling in futureSiblings { context.delete(sibling) }

            if recurrenceRule != RecurrenceRule.none {
                for occurrence in generateOccurrences(from: event, rule: recurrenceRule) {
                    context.insert(occurrence)
                }
            }
        }

        saveAndRefresh()
        Task {
            await NotificationEngine.shared.cancelNotifications(for: id)
            await NotificationEngine.shared.scheduleNotifications(for: event)
        }
        OlanaAnalytics.eventEdited(
            urgencyChanged:    urgency != oldUrgency,
            recurrenceChanged: recurrenceRule != oldRule
        )
    }
    
    // ✅ Toggle completion with proper return type
    func toggleEventCompletion(_ id: UUID) -> (xp: Int, rewards: [String], newBadges: [Badge])? {
        guard let event = events.first(where: { $0.id == id }) else {
            return nil
        }
        
        if event.completed {
            // Uncomplete - just toggle back
            let urgency = event.urgency
            event.completed = false
            event.completedAt = nil
            saveAndRefresh()
            // Undoing Mark done brings its reminders back.
            Task { await NotificationEngine.shared.scheduleNotifications(for: event) }
            OlanaAnalytics.eventUncompleted(urgency: urgency)
            return nil
        } else {
            // Complete - mark and award XP
            let urgency    = event.urgency
            let isRecurring = event.recurrenceRule != .none
            event.completed = true
            event.completedAt = Date()

            let result = XPManager.shared.completeEvent(event)

            saveAndRefresh()
            Task { await NotificationEngine.shared.cancelNotifications(for: id) }
            OlanaAnalytics.eventCompleted(
                urgency:    urgency,
                xpEarned:   result.xp,
                streakDays: XPManager.shared.streakDays,
                isRecurring: isRecurring
            )
            return (xp: result.xp, rewards: result.rewards, newBadges: result.newBadges)
        }
    }

    private func generateOccurrences(from event: OlanaEvent, rule: RecurrenceRule) -> [OlanaEvent] {
        var occurrences: [OlanaEvent] = []
        let calendar = Calendar.current
        let duration = event.end.timeIntervalSince(event.start)

        switch rule {
        case .none:
            break
        case .daily:
            for i in 1..<14 {
                guard let nextStart = calendar.date(byAdding: .day, value: i, to: event.start) else { continue }
                let nextEnd = nextStart.addingTimeInterval(duration)
                occurrences.append(OlanaEvent(title: event.title, start: nextStart, end: nextEnd, urgency: event.urgency, recurrenceRule: rule))
            }
        case .weekdays:
            var count = 0
            var dayOffset = 1
            while count < 9 {
                guard let nextStart = calendar.date(byAdding: .day, value: dayOffset, to: event.start) else { break }
                let weekday = calendar.component(.weekday, from: nextStart)
                if weekday >= 2 && weekday <= 6 { // Mon(2)–Fri(6)
                    let nextEnd = nextStart.addingTimeInterval(duration)
                    occurrences.append(OlanaEvent(title: event.title, start: nextStart, end: nextEnd, urgency: event.urgency, recurrenceRule: rule))
                    count += 1
                }
                dayOffset += 1
            }
        case .weekly:
            for i in 1..<8 {
                guard let nextStart = calendar.date(byAdding: .weekOfYear, value: i, to: event.start) else { continue }
                let nextEnd = nextStart.addingTimeInterval(duration)
                occurrences.append(OlanaEvent(title: event.title, start: nextStart, end: nextEnd, urgency: event.urgency, recurrenceRule: rule))
            }
        case .monthly:
            for i in 1..<3 {
                guard let nextStart = calendar.date(byAdding: .month, value: i, to: event.start) else { continue }
                let nextEnd = nextStart.addingTimeInterval(duration)
                occurrences.append(OlanaEvent(title: event.title, start: nextStart, end: nextEnd, urgency: event.urgency, recurrenceRule: rule))
            }
        }

        return occurrences
    }

    // MARK: - External Calendar Sync

    /// Merges freshly normalised events from one external source into the store.
    ///
    /// Matching events are updated in place, not replaced. Replacing them gave
    /// every synced event a new id on every sync and threw away everything Olana
    /// knew about it: cached semantics (so the model re-judged the same events on
    /// every foreground), completion, the user's urgency override, and the id that
    /// scheduled notifications and alarms are keyed on.
    ///
    /// Matching follows PRD §3.12 (see SyncMatcher.match): source id + start,
    /// then iCalUID + occurrence date, then a lone source id for a moved
    /// one-off event. A match keeps its OlanaEvent.id.
    ///
    /// Lookups span the whole source so an event moved into the window from
    /// outside it is updated rather than duplicated. Deletion is limited to the
    /// window, since that is all the source was asked about.
    func syncExternalCalendarEvents(
        source: String,
        from start: Date,
        to end: Date,
        events normalisedEvents: [OlanaEvent]
    ) {
        let existing = allEvents.filter { $0.externalCalendarId == source }
        let now = Date()

        // Which stored event each incoming one is (PRD §3.12; SyncMatcher).
        let matches = SyncMatcher.match(existing: existing.map { ($0.id, $0.syncKeys) },
                                        incoming: normalisedEvents.map(\.syncKeys),
                                        windowStart: start)
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var matched = Set<UUID>()
        var changed: [OlanaEvent] = []
        var inserted: [OlanaEvent] = []
        for (i, incoming) in normalisedEvents.enumerated() {
            if let id = matches[i], let event = byID[id] {
                matched.insert(id)
                if event.mergeSynced(from: incoming) { changed.append(event) }
            } else {
                context.insert(incoming)
                inserted.append(incoming)
            }
        }

        // Gone from the source. Keep the user's overrides for 24 h in case the
        // event comes back under a new identifier (Exchange, some CalDAV).
        let removed = existing.filter {
            $0.start >= start && $0.start <= end && !matched.contains($0.id)
        }
        var tombstones = loadTombstones().filter { now.timeIntervalSince($0.removedAt) <= SyncMatcher.tombstoneLife }
        for event in removed {
            if let t = event.overrideTombstone(removedAt: now) { tombstones.append(t) }
            context.delete(event)
        }
        // New events that are the same title, start, end and organizer as one
        // that just disappeared get its overrides. Nothing merges or deletes.
        for event in inserted {
            if let t = SyncMatcher.carryOver(tombstones: tombstones, newEvent: event.syncKeys, now: now) {
                event.adoptOverrides(from: t)
                tombstones.removeAll { $0 == t }
            }
        }
        saveTombstones(tombstones)
        saveAndRefresh()

        // After the save, so it sees inserts and not the deleted.
        let newlyHidden = markCrossSourceDuplicates()
        if !newlyHidden.isEmpty { saveAndRefresh() }

        // Events gone from the source lose their reminders. Changed events get
        // their alarm and Live Activity rebuilt; the replan then fixes every
        // event's reminders, new ones included (PRD §3.9).
        let removedIds = removed.map(\.id)
        let changedEvents = changed
        Task {
            let engine = NotificationEngine.shared
            for id in removedIds + newlyHidden {
                await engine.cancelNotifications(for: id)
            }
            for event in changedEvents where !event.completed && event.duplicateOf == nil {
                await engine.scheduleNotifications(for: event)
            }
            engine.requestReplan("sync")
        }
    }

    /// The same Google event connected directly and through iOS Calendar: keep
    /// the direct copy (richer data), hide the other. Recomputed every sync, so
    /// disconnecting Google brings the iOS Calendar copy back. A user override
    /// made on the hidden copy moves to the kept one if it has none.
    /// Returns the ids hidden by this pass, so their alarms can be cancelled.
    @discardableResult
    private func markCrossSourceDuplicates() -> [UUID] {
        let apple = allEvents.filter { $0.externalCalendarId == "apple" }
        let google = allEvents.filter { $0.externalCalendarId == "google" }
        let dupes = SyncMatcher.crossSourceDuplicates(apple: apple.map { ($0.id, $0.syncKeys) },
                                                      google: google.map { ($0.id, $0.syncKeys) })
        let googleByID = Dictionary(google.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newlyHidden: [UUID] = []
        for event in apple {
            let keep = dupes[event.id]
            if let keep, let kept = googleByID[keep], event.hasUserOverride, !kept.hasUserOverride {
                kept.urgencyOverrideRaw = event.urgencyOverrideRaw
                kept.urgencyOverrideFromCalendar = nil
                kept.refreshUrgency()
            }
            if event.duplicateOf != keep {
                if event.duplicateOf == nil { newlyHidden.append(event.id) }
                event.duplicateOf = keep
            }
        }
        return newlyHidden
    }

    // MARK: Tombstones

    private static let tombstoneKey = "olanaOverrideTombstones_v1"

    private func loadTombstones() -> [OverrideTombstone] {
        guard let data = UserDefaults.standard.data(forKey: Self.tombstoneKey) else { return [] }
        return (try? JSONDecoder().decode([OverrideTombstone].self, from: data)) ?? []
    }

    private func saveTombstones(_ t: [OverrideTombstone]) {
        if let data = try? JSONEncoder().encode(t) { UserDefaults.standard.set(data, forKey: Self.tombstoneKey) }
    }

    // MARK: - Notification Action Observers

    /// Wires up observers for notification banner actions (Mark Done / Snooze).
    /// Both actions are posted by NotificationEngine after the user taps a button
    /// on a delivered notification. Without these observers the actions are no-ops.
    private func setupNotificationActionObservers() {
        // MARK: Mark Done — complete the event from the notification banner
        let markDoneToken = NotificationCenter.default.addObserver(
            forName: .eventMarkedDone, object: nil, queue: .main
        ) { [weak self] notification in
            guard let eventId = notification.userInfo?["eventId"] as? UUID else { return }
            Task { @MainActor [weak self] in
                // Discard the celebration tuple — user isn't in the app to see it
                _ = self?.toggleEventCompletion(eventId)
            }
        }

        // MARK: Snooze — reschedule a single reminder N minutes from now
        let snoozeToken = NotificationCenter.default.addObserver(
            forName: .eventSnoozed, object: nil, queue: .main
        ) { [weak self] notification in
            guard
                let eventId = notification.userInfo?["eventId"] as? UUID,
                let minutes = notification.userInfo?["snoozeMinutes"] as? Int
            else { return }
            Task { @MainActor [weak self] in
                guard
                    let self,
                    let event = self.events.first(where: { $0.id == eventId })
                else { return }
                await NotificationEngine.shared.scheduleSnoozeNotification(for: event, snoozeMinutes: minutes)
            }
        }

        notificationObservers = [markDoneToken, snoozeToken]
    }

    private func saveAndRefresh() {
        do {
            try context.save()
        } catch {
            print("Failed to save context: \(error)")
        }
        load()
    }
}

// MARK: - Sync merging

private extension OlanaEvent {

    /// Copy what the source calendar owns from a freshly normalised copy.
    ///
    /// Olana-owned state is left alone: id, completion, the user's own override
    /// and cached semantics. Semantics stay valid unless the title changed,
    /// which `cachedSemantics` detects by itself.
    ///
    /// Returns true when anything a reminder depends on changed.
    func mergeSynced(from incoming: OlanaEvent) -> Bool {
        let oldUrgency = urgency
        let timingChanged = title != incoming.title
            || start != incoming.start
            || end != incoming.end
            || isAllDay != incoming.isAllDay

        title            = incoming.title
        start            = incoming.start
        end              = incoming.end
        isAllDay         = incoming.isAllDay
        notes            = incoming.notes
        location         = incoming.location
        calendarName     = incoming.calendarName
        calendarColorHex = incoming.calendarColorHex
        externalEventId  = incoming.externalEventId
        iCalUID          = incoming.iCalUID
        occurrenceStart  = incoming.occurrenceStart
        seriesID         = incoming.seriesID
        calendarItemID   = incoming.calendarItemID
        organizer        = incoming.organizer
        sourceModifiedAt = incoming.sourceModifiedAt
        syncedAt         = incoming.syncedAt

        // The calendar's urgency setting follows the calendar: set, changed or
        // removed there, it is set, changed or removed here. An override the user
        // made on this event is theirs and sync never touches it.
        let userOverride = urgencyOverrideRaw != nil && urgencyOverrideFromCalendar != true
        if !userOverride {
            urgencyOverrideRaw = incoming.urgencyOverrideRaw
            urgencyOverrideFromCalendar = incoming.urgencyOverrideFromCalendar
            // Not judged yet: show the placeholder sync assigned.
            if urgencyOverrideRaw == nil && cachedSemantics == nil { urgency = incoming.urgency }
        }
        refreshUrgency()

        return timingChanged || urgency != oldUrgency
    }
}

// MARK: - Identity

extension OlanaEvent {
    var syncKeys: SyncKeys {
        SyncKeys(sourceID: externalEventId, title: title, start: start, end: end,
                 iCalUID: iCalUID, occurrence: occurrenceStart, organizer: organizer)
    }

    /// An urgency the user set on this event (not the calendar's setting).
    var hasUserOverride: Bool {
        urgencyOverrideRaw != nil && urgencyOverrideFromCalendar != true
    }

    /// The user's overrides, if any, kept when the event disappears.
    func overrideTombstone(removedAt: Date) -> OverrideTombstone? {
        guard hasUserOverride else { return nil }
        return OverrideTombstone(title: title, start: start, end: end, organizer: organizer,
                                 removedAt: removedAt, urgencyOverrideRaw: urgencyOverrideRaw)
    }

    func adoptOverrides(from t: OverrideTombstone) {
        guard !hasUserOverride, let raw = t.urgencyOverrideRaw else { return }
        urgencyOverrideRaw = raw
        urgencyOverrideFromCalendar = nil
        refreshUrgency()
    }
}
