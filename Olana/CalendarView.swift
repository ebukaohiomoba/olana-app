//
//  CalendarView.swift
//  Olana
//
//  FIXED: Removed showingProfile binding, using NavigationLink instead
//

import SwiftUI
import SwiftData
import Combine
import UIKit
import EventKit

private let calendarTimeFormatter: DateFormatter = {
    let df = DateFormatter()
    df.timeStyle = .short
    return df
}()

struct CalendarView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.olanaTheme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var calendarManager: CalendarIntegrationManager

    // Calendar permission consent sheet
    @State private var showingCalendarConsent = false
    // ✅ REMOVED: @Binding var showingProfile: Bool

    // Fetch events sorted by start date
    @Query(sort: [SortDescriptor(\OlanaEvent.start, order: .forward)])
    private var events: [OlanaEvent]

    // Selection & navigation state
    @State private var selectedDate: Date = Date()
    @State private var monthAnchor: Date = Calendar.current.nv_startOfMonth(for: Date())

    // Add sheet state
    @State private var showingAddSheet = false
    @State private var showingMonthPicker = false
    @State private var filterUrgency: EventUrgency? = nil

    // Dynamic bottom sheet offsets
    @State private var minSheetOffset: CGFloat = 180
    @State private var maxSheetOffset: CGFloat = 450
    @State private var defaultSheetOffset: CGFloat = 450
    @State private var safeAreaBottom: CGFloat = 0

    // Bottom sheet state
    @State private var sheetOffset: CGFloat = 450
    @State private var isDragging = false
    @State private var dragStartOffset: CGFloat = 0
    
    // Toast state
    @State private var toastMessage: String? = nil
    @State private var showingToast: Bool = false
    @State private var toastTimer: Timer?
    @State private var isViewVisible = false
    

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Month navigation header
                    monthNavigationHeader
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    
                    // Calendar grid
                    calendarGrid
                        .padding(.horizontal, 24)
                    
                    Spacer()
                }
                
                // Bottom sheet with today's events
                GeometryReader { geometry in
                    let safeTop = geometry.safeAreaInsets.top
                    let safeBottom = geometry.safeAreaInsets.bottom
                    let screenHeight = geometry.size.height
                    
                    bottomSheet
                        .onAppear {
                            minSheetOffset = max(safeTop + 120, screenHeight * 0.15)
                            defaultSheetOffset = screenHeight * 0.62
                            maxSheetOffset = defaultSheetOffset
                            safeAreaBottom = safeBottom
                            sheetOffset = defaultSheetOffset
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            let h = newSize.height
                            let oldDefault = defaultSheetOffset
                            
                            minSheetOffset = max(safeTop + 120, h * 0.15)
                            defaultSheetOffset = h * 0.62
                            maxSheetOffset = defaultSheetOffset
                            safeAreaBottom = safeBottom
                            
                            if abs(sheetOffset - oldDefault) < 40 {
                                sheetOffset = defaultSheetOffset
                            } else {
                                sheetOffset = min(max(sheetOffset, minSheetOffset), maxSheetOffset)
                            }
                        }
                        .offset(y: sheetOffset)
                        .animation(isDragging ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: sheetOffset)
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    if !isDragging {
                                        isDragging = true
                                        dragStartOffset = sheetOffset
                                    }
                                    
                                    let proposedOffset = dragStartOffset + value.translation.height
                                    sheetOffset = max(minSheetOffset, min(proposedOffset, maxSheetOffset))
                                }
                                .onEnded { value in
                                    isDragging = false
                                    
                                    let velocity = value.predictedEndLocation.y - value.location.y
                                    let snapToMin = minSheetOffset
                                    let snapToDefault = defaultSheetOffset
                                    let midPoint = (snapToMin + snapToDefault) / 2
                                    
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                                        if velocity > 200 {
                                            sheetOffset = snapToDefault
                                        } else if velocity < -200 {
                                            sheetOffset = snapToMin
                                        } else {
                                            if sheetOffset < midPoint {
                                                sheetOffset = snapToMin
                                            } else {
                                                sheetOffset = snapToDefault
                                            }
                                        }
                                    }
                                }
                        )
                }
                .ignoresSafeArea()
                
                // Floating plus button
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [theme.colors.ribbon, theme.colors.ribbon.opacity(0.8)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                )
                                .shadow(color: theme.colors.ribbon.opacity(0.4), radius: 16, x: 0, y: 8)
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 20)
                    }
                }
            }
            .overlay(alignment: .top) {
                if showingToast, let message = toastMessage {
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.85))
                        )
                        .foregroundStyle(.white)
                        .shadow(color: theme.colors.pillShadow, radius: 8, x: 0, y: 4)
                        .padding(.top, 60)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showingToast)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isViewVisible = true
                selectedDate = Date()
                // Quick-sync calendar events on each foreground appearance
                Task { await calendarManager.performQuickSync() }
                // Catch up: start Live Activities for any events already in the lead window.
                let events = store.events
                Task { await NotificationEngine.shared.startLiveActivitiesIfNeeded(for: events) }
                // Show consent sheet contextually when user first opens Calendar tab
                let status = EKEventStore.authorizationStatus(for: .event)
                if status == .notDetermined {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showingCalendarConsent = true
                    }
                }
            }
            .onDisappear {
                isViewVisible = false
                stopToastTimer()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    break
                case .background, .inactive:
                    stopToastTimer()
                @unknown default:
                    break
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddEventView()
                    .environmentObject(store)
                    .presentationDetents([.fraction(0.75), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showingCalendarConsent) {
                CalendarConsentSheet(onConnect: {
                    showingCalendarConsent = false
                    // The actual permission request is handled by CalendarIntegrationManager
                    // which is set up in ContentView. Post a notification so it can respond.
                    NotificationCenter.default.post(name: .calendarAccessRequested, object: nil)
                }, onDismiss: {
                    showingCalendarConsent = false
                })
                .presentationDetents([.fraction(0.55)])
            }
            .sheet(isPresented: $showingMonthPicker) {
                MonthYearPickerView(selectedDate: $monthAnchor, isPresented: $showingMonthPicker)
                    .presentationDetents([.height(400)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
    
    // MARK: - Month Navigation Header
    private var monthNavigationHeader: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    monthAnchor = Calendar.current.date(byAdding: .month, value: -1, to: monthAnchor) ?? monthAnchor
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ribbon)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Spacer()
            
            Button {
                showingMonthPicker = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 6) {
                    Text(monthTitle(for: monthAnchor))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.colors.ink)
                    
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.colors.ribbon)
                }
                .contentShape(Rectangle())
            }
            
            Spacer()

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    monthAnchor = Calendar.current.date(byAdding: .month, value: 1, to: monthAnchor) ?? monthAnchor
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ribbon)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }
    
    // MARK: - Calendar Grid
    private var calendarGrid: some View {
        let cal = Calendar.current
        let dates = cal.nv_monthGridDates(for: monthAnchor)
        let weekdaySymbols = cal.veryShortWeekdaySymbols
        let todayStart = cal.startOfDay(for: Date())
        let selectedStart = cal.startOfDay(for: selectedDate)
        let anchorStart = cal.startOfDay(for: monthAnchor)
        let nextMonthStart = cal.date(byAdding: .month, value: 1, to: anchorStart) ?? anchorStart
        // Build lookup once — O(n) total instead of O(n × 42 cells)
        let eventsByDay = Dictionary(
            grouping: events.sorted { $0.start < $1.start },
            by: { cal.startOfDay(for: $0.start) }
        )

        return VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, dayName in
                    Text(dayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(dates, id: \.self) { date in
                    let dayStart = cal.startOfDay(for: date)
                    let isToday = dayStart == todayStart
                    let isSelected = dayStart == selectedStart
                    let isCurrentMonth = dayStart >= anchorStart && dayStart < nextMonthStart
                    let dayEvents = eventsByDay[dayStart] ?? []
                    let dayNumber = cal.component(.day, from: date)

                    VStack(spacing: 4) {
                        Text(String(dayNumber))
                            .font(.body.weight(isToday ? .bold : .medium))
                            .foregroundColor(
                                isToday ? .white :
                                isCurrentMonth ? theme.colors.ink : Color.secondary.opacity(0.3)
                            )
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(
                                        isToday ? theme.colors.ribbon :
                                        isSelected ? theme.colors.ribbon.opacity(0.15) :
                                        Color.clear
                                    )
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected && !isToday ? theme.colors.ribbon : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                        
                        HStack(spacing: 3) {
                            if !dayEvents.isEmpty {
                                ForEach(0..<min(dayEvents.count, 3), id: \.self) { index in
                                    Circle()
                                        .fill(color(for: dayEvents[index].effectiveUrgency))
                                        .frame(width: 4, height: 4)
                                }
                                if dayEvents.count > 3 {
                                    Text("+")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(theme.colors.ribbon)
                                }
                            }
                        }
                        .frame(height: 6)
                    }
                    .frame(height: 50)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            selectedDate = date
                            if !dayEvents.isEmpty && sheetOffset > defaultSheetOffset {
                                sheetOffset = defaultSheetOffset
                            }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
        .drawingGroup()
    }
    
    // MARK: - Bottom Sheet
    private var bottomSheet: some View {
        let selectedEvents = events(on: selectedDate)
        let isToday = Calendar.current.isDate(selectedDate, inSameDayAs: Date())
        let isAtDefaultPosition = abs(sheetOffset - defaultSheetOffset) < 50
        let shouldShowCondensed = selectedEvents.count > 2 && isAtDefaultPosition
        
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)
            
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dayTitle(for: selectedDate))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.colors.ink)
                    
                    Text(selectedDate, format: .dateTime.month(.wide).day().year())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                if !selectedEvents.isEmpty {
                    Text("\(selectedEvents.count) event\(selectedEvents.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            
            if selectedEvents.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 52))
                        .foregroundStyle(theme.colors.ribbon.opacity(0.3))
                    
                    VStack(spacing: 6) {
                        Text("No events today")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.colors.ink)
                        
                        Text("Tap + to add an event")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .padding(.horizontal, 24)
            } else if shouldShowCondensed {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.colors.ribbon.opacity(0.5))
                        
                        VStack(spacing: 6) {
                            Text("\(selectedEvents.count) events scheduled")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(theme.colors.ink)
                            
                            Text("Swipe up to see all events")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    VStack(spacing: 12) {
                        ForEach(Array(selectedEvents.prefix(2).enumerated()), id: \.element.id) { index, event in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(color(for: event.effectiveUrgency))
                                    .frame(width: 8, height: 8)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(theme.colors.ink)
                                        .lineLimit(1)
                                    
                                    Text(event.isAllDay
                                        ? "All Day"
                                        : event.isTask
                                            ? "Start  \(calendarTimeFormatter.string(from: event.start))"
                                            : "Start  \(calendarTimeFormatter.string(from: event.start))  ·  End  \(calendarTimeFormatter.string(from: event.end))"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                        }
                        
                        if selectedEvents.count > 2 {
                            Text("+ \(selectedEvents.count - 2) more event\(selectedEvents.count - 2 == 1 ? "" : "s")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(theme.colors.ribbon)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(selectedEvents.enumerated()), id: \.element.id) { index, event in
                            EventTimelineRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == selectedEvents.count - 1,
                                theme: theme
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 120)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(theme.colors.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(theme.colors.cardBorder, lineWidth: 1)
                )
        )
        .shadow(
            color: isDragging ? Color.clear : theme.colors.pillShadow.opacity(0.15),
            radius: isDragging ? 0 : 24,
            x: 0,
            y: -10
        )
        .ignoresSafeArea()
    }

    // MARK: - Helpers
    private func events(on day: Date) -> [OlanaEvent] {
        let key = Calendar.current.startOfDay(for: day)
        return events
            .filter { Calendar.current.startOfDay(for: $0.start) == key }
            .sorted { $0.start < $1.start }
    }

    private static let dayTitleFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        return df
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df
    }()

    private func dayTitle(for date: Date) -> String {
        CalendarView.dayTitleFormatter.string(from: date)
    }

    private func monthTitle(for date: Date) -> String {
        CalendarView.monthTitleFormatter.string(from: date)
    }

    private func color(for urgency: EventUrgency) -> Color {
        switch urgency {
        case .low: return theme.colors.urgencyLow
        case .medium: return theme.colors.urgencyMedium
        case .high: return theme.colors.urgencyHigh
        }
    }
    
    private func showToast(_ message: String) {
        toastTimer?.invalidate()
        
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showingToast = true
        }
        
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showingToast = false
            }
            toastTimer?.invalidate()
            toastTimer = nil
        }
    }
    
    private func stopToastTimer() {
        toastTimer?.invalidate()
        toastTimer = nil
        showingToast = false
    }
}

