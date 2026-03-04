import SwiftUI

struct AddEventRequest {
    var title: String
    var start: Date
    var end: Date
    var category: String?
    var urgency: Urgency
}

enum Urgency: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

struct AddEventGlassPanel: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var start: Date = Date()
    @State private var end: Date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var category: String = ""
    @State private var urgency: Urgency = .medium

    var onSubmit: (AddEventRequest) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Add Event")
                        .font(.title3.bold())
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Close")
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        DatePicker("Start", selection: $start)
                        DatePicker("End", selection: $end)
                    }

                    TextField("Category (optional)", text: $category)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        ForEach(Urgency.allCases) { u in
                            Button(u.label) { urgency = u }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    Capsule().fill(urgency == u ? tint(for: u).opacity(0.2) : Color(.secondarySystemBackground))
                                )
                                .foregroundStyle(urgency == u ? tint(for: u) : .primary)
                                .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                    Spacer()
                    Button {
                        let request = AddEventRequest(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            start: start,
                            end: end,
                            category: category.isEmpty ? nil : category,
                            urgency: urgency
                        )
                        onSubmit(request)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Event")
                        }
                    }
                    .buttonStyle(GlassProminentButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
            )
            .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .presentationBackground(.clear)
    }

    private func tint(for u: Urgency) -> Color {
        switch u {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }
}

#Preview {
    AddEventGlassPanel { _ in }
        .padding()
}
