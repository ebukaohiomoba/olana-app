//
//  AddEventView.swift
//  Olana
//
//  Redesigned: bottom sheet (60 % → full), two-step flow.
//  Step 1 — NLP text input, detected date/time chips, quick-date + time pickers.
//  Step 2 — urgency cards with Olu suggestion, notification preview, save.
//

import SwiftUI
import Speech
import AVFoundation

// MARK: - Main View

struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @Environment(\.olanaTheme) private var theme

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

    // ── Olu ───────────────────────────────────────────────────────────
    @State private var oluState: OluState = .idle

    // ── Pickers ───────────────────────────────────────────────────────
    @State private var showDatePicker = false
    @State private var showTimePicker = false

    // ── Speech ────────────────────────────────────────────────────────
    @State private var isRecording = false
    @State private var speechRecognizer: SFSpeechRecognizer?
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine: AVAudioEngine?
    @State private var speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var speechInitialized = false

    @FocusState private var isTextFieldFocused: Bool

    enum AddEventStep { case input, review }

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
            Color(hex: "F5EDD8").ignoresSafeArea()

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
                .foregroundStyle(theme.colors.ribbon)
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
                        Text(isAnalyzing ? "…" : "Next")
                            .font(.subheadline.weight(.medium))
                        if !isAnalyzing {
                            Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundStyle(eventText.isEmpty
                        ? theme.colors.ribbon.opacity(0.35)
                        : theme.colors.ribbon)
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
            .fill(filled ? theme.colors.ribbon : theme.colors.ribbon.opacity(0.25))
            .frame(width: 56, height: 4)
    }

    // MARK: - Input Step

    private var inputStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {

                    // Headline row — Olu Lottie + title
                    HStack(spacing: 12) {
                        OluView(state: $oluState, size: 46)
                        Text("What's the plan?")
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(Color(hex: "1A0F00"))
                    }

                    // Text input card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            TextField("Dentist appt tomorrow at 3pm…", text: $eventText, axis: .vertical)
                                .font(.system(size: 17))
                                .foregroundStyle(Color(hex: "1A0F00"))
                                .tint(theme.colors.ribbon)
                                .lineLimit(2...4)
                                .focused($isTextFieldFocused)
                                .onChange(of: eventText) { _, v in handleTextChange(v) }

                            // Mic button
                            Button(action: toggleRecording) {
                                ZStack {
                                    Circle()
                                        .fill(isRecording
                                            ? Color.red.opacity(0.12)
                                            : theme.colors.ribbon.opacity(0.10))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: isRecording ? "waveform" : "mic")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(isRecording ? .red : theme.colors.ribbon)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // Detected date/time chips — tappable to open pickers
                        if let date = activeDate {
                            HStack(spacing: 8) {
                                // Date chip
                                Button { showDatePicker = true } label: {
                                    tokenChip(
                                        label: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                        icon: "📅"
                                    )
                                }
                                .buttonStyle(.plain)

                                // Time chip
                                Button { showTimePicker = true } label: {
                                    tokenChip(
                                        label: date.formatted(.dateTime.hour().minute()),
                                        icon: "🕐"
                                    )
                                }
                                .buttonStyle(.plain)

                                // Clear
                                Button {
                                    withAnimation(.spring(response: 0.25)) {
                                        selectedDate = nil
                                        extractedDate = nil
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color(hex: "A07850"))
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(hex: "E8D9C4"), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)

                    // Quick date
                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK DATE")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Color(hex: "A07850"))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickDates, id: \.label) { item in
                                    quickDateCard(item: item)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }

                    // Quick time
                    HStack(alignment: .center, spacing: 12) {
                        Text("TIME")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Color(hex: "A07850"))
                            .frame(width: 40, alignment: .leading)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickTimes, id: \.hour) { item in
                                    quickTimeChip(item: item)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }

            // "Next — set urgency" button
            VStack(spacing: 0) {
                Button(action: analyzeAndContinue) {
                    HStack(spacing: 10) {
                        OluView(state: $oluState, size: 26)
                        Text(isAnalyzing ? "Analyzing…" : "Next — set urgency")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(eventText.isEmpty
                                  ? theme.colors.ribbon.opacity(0.5)
                                  : theme.colors.ribbon)
                    )
                }
                .disabled(eventText.isEmpty || isAnalyzing)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(Color(hex: "F5EDD8"))
        }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .sheet(isPresented: $showTimePicker) { timePickerSheet }
    }

    // MARK: - NLP Token Chip

    private func tokenChip(label: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Text(icon).font(.system(size: 13))
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "1A0F00"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.colors.ribbon.opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.colors.ribbon.opacity(0.3), lineWidth: 1))
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(isSelected ? .white : Color(hex: "A07850"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(dayNum)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isSelected ? .white : Color(hex: "1A0F00"))

                Text(weekday)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : Color(hex: "A07850"))
            }
            .frame(width: 72, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? theme.colors.ribbon : Color.white)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.12 : 0.04),
                    radius: isSelected ? 6 : 4, x: 0, y: 2)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Color(hex: "1A0F00"))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? theme.colors.ribbon : Color.white)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
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
            .tint(theme.colors.ribbon)
            .padding()
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDatePicker = false }
                        .foregroundStyle(theme.colors.ribbon)
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
            .tint(theme.colors.ribbon)
            .labelsHidden()
            .padding()
            .navigationTitle("Pick a time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTimePicker = false }
                        .foregroundStyle(theme.colors.ribbon)
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

                    // Olu suggestion — full-width card, no character to the left
                    oluSuggestionCard

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
                    HStack(spacing: 10) {
                        OluView(state: $oluState, size: 26)
                        Text("Done — add it")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.colors.ribbon)
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(Color(hex: "F5EDD8"))
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editedTitle.isEmpty ? "Event" : editedTitle)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color(hex: "1A0F00"))

            HStack(spacing: 8) {
                Label(
                    finalDateForSave.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                    systemImage: "calendar"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: "3B1F0A"))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "F5EDD8"))
                .clipShape(Capsule())

                Label(
                    finalDateForSave.formatted(.dateTime.hour().minute()),
                    systemImage: "clock"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: "3B1F0A"))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "F5EDD8"))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "E8D9C4"), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    // MARK: - Olu Suggestion Card (full width — no character beside it)

    private var oluSuggestionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OLU SUGGESTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color(hex: "A07850"))

            Text(friendlyUrgencyName(for: mlUrgency))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(hex: "1A0F00"))

            if let rationale = mlClassification?.rationale {
                Text(rationale)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(Color(hex: "A07850"))
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "E8D9C4"), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
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
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSelected ? .white : Color(hex: "1A0F00"))
                Text(urgencySubtitle(for: urgency))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : Color(hex: "A07850"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? theme.colors.ribbon : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color(hex: "E8D9C4"), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.10 : 0.04),
                    radius: isSelected ? 6 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A0F00"))
                    Spacer()
                    Text("SELECTED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(theme.colors.ribbon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.colors.ribbon.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(notificationDescription(for: resolvedUrgency))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "5C3D1E"))
                    .lineSpacing(3)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "E8D9C4"), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    // MARK: - Helpers

    /// The active date shown in chips and used by quick-date/time taps
    private var activeDate: Date? { selectedDate ?? extractedDate }

    /// Currently selected hour (for highlighting quick-time chips)
    private var activeHour: Int? {
        activeDate.map { Calendar.current.component(.hour, from: $0) }
    }

    private var mlUrgency: EventUrgency {
        urgencyFromBucket(mlClassification?.bucket ?? .medium)
    }

    private var resolvedUrgency: EventUrgency { userSelectedUrgency ?? mlUrgency }

    private var finalDateForSave: Date { selectedDate ?? extractedDate ?? Date() }

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

    /// Dot colors match the screenshot (red / yellow / blue)
    private func urgencyDotColor(for urgency: EventUrgency) -> Color {
        switch urgency {
        case .high:   return Color(red: 0.80, green: 0.22, blue: 0.22)
        case .medium: return Color(red: 0.94, green: 0.78, blue: 0.17)
        case .low:    return Color(red: 0.32, green: 0.54, blue: 0.84)
        }
    }

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
            return "Olu will remind you repeatedly throughout the day. You'll get alerts at key intervals so nothing slips."
        case .medium:
            return "Olu will remind you once in the morning and once in the afternoon. No notifications at night. You can change this anytime from the task."
        case .low:
            return "Olu will send a gentle reminder a day before. No recurring alerts — it'll show up when it matters."
        }
    }

    // MARK: - NLP Analysis

    private func handleTextChange(_ newValue: String) {
        analysisTask?.cancel()
        guard newValue.count > 3 else { return }
        analysisTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if let date = await extractDateFromText(newValue) {
                await MainActor.run { extractedDate = date }
            }
        }
    }

    private func analyzeAndContinue() {
        guard !eventText.isEmpty else { return }
        isAnalyzing = true

        Task {
            // ML classification off main thread
            let text = eventText
            let dateHint = selectedDate ?? extractedDate
            let classification = await Task.detached(priority: .userInitiated) {
                UrgencyManager.shared.classify(text: text, date: dateHint)
            }.value

            if selectedDate == nil {
                extractedDate = await extractDateFromText(text)
            }
            let title = extractTitle(from: text)

            await MainActor.run {
                mlClassification = classification
                editedTitle      = title
                isAnalyzing      = false
                withAnimation(.spring(response: 0.35)) { currentStep = .review }
            }
        }
    }

    private func saveEvent() {
        let finalUrgency = resolvedUrgency
        let title    = editedTitle.isEmpty ? extractTitle(from: eventText) : editedTitle
        let date     = finalDateForSave
        let endDate  = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date

        store.addEvent(
            title: title, start: date, end: endDate,
            urgency: finalUrgency, recurrenceRule: selectedRecurrence
        )

        if let classification = mlClassification {
            urgencyManager.logFeedback(
                text: eventText, date: date,
                mlPrediction: classification.bucket,
                userChoice:   urgencyBucketFrom(finalUrgency)
            )
        }

        oluState = .celebrate
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
    }

    // MARK: - Date Extraction

    private func extractDateFromText(_ text: String) async -> Date? {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let now      = Date()
                let calendar = Calendar.current
                let lc       = text.lowercased()

                // 1. NSDataDetector — handles "tomorrow at 3pm", "next Monday at noon", etc.
                if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
                    let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    if let date = matches.first?.date {
                        continuation.resume(returning: date); return
                    }
                }

                // 2. Relative time — "in 30 minutes", "in 2 hours", "2 hours from now"
                if let date = relativeOffsetDate(from: lc, now: now, calendar: calendar) {
                    continuation.resume(returning: date); return
                }

                // 3. Keyword fallback
                let result: Date?
                if lc.contains("tonight") {
                    result = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
                } else if lc.contains("tomorrow") {
                    let t = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                    result = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: t)
                } else if lc.contains("today") {
                    result = now
                } else if lc.contains("next week") {
                    result = calendar.date(byAdding: .weekOfYear, value: 1, to: now)
                } else {
                    result = nil
                }
                continuation.resume(returning: result)
            }
        }
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
