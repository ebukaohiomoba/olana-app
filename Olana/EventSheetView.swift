//
//  EventSheetView.swift
//  Olana
//
//  One sheet per event (PRD v3 §1.7 Job 4): the state machine's top action,
//  then the helpers that have data, in the order Apple Intelligence picks.
//  EventSheetBuilder decides everything shown; this view draws it and saves
//  what the user does (steps, bring, assist mode, I'm leaving / I'm here).
//
//  Every model-written item can be edited or removed; on a recurring event the
//  edit asks "This event / All events in this series" (PRD v3 §3.11).
//

import SwiftUI

struct EventSheetView: View {
    let event: OlanaEvent
    var onEdit: () -> Void = {}
    /// DEBUG fixtures pass a fixed answer instead of running the model.
    var fixtureOutcome: AssistOutcome? = nil

    @EnvironmentObject private var store: EventStore
    @Environment(\.homePalette) private var c
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .title) private var l1Size: CGFloat = 28

    @State private var outcome: AssistOutcome?
    @State private var progress = EventProgress()
    @State private var overrides = OverrideResolver.resolve(event: nil, series: nil)
    @State private var now = Date()
    @State private var editingList: ListKind?
    @State private var draftItems: [String] = []
    @State private var newItem = ""
    @State private var scopeAsk: (() -> Void)?
    @State private var pendingScopeChange: ((OverrideScope) -> Void)?

    enum ListKind: Identifiable { case steps, bring; var id: Self { self } }

    private var facts: EventFacts {
        NotesCleaner.clean(notes: event.isFromExternalCalendar ? event.notes : nil, location: event.location,
                           conferenceURL: event.meetingURL)
    }

    private var content: SheetContent { EventSheetBuilder.build(sheetInput) }

    private var sheetInput: SheetInput {
        let prep = event.cachedSemantics?.effectivePrep.hours ?? 0
        return SheetInput(
            title: event.title, start: event.start, end: event.end, isTask: event.isTask,
            isRecurring: event.recurrenceRule != .none || event.seriesID != nil,
            location: event.location, facts: facts, meetingURL: event.meetingURL, assist: outcome,
            overrides: overrides, userSteps: event.prepItems, userBring: event.bringItems,
            arriveEarlyMinutes: event.arriveEarlyMinutes,
            attendance: event.attendanceRaw.flatMap(AssistAttendance.init(rawValue:)),
            place: event.resolvedPlace,
            actBy: prep > 0 ? event.start.addingTimeInterval(-prep * 3600) : nil,
            eta: nil,
            checkedSteps: Set(progress.checkedSteps),
            state: PhaseState(finished: event.completed || progress.finished, onTheWay: progress.onTheWay,
                              prepDone: progress.prepDone),
            // Refused, failed too often, or a placeholder title: not merely not judged yet.
            unranked: event.isUnrankable,
            hasPlus: PlusAccess.hasPlus, now: now)
    }

    var body: some View {
        let s = content
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(s)
                    if s.asksImportant { importantPrompt }
                    ForEach(Array(s.helpers.enumerated()), id: \.offset) { _, h in
                        helperView(h, gold: s.gold == h.kind && !s.goldIsTop)
                    }
                    if s.helpers.isEmpty && outcome == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 8)
                    }
                    assistModeRow(s)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(c.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Edit") { onEdit() } }
            }
        }
        .task { await load() }
        .task {
            // The top action follows the clock while the sheet is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                now = Date()
            }
        }
        .sheet(item: $editingList) { kind in listEditor(kind) }
        .confirmationDialog("Save for", isPresented: Binding(get: { pendingScopeChange != nil },
                                                               set: { if !$0 { pendingScopeChange = nil } })) {
            Button("This event") { pendingScopeChange?(.event); pendingScopeChange = nil }
            Button("All events in this series") { pendingScopeChange?(.series); pendingScopeChange = nil }
        }
    }

    // MARK: Load

    private func load() async {
        overrides = store.effectiveOverrides(for: event)
        progress = EventProgressStore.shared.get(event.overrideEventKey)
        let input = AssistInput(title: event.title, calendar: event.calendarName, location: event.location,
                                facts: facts, savedSteps: overrides.steps ?? [], overrideVersions: overrides.versions)
        if let fixtureOutcome { outcome = fixtureOutcome; return }
        outcome = await EventAssistService.shared.assist(input)
    }

    // MARK: Header and top action

    private func header(_ s: SheetContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(.headline)
                .foregroundStyle(c.text)
            Text(EventSheetBuilder.dayName(event.start, now: now, calendar: .current).capitalizedFirst
                 + " · " + EventSheetBuilder.clock(event.start, .current) + "–" + EventSheetBuilder.clock(event.end, .current))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(c.muted)

            Text(s.top.line)
                .font(HomeType.serif(size: l1Size))
                .foregroundStyle(s.top.locked ? c.text : c.goldText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)

            if s.top.locked {
                Label("Leave-by and prep timing are part of Plus", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(c.muted)
            }
            if let b = s.top.button { topButton(b, gold: s.goldIsTop) }

            HStack(spacing: 8) {
                if let why = s.why { Text(why).font(.caption).foregroundStyle(c.faint) }
                if let tag = s.tag {
                    Text(tag).font(.caption.weight(.semibold)).foregroundStyle(c.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(c.card2))
                }
            }
        }
    }

    @ViewBuilder
    private func topButton(_ b: SheetTopAction.Button, gold: Bool) -> some View {
        switch b {
        case .join(let url):
            primary("Join", icon: "video.fill", gold: gold) { join(url) }
        case .directions:
            HStack(spacing: 10) {
                primary("Directions", icon: "arrow.triangle.turn.up.right.diamond.fill", gold: gold) { directions() }
                secondary("I'm leaving") { leave() }
            }
        case .imLeaving:
            secondary("I'm leaving") { leave() }
        case .imHere:
            secondary("I'm here") { arrive() }
        case .prepDone:
            secondary("Prep done") { prepDone() }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func helperView(_ h: SheetHelper, gold: Bool) -> some View {
        switch h {
        case .join(let url, let service):
            section("Join") {
                primary("Join \(service)", icon: "video.fill", gold: gold) { join(url) }
            }
        case .materials(let items):
            section("Materials") {
                ForEach(items, id: \.self) { m in
                    Button { openURL(m.url) } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(c.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.label).foregroundStyle(c.text)
                                Text(m.host).font(.caption).foregroundStyle(c.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(c.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.label), \(m.host)")
                }
            }
        case .bring(let items, _, let locked):
            section("Bring", locked: locked, edit: locked ? nil : { startEditing(.bring, items) }) {
                if locked { lockedLine("Your bring list is part of Plus") }
                else {
                    FlowRow(spacing: 8) {
                        ForEach(items, id: \.self) { item in
                            Text("🎒 \(item)").font(.subheadline).foregroundStyle(c.text)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(c.card2))
                        }
                    }
                }
            }
        case .place(let p):
            section("Place") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).foregroundStyle(c.text)
                    if let a = p.address { Text(a).font(.footnote).foregroundStyle(c.muted) }
                    HStack(spacing: 16) {
                        if let w = p.website { link("Website", icon: "safari") { openURL(w) } }
                        if let phone = p.phone, let tel = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                            link("Call", icon: "phone") { openURL(tel) }
                        }
                        if !p.textOnly, p.appleMaps != nil { link("Maps", icon: "map") { directions() } }
                    }
                    .padding(.top, 2)
                }
            }
        case .prep(let p):
            section("Prep", locked: p.locked, edit: p.locked ? nil : { startEditing(.steps, p.steps.map(\.text)) }) {
                if let timing = p.timing { Text(timing).font(.subheadline.weight(.medium)).foregroundStyle(c.goldText) }
                if let e = p.effort { Text(e).font(.footnote).foregroundStyle(c.muted) }
                if p.locked {
                    lockedLine("Prep steps and timing are part of Plus")
                } else if p.steps.isEmpty {
                    Button { startEditing(.steps, []) } label: {
                        Label("Add a prep step", systemImage: "plus").font(.subheadline)
                    }
                } else {
                    ForEach(p.steps, id: \.self) { step in
                        Button { toggle(step.text, first: p.steps.first?.text) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: step.checked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(step.checked ? c.goldText : c.muted)
                                Text(step.text).strikethrough(step.checked).foregroundStyle(step.checked ? c.muted : c.text)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(step.checked ? [.isSelected] : [])
                    }
                }
            }
        case .leave(let l):
            section("Leave", locked: l.locked) {
                if let line = l.line { Text(line).font(.subheadline.weight(.medium)).foregroundStyle(c.text) }
                if l.locked { lockedLine("Leave-by timing is part of Plus") }
                HStack(spacing: 16) {
                    if l.appleMaps != nil { link("Apple Maps", icon: "map") { directions(google: false) } }
                    if l.googleMaps != nil, canOpenGoogleMaps { link("Google Maps", icon: "map.fill") { directions(google: true) } }
                }
            }
        }
    }

    private var importantPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this important?").font(.headline).foregroundStyle(c.text)
            Text("Olana couldn't tell from the title. Your answer decides how much help this gets.")
                .font(.footnote).foregroundStyle(c.muted)
            HStack(spacing: 10) {
                secondary("Yes") { setMode(.always) }
                secondary("No") { setMode(.noAlerts) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(c.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.line, lineWidth: 1))
    }

    private func assistModeRow(_ s: SheetContent) -> some View {
        Menu {
            ForEach(AssistMode.allCases, id: \.self) { m in
                Button { setMode(m) } label: {
                    if m == s.assistMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        } label: {
            HStack {
                Text("Help for this event").foregroundStyle(c.muted)
                Spacer()
                Text(s.assistMode.title).foregroundStyle(c.text)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(c.faint)
            }
            .font(.subheadline)
        }
        .padding(.top, 8)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, locked: Bool = false, edit: (() -> Void)? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(c.muted)
                if locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(c.faint) }
                Spacer()
                if let edit { Button("Edit", action: edit).font(.caption.weight(.semibold)) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(c.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.line, lineWidth: 1))
    }

    private func primary(_ title: String, icon: String, gold: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(gold ? c.onGold : c.text)
                .background(RoundedRectangle(cornerRadius: 12).fill(gold ? c.gold : c.card2))
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(c.text)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).stroke(c.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline) }
            .buttonStyle(.plain)
            .foregroundStyle(c.goldText)
    }

    private func lockedLine(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(c.muted)
    }

    private var canOpenGoogleMaps: Bool {
        UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
    }

    // MARK: Editing (series or event)

    private func startEditing(_ kind: ListKind, _ items: [String]) {
        draftItems = items
        newItem = ""
        editingList = kind
    }

    private func listEditor(_ kind: ListKind) -> some View {
        NavigationStack {
            List {
                ForEach(draftItems, id: \.self) { Text($0) }
                    .onDelete { draftItems.remove(atOffsets: $0) }
                    .onMove { draftItems.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField(kind == .steps ? "Add a step" : "Add something to bring", text: $newItem)
                        .submitLabel(.done)
                        .onSubmit(addDraft)
                    Button("Add", action: addDraft).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(kind == .steps ? "Prep steps" : "Bring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingList = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let items = draftItems
                        editingList = nil
                        save { v in if kind == .steps { v.steps = items } else { v.bring = items } }
                    }
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }

    private func addDraft() {
        let t = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !draftItems.contains(t) else { return }
        draftItems.append(t)
        newItem = ""
    }

    /// One-off events save to the event; recurring ones ask (PRD v3 §3.11).
    private func save(_ change: @escaping (inout OverrideValues) -> Void) {
        let apply: (OverrideScope) -> Void = { scope in
            store.updateOverride(for: event, scope: scope, change)
            overrides = store.effectiveOverrides(for: event)
            Task { await load() }
        }
        if event.overrideSeriesKey != nil { pendingScopeChange = apply } else { apply(.event) }
    }

    private func setMode(_ m: AssistMode) { save { $0.assistMode = m } }

    // MARK: Actions

    private func update(_ change: (inout EventProgress) -> Void) {
        EventProgressStore.shared.update(event.overrideEventKey, eventStart: event.start, change)
        progress = EventProgressStore.shared.get(event.overrideEventKey)
    }

    private func toggle(_ step: String, first: String?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        update { $0.toggle(step: step, firstStep: first, now: Date()) }
    }

    private func prepDone() { update { $0.prepDone = true } }

    private func join(_ url: URL) {
        update { $0.joinedAt = Date() }
        openURL(url)
        // Tapping Join removes the rest of the floor (PRD v6 §1.4 principle 7).
        Task { await NotificationEngine.shared.cancelNotifications(for: event.id) }
    }

    private func leave() {
        update { p in p.leftAt = Date() }
        // Leaving cancels the pending leave alert and its snoozes, and floor
        // reminders before the start (PRD v6 §3.6, scenario 19).
        Task { await NotificationEngine.shared.cancelNotifications(for: event.id) }
    }

    private func arrive() { update { $0.arrivedAt = Date() } }

    private func directions(google: Bool = false) {
        let (apple, gmaps) = EventSheetBuilder.mapsLinks(sheetInput)
        if google, let gmaps { openURL(gmaps) } else if let apple { openURL(apple) }
        // Tapping Directions also starts On the way (PRD v6 §3.6).
        if content.helpers.contains(where: { $0.kind == .leave }) && progress.leftAt == nil { leave() }
    }
}