// MARK: - Event Timeline Row
struct EventTimelineRow: View {
    let event: OlanaEvent
    let isFirst: Bool
    let isLast: Bool
    let theme: OlanaTheme
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var urgencyColor: Color {
        switch event.effectiveUrgency {
        case .low: return theme.colors.urgencyLow
        case .medium: return theme.colors.urgencyMedium
        case .high: return theme.colors.urgencyHigh
        }
    }
    
    // Status derived from completion flag and real time bounds — no fallbacks.
    private var statusColor: Color {
        let now = Date()
        if event.completed              { return theme.colors.success }
        if event.start > now            { return urgencyColor }
        if event.isTask                 { return .orange }          // task is past due
        if event.end > now              { return theme.colors.urgencyMedium } // in progress
        return .gray                                                // event ended
    }

    private var statusText: String {
        let now = Date()
        if event.completed              { return "Completed" }
        if event.start > now            { return "Upcoming" }
        if event.isTask                 { return "Past Due" }
        if event.end > now              { return "In Progress" }
        return "Ended"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Timeline connector
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(height: 12)
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(statusColor.opacity(0.3), lineWidth: 4))
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                // Title
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)

                // Date + time pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if event.isAllDay {
                            timePill(relativeDateLabel(for: event.start))
                            timePill("All Day")
                        } else {
                            timePill(relativeDateLabel(for: event.start))
                            timePill("Start  \(calendarTimeFormatter.string(from: event.start))")
                            if !event.isTask {
                                timePill("End  \(calendarTimeFormatter.string(from: event.end))")
                            }
                        }
                    }
                }

                // Status · urgency · type badges
                HStack(spacing: 6) {
                    badge(statusText, color: statusColor)
                    badge(urgencyLabel(event.effectiveUrgency), color: urgencyColor)
                    badge(
                        event.isTask ? "Task" : "Event",
                        color: event.isTask ? .secondary : theme.colors.ribbon
                    )
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLast ? 0 : 8)
    }

    // MARK: - Helpers

    private func timePill(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    private func relativeDateLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInTomorrow(date)  { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func urgencyLabel(_ urgency: EventUrgency) -> String {
        switch urgency {
        case .low:    return "Later"
        case .medium: return "Soon"
        case .high:   return "Critical"
        }
    }
}

// MARK: - Calendar Helpers
fileprivate extension Calendar {
    func nv_startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }

    func nv_startOfWeek(containing date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? date
    }

    func nv_monthGridDates(for anchor: Date) -> [Date] {
        let startOfMonth = nv_startOfMonth(for: anchor)
        let weekday = component(.weekday, from: startOfMonth)
        let leading = weekday - 1
        let firstShown = date(byAdding: .day, value: -leading, to: startOfMonth) ?? startOfMonth
        return (0..<(6*7)).compactMap { dayOffset in
            date(byAdding: .day, value: dayOffset, to: firstShown)
        }
    }
}

