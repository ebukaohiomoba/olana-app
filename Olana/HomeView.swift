//
//  HomeView.swift
//  Olana
//
//  "The list is the day" (home_literata.html, spec_m0_m1_v2 §14):
//    date label → next card → the rest of today on one rail.
//  An empty day says "Your day is open." with a peek at the next thing that
//  matters.
//
//  Everything the screen says comes from HomeDayBuilder, which is pure. This
//  view snapshots the store into HomeDayBuilder.Input once a minute and draws.
//
//  M1-B removed from home: greeting, Olu, the progress card (XP, streak, grace
//  tokens), the imminent card, the day strip and navigator, the event list and
//  the floating add button (now the raised + in OlanaTabBar). Their data stays.
//

import SwiftUI
import EventKit

struct HomeView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var calendarDataStore: CalendarDataStore
    @Environment(\.homePalette) private var c
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var notificationSettings = NotificationSettings.shared

    @State private var editingEvent: OlanaEvent?

    // Delete confirmation for recurring events
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteChoice = false

    // 15-minute nudge and Live Activity start
    @State private var isViewVisible = false
    @State private var imminentTimer: Timer?
    @State private var nudgedIDs: Set<String> = []
    @State private var nudgeBannerText: String?
    @State private var nudgeDismissTimer: Timer?

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let day = buildDay(now: context.date)
                ScrollView {
                    HomeScreenContent(day: day,
                                      syncText: syncText(now: context.date, alwaysShow: day.isOpen),
                                      onSelect: { open($0) },
                                      onToggleDone: { toggleDone($0) },
                                      onDelete: { handleDeleteIntent(id: $0, isRecurring: $1) })
                }
                .scrollIndicators(.hidden)
            }
            .background(c.bg.ignoresSafeArea())
            .overlay(alignment: .top) { nudgeBanner }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                isViewVisible = true
                startImminentTimerIfNeeded()
                // Quick-sync on each appearance, then extract semantics for
                // anything new so the card is live on cold launch.
                Task {
                    await calendarManager.performQuickSync()
                    await store.backfillSemantics()
                }
                let events = store.events
                Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }
            }
            .onDisappear {
                isViewVisible = false
                stopImminentTimer()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    guard isViewVisible else { return }
                    startImminentTimerIfNeeded()
                    Task {
                        await calendarManager.performQuickSync()
                        await store.backfillSemantics()
                    }
                    let events = store.events
                    Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }
                case .background, .inactive:
                    stopImminentTimer()
                @unknown default:
                    break
                }
            }
            .sheet(item: $editingEvent) { event in
                EditEventGlassPanel(event: event) { updated in
                    store.updateEvent(
                        id: event.id,
                        title: updated.title,
                        start: updated.start,
                        end: updated.end,
                        urgency: updated.urgency,
                        recurrenceRule: updated.recurrenceRule
                    )
                }
            }
            .confirmationDialog(
                "Delete recurring event?",
                isPresented: $showDeleteChoice,
                titleVisibility: .visible
            ) {
                Button("Delete This Event Only", role: .destructive) {
                    if let id = pendingDeleteID { store.removeEvent(id: id) }
                    pendingDeleteID = nil
                }
                Button("Delete This & All Upcoming", role: .destructive) {
                    if let id = pendingDeleteID { store.removeSeriesFromEvent(id: id) }
                    pendingDeleteID = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteID = nil
                }
            } message: {
                Text("Remove just this occurrence, or this and all upcoming events in the series?")
            }
        }
    }

    // MARK: - Day

    private func buildDay(now: Date) -> HomeDay {
        let cal = Calendar.current
        // Today's events for the rail, plus anything still ahead for the card,
        // which picks by earliest actionable moment wherever it falls.
        let inputs = store.events
            .filter { cal.isDate($0.start, inSameDayAs: now) || ($0.end > now && !$0.completed) }
            .map { input($0, now: now) }
        return HomeDayBuilder.build(inputs: inputs, now: now, bed: bedTime(now: now))
    }

    private func input(_ e: OlanaEvent, now: Date) -> HomeDayBuilder.Input {
        let sem = e.cachedSemantics
        let prep = sem?.effectivePrep.hours ?? 0
        return HomeDayBuilder.Input(
            id: e.id, title: e.title, start: e.start, end: e.end,
            isAllDay: e.isAllDay, isTask: e.isTask,
            completed: e.completed, completedAt: e.completedAt,
            isRecurring: e.recurrenceRule != .none,
            location: e.location, urgency: e.urgency,
            scored: UrgencyManager.shared.cachedScore(for: e, now: now),
            prepHours: prep > 0 ? prep : nil,
            assisted: Self.isAssisted(e, semantics: sem))
    }

    /// PRD §1.6: help runs for Moderate+ consequence. The user has the last
    /// word: an urgency they set themselves decides instead. Assist modes
    /// (Always Assist / No Execution Alerts) replace this check in M1-C.
    static func isAssisted(_ e: OlanaEvent, semantics: EventSemantics?) -> Bool {
        if let override = e.urgencyOverrideRaw.flatMap(EventUrgency.init(rawValue:)) {
            return override != .low
        }
        guard let c = semantics?.consequence else { return false }
        return c != .minor
    }

    /// Quiet-hours start today, used as "Bed around 10". nil when quiet hours are off.
    private func bedTime(now: Date) -> Date? {
        guard notificationSettings.quietHoursEnabled else { return nil }
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: notificationSettings.quietHoursStart)
        return cal.date(bySettingHour: hm.hour ?? 22, minute: hm.minute ?? 0, second: 0, of: now)
    }

    // MARK: - Pieces

    private var syncSources: String {
        var names: [String] = []
        if calendarManager.authorizationStatus == .fullAccess { names.append("Apple Calendar") }
        if calendarManager.hasGoogleAccounts { names.append("Google") }
        return names.isEmpty ? "Calendars" : names.joined(separator: " and ")
    }

    /// "Apple Calendar and Google synced 2 min ago". On a full day it only
    /// appears once the data is over 2 h old (spec §5.6, stale sync).
    private func syncText(now: Date, alwaysShow: Bool) -> HomeScreenContent.Sync? {
        guard let last = calendarManager.lastSyncDate else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(last) / 60))
        if minutes >= 120 { return .init(text: "Updated \(minutes / 60) h ago", fresh: false) }
        guard alwaysShow else { return nil }
        return .init(text: "\(syncSources) synced \(minutes < 1 ? "just now" : "\(minutes) min ago")", fresh: true)
    }

    @ViewBuilder
    private var nudgeBanner: some View {
        if let nudge = nudgeBannerText {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(c.goldText)
                Text(nudge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(c.text)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(c.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(c.line, lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Intents

    private func open(_ id: UUID) {
        editingEvent = store.events.first { $0.id == id }
    }

    private func toggleDone(_ id: UUID) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        _ = store.toggleEventCompletion(id)
    }

    private func handleDeleteIntent(id: UUID, isRecurring: Bool) {
        if isRecurring {
            pendingDeleteID = id
            showDeleteChoice = true
        } else {
            store.removeEvent(id: id)
        }
    }

    // MARK: - Imminent timer (60 s): Live Activities + 15-minute nudge

    private func startImminentTimerIfNeeded() {
        guard imminentTimer == nil else { return }
        imminentTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.checkForImminentNudge()
        }
    }

    private func stopImminentTimer() {
        imminentTimer?.invalidate()
        imminentTimer = nil
        nudgeDismissTimer?.invalidate()
        nudgeDismissTimer = nil
    }

    private func checkForImminentNudge() {
        let now       = Date()
        let leadMins  = Double(NotificationSettings.shared.liveActivityLeadMinutes)
        let lowerBound = (leadMins - 1) * 60
        let upperBound = (leadMins + 1) * 60

        // On every tick, start Live Activities for any events now inside the lead window.
        let events = store.events
        Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }

        for event in store.events {
            let timeUntil = event.start.timeIntervalSince(now)
            guard timeUntil >= lowerBound && timeUntil <= upperBound else { continue }
            let key = event.externalEventId ?? event.id.uuidString
            guard !nudgedIDs.contains(key) else { continue }

            nudgedIDs.insert(key)

            let nudgeText = "Your \(HomeFormat.clock(event.start)) is coming up. Want to wrap up what you're doing?"
            showNudgeBanner(nudgeText)

            let capturedEvent = event
            Task { await NotificationEngine.shared.startLiveActivityNow(for: capturedEvent) }

            break   // one nudge at a time
        }
    }

    private func showNudgeBanner(_ text: String) {
        withAnimation(.easeInOut(duration: 0.25)) { nudgeBannerText = text }
        nudgeDismissTimer?.invalidate()
        nudgeDismissTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { self.nudgeBannerText = nil }
        }
    }
}

