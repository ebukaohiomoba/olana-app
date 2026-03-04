//
//  HomeView.swift
//  Olana
//
//  Architecture:
//  - Single List owns all scrollable content (no List-inside-ScrollView anti-pattern)
//  - EventRowModel is a value-type snapshot of OlanaEvent — cards never hold a
//    SwiftData reference, so deleting the last event cannot cause a zombie crash
//  - confirmationDialog and celebration sheet are presented from HomeView,
//    not from inside a List row, so they always appear reliably
//

import SwiftUI
import Combine

// MARK: - EventRowModel (value-type snapshot)
// Cards render from this struct, not from the live SwiftData object.
// This means deleting an event mid-animation cannot crash the app.

struct EventRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let start: Date
    let urgency: EventUrgency
    let recurrenceRule: RecurrenceRule
    let completed: Bool

    /// Stable identity for ForEach. Recurring series share a key so the
    /// representative can change without causing an "Invalid update" crash.
    var homeListKey: String {
        recurrenceRule == .none ? id.uuidString : "\(title)|\(recurrenceRule.rawValue)"
    }

    init(_ event: OlanaEvent) {
        id             = event.id
        title          = event.title
        start          = event.start
        urgency        = event.urgency
        recurrenceRule = event.recurrenceRule
        completed      = event.completed
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.olanaTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    // ── Navigation / sheets ──────────────────────────────────────────
    @State private var showingAdd       = false
    @State private var editingEvent: OlanaEvent? = nil
    @State private var showingProfile   = false

    // ── Delete confirmation (lifted out of list rows) ─────────────────
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteChoice = false

    // ── Celebration sheet (lifted out of list rows) ───────────────────
    @State private var celebrationData: (xp: Int, rewards: [String], newBadges: [Badge], eventTitle: String)?
    @State private var showCelebrationModal = false

    // ── Banner ────────────────────────────────────────────────────────
    @State private var bannerEvent: OlanaEvent?
    @State private var snoozed: [UUID: Date] = [:]
    @State private var bannerTimer: Timer?

    // ── Greeting ──────────────────────────────────────────────────────
    @State private var greeting: String = ""
    @State private var motivationalMessage: String = ""
    @State private var greetingTimer: Timer?
    @State private var isViewVisible = false

    // ── Day navigator ─────────────────────────────────────────────────
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    // ── Olu ───────────────────────────────────────────────────────────
    @StateObject private var oluManager = OluManager()

    // ── Calendar integration ──────────────────────────────────────────
    @EnvironmentObject private var calendarManager: CalendarIntegrationManager
    @EnvironmentObject private var calendarDataStore: CalendarDataStore
    /// Ticks every 60 s to refresh ImminentEventCard countdown and check for nudges.
    @State private var imminentTick: Int = 0
    @State private var imminentTimer: Timer?
    /// Tracks which event IDs have already triggered a 15-minute nudge (this session).
    @State private var nudgedIDs: Set<String> = []
    /// Text shown in the ephemeral nudge banner (nil = hidden).
    @State private var nudgeBannerText: String? = nil
    @State private var nudgeDismissTimer: Timer?

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default:     return "Good evening"
        }
    }

    private var eventsForSelectedDay: [EventRowModel] {
        let cal = Calendar.current
        return store.homeDisplayEvents
            .filter { cal.isDate($0.start, inSameDayAs: selectedDay) }
            .map(EventRowModel.init)
    }

    private func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInTomorrow(date)  { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private let motivationalMessages = [
        "Keep up the great work to earn more rewards!",
        "Earn badges and celebrate your wins!",
        "No win is too small!",
        "Stack good days until you reach your goal!",
        "Keep going, you've got this!",
        "Continue to push through!",
        "You can change your life with one good day!"
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {

                // Background gradient — sits behind the List
                LinearGradient(
                    colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // ── Single List for all scrollable content ─────────────
                // Using one List eliminates the ScrollView+List conflict that
                // caused the UICollectionView "Invalid update" crash.
                List {

                    // ── Welcome: greeting + Olu ──────────────────────
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(greeting)
                                .font(.system(size: 34, weight: .bold, design: .serif))
                                .foregroundStyle(theme.colors.ink)
                            Text(motivationalMessage)
                                .font(.system(size: 15, weight: .light))
                                .italic()
                                .foregroundStyle(theme.colors.slate)
                                .lineSpacing(2)
                        }
                        Spacer()
                        OluView(state: $oluManager.state, size: 170)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))

                    // ── Progress card ────────────────────────────────
                    // Button + navigationDestination avoids the automatic
                    // disclosure chevron that NavigationLink adds in a List.
                    Button { showingProfile = true } label: {
                        ProgressCardContent()
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))

                    // ── Imminent Event Card ───────────────────────────
                    if calendarDataStore.preferences.showImminentCard {
                        ImminentEventCard(
                            windowMinutes: calendarDataStore.preferences.imminentWindowMinutes,
                            timerTick: imminentTick
                        )
                        .environmentObject(store)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    }

                    // ── Day navigator ─────────────────────────────────
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedDay = Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(theme.colors.ribbon)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        VStack(spacing: 3) {
                            HStack(spacing: 6) {
                                Text(dayLabel(for: selectedDay))
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1.4)
                                    .textCase(.uppercase)
                                    .foregroundStyle(theme.colors.ink)

                                if !Calendar.current.isDateInToday(selectedDay) {
                                    Button("Today") {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            selectedDay = Calendar.current.startOfDay(for: Date())
                                        }
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.colors.ribbon)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(theme.colors.ribbon.opacity(0.12)))
                                }
                            }

                            let count = eventsForSelectedDay.count
                            Text(count == 0 ? "No events" : "\(count) event\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(theme.colors.slate.opacity(0.7))
                        }

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedDay = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(theme.colors.ribbon)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))

                    // ── Events for selected day or empty state ────────
                    if eventsForSelectedDay.isEmpty {
                        EmptyStateView()
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    } else {
                        ForEach(eventsForSelectedDay, id: \.homeListKey) { model in
                            EventCardRow(
                                model: model,
                                onToggleComplete: { id, title in
                                    handleCompletion(id: id, title: title)
                                },
                                onUncomplete: { id in
                                    _ = store.toggleEventCompletion(id)
                                },
                                onEdit: {
                                    // Look up the live event by ID at tap time —
                                    // safe because the user just tapped Edit (event exists)
                                    editingEvent = store.events.first { $0.id == model.id }
                                },
                                onDeleteIntent: { id, isRecurring in
                                    handleDeleteIntent(id: id, isRecurring: isRecurring)
                                }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }

                    // Bottom padding so content clears the FAB
                    Color.clear.frame(height: 96)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in oluManager.userDidInteract() }
                )

                // ── 15-minute nudge banner ────────────────────────────
                if let nudge = nudgeBannerText {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(theme.colors.ribbon)
                            Text(nudge)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(theme.colors.ink)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(theme.colors.paper)
                                .shadow(color: theme.colors.pillShadow, radius: 8, x: 0, y: 4)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.colors.cardBorder, lineWidth: 1))
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .padding(.top, 16)
                }

                // ── T-5 banner ────────────────────────────────────────
                if let be = bannerEvent {
                    VStack {
                        Spacer()
                        TMinusFiveBanner(
                            title: be.title,
                            reasons: bannerReasons(for: be),
                            onStart: { bannerEvent = nil },
                            onSnooze: { interval in
                                snoozed[be.id] = Date().addingTimeInterval(interval)
                                bannerEvent = nil
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 100)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }

                // ── FAB ───────────────────────────────────────────────
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(LinearGradient(
                                    colors: [theme.colors.ribbon, theme.colors.ribbon.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                        )
                        .shadow(color: theme.colors.ribbon.opacity(0.3), radius: 12, x: 0, y: 6)
                        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
                }
                .padding(.trailing, 24)
                .padding(.bottom, 20)
            }
            .onAppear {
                isViewVisible = true
                refreshBannerCandidate()
                greeting = timeGreeting
                motivationalMessage = motivationalMessages.randomElement() ?? motivationalMessages[0]
                startTimersIfNeeded()
                startImminentTimerIfNeeded()
                // Quick-sync calendar events on each foreground appearance
                Task { await calendarManager.performQuickSync() }
            }
            .onDisappear {
                isViewVisible = false
                stopTimers()
                stopImminentTimer()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    guard isViewVisible else { return }
                    refreshBannerCandidate()
                    updateGreetingIfNeeded()
                    startTimersIfNeeded()
                    startImminentTimerIfNeeded()
                    oluManager.updateForTimeOfDay()
                    Task { await calendarManager.performQuickSync() }
                case .background, .inactive:
                    stopTimers()
                    stopImminentTimer()
                @unknown default:
                    break
                }
            }
            // ── Navigation destinations ───────────────────────────────
            .navigationDestination(isPresented: $showingProfile) {
                ProfileView()
            }
            // ── Sheets ────────────────────────────────────────────────
            .sheet(isPresented: $showingAdd) {
                AddEventView()
                    .environmentObject(store)
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
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
            .sheet(isPresented: $showCelebrationModal) {
                if let data = celebrationData {
                    CompletionCelebrationView(
                        xpEarned: data.xp,
                        streakDays: XPManager.shared.streakDays,
                        eventTitle: data.eventTitle,
                        rewards: data.rewards,
                        newBadges: data.newBadges
                    )
                }
            }
            // ── Delete confirmation (stable: presented from NavigationStack) ──
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

    // MARK: - Intent handlers

    private func handleCompletion(id: UUID, title: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let result = store.toggleEventCompletion(id) {
            celebrationData = (
                xp: result.xp,
                rewards: result.rewards,
                newBadges: result.newBadges,
                eventTitle: title
            )
            showCelebrationModal = true
            oluManager.celebrate()
        }
    }

    private func handleDeleteIntent(id: UUID, isRecurring: Bool) {
        if isRecurring {
            pendingDeleteID = id
            showDeleteChoice = true
        } else {
            store.removeEvent(id: id)
        }
    }

    // MARK: - Banner

    private func refreshBannerCandidate() {
        let now    = Date()
        let window: TimeInterval = 5 * 60
        let sorted = store.events.filter { $0.start >= now }.sorted { $0.start < $1.start }
        guard let next = sorted.first else { bannerEvent = nil; return }
        if let until = snoozed[next.id], until > now { bannerEvent = nil; return }
        bannerEvent = next.start.timeIntervalSince(now) <= window ? next : nil
    }

    private func bannerReasons(for event: OlanaEvent) -> [String] {
        let minutes = max(0, Int(event.start.timeIntervalSince(Date()) / 60))
        return [minutes == 0 ? "starts now" : "starts in \(minutes)m"]
    }

    // MARK: - Timers

    private func startTimersIfNeeded() {
        guard bannerTimer == nil && greetingTimer == nil else { return }
        let hasUpcomingNearby = store.events.contains {
            let t = $0.start.timeIntervalSince(Date())
            return t > 0 && t <= 30 * 60
        }
        if hasUpcomingNearby {
            bannerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                self.refreshBannerCandidate()
            }
        }
        greetingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.updateGreetingIfNeeded()
        }
    }

    private func stopTimers() {
        bannerTimer?.invalidate();   bannerTimer  = nil
        greetingTimer?.invalidate(); greetingTimer = nil
    }

    private func updateGreetingIfNeeded() {
        let new = timeGreeting
        if new != greeting { greeting = new }
    }

    // MARK: - Imminent Timer (60 s) — countdown + 15-min nudge

    private func startImminentTimerIfNeeded() {
        guard imminentTimer == nil else { return }
        imminentTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.imminentTick &+= 1      // wraps instead of overflowing
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
        for event in store.events {
            let timeUntil = event.start.timeIntervalSince(now)
            guard timeUntil >= lowerBound && timeUntil <= upperBound else { continue }
            let key = event.externalEventId ?? event.id.uuidString
            guard !nudgedIDs.contains(key) else { continue }

            nudgedIDs.insert(key)
            oluManager.imminentNudge()

            let timeFmt = DateFormatter()
            timeFmt.timeStyle = .short
            let nudgeText = "Your \(timeFmt.string(from: event.start)) is coming up. Want to wrap up what you're doing?"
            showNudgeBanner(nudgeText)

            // Start the Live Activity countdown now that we're in the 15-minute window.
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

// MARK: - EventCardRow

private struct EventCardRow: View {
    @Environment(\.olanaTheme) private var theme

    let model: EventRowModel
    var onToggleComplete: ((UUID, String) -> Void)? = nil
    var onUncomplete: ((UUID) -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDeleteIntent: ((UUID, Bool) -> Void)? = nil

    @State private var showUncompleteAlert = false

    private var accentColor: Color {
        if model.completed { return theme.colors.success }
        switch model.urgency {
        case .high:   return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low:    return theme.colors.urgencyLow
        }
    }

    private var subtitleText: String {
        "\(relativeDateLabel(for: model.start)) · \(model.urgency.displayName) urgency"
    }

    private func relativeDateLabel(for date: Date) -> String {
        let cal = Calendar.current
        if date < Date()              { return "Past due" }
        if cal.isDateInToday(date)    { return "Due today" }
        if cal.isDateInTomorrow(date) { return "Due tomorrow" }
        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 7  { return "This week" }
        if days <= 14 { return "Next week" }
        return "Due \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left accent bar
            Capsule()
                .fill(accentColor)
                .frame(width: 4, height: 46)

            // Title + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                    .lineLimit(1)
                    .strikethrough(model.completed, color: .secondary)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if model.recurrenceRule != .none {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.caption2)
                        Text(model.recurrenceRule.repeatLabel)
                            .font(.caption2)
                    }
                    .foregroundStyle(theme.colors.slate)
                }
            }
            .opacity(model.completed ? 0.55 : 1.0)

            Spacer()

            // Completion circle
            Button {
                if model.completed {
                    showUncompleteAlert = true
                } else {
                    onToggleComplete?(model.id, model.title)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(model.completed ? accentColor : Color.clear)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle().stroke(
                                model.completed ? Color.clear : accentColor.opacity(0.45),
                                lineWidth: 1.5
                            )
                        )
                    if model.completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.colors.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: theme.colors.pillShadow, radius: 6, x: 0, y: 2)
        // Swipe left to reveal Edit and Delete
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDeleteIntent?(model.id, model.recurrenceRule != .none)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                onEdit?()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        // Uncomplete alert stays local — alerts inside list rows work reliably
        .alert("Undo completion?", isPresented: $showUncompleteAlert) {
            Button("Yes, undo", role: .destructive) {
                onUncomplete?(model.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will mark the event as incomplete. Your XP will remain.")
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    @Environment(\.olanaTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.colors.ribbon.opacity(0.1), theme.colors.ribbon.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)
                    .shadow(color: theme.colors.ribbon.opacity(0.1), radius: 20, x: 0, y: 10)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 44))
                    .foregroundStyle(LinearGradient(
                        colors: [theme.colors.ribbon, theme.colors.ribbon.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            VStack(spacing: 8) {
                Text("No upcoming events")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                Text("Tap the + button to create your first event")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(theme.colors.paper))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(theme.colors.cardBorder, lineWidth: 1))
        .shadow(color: theme.colors.pillShadow, radius: 10, x: 0, y: 4)
    }
}

// MARK: - Progress Card

private struct ProgressCardContent: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var xpManager = XPManager.shared

    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Progress")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isLight ? .white : theme.colors.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isLight ? Color.white.opacity(0.7) : theme.colors.slate)
            }
            HStack(spacing: 0) {
                StatColumn(
                    icon: "flame.fill",
                    iconGradient: LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom),
                    value: "\(xpManager.streakDays)",
                    label: "Streak Days",
                    textColor: isLight ? .white : nil
                )
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 60).padding(.horizontal, 8)
                StatColumn(
                    icon: "sparkles",
                    iconColor: isLight ? .white : theme.colors.ribbon,
                    value: "\(xpManager.graceTokens)",
                    label: "Grace Tokens",
                    textColor: isLight ? .white : nil
                )
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 60).padding(.horizontal, 8)
                StatColumn(
                    icon: "star.fill",
                    iconColor: .yellow,
                    value: formatXP(xpManager.totalXP),
                    label: "Total XP",
                    textColor: isLight ? .white : nil
                )
            }
        }
        .padding(24)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(
                        colors: [theme.colors.heroStart, theme.colors.heroEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Circle()
                    .fill(Color.white.opacity(isLight ? 0.09 : 0.05))
                    .frame(width: 110, height: 110)
                    .offset(x: 28, y: -28)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        .shadow(color: isLight ? theme.colors.heroEnd.opacity(0.35) : Color.black.opacity(0.4), radius: 16, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 12)
    }

    private func formatXP(_ xp: Int) -> String {
        if xp >= 10000 { return String(format: "%.1fk", Double(xp) / 1000.0) }
        if xp >= 1000  {
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: xp)) ?? "\(xp)"
        }
        return "\(xp)"
    }
}

// MARK: - Stat Column

private struct StatColumn: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    var iconGradient: LinearGradient? = nil
    var iconColor: Color? = nil
    let value: String
    let label: String
    var textColor: Color? = nil

    private var resolvedText: Color { textColor ?? theme.colors.ink }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 48, height: 48)
                if let gradient = iconGradient {
                    Image(systemName: icon).font(.title2).foregroundStyle(gradient)
                        .shadow(color: Color.orange.opacity(0.3), radius: 4, x: 0, y: 2)
                } else if let color = iconColor {
                    Image(systemName: icon).font(.title2).foregroundStyle(color)
                        .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 2)
                }
            }
            VStack(spacing: 4) {
                Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(resolvedText)
                Text(label).font(.caption.weight(.medium)).foregroundStyle(resolvedText.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview {
    HomeView()
        .environmentObject(EventStore())
        .environmentObject(CalendarIntegrationManager())
        .environmentObject(CalendarDataStore())
        .environment(\.olanaTheme, OlanaTheme.light)
}
