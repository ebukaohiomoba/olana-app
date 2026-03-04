import SwiftUI

struct EditEventRequest {
    var title: String
    var start: Date
    var end: Date
    var urgency: EventUrgency
    var recurrenceRule: RecurrenceRule
}

struct EditEventGlassPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.olanaTheme) private var theme

    let event: OlanaEvent
    var onSave: (EditEventRequest) -> Void

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var urgency: EventUrgency
    @State private var recurrenceRule: RecurrenceRule
    @FocusState private var titleFocused: Bool

    init(event: OlanaEvent, onSave: @escaping (EditEventRequest) -> Void) {
        self.event  = event
        self.onSave = onSave
        _title          = State(initialValue: event.title)
        _start          = State(initialValue: event.start)
        _end            = State(initialValue: event.end)
        _urgency        = State(initialValue: event.urgency)
        _recurrenceRule = State(initialValue: event.recurrenceRule)
    }

    private var accentColor: Color {
        switch urgency {
        case .high:   return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low:    return theme.colors.urgencyLow
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            HStack {
                Text("Edit Event")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(theme.colors.ink)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.colors.slate.opacity(0.5))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            // ── Title ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("TITLE")
                TextField("Event title", text: $title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                    .tint(accentColor)
                    .textInputAutocapitalization(.sentences)
                    .focused($titleFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(accentColor.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(
                                        titleFocused ? accentColor.opacity(0.4) : theme.colors.cardBorder,
                                        lineWidth: 1.5
                                    )
                            )
                    )
                    .animation(.easeInOut(duration: 0.18), value: titleFocused)
            }
            .padding(.horizontal, 24)

            RowDivider()

            // ── Dates — vertical rows, each label-left / picker-right ─
            VStack(spacing: 0) {
                DateRow(label: "STARTS", date: $start)
                Divider().padding(.horizontal, 4)
                DateRow(label: "ENDS",   date: $end)
            }
            .padding(.horizontal, 24)

            RowDivider()

            // ── Urgency ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("URGENCY")
                HStack(spacing: 7) {
                    ForEach([EventUrgency.high, .medium, .low], id: \.self) { u in
                        UrgencyChip(
                            label: u.displayName,
                            color: colorFor(u),
                            isSelected: urgency == u
                        ) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                urgency = u
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            RowDivider()

            // ── Recurrence ───────────────────────────────────────────
            HStack {
                SectionLabel("REPEAT")
                Spacer()
                Menu {
                    ForEach(RecurrenceRule.allCases, id: \.self) { rule in
                        Button {
                            withAnimation { recurrenceRule = rule }
                        } label: {
                            HStack {
                                Text(rule.displayName)
                                if rule == recurrenceRule {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(recurrenceRule.displayName)
                            .font(.subheadline)
                            .foregroundStyle(
                                recurrenceRule == RecurrenceRule.none
                                    ? theme.colors.slate
                                    : theme.colors.ribbon
                            )
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.colors.slate)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.colors.ribbon.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(theme.colors.cardBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // ── Save ─────────────────────────────────────────────────
            Button {
                guard canSave else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onSave(EditEventRequest(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: start,
                    end: end,
                    urgency: urgency,
                    recurrenceRule: recurrenceRule
                ))
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                    Text("Save Changes")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accentColor, accentColor.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                )
                .opacity(canSave ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .animation(.easeInOut(duration: 0.15), value: accentColor)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(theme.colors.paper.ignoresSafeArea())
        .presentationDetents([.fraction(0.75)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { titleFocused = false }
                    .foregroundStyle(accentColor)
            }
        }
    }

    private func colorFor(_ u: EventUrgency) -> Color {
        switch u {
        case .high:   return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low:    return theme.colors.urgencyLow
        }
    }
}

// MARK: - Small reusable pieces

private struct SectionLabel: View {
    @Environment(\.olanaTheme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(theme.colors.slate)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
    }
}

// ── Date row: label on left, compact picker on right ──────────────

private struct DateRow: View {
    @Environment(\.olanaTheme) private var theme
    let label: String
    @Binding var date: Date

    var body: some View {
        HStack {
            SectionLabel(label)
            Spacer()
            DatePicker("", selection: $date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(theme.colors.ribbon)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Urgency Chip

private struct UrgencyChip: View {
    @Environment(\.olanaTheme) private var theme
    let label: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(isSelected ? 1 : 0.35)
                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? color : theme.colors.slate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isSelected ? color.opacity(0.4) : theme.colors.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    Color.gray.opacity(0.3).ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            EditEventGlassPanel(
                event: OlanaEvent(
                    title: "Team standup",
                    start: .now,
                    end: .now.addingTimeInterval(3600),
                    urgency: .medium,
                    recurrenceRule: RecurrenceRule.weekly
                )
            ) { _ in }
        }
        .environment(\.olanaTheme, OlanaTheme.light)
}
