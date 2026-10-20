//
//  AddEventView.swift
//  Olana
//
//  Redesigned: bottom sheet (60 % → full), two-step flow.
//  Step 1 — the message, with what was read as chips: 📅 🕐 🕑 📍 (tap to change).
//  Step 2 — read-back chips with Olana's tier (cards on tap), "Is this important?" when unjudged, save.
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
    /// The 🕑 chip as task-or-event override: true after the user sets an end,
    /// false after they remove it. nil: inferred (`AddKind`).
    @State private var endChoice: Bool?
    /// The tier cards, opened from the tier chip on review.
    @State private var showTiers = false
    /// "Is this important?" answered on review (only asked when unjudged).
    @State private var importantAnswer: AssistMode?
    @State private var placeholderIndex = 0

    // ── Pickers ───────────────────────────────────────────────────────
    @State private var showDatePicker = false
    @State private var showTimePicker = false
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

    // ── Sheet height: fits the content, so there's no empty space below it ──
    @State private var barHeight: CGFloat = 60
    @State private var contentHeight: CGFloat = 220
    @State private var footerHeight: CGFloat = 86
    @State private var bottomInset: CGFloat = 0
    /// Starts at the usual step-1 height so the sheet opens at its size
    /// instead of opening at another and then jumping.
    @State private var detent: PresentationDetent = .height(AddEventView.openingHeight)
    @State private var hasFitted = false
    static let openingHeight: CGFloat = 412

    #if DEBUG
    /// Screenshot fixtures (`-homeFixture add…`): a message typed on appear,
    /// and Next pressed once the capture read is in.
    var fixtureText = ""
    var fixtureNext = false
    var fixtureTiers = false
    #endif

    enum AddEventStep { case input, review }

    /// N2: full messages, so people learn they can say more.
    private static let placeholders = [
        "Dentist tomorrow 3pm at Smile Dental, bring insurance card",
        "Interview Thursday 10am on Zoom, review my portfolio first",
        "Gym 6pm at Equinox Flatiron",
        "Flight Friday 7:30am from JFK T4, be there 2 hours early",
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }

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
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        // The sheet is as tall as what's on it, and grows as chips wrap or the
        // tier cards open; Large stays available for long content.
        .presentationDetents([.height(hasFitted ? fittedHeight : Self.openingHeight), .large], selection: $detent)
        .onChange(of: fittedHeight) { _, h in
            guard detent != .large else { return }
            // The first fit lands without animation; later changes (chips
            // wrapping, tier cards opening) animate.
            if hasFitted { withAnimation(.snappy) { detent = .height(h) } }
            else {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { hasFitted = true; detent = .height(h) }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .onAppear { isTextFieldFocused = (currentStep == .input) }
        #if DEBUG
        .task {
            guard !fixtureText.isEmpty else { return }
            eventText = fixtureText
            guard fixtureNext else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            analyzeAndContinue()
            guard fixtureTiers else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showTiers = true
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
                        // With nothing read yet, "📅 When?" is the way to pick a time.
                        if !eventText.isEmpty {
                            CaptureChips(draft: $captureDraft, isTask: !isEventMode, placeOnly: true,
                                         onPlaceChanged: { _ in }) {
                                dateTimeChips(clearable: true)
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

                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // Nothing on the input step changes while the message is being read.
            .disabled(isAnalyzing)
            .opacity(isAnalyzing ? 0.6 : 1)

            // "Next" button
            VStack(spacing: 0) {
                Button(action: analyzeAndContinue) {
                    HStack(spacing: 10) {
                        if isAnalyzing {
                            ProgressView().tint(c.onGold)
                        }
                        Text(isAnalyzing ? "Reading your event…" : "Next")
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        // Setting an end time is the "it's an event" answer.
        .onChange(of: selectedEndDate) { _, end in if end != nil { endChoice = true } }
    }

    // MARK: - NLP Token Chip

    /// 📅 🕐 🕑, each opening its picker, shared by both steps. The 🕑 chip is
    /// also task-or-event: an event shows its end with ×, which makes it a task;
    /// a task shows "End time", which makes it an event. On step 1 the 📅 chip's
    /// × clears the date and both times.
    @ViewBuilder
    private func dateTimeChips(clearable: Bool = false) -> some View {
        if activeDate == nil {
            whenChip("📅", "When?", dimmed: true) { showDatePicker = true }
        } else {
            whenChip("📅", finalDateForSave.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     onTap: { showDatePicker = true },
                     onRemove: clearable ? {
                         withAnimation(.spring(response: 0.25)) {
                             selectedDate = nil
                             extractedDate = nil
                             selectedEndDate = nil
                             extractedEndDate = nil
                             endChoice = nil
                         }
                     } : nil)
            whenChip("🕐", finalDateForSave.formatted(.dateTime.hour().minute())) { showTimePicker = true }
            if isEventMode {
                whenChip("🕑", finalEndDateForSave.formatted(.dateTime.hour().minute()),
                         onTap: { showEndTimePicker = true },
                         onRemove: {
                             withAnimation(.spring(response: 0.25)) {
                                 selectedEndDate = nil
                                 extractedEndDate = nil
                                 endChoice = false
                             }
                         })
            } else {
                whenChip("🕑", "End time", dimmed: true) { showEndTimePicker = true }
            }
        }
    }

    /// A date or time chip, the same capsule as the capture chips.
    private func whenChip(_ icon: String, _ label: String, dimmed: Bool = false,
                          onTap: @escaping () -> Void, onRemove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Button(action: onTap) {
                HStack(spacing: 5) {
                    Text(icon).font(.footnote)
                    Text(label).font(.footnote.weight(.semibold)).foregroundStyle(dimmed ? c.muted : c.text)
                }
                .frame(minHeight: 22)
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(c.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon == "🕑" ? "Remove end time" : "Clear date and time")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onRemove == nil ? 12 : 4)
        .padding(.vertical, 4)
        .background(c.gold.opacity(dimmed ? 0.06 : 0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(c.gold.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Date / Time Picker Sheets

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "Date",
                selection: Binding(
                    get: { activeDate ?? Self.nextHour() },
                    set: { selectedDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .tint(c.gold)
            .padding()
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Done without scrolling still keeps the time shown.
                        if activeDate == nil { selectedDate = Self.nextHour() }
                        showDatePicker = false
                    }
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
                    Button("Done") {
                        if selectedEndDate == nil { selectedEndDate = finalDateForSave.addingTimeInterval(3600) }
                        showEndTimePicker = false
                    }
                        .foregroundStyle(c.goldText)
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    // MARK: - Review Step

    /// One tap to save (PRD v3 §1.6): Olana's tier is a chip, not a step. The
    /// tier cards open only from the chip; "Is this important?" shows only when
    /// the model couldn't judge the title.
    private var reviewStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    summaryCard

                    if mlClassification == nil {
                        importantPrompt
                    } else if showTiers {
                        urgencyGridCards
                        selectedUrgencyDetailCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editedTitle.isEmpty ? "Event" : editedTitle)
                .font(HomeType.serif(size: 24))
                .foregroundStyle(c.text)

            // One row: when, how important, then what Olana understood (PRD v6 §1.7a).
            CaptureChips(draft: $captureDraft, isTask: !isEventMode, onPlaceChanged: resolvePlace) {
                dateTimeChips()
                if mlClassification != nil { tierChip }
            }

            // Why Olana judged it this way, while the judgement is Olana's.
            if userSelectedUrgency == nil, let why = mlClassification?.rationale {
                Text(why)
                    .font(.footnote)
                    .foregroundStyle(c.muted)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// `● Critical ⌄`: Olana's tier. Tap to see the tiers and change it.
    private var tierChip: some View {
        let name = friendlyUrgencyName(for: resolvedUrgency)
        return Button {
            withAnimation(.spring(response: 0.3)) { showTiers.toggle() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(urgencyDotColor(for: resolvedUrgency)).frame(width: 9, height: 9)
                Text(name).font(.footnote.weight(.semibold)).foregroundStyle(c.text)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(c.muted)
                    .rotationEffect(.degrees(showTiers ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(c.gold.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(c.gold.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Importance: \(name)")
        .accessibilityHint("Shows the levels, to change how much help this gets")
    }

    // MARK: - Is this important? (the model couldn't judge)

    /// The same question and answers as the card and sheet (PRD v3 §1.6):
    /// Yes is Always Assist, No is No Execution Alerts. Optional: unanswered,
    /// the event saves unranked and the card asks later.
    private var importantPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this important?").font(.headline).foregroundStyle(c.text)
            Text(AIAssistant.shared.unavailableMessage
                 ?? "Olana couldn't tell from the title. Your answer decides how much help this gets.")
                .font(.footnote)
                .foregroundStyle(c.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                importantAnswerPill("Yes", .always)
                importantAnswerPill("No", .noAlerts)
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

    private func importantAnswerPill(_ label: String, _ mode: AssistMode) -> some View {
        let isSelected = importantAnswer == mode
        return Button {
            withAnimation(.spring(response: 0.25)) { importantAnswer = isSelected ? nil : mode }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? c.onGold : c.text)
                .padding(.horizontal, 22)
                .frame(minHeight: 40)
                .background(Capsule().fill(isSelected ? c.gold : c.card2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    /// The step bar, the step's content and its button, plus the home indicator.
    private var fittedHeight: CGFloat {
        (barHeight + contentHeight + footerHeight + bottomInset).rounded(.up)
    }

    /// The active date shown in chips and used by quick-date/time taps
    private var activeDate: Date? { selectedDate ?? extractedDate }

    /// The active end date shown in the end-time chip
    private var activeEndDate: Date? { selectedEndDate ?? extractedEndDate }

    /// Task or event, with no switch: the user's 🕑 choice, else inferred from
    /// the end time, place, link and wording (`AddKind`).
    private var isEventMode: Bool {
        endChoice ?? AddKind.isEvent(hasEnd: activeEndDate != nil, draft: captureDraft, message: eventText)
    }

    /// The top of the next hour: the picker's starting point when nothing was read.
    private static func nextHour() -> Date {
        let cal = Calendar.current
        let now = Date()
        let top = cal.date(bySettingHour: cal.component(.hour, from: now), minute: 0, second: 0, of: now) ?? now
        return top.addingTimeInterval(3600)
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

    /// How much it matters, not when it is.
    private func urgencySubtitle(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:   return "Can't be\nmissed"
        case .medium: return "Matters"
        case .low:    return "Routine"
        }
    }

    /// What each tier sends, as Settings › Notifications schedules it
    /// (ReminderSchedule: Critical adds the evening before and an hour before).
    private func notificationDescription(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:
            return "A reminder the evening before, an hour before and just before it starts. It can break through Focus if you allow it in Settings."
        case .medium:
            return "A reminder just before it starts, with sound."
        case .low:
            return "A quiet reminder just before it starts."
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

    /// Takes a capture read. Task or event follows from it (`isEventMode`).
    private func applyCapture(_ draft: CaptureDraft) {
        captureDraft = draft
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
            let classification = await UrgencyManager.shared.classify(text: text, date: dateHint, typed: true)
            let draft = await captured

            if selectedDate == nil || (selectedEndDate == nil && extractedEndDate == nil) {
                let (start, end) = await extractDateRangeFromText(text)
                if selectedDate == nil, let s = start { extractedDate = s }
                if selectedEndDate == nil && extractedEndDate == nil, let e = end {
                    extractedEndDate = e
                }
            }
            // Auto-set recurrence if detected and not already chosen by the user.
            let recurrence = extractRecurrenceFromText(text)
            if recurrence != .none && selectedRecurrence == .none {
                selectedRecurrence = recurrence
            }
            await MainActor.run {
                mlClassification = classification
                showTiers        = false
                importantAnswer  = nil
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
            place: captureDraft.place,
            assistMode: mlClassification == nil ? importantAnswer : nil
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
    private func extractDateRangeFromText(_ message: String) async -> (start: Date?, end: Date?) {
        // "tomorrow by 5pm" reads as one moment only without the connector.
        let text = AddKind.dateText(message)
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
