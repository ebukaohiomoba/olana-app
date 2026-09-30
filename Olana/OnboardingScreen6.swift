//
//  OnboardingScreen6.swift
//  Olana
//
//  First Task — text input with CoreML urgency suggestion, urgency pills,
//  Olu celebrates on submit, then transitions into the main app.
//

import SwiftUI

struct OnboardingScreen6: View {
    let onComplete: () -> Void

    @EnvironmentObject private var store: EventStore

    @State private var oluState: OluState = .idle
    @State private var taskText: String = ""
    @State private var selectedUrgency: EventUrgency = .medium
    @State private var userOverrode: Bool = false        // true once user taps a pill manually

    @State private var showConfirmation: Bool = false
    @State private var isSubmitted: Bool = false

    @FocusState private var isTextFieldFocused: Bool

    private let urgencyPills: [(label: String, urgency: EventUrgency)] = [
        ("Now",   .high),
        ("Soon",  .medium),
        ("Later", .low),
    ]

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: "F5EDD8")
                .ignoresSafeArea()

            // Olu — small, top right; celebrates on submit
            OnboardingOluView(state: $oluState, size: 58)
                .padding(.top, 56)
                .padding(.trailing, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 108)

                    Text("What's asking for you today?")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: "3B1F0A"))
                        .lineSpacing(4)
                        .padding(.bottom, 10)

                    Text("Add one thing. It doesn't have to be big.")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color(hex: "5C3D1E"))
                        .lineSpacing(6)
                        .padding(.bottom, 24)

                    // Task input
                    TextField("e.g. Reply to that email", text: $taskText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "1A0F00"))
                        .tint(Color(hex: "F0A500"))
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(hex: "E8D9C4"), lineWidth: 1.5)
                        )
                        .focused($isTextFieldFocused)
                        .disabled(isSubmitted)
                        .lineLimit(1...4)
                        .onChange(of: taskText) { _, newValue in
                        }
                        .padding(.bottom, 10)

                    // ML suggestion chip
                    mlSuggestionRow
                        .padding(.bottom, 14)

                    // Urgency pills
                    HStack(spacing: 8) {
                        ForEach(urgencyPills, id: \.label) { option in
                            let isSelected = selectedUrgency == option.urgency
                            Button {
                                userOverrode = true
                                selectedUrgency = option.urgency
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(isSelected ? .white : Color(hex: "5C3D1E"))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Color(hex: "F0A500") : Color(hex: "F5EDD8"))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                isSelected ? Color.clear : Color(hex: "E8D9C4"),
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitted)
                            .animation(.easeInOut(duration: 0.15), value: selectedUrgency)
                        }
                    }
                    .padding(.bottom, 28)

                    // Button sits right here — no Spacer pushing it to the bottom
                    OnboardingPrimaryButton(
                        title: "This is mine to do →",
                        action: submitTask,
                        isDisabled: taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitted
                    )
                    .padding(.bottom, 20)

                    // Confirmation message fades in below the button after submit
                    if showConfirmation {
                        Text("That's your first one. You already know what to do.")
                            .font(.system(size: 15, weight: .regular))
                            .italic()
                            .foregroundStyle(Color(hex: "F0A500"))
                            .lineSpacing(4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Spacer().frame(height: 60)
                }
                .padding(.horizontal, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }

    // MARK: - Suggestion Row
    //
    // Onboarding no longer runs urgency classification. The task it creates starts
    // at `now`, so the combiner's past-event guard rejects it and it can never rank
    // or alert — a second of on-device inference bought a label on a throwaway event.
    // Picking the urgency by hand is also the better teaching moment: it is how the
    // user learns the three levels exist.

    @ViewBuilder
    private var mlSuggestionRow: some View {
        Color.clear.frame(height: 20)
    }

    // MARK: - Submit

    private func submitTask() {
        let title = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSubmitted else { return }

        isTextFieldFocused = false
        isSubmitted = true

        let now = Date()
        let end = now.addingTimeInterval(3600)

        // Persist the task
        // No semantics passed: this event starts at `now`, so the combiner's
        // past-event guard rejects it and backfill's `start > now` filter never
        // sees it. Caching would prevent nothing.
        store.addEvent(title: title, start: now, end: end, urgency: selectedUrgency)


        // Celebrate
        oluState = .celebrate

        withAnimation(.easeIn(duration: 0.4)) {
            showConfirmation = true
        }

        // Exit onboarding after Olu's celebration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            onComplete()
        }
    }

    // MARK: - Helpers



    private func pillLabel(for urgency: EventUrgency) -> String {
        switch urgency {
        case .high:   return "Now"
        case .medium: return "Soon"
        case .low:    return "Later"
        }
    }
}
