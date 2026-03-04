import Foundation
import SwiftUI
import Combine
import SwiftData

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [OlanaEvent] = []
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

        homeDisplayEvents = (nonRecurring + representatives).sorted { $0.start < $1.start }
    }

    func load(predicate: Predicate<OlanaEvent>? = nil, sort: [SortDescriptor<OlanaEvent>] = [SortDescriptor(\OlanaEvent.start, order: .forward)]) {
        do {
            var descriptor = FetchDescriptor<OlanaEvent>(predicate: predicate, sortBy: sort)
            descriptor.fetchLimit = 0
            events = try context.fetch(descriptor)
        } catch {
            print("Failed to fetch events: \(error)")
            events = []
        }
        rebuildHomeDisplayEvents()
    }

    func addEvent(title: String, start: Date, end: Date, urgency: EventUrgency, recurrenceRule: RecurrenceRule = .none) {
        let new = OlanaEvent(title: title, start: start, end: end, urgency: urgency, recurrenceRule: recurrenceRule)
        context.insert(new)
        if recurrenceRule != .none {
            for occurrence in generateOccurrences(from: new, rule: recurrenceRule) {
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

    /// Replaces all events from a given external calendar source within the
    /// specified date range with the newly-normalised events.
    /// Called by CalendarIntegrationManager after each sync cycle.
    func syncExternalCalendarEvents(
        source: String,
        from start: Date,
        to end: Date,
        events normalisedEvents: [OlanaEvent]
    ) {
        // Remove stale synced events in this window
        let toRemove = events.filter {
            $0.externalCalendarId == source &&
            $0.start >= start &&
            $0.start <= end
        }
        for e in toRemove { context.delete(e) }

        // Insert normalised replacements
        for event in normalisedEvents { context.insert(event) }

        saveAndRefresh()
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
