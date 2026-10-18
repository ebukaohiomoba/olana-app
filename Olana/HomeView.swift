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
//  M1-B removed from home: greeting, Olu, the progress card, the imminent
//  card, the day strip and navigator, the event list and the floating add
//  button (now Add in the tab bar). XP, streaks and friends are gone entirely.
//
//  Also asks, just in time (PRD v3 §1.11): notifications after first value,
//  and the calendar-alerts tip a week after onboarding.
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
    /// The event sheet (PRD v3 §1.7 Job 4); its Edit opens the edit panel.
    @State private var sheetEvent: OlanaEvent?
    @State private var editAfterSheet: OlanaEvent?
    /// Bumped by a card action so the card redraws before the next minute.
    @State private var actionTick = 0
    /// "Which one?" for a "Where is this?" answer with several matches.
    @State private var placeChoice: (event: OlanaEvent, options: [ResolvedPlace])?
    @State private var placeNotFound = false
    @State private var showGettingThere = false
    // Just-in-time asks (PRD §1.11): notifications after first value, the
    // calendar-alerts tip after a week.
    @State private var jitAsk: JustInTimeAsk?
    @AppStorage("olanaNotifAsked_v1") private var notifAsked = false
    @AppStorage("olanaBackupTipShown_v1") private var backupTipShown = false
    @AppStorage("olanaOnboardedAt_v1") private var onboardedAt: Double = 0

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
                let _ = actionTick
                let day = buildDay(now: context.date)
                ScrollView {
                    HomeScreenContent(day: day,
                                      syncText: syncText(now: context.date, alwaysShow: day.isOpen),
                                      onSelect: { open($0) },
                                      onAction: { act($0, $1, $2) },
                                      onToggleDone: { toggleDone($0) },
                                      onDelete: { handleDeleteIntent(id: $0, isRecurring: $1) })
                }
                .scrollIndicators(.hidden)
                #if DEBUG
                .spikeCardLog(day.card)
                #endif
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
                    // Integrity check on every foreground (PRD v3 §3.10).
                    NotificationEngine.shared.requestReplan("foreground")
                    await askJustInTime()
                }
                let events = store.events
                Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }
            }
            .onDisappear {
                isViewVisible = false
                stopImminentTimer()
            }
            .task {
                // Spec §7.6: every 5 min while home is open, refresh ETAs for
                // leave-by within 45 min, and replan if one moved.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    guard scenePhase == .active, isViewVisible else { continue }
                    if await ExecRefresher.refreshETAs(store: store, horizon: 45 * 60) > 0 {
                        NotificationEngine.shared.requestReplan("eta 5 min")
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    guard isViewVisible else { return }
                    startImminentTimerIfNeeded()
                    Task {
                        await calendarManager.performQuickSync()
                        await store.backfillSemantics()
                        NotificationEngine.shared.requestReplan("foreground")
                        // M1-C: up to 10 EventAssist jobs in the foreground (spec §6.4),
                        // then ETAs for the next 24 h, then plan with them.
                        _ = await ExecRefresher.assistJobs(store: store, limit: 10)
                        if await ExecRefresher.refreshETAs(store: store, horizon: 24 * 3600) > 0 {
                            NotificationEngine.shared.requestReplan("foreground eta")
                        }
                    }
                    let events = store.events
                    Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }
                case .background, .inactive:
                    stopImminentTimer()
                @unknown default:
                    break
                }
            }
            .alert(jitAsk?.title ?? "", isPresented: Binding(get: { jitAsk != nil }, set: { if !$0 { jitAsk = nil } }),
                   presenting: jitAsk) { ask in
                switch ask {
                case .notifications:
                    Button("Yes") {
                        notifAsked = true
                        Task {
                            if await NotificationEngine.shared.requestAuthorization() {
                                NotificationEngine.shared.requestReplan("notifications allowed")
                            }
                        }
                    }
                    Button("Not now", role: .cancel) { notifAsked = true }
                case .calendarBackupTip:
                    Button("OK") { backupTipShown = true }
                }
            } message: { ask in
                Text(ask.message)
            }
            .confirmationDialog("Which one?", isPresented: Binding(get: { placeChoice != nil },
                                                                   set: { if !$0 { placeChoice = nil } }), titleVisibility: .visible) {
                if let choice = placeChoice {
                    ForEach(choice.options, id: \.self) { p in
                        Button([p.name, p.address].compactMap { $0 }.joined(separator: " · ")) { savePlace(choice.event, p) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't find that place", isPresented: $placeNotFound) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try the name and street, like \"Smile Dental on 23rd\".")
            }
            .sheet(item: $sheetEvent, onDismiss: {
                if let e = editAfterSheet { editAfterSheet = nil; editingEvent = e }
            }) { event in
                EventSheetView(event: event) {
                    editAfterSheet = event
                    sheetEvent = nil
                }
                .homePalette()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showGettingThere, onDismiss: { actionTick += 1 }) {
                NavigationStack {
                    TravelSettingsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGettingThere = false } } }
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
        let ov = store.effectiveOverrides(for: e)
        var i = HomeDayBuilder.Input(
            id: e.id, title: e.title, start: e.start, end: e.end,
            isAllDay: e.isAllDay, isTask: e.isTask,
            completed: e.completed, completedAt: e.completedAt,
            isRecurring: e.recurrenceRule != .none,
            location: e.location, urgency: e.urgency,
            scored: UrgencyManager.shared.cachedScore(for: e, now: now),
            prepHours: prep > 0 ? prep : nil,
            assisted: Self.isAssisted(e, semantics: sem, mode: ov.assistMode))
        // M1-C: the same trip times the alerts and the sheet use.
        let trip = ExecContext.trip(for: e, overrides: ov, now: now)
        let stored = ETAStore.shared.get(e.overrideEventKey)
        let eta = stored.flatMap { ETAFreshness.effective($0.reading, start: e.start, now: now) }
        let progress = EventProgressStore.shared.get(e.overrideEventKey)
        i.exec = trip.times
        i.state = PhaseState(finished: progress.finished, onTheWay: progress.onTheWay, prepDone: progress.prepDone)
        i.etaSeconds = eta?.seconds
        i.approximate = eta?.approximate ?? false
        if trip.planTravel { i.tripPhrase = "plan travel" }
        else if let eta, let stored {
            let mode = ov.travelMode.flatMap(TravelMode.init(rawValue:)) ?? ExecPreferences.defaultMode
            i.tripPhrase = "\(ETAFreshness.phrase(eta.seconds, mode: mode)) from \(stored.originName)"
        }
        i.hasPlus = PlusAccess.hasPlus
        // The question this event waits on (spec §7.2, §7.8, §7.9).
        let assist = ExecContext.cachedAssist(for: e, facts: NotesCleaner.clean(notes: e.isFromExternalCalendar ? e.notes : nil,
                                                                              location: e.location, conferenceURL: e.meetingURL),
                                              overrides: ov)
        i.question = CardAction.question(
            unranked: e.isUnrankable, modeChosen: ov.assistMode != .normal, asksAttendance: trip.asksAttendance,
            assisted: i.assisted, start: e.start, now: now,
            hasUsablePlace: trip.geocodable || trip.roomish || ov.place != nil,
            hasLink: e.meetingURL != nil || trip.attendance == .virtual,
            looksLikeTravel: !e.isTask && (e.likelyNeedsTravel ?? assist?.needsTravel ?? false),
            travelNotNeeded: ov.travelNotNeeded,
            needsOrigin: trip.needsTravel && !trip.planTravel && !ExecPreferences.hasSavedOrigin && !ExecPreferences.originAsked)
        return i
    }

    // MARK: - Just in time (PRD v3 §1.11)

    private func askJustInTime() async {
        // Users from before this build start their week now.
        if onboardedAt == 0 { onboardedAt = Date().timeIntervalSince1970 }
        // Let home show first: the ask follows first value.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard isViewVisible, jitAsk == nil else { return }
        await NotificationEngine.shared.checkAuthorizationStatus()
        let now = Date()
        jitAsk = JustInTimeAsk.next(
            notificationsUndetermined: NotificationEngine.shared.authorizationStatus == .notDetermined,
            notificationsAsked: notifAsked, nextEventTitle: buildDay(now: now).card?.title,
            onboardedAt: Date(timeIntervalSince1970: onboardedAt), tipShown: backupTipShown, now: now)
    }

    // MARK: - Card actions (spec v3 §14.8)

    private func act(_ id: UUID, _ action: CardAction, _ text: String?) {
        guard let e = store.events.first(where: { $0.id == id }) else { return }
        let ov = store.effectiveOverrides(for: e)
        let key = e.overrideEventKey
        func progress(_ change: (inout EventProgress) -> Void) {
            EventProgressStore.shared.update(key, eventStart: e.start, change)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch action {
        case .imLeaving:
            Task {
                await NotificationEngine.shared.markLeaving(e, overrides: ov)
                NotificationEngine.shared.requestReplan("leaving")
                actionTick += 1
            }
        case .imHere:
            progress { $0.arrivedAt = Date() }
            Task { await NotificationEngine.shared.cancelNotifications(for: e.id) }
        case .prepDone:
            progress { $0.prepDone = true }
            PlusStore.shared.record(.prepStarted, eventKey: key)
            NotificationEngine.shared.requestReplan("prep done")
        case .join:
            progress { $0.joinedAt = Date() }
            let link = e.meetingURL ?? NotesCleaner.clean(notes: e.notes, location: e.location).meetingURL
            if let link { UIApplication.shared.open(link) }
            Task { await NotificationEngine.shared.cancelNotifications(for: e.id) }
        case .inPersonOrOnline:
            store.updateOverride(for: e, scope: .series) { $0.attendance = text == "virtual" ? .virtual : .inPerson }
        case .isImportant:
            store.updateOverride(for: e, scope: .series) { $0.assistMode = text == "yes" ? .always : .noAlerts }
        case .whereIsThis:
            answerWhere(e, text ?? "")
        case .whereFrom:
            ExecPreferences.originAsked = true
            if text == "setup" { showGettingThere = true }
        }
        actionTick += 1
    }

    /// "Where is this?" (spec §7.9): Online and Not needed are shortcuts; other
    /// words go through MapKit near the origin. Saved for the series, never
    /// written back to the calendar.
    private func answerWhere(_ e: OlanaEvent, _ text: String) {
        switch CaptureCode.squash(text) {
        case "online":
            store.updateOverride(for: e, scope: .series) { $0.attendance = .virtual }
        case "not needed":
            store.updateOverride(for: e, scope: .series) { $0.travelNotNeeded = true }
        default:
            Task {
                switch await PlaceResolver.shared.resolve(text) {
                case .resolved(let p): savePlace(e, p)
                case .choose(let options): placeChoice = (e, options)
                case .personal, .none: placeNotFound = true
                }
            }
        }
    }

    private func savePlace(_ e: OlanaEvent, _ p: ResolvedPlace) {
        store.updateOverride(for: e, scope: .series) { $0.place = p; $0.attendance = .inPerson }
        Task {
            let ov = store.effectiveOverrides(for: e)
            await TravelService.shared.refresh(e, events: store.events, overrides: ov)
            NotificationEngine.shared.requestReplan("place answered")
            actionTick += 1
        }
    }

    /// PRD §1.6: help runs for Always Assist, or Normal mode with Moderate+
    /// consequence. The user has the last word: an urgency they set decides
    /// instead of the model.
    static func isAssisted(_ e: OlanaEvent, semantics: EventSemantics?, mode: AssistMode = .normal) -> Bool {
        if mode == .always { return true }
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
        sheetEvent = store.events.first { $0.id == id }
    }

    private func toggleDone(_ id: UUID) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        store.toggleEventCompletion(id)
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
    var onAction: (UUID, CardAction, String?) -> Void = { _, _, _ in }
    var onToggleDone: (UUID) -> Void = { _ in }
    var onDelete: (UUID, Bool) -> Void = { _, _ in }

    @Environment(\.homePalette) private var c
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dateLabel
                .padding(.top, 6)
                .padding(.bottom, 16)

            if day.isOpen {
                OpenDayView(day: day, onSelect: onSelect)
            } else {
                if let card = day.card {
                    NextCardView(card: card, onTap: { onSelect(card.eventID) },
                                 onAction: { onAction(card.eventID, $0, $1) })
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
        // Stacked at accessibility sizes so the day name never hyphenates.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var l1Size: CGFloat = 33

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Your day is ").foregroundStyle(c.text) + Text("open.").foregroundStyle(c.goldText))
                .font(HomeType.serif(size: l1Size))
                .tracking(-0.7)
                .minimumScaleFactor(0.8)
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
                        if !typeSize.isAccessibilitySize {
                        Image(systemName: "calendar")
                            .font(.system(size: 16))
                            .foregroundStyle(c.muted)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 10).fill(c.card2))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peek.title).font(.callout).foregroundStyle(c.text).lineLimit(3)
                            Text("\(HomeFormat.dayName(peek.start, now: day.now).capitalizedFirst) \(peek.start.formatted(date: .omitted, time: .shortened)) · next thing that matters")
                                .font(.caption)
                                .foregroundStyle(c.muted)
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