// MARK: - Month/Year Picker View
struct MonthYearPickerView: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool
    @Environment(\.olanaTheme) private var theme
    
    @State private var tempDate: Date
    
    init(selectedDate: Binding<Date>, isPresented: Binding<Bool>) {
        self._selectedDate = selectedDate
        self._isPresented = isPresented
        self._tempDate = State(initialValue: selectedDate.wrappedValue)
    }
    
    private let months = Calendar.current.monthSymbols
    private let currentYear = Calendar.current.component(.year, from: Date())
    private let years = Array((Calendar.current.component(.year, from: Date()) - 10)...(Calendar.current.component(.year, from: Date()) + 10))
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    Picker("Month", selection: Binding(
                        get: { Calendar.current.component(.month, from: tempDate) },
                        set: { newMonth in
                            let components = Calendar.current.dateComponents([.year, .day], from: tempDate)
                            var newComponents = DateComponents()
                            newComponents.year = components.year
                            newComponents.month = newMonth
                            newComponents.day = 1
                            if let newDate = Calendar.current.date(from: newComponents) {
                                tempDate = newDate
                            }
                        }
                    )) {
                        ForEach(1...12, id: \.self) { month in
                            Text(months[month - 1])
                                .tag(month)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    
                    Picker("Year", selection: Binding(
                        get: { Calendar.current.component(.year, from: tempDate) },
                        set: { newYear in
                            let components = Calendar.current.dateComponents([.month, .day], from: tempDate)
                            var newComponents = DateComponents()
                            newComponents.year = newYear
                            newComponents.month = components.month
                            newComponents.day = 1
                            if let newDate = Calendar.current.date(from: newComponents) {
                                tempDate = newDate
                            }
                        }
                    )) {
                        ForEach(years, id: \.self) { year in
                            Text(String(year))
                                .tag(year)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Select Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedDate = Calendar.current.nv_startOfMonth(for: tempDate)
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    CalendarView()
        .environmentObject(EventStore())
        .modelContainer(for: [OlanaEvent.self], inMemory: true)
        .olanaThemeProvider(variant: .system)
}