// MARK: - Screen content

/// Everything below the status bar, from a HomeDay. Shared by HomeView and the
/// DEBUG fixture screen so both draw exactly the same thing.
struct HomeScreenContent: View {
    struct Sync: Equatable { let text: String; let fresh: Bool }

    let day: HomeDay
    let syncText: Sync?
    var onSelect: (UUID) -> Void = { _ in }
    var onToggleDone: (UUID) -> Void = { _ in }
    var onDelete: (UUID, Bool) -> Void = { _, _ in }

    @Environment(\.homePalette) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dateLabel
                .padding(.top, 6)
                .padding(.bottom, 16)

            if day.isOpen {
                OpenDayView(day: day, onSelect: onSelect)
            } else {
                if let card = day.card {
                    NextCardView(card: card) { onSelect(card.eventID) }
                        .padding(.bottom, 16)
                }
                DayRailView(day: day, onSelect: onSelect,
                            onToggleDone: onToggleDone, onDelete: onDelete)
            }

            if let sync = syncText {
                HStack(spacing: 5) {
                    if sync.fresh { Text("●").foregroundStyle(c.synced) }
                    Text(sync.text).foregroundStyle(c.faint)
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    private var dateLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.now.formatted(.dateTime.weekday(.wide)))
                .font(.headline)
                .foregroundStyle(c.text)
            Text(day.now.formatted(.dateTime.month(.wide).day()))
                .font(.subheadline)
                .foregroundStyle(c.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Open day

/// "Your day is open." (spec §14.6): one serif line, one sentence, a peek at
/// the next thing that matters, and a dotted free rail to wind down.
private struct OpenDayView: View {
    let day: HomeDay
    var onSelect: (UUID) -> Void

    @Environment(\.homePalette) private var c
    @ScaledMetric(relativeTo: .title) private var l1Size: CGFloat = 33

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Your day is ").foregroundStyle(c.text) + Text("open.").foregroundStyle(c.goldText))
                .font(HomeType.serif(size: l1Size))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)

            Text(!day.done.isEmpty
                 ? "Nothing else on your calendars today, so there's nothing to prep for."
                 : "Nothing on your calendars today, so there's nothing to prep for.")
                .font(.subheadline)
                .foregroundStyle(c.muted)
                .padding(.top, 10)

            if let peek = day.peek {
                Button { onSelect(peek.eventID) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .font(.system(size: 16))
                            .foregroundStyle(c.muted)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 10).fill(c.card2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peek.title).font(.callout).foregroundStyle(c.text).lineLimit(1)
                            Text("\(HomeFormat.dayName(peek.start, now: day.now).capitalizedFirst) \(peek.start.formatted(date: .omitted, time: .shortened)) · next thing that matters")
                                .font(.caption)
                                .foregroundStyle(c.muted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(c.faint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 18).fill(c.card))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }

            if !day.done.isEmpty || day.bed != nil {
                DayRailView(day: day, freeTime: true, onSelect: onSelect)
                    .padding(.top, 26)
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(EventStore())
        .environmentObject(CalendarIntegrationManager())
        .environmentObject(CalendarDataStore())
        .homePalette()
}
