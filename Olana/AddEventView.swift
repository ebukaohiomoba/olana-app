//
//  AddEventView.swift
//  Olana
//
//  Redesigned: bottom sheet (60 % → full), two-step flow.
//  Step 1 — NLP text input, detected date/time/place chips, quick-date + time pickers.
//  Step 2 — urgency cards with Olana's suggestion, notification preview, save.
//

import SwiftUI
import Speech
import AVFoundation

// MARK: - Main View

struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @Environment(\.homePalette) private var c

    @ObservedObject private var urgencyManager = UrgencyManager.shared

    // ── Step ──────────────────────────────────────────────────────────
    @State private var currentStep: AddEventStep = .input

    // ── Input data ────────────────────────────────────────────────────
    @State private var eventText: String = ""
    /// Date extracted by NLP (cleared when user overrides with selectedDate)
    @State private var extractedDate: Date? = nil
    /// Date chosen via quick-date cards, quick-time chips, or full pickers
    @State private var selectedDate: Date? = nil

    // ── ML results ────────────────────────────────────────────────────
    @State private var mlClassification: UrgencyClassification?
    @State private var userSelectedUrgency: EventUrgency? = nil
    @State private var isAnalyzing: Bool = false
    @State private var editedTitle: String = ""
    @State private var selectedRecurrence: RecurrenceRule = .none
    @State private var analysisTask: Task<Void, Never>?
    /// What the message said besides the time (PRD v6 §1.7a): read-back chips.
    @State private var captureDraft = CaptureDraft()
    /// The title before chip words are taken out; chips come and go against it.
    @State private var captureBaseTitle = ""
    /// The capture parse while typing, so 📍 shows next to 📅 🕐 before Next.
    @State private var captureTask: Task<Void, Never>?
    /// Set when the user taps Task or Event; a found place then won't switch it.
    @State private var userChoseMode = false
    @State private var placeholderIndex = 0

    // ── Pickers ───────────────────────────────────────────────────────
    @State private var showDatePicker = false
    @State private var showTimePicker = false
    @State private var isEventMode: Bool = false
    @State private var selectedEndDate: Date? = nil
    @State private var extractedEndDate: Date? = nil
    @State private var showEndTimePicker = false

    // ── Speech ────────────────────────────────────────────────────────
    @State private var isRecording = false
    @State private var speechRecognizer: SFSpeechRecognizer?
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine: AVAudioEngine?
    @State private var speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var speechInitialized = false

    @FocusState private var isTextFieldFocused: Bool

    #if DEBUG
    /// Screenshot fixtures (`-homeFixture add…`): a message typed on appear,
    /// and Next pressed once the capture read is in.
    var fixtureText = ""
    var fixtureNext = false
    #endif

    enum AddEventStep { case input, review }

    /// N2: full messages, so people learn they can say more.
    private static let placeholders = [
        "Dentist tomorrow 3pm at Smile Dental, bring insurance card",
        "Interview Thursday 10am on Zoom, review my portfolio first",
        "Gym 6pm at Equinox Flatiron",
        "Flight Friday 7:30am from JFK T4, be there 2 hours early",
    ]

    // ── Quick-date: today + next 6 days ──────────────────────────────
    private var quickDates: [(label: String, date: Date)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            let label: String
            if offset == 0      { label = "TODAY" }
            else if offset == 1 { label = "TOMORROW" }
            else                { label = d.formatted(.dateTime.weekday(.abbreviated)).uppercased() }
            return (label, d)
        }
    }

    private let quickTimes: [(label: String, hour: Int)] = [
        ("9 AM", 9), ("12 PM", 12), ("3 PM", 15), ("5 PM", 17), ("8 PM", 20)
    ]

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            c.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                stepBar
                    .padding(.top, 16)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                switch currentStep {
                case .input:
                    inputStep
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)
                        ))
                case .review:
                    reviewStep
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
        }
        .onAppear { isTextFieldFocused = (currentStep == .input) }
        #if DEBUG
        .task {
            guard !fixtureText.isEmpty else { return }
            eventText = fixtureText
            guard fixtureNext else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            analyzeAndContinue()
        }
        #endif
        .task {
            // Rotate the example while the box is empty.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if eventText.isEmpty {
                    withAnimation(.easeInOut(duration: 0.3)) { placeholderIndex = (placeholderIndex + 1) % Self.placeholders.count }
                }
            }
        }
        .onChange(of: captureDraft) { _, draft in
            // A chip removed or corrected: rebuild the title from the chips still on.
            guard currentStep == .review, !captureBaseTitle.isEmpty else { return }
            editedTitle = draft.title(captureBaseTitle, isTask: !isEventMode)
        }
        // Date and time chips open these on both steps.
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .sheet(isPresented: $showTimePicker) { timePickerSheet }
        .sheet(isPresented: $showEndTimePicker) { endTimePickerSheet }
    }

    /// Step 6 of §3.4a, after the review step is showing: MapKit near the origin.
    private func resolvePlace(_ words: String) {
        guard isEventMode else { return }
        Task {
            let match = await PlaceResolver.shared.resolve(words)
            if captureDraft.result.placeText == words { captureDraft.match = match }
        }
    }

    // MARK: - Step Bar

    private var stepBar: some View {
        HStack(spacing: 0) {
            // Left action: Cancel (step 1) or Back (step 2)
            Button {
                if currentStep == .review {
                    withAnimation(.spring(response: 0.35)) { currentStep = .input }
                } else {
                    dismiss()
                }
            } label: {
                HStack(spacing: 4) {
                    if currentStep == .review {
                        Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                    }
                    Text(currentStep == .review ? "Back" : "Cancel")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(c.goldText)
            }

            Spacer()

            // Progress segments
            HStack(spacing: 6) {
                stepSegment(filled: true)
                stepSegment(filled: currentStep == .review)
            }

            Spacer()

            // Right action: Next (step 1) or invisible placeholder (step 2)
            if currentStep == .input {
                Button(action: analyzeAndContinue) {
                    HStack(spacing: 4) {
                        if isAnalyzing {
                            ProgressView().controlSize(.small).tint(c.goldText)
                        } else {
                            Text("Next")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundStyle(eventText.isEmpty
                        ? c.goldText.opacity(0.35)
                        : c.goldText)
                }
                .disabled(eventText.isEmpty || isAnalyzing)
            } else {
                Text("Next")
                    .font(.subheadline.weight(.medium))
                    .opacity(0)
            }
        }
    }

    private func stepSegment(filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(filled ? c.gold : c.gold.opacity(0.25))
            .frame(width: 56, height: 4)
    }

    // MARK: - Input Step

    private var inputStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {

                    Text("What's the plan?")
                        .font(HomeType.serif(size: 30))
                        .foregroundStyle(c.text)

                    // Task / Event toggle
                    taskEventToggle

                    // Text input card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            TextField(Self.placeholders[placeholderIndex], text: $eventText, axis: .vertical)
                                .font(.body)
                                .foregroundStyle(c.text)
                                .tint(c.gold)
                                .lineLimit(2...4)
                                .focused($isTextFieldFocused)
                                .onChange(of: eventText) { _, v in handleTextChange(v) }

                            // Mic button
                            Button(action: toggleRecording) {
                                ZStack {
                                    Circle()
                                        .fill(isRecording
                                            ? Color.red.opacity(0.12)
                                            : c.gold.opacity(0.10))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: isRecording ? "waveform" : "mic")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(isRecording ? .red : c.goldText)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // What Olana read so far: 📅 🕐 🕑 from code, 📍 from the
                        // capture parse. Tap to change, × to remove.
                        if activeDate != nil || (isEventMode && captureDraft.placeChip != nil) {
                            CaptureChips(draft: $captureDraft, isTask: !isEventMode, placeOnly: true,
                                         onPlaceChanged: { _ in }) {
                                if activeDate != nil {
                                    dateTimeChips(includeEnd: activeEndDate != nil, clearable: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(c.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(c.line, lineWidth: 1)
                    )
                    .shadow(color: c.cardShadow, radius: 8, x: 0, y: 3)

                    // Quick date
                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK DATE")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(c.muted)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickDates, id: \.label) { item in
                                    quickDateCard(item: item)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }

                    // Time row — task mode unchanged / event mode split into START + END
                    if !isEventMode {
                        // ── Task mode: TIME row, pixel-perfect original ──────────────
                        HStack(alignment: .center, spacing: 12) {
                            Text("TIME")
                                .font(.caption.weight(.semibold))
                                .tracking(1.2)
                                .foregroundStyle(c.muted)
                                .frame(width: 40, alignment: .leading)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickTimes, id: \.hour) { item in
                                        quickTimeChip(item: item)
                                    }
                                }
                            }
                        }
                    } else {
                        // ── Event mode: START chips + END single-pill ────────────────
                        VStack(alignment: .leading, spacing: 10) {

                            // START — same quick chips, no frame constraint on label
                            HStack(alignment: .center, spacing: 12) {
                                Text("START")
                                    .font(.caption.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(c.muted)
                                    .fixedSize()

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(quickTimes, id: \.hour) { item in
                                            quickTimeChip(item: item)
                                        }
                                    }
                                }
                            }

                            // END — same chips as START row
                            HStack(alignment: .center, spacing: 12) {
                                Text("END")
                                    .font(.caption.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(c.muted)
                                    .fixedSize()

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(quickTimes, id: \.hour) { item in
                                            quickEndTimeChip(item: item)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }
            // Nothing on the input step changes while the message is being read.
            .disabled(isAnalyzing)
            .opacity(isAnalyzing ? 0.6 : 1)

            // "Next — set urgency" button
            VStack(spacing: 0) {
                Button(action: analyzeAndContinue) {
                    HStack(spacing: 10) {
                        if isAnalyzing {
                            ProgressView().tint(c.onGold)
                        }
                        Text(isAnalyzing ? "Reading your event…" : "Next — set urgency")
                            .font(.headline)
                            .foregroundStyle(c.onGold)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.2), value: isAnalyzing)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(eventText.isEmpty ? c.gold.opacity(0.5) : c.gold))
                }
                .disabled(eventText.isEmpty || isAnalyzing)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(c.bg)
        }
        .onChange(of: isEventMode) { _, newValue in
            // Only pre-fill end time when we already know the start.
            // Using Date() as a fallback produces a stale "now + 1hr" that
            // persists and overrides later NLP-detected times.
            guard newValue,
                  selectedEndDate == nil,
                  extractedEndDate == nil,
                  let knownStart = activeDate else { return }
            selectedEndDate = knownStart.addingTimeInterval(3600)
        }
    }

    // MARK: - NLP Token Chip

    /// 📅 🕐 🕑, each opening its picker. Shared by both steps. On step 1 the
    /// 📅 chip's × clears the date and both times.
    @ViewBuilder
    private func dateTimeChips(includeEnd: Bool, clearable: Bool = false) -> some View {
        let dateLabel = finalDateForSave.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if clearable {
            HStack(spacing: 5) {
                Button { showDatePicker = true } label: {
                    HStack(spacing: 5) {
                        Text("📅").font(.footnote)
                        Text(dateLabel).font(.footnote.weight(.semibold)).foregroundStyle(c.text)
                    }
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        selectedDate = nil
                        extractedDate = nil
                        selectedEndDate = nil
                        extractedEndDate = nil
                    }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(c.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear date and time")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(c.gold.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(c.gold.opacity(0.3), lineWidth: 1))
        } else {
            Button { showDatePicker = true } label: { tokenChip(label: dateLabel, icon: "📅") }
                .buttonStyle(.plain)
        }
        Button { showTimePicker = true } label: {
            tokenChip(label: finalDateForSave.formatted(.dateTime.hour().minute()), icon: "🕐")
        }
        .buttonStyle(.plain)
        if includeEnd {
            Button { showEndTimePicker = true } label: {
                tokenChip(label: finalEndDateForSave.formatted(.dateTime.hour().minute()), icon: "🕑")
            }
            .buttonStyle(.plain)
        }
    }

    private func tokenChip(label: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Text(icon).font(.footnote)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(c.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(c.gold.opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(c.gold.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Quick Date Card

    private func quickDateCard(item: (label: String, date: Date)) -> some View {
        let cal = Calendar.current
        let isSelected = activeDate.map { cal.isDate($0, inSameDayAs: item.date) } ?? false
        let dayNum = cal.component(.day, from: item.date)
        let weekday = item.date.formatted(.dateTime.weekday(.abbreviated))

        return Button {
            let hour = activeHour ?? 9
            let newDate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: item.date) ?? item.date
            withAnimation(.spring(response: 0.25)) { selectedDate = newDate }
        } label: {
            VStack(spacing: 4) {
                Text(item.label)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(isSelected ? c.onGold : c.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(dayNum)")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? c.onGold : c.text)

                Text(weekday)
                    .font(.caption)
                    .foregroundStyle(isSelected ? c.onGold.opacity(0.8) : c.muted)
            }
            .frame(width: 72, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? c.gold : c.card)
            )
            .shadow(color: c.cardShadow, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Time Chip

    private func quickTimeChip(item: (label: String, hour: Int)) -> some View {
        let isSelected = activeHour == item.hour

        return Button {
            let base = activeDate ?? Date()
            let newDate = Calendar.current.date(bySettingHour: item.hour, minute: 0, second: 0, of: base) ?? base
            withAnimation(.spring(response: 0.25)) { selectedDate = newDate }
        } label: {
            Text(item.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? c.onGold : c.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? c.gold : c.card)
                )
                .shadow(color: c.cardShadow, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - End Time Chip

    private func quickEndTimeChip(item: (label: String, hour: Int)) -> some View {
        let currentHour = activeEndDate.map { Calendar.current.component(.hour, from: $0) }
        let isSelected  = currentHour == item.hour

        return Button {
            let base    = activeDate ?? Date()
            let newDate = Calendar.current.date(bySettingHour: item.hour, minute: 0, second: 0, of: base) ?? base
            withAnimation(.spring(response: 0.25)) { selectedEndDate = newDate }
        } label: {
            Text(item.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? c.onGold : c.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(isSelected ? c.gold : c.card))
                .shadow(color: c.cardShadow, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task / Event Toggle

    private var taskEventToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(label: "Task", icon: "checkmark.circle", isSelected: !isEventMode) {
                userChoseMode = true
                withAnimation(.spring(response: 0.25)) { isEventMode = false }
            }
            toggleSegment(label: "Event", icon: "calendar", isSelected: isEventMode) {
                userChoseMode = true
                withAnimation(.spring(response: 0.25)) { isEventMode = true }
            }
        }
        .padding(3)
        .background(c.card2)
        .clipShape(Capsule())
    }

    private func toggleSegment(label: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.medium))
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? c.text : c.muted)
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
            .background(
                Capsule()
                    .fill(isSelected ? c.card : Color.clear)
                    .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 4, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Date / Time Picker Sheets

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "Date",
                selection: Binding(
                    get: { activeDate ?? Date() },
                    set: { selectedDate = $0 }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(c.gold)
            .padding()
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDatePicker = false }
                        .foregroundStyle(c.goldText)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var timePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "Time",
                selection: Binding(
                    get: { activeDate ?? Date() },
                    set: { selectedDate = $0 }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .tint(c.gold)
            .labelsHidden()
            .padding()
            .navigationTitle("Pick a time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTimePicker = false }
                        .foregroundStyle(c.goldText)
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    private var endTimePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "End Time",
                selection: Binding(
                    get: { selectedEndDate ?? (activeDate ?? Date()).addingTimeInterval(3600) },
                    set: { selectedEndDate = $0 }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .tint(c.gold)
            .labelsHidden()
            .padding()
            .navigationTitle("Pick end time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showEndTimePicker = false }
                        .foregroundStyle(c.goldText)
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    // MARK: - Review Step

    private var reviewStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {

                    // Event summary card
                    summaryCard

                    // Olana's suggestion — full-width card
                    suggestionCard

                    // 3 urgency option cards
                    urgencyGridCards

                    // Selected urgency notification preview
                    selectedUrgencyDetailCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }

            // "Done — add it" button
            VStack(spacing: 0) {
                Button(action: saveEvent) {
                    Text("Done — add it")
                        .font(.headline)
                        .foregroundStyle(c.onGold)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(c.gold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(c.bg)
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editedTitle.isEmpty ? "Event" : editedTitle)
                .font(HomeType.serif(size: 24))
                .foregroundStyle(c.text)

            // One row: when, then what Olana understood besides the time (PRD v6 §1.7a).
            CaptureChips(draft: $captureDraft, isTask: !isEventMode, onPlaceChanged: resolvePlace) {
                dateTimeChips(includeEnd: isEventMode)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(c.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(c.line, lineWidth: 1)
        )
        .shadow(color: c.cardShadow, radius: 8, x: 0, y: 3)
    }

    // MARK: - Suggestion Card

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OLANA SUGGESTS")
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(c.muted)

            if mlClassification == nil {
                // No judgement to show. Say so rather than presenting the default
                // selection below as if Olana had chosen it.
                Text("Pick one below")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(c.text)

                Text(AIAssistant.shared.unavailableMessage
                     ?? "Olana couldn't tell how urgent this is from the title.")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(c.muted)
                    .lineSpacing(3)
            } else {
                Text(friendlyUrgencyName(for: mlUrgency))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(c.text)
            }

            if let rationale = mlClassification?.rationale {
                Text(rationale)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(c.muted)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(c.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(c.line, lineWidth: 1)
        )
        .shadow(color: c.cardShadow, radius: 8, x: 0, y: 3)
    }

    // MARK: - 3 Urgency Cards (grid row)

    private var urgencyGridCards: some View {
        HStack(spacing: 10) {
            ForEach([EventUrgency.high, .medium, .low], id: \.self) { urgency in
                urgencyCard(urgency)
            }
        }
    }

    private func urgencyCard(_ urgency: EventUrgency) -> some View {
        let isSelected = resolvedUrgency == urgency
        return Button {
            withAnimation(.spring(response: 0.25)) { userSelectedUrgency = urgency }
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(urgencyDotColor(for: urgency))
                    .frame(width: 20, height: 20)
                Text(friendlyUrgencyName(for: urgency))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(c.text)
                Text(urgencySubtitle(for: urgency))
                    .font(.caption)
                    .foregroundStyle(c.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? c.card2 : c.card)
            )
            // Selected is a gold outline, not a fill, so the tier dot keeps its color.
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? c.gold : c.line, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: c.cardShadow, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Selected Urgency Detail Card

    private var selectedUrgencyDetailCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(urgencyDotColor(for: resolvedUrgency))
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(friendlyUrgencyName(for: resolvedUrgency))
                        .font(.headline)
                        .foregroundStyle(c.text)
                    Spacer()
                    Text("SELECTED")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.0)
                        .foregroundStyle(c.goldText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(c.gold.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(notificationDescription(for: resolvedUrgency))
                    .font(.subheadline)
                    .foregroundStyle(c.muted)
                    .lineSpacing(3)
            }
        }
        .padding(16)
        .background(c.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(c.line, lineWidth: 1)
        )
        .shadow(color: c.cardShadow, radius: 8, x: 0, y: 3)
    }

    // MARK: - Helpers

    /// The active date shown in chips and used by quick-date/time taps
    private var activeDate: Date? { selectedDate ?? extractedDate }

    /// The active end date shown in the end-time chip
    private var activeEndDate: Date? { selectedEndDate ?? extractedEndDate }

    /// Currently selected hour (for highlighting quick-time chips)
    private var activeHour: Int? {
        activeDate.map { Calendar.current.component(.hour, from: $0) }
    }

    private var mlUrgency: EventUrgency {
        urgencyFromBucket(mlClassification?.bucket ?? .medium)
    }

    private var resolvedUrgency: EventUrgency { userSelectedUrgency ?? mlUrgency }

    private var finalDateForSave: Date { selectedDate ?? extractedDate ?? Date() }

    private var finalEndDateForSave: Date {
        guard isEventMode else { return finalDateForSave }
        return selectedEndDate ?? extractedEndDate ?? finalDateForSave.addingTimeInterval(3600)
    }

    private func urgencyFromBucket(_ bucket: UrgencyBucket) -> EventUrgency {
        switch bucket {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }

    private func urgencyBucketFrom(_ urgency: EventUrgency) -> UrgencyBucket {
        switch urgency {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }

    /// The home tier colors, so "Critical" here matches the card's dot.
    private func urgencyDotColor(for urgency: EventUrgency) -> Color { c.tier(urgency) }

    private func friendlyUrgencyName(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:   return "Critical"
        case .medium: return "Soon"
        case .low:    return "Later"
        }
    }

    private func urgencySubtitle(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:   return "Must act\ntoday"
        case .medium: return "This week"
        case .low:    return "No rush yet"
        }
    }

    private func notificationDescription(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:
            return "Olana will remind you repeatedly throughout the day. You'll get alerts at key intervals so nothing slips."
        case .medium:
            return "Olana will remind you once in the morning and once in the afternoon. No notifications at night. You can change this anytime from the task."
        case .low:
            return "Olana will send a gentle reminder a day before. No recurring alerts — it'll show up when it matters."
        }
    }

    // MARK: - NLP Analysis

    private func handleTextChange(_ newValue: String) {
        scheduleCapture(newValue)
        analysisTask?.cancel()
        guard newValue.count > 3 else { return }
        analysisTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let (start, end) = await extractDateRangeFromText(newValue)
            let recurrence   = extractRecurrenceFromText(newValue)
            await MainActor.run {
                if let s = start { extractedDate = s }
                if let e = end {
                    extractedEndDate = e
                    isEventMode = true   // NLP found a range → switch to Event mode
                }
                if recurrence != .none { selectedRecurrence = recurrence }
            }
        }
    }

    /// The capture parse once typing pauses (on-device, so no cost). A newer
    /// message cancels an older run; Next reuses the result for the same text.
    private func scheduleCapture(_ text: String) {
        captureTask?.cancel()
        guard text.count > 3 else {
            captureDraft = CaptureDraft()
            return
        }
        captureTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            let result = await CaptureParser.run(message: text, title: extractTitle(from: text))
            await MainActor.run {
                guard !Task.isCancelled, text == eventText, currentStep == .input else { return }
                withAnimation(.spring(response: 0.25)) { applyCapture(captureDraft.reparsed(result, message: text)) }
            }
        }
    }

    /// Takes a capture read, switching to Event when it found a place or link,
    /// the way an end time does, unless the user picked Task themselves.
    private func applyCapture(_ draft: CaptureDraft) {
        captureDraft = draft
        if draft.impliesEvent && !userChoseMode { isEventMode = true }
    }

    /// The capture for `text`: the live read when it's for the same text, so
    /// chip changes made while typing carry over.
    private func capture(for text: String, title: String) async -> CaptureDraft {
        let current = await MainActor.run { captureDraft }
        if current.message == text { return current }
        let result = await CaptureParser.run(message: text, title: title)
        return current.reparsed(result, message: text)
    }

    private func analyzeAndContinue() {
        guard !eventText.isEmpty else { return }
        isAnalyzing = true

        Task {
            // ML classification off main thread
            let text = eventText
            let dateHint = selectedDate ?? extractedDate
            // Capture parse runs alongside urgency, not inside it (§3.4a).
            let baseTitle = extractTitle(from: text)
            captureTask?.cancel()
            async let captured = capture(for: text, title: baseTitle)
            let classification = await UrgencyManager.shared.classify(text: text, date: dateHint)
            let draft = await captured

            if selectedDate == nil || (selectedEndDate == nil && extractedEndDate == nil) {
                let (start, end) = await extractDateRangeFromText(text)
                if selectedDate == nil, let s = start { extractedDate = s }
                if selectedEndDate == nil && extractedEndDate == nil, let e = end {
                    extractedEndDate = e
                    isEventMode = true
                }
            }
            // Auto-set recurrence if detected and not already chosen by the user.
            let recurrence = extractRecurrenceFromText(text)
            if recurrence != .none && selectedRecurrence == .none {
                selectedRecurrence = recurrence
            }
            await MainActor.run {
                mlClassification = classification
                captureBaseTitle = baseTitle
                applyCapture(draft)
                editedTitle      = draft.title(baseTitle, isTask: !isEventMode)
                if let place = draft.effective.placeText, draft.match == nil, draft.picked == nil { resolvePlace(place) }
                isAnalyzing      = false
                withAnimation(.spring(response: 0.35)) { currentStep = .review }
            }
        }
    }

    private func saveEvent() {
        let finalUrgency = resolvedUrgency
        let title    = editedTitle.isEmpty ? extractTitle(from: eventText) : editedTitle
        let date     = finalDateForSave
        let endDate  = finalEndDateForSave

        store.addEvent(
            title: title, start: date, end: endDate,
            urgency: finalUrgency, recurrenceRule: selectedRecurrence,
            isTask: !isEventMode,
            // Carry the judgement made on the review screen rather than discarding
            // it and paying for the same extraction again during backfill.
            semantics: mlClassification?.semantics,
            userPickedUrgency: userSelectedUrgency != nil,
            capture: captureDraft.effective, message: eventText,
            place: captureDraft.place
        )

        if let classification = mlClassification {
            urgencyManager.logDisagreement(
                title: title, suggested: classification.bucket,
                chosen: finalUrgency, semantics: classification.semantics
            )
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    // MARK: - Date / Range Extraction

    /// Hybrid extraction: NSDataDetector for start time (and range when unambiguous),
    /// regex fallback for end time when NSDataDetector reads "3 to 5" as a date range.
    /// Falls back to relative-offset patterns for "in 30 minutes" / "2 hours from now".
    private func extractDateRangeFromText(_ text: String) async -> (start: Date?, end: Date?) {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let now      = Date()
                let calendar = Calendar.current
                let lc       = text.lowercased()

                var start: Date? = nil
                var end:   Date? = nil

                let contextSuffix = timeOfDayContext(from: lc)

                // ── 1. NSDataDetector for start (+ range when plausible) ──────────
                if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
                    let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    if let match = matches.first, let rawStart = match.date {
                        let hour   = calendar.component(.hour, from: rawStart)
                        let minute = calendar.component(.minute, from: rawStart)
                        var adjusted = rawStart

                        // Date-only result (midnight, no explicit time) → default 9 AM
                        if !hasExplicitTime(lc) && hour == 0 && minute == 0 {
                            adjusted = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: rawStart) ?? rawStart
                        }
                        // Context word overrides ambiguous AM/PM on the start hour (1–11)
                        else if !hasExplicitAMPM(lc), let ctx = contextSuffix, hour >= 1 && hour <= 11 {
                            if ctx == "pm" && hour < 12 {
                                adjusted = calendar.date(byAdding: .hour, value: 12, to: rawStart) ?? rawStart
                            } else if ctx == "am" && hour >= 12 {
                                adjusted = calendar.date(byAdding: .hour, value: -12, to: rawStart) ?? rawStart
                            }
                        }
                        // No context word, ambiguous hour 1–7 → assume PM
                        else if !hasExplicitAMPM(lc) && contextSuffix == nil && hour >= 1 && hour <= 7 {
                            adjusted = calendar.date(byAdding: .hour, value: 12, to: rawStart) ?? rawStart
                        }

                        start = adjusted

                        // Cap at 12 hours: longer durations mean NSDataDetector
                        // misread "3 to 5" as a date range, not a time range.
                        if match.duration > 0 && match.duration <= 43200 {
                            end = adjusted.addingTimeInterval(match.duration)
                        }
                    }
                }

                // ── 2. Regex fallback for end ("X to Y" / "X - Y") ───────────────
                // Runs when NSDataDetector gave no range or an implausible duration.
                if end == nil {
                    let base = start ?? now
                    let pattern = #"\d{1,2}(?::\d{2})?\s*(?:am|pm)?\s*(?:to|-)\s*(\d{1,2}(?::\d{2})?(?:\s*(?:am|pm))?)\b"#
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: lc, range: NSRange(lc.startIndex..., in: lc)),
                       let endRange = Range(match.range(at: 1), in: lc) {

                        var endToken = String(lc[endRange]).trimmingCharacters(in: .whitespaces)
                        let tokenHasAMPM = endToken.range(of: #"\b(am|pm)\b"#, options: .regularExpression) != nil

                        if !tokenHasAMPM {
                            if let ctx = contextSuffix {
                                // Priority 1: context word ("afternoon" / "evening" / "morning")
                                endToken += ctx
                            } else {
                                // Priority 2: infer from start time, then business-hours heuristic
                                let startHour  = calendar.component(.hour, from: base)
                                let startIsPM  = startHour >= 12
                                let normalized = startHour % 12 == 0 ? 12 : startHour % 12
                                if let hourStr = endToken.components(separatedBy: ":").first,
                                   let endHour = Int(hourStr.trimmingCharacters(in: .whitespaces)) {
                                    endToken += inferEndSuffix(endHour: endHour, startHour: normalized, startIsPM: startIsPM)
                                }
                            }
                        }

                        let probe = "meeting at \(endToken)"
                        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
                           let m = detector.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)),
                           let parsed = m.date {
                            let comps = calendar.dateComponents([.hour, .minute], from: parsed)
                            end = calendar.date(bySettingHour: comps.hour ?? 0,
                                                minute: comps.minute ?? 0,
                                                second: 0, of: base)
                        }
                    }
                }

                // ── 3. Relative offset fallback for start ─────────────────────────
                if start == nil {
                    start = relativeOffsetDate(from: lc, now: now, calendar: calendar)
                }

                continuation.resume(returning: (start, end))
            }
        }
    }

    // MARK: - Recurrence Extraction

    /// Detects recurrence keywords and returns the matching rule.
    /// Priority: weekdays > daily > weekly > monthly.
    private func extractRecurrenceFromText(_ text: String) -> RecurrenceRule {
        let lc = text.lowercased()
        if lc.range(of: #"\b(every\s+weekday|weekdays|mon(day)?\s+(through|to|-)\s+fri(day)?)\b"#, options: .regularExpression) != nil {
            return .weekdays
        }
        if lc.range(of: #"\b(every\s+day|daily)\b"#, options: .regularExpression) != nil {
            return .daily
        }
        if lc.range(of: #"\b(every\s+week|weekly|every\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun))\b"#, options: .regularExpression) != nil {
            return .weekly
        }
        if lc.range(of: #"\b(every\s+month|monthly)\b"#, options: .regularExpression) != nil {
            return .monthly
        }
        return .none
    }

    // MARK: - Title Extraction

    private func extractTitle(from text: String) -> String {
        var result = text

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let r = Range(match.range, in: result) { result.removeSubrange(r) }
            }
        }

        let temporalPatterns = [
            "\\b(every|each)\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|day|weekday|week|month)\\b",
            "\\b(next|this|last)\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|week|month|year)\\b",
            "\\b(tomorrow|today|tonight|yesterday)\\b",
            "\\b(every|each)\\b",
            "\\bin\\s+\\d+\\s*(minute|minutes|min|mins|hour|hours|hr|hrs|day|days|week|weeks)\\b",
            "\\bin\\s+(a|an)\\s+(minute|hour|day|week)\\b",
            "\\bin\\s+half(\\s+an?)?\\s+hour\\b",
            "\\b\\d+\\s*(minute|minutes|min|mins|hour|hours|hr|hrs)\\s+from\\s+now\\b",
        ]
        for pattern in temporalPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        let trailingPrep = "\\s+(at|on|by|for|in|every|each|from|to|until|till)\\s*$"
        if let regex = try? NSRegularExpression(pattern: trailingPrep, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        result = result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty { result = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = result.first else { return result }
        return first.uppercased() + result.dropFirst()
    }

    // MARK: - Speech Recognition

    private func initializeSpeechIfNeeded() {
        guard !speechInitialized else { return }
        speechRecognizer   = SFSpeechRecognizer()
        audioEngine        = AVAudioEngine()
        speechInitialized  = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { self.speechAuthorizationStatus = status }
        }
    }

    private func toggleRecording() {
        if !speechInitialized { initializeSpeechIfNeeded() }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard speechAuthorizationStatus == .authorized else { return }
        guard let audioEngine, !audioEngine.isRunning else { return }
        isTextFieldFocused = false
        recognitionTask?.cancel(); recognitionTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let req = recognitionRequest else { return }
            req.shouldReportPartialResults = true
            recognitionTask = speechRecognizer?.recognitionTask(with: req) { result, error in
                DispatchQueue.main.async {
                    if let result { self.eventText = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stopRecording() }
                }
            }
            let fmt = audioEngine.inputNode.outputFormat(forBus: 0)
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                self.recognitionRequest?.append(buf)
            }
            audioEngine.prepare(); try audioEngine.start()
            isRecording = true
        } catch { stopRecording() }
    }

    private func stopRecording() {
        guard let audioEngine, audioEngine.isRunning else { isRecording = false; return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio(); recognitionRequest = nil
        recognitionTask?.cancel();      recognitionTask   = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - NLP helpers (file-scope for Task.detached)

/// Returns true if the text contains an explicit clock time (digits + am/pm, or HH:MM).
private func hasExplicitTime(_ lc: String) -> Bool {
    lc.range(of: #"\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|\b\d{1,2}:\d{2}\b|\b(?:noon|midnight)\b"#,
             options: .regularExpression) != nil
}

/// Returns true if the text contains an explicit am/pm marker.
private func hasExplicitAMPM(_ lc: String) -> Bool {
    lc.range(of: #"\b(am|pm)\b"#, options: .regularExpression) != nil
}

/// Returns "am" or "pm" based on time-of-day words in the text, or nil if none found.
/// Priority: afternoon / evening / night → "pm";  morning → "am"
private func timeOfDayContext(from lc: String) -> String? {
    if lc.range(of: #"\b(afternoon|evening|tonight|at night)\b"#, options: .regularExpression) != nil { return "pm" }
    if lc.range(of: #"\b(morning)\b"#, options: .regularExpression) != nil { return "am" }
    return nil
}

/// Last-resort AM/PM inference when no context word and no explicit AM/PM on the token.
/// - end == 12 or end < 8  → "pm"
/// - end > startHour       → same period as start
/// - end ≤ startHour       → "pm" (e.g. "9 to 5" → 5 PM)
private func inferEndSuffix(endHour: Int, startHour: Int, startIsPM: Bool) -> String {
    if endHour == 12 { return "pm" }
    if endHour < 8   { return "pm" }
    if endHour > startHour { return startIsPM ? "pm" : "am" }
    return "pm"
}

// MARK: - Relative time helpers (file-scope for Task.detached)

private func relativeOffsetDate(from lowercased: String, now: Date, calendar: Calendar) -> Date? {
    let numericPattern = #"\bin\s+(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs|day|days|week|weeks)\b"#
    if let regex = try? NSRegularExpression(pattern: numericPattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
       let qRange = Range(match.range(at: 1), in: lowercased),
       let uRange = Range(match.range(at: 2), in: lowercased),
       let qty    = Double(lowercased[qRange]) {
        return applyRelativeOffset(quantity: qty, unit: String(lowercased[uRange]), to: now, calendar: calendar)
    }
    let articlePattern = #"\bin\s+(a|an)\s+(hour|minute|day|week)\b"#
    if let regex = try? NSRegularExpression(pattern: articlePattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
       let uRange = Range(match.range(at: 2), in: lowercased) {
        return applyRelativeOffset(quantity: 1, unit: String(lowercased[uRange]), to: now, calendar: calendar)
    }
    if lowercased.range(of: #"\bin\s+half(\s+an?)?\s+hour\b"#, options: .regularExpression) != nil {
        return now.addingTimeInterval(30 * 60)
    }
    let fromNowPattern = #"(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)\s+from\s+now\b"#
    if let regex = try? NSRegularExpression(pattern: fromNowPattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
       let qRange = Range(match.range(at: 1), in: lowercased),
       let uRange = Range(match.range(at: 2), in: lowercased),
       let qty    = Double(lowercased[qRange]) {
        return applyRelativeOffset(quantity: qty, unit: String(lowercased[uRange]), to: now, calendar: calendar)
    }
    return nil
}

private func applyRelativeOffset(quantity: Double, unit: String, to now: Date, calendar: Calendar) -> Date? {
    switch unit {
    case "minute","minutes","min","mins": return now.addingTimeInterval(quantity * 60)
    case "hour","hours","hr","hrs":       return now.addingTimeInterval(quantity * 3600)
    case "day","days":   return calendar.date(byAdding: .day,        value: Int(quantity), to: now)
    case "week","weeks": return calendar.date(byAdding: .weekOfYear, value: Int(quantity), to: now)
    default:             return nil
    }
}

#Preview {
    AddEventView()
        .environmentObject(EventStore())
}
