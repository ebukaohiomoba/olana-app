//
//  CaptureChips.swift
//  Olana
//
//  The read-back on the add flow's review step (PRD v6 §1.7a): what Olana
//  understood from the message, as chips in the row under 📅 🕐 🕑.
//  `📍 Smile Dental` · `🔗 Zoom` · `🎒 Insurance card` · `✓ Review the deck` · `⏱ 15 min early`
//
//  Tap a chip to correct it in words ("the one on 5th", "online", "also bring my
//  ID"), parsed the same way; × removes it and its words go back in the title.
//  Places with several matches show "Which …?" and get no leave-by until picked.
//

import SwiftUI

struct CaptureChips: View {
    @Binding var draft: CaptureDraft
    let isTask: Bool
    /// Called after a correction changes the place, so the parent can re-resolve.
    var onPlaceChanged: (String) -> Void

    @State private var editing: CaptureChipID?
    @State private var editText = ""
    @State private var whereText = ""
    @State private var choosing = false
    @State private var working = false

    private let ink = Color(hex: "1A0F00"), muted = Color(hex: "A07850")

    var body: some View {
        let e = draft.effective
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 8) {
                if !isTask, let place = e.placeText {
                    chip(.place, icon: "📍", label: placeLabel(place))
                }
                if let service = e.meetingService {
                    chip(.link, icon: "🔗", label: service.name)
                } else if e.meetingURL != nil {
                    chip(.link, icon: "🔗", label: "Link")
                }
                ForEach(e.bring, id: \.self) { chip(.bring($0), icon: "🎒", label: $0) }
                ForEach(e.steps, id: \.self) { chip(.step($0), icon: "✓", label: $0) }
                if !isTask, let m = e.arriveEarlyMinutes, m > 0 {
                    chip(.early, icon: "⏱", label: "\(m) min early")
                }
            }

            if draft.asksWhere(isTask: isTask) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(muted).font(.system(size: 13))
                    TextField("Where is it? (optional)", text: $whereText)
                        .font(.system(size: 14))
                        .foregroundStyle(ink)
                        .submitLabel(.done)
                        .onSubmit { Task { await applyWhere() } }
                    if working { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "F5EDD8"))
                .clipShape(Capsule())
                .accessibilityHint("Type or say where it is. Optional.")
            }
        }
        .alert(editTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(editPlaceholder, text: $editText)
            Button("Update") { Task { await applyCorrection() } }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .confirmationDialog(whichTitle, isPresented: $choosing, titleVisibility: .visible) {
            if case .choose(let options)? = draft.match {
                ForEach(options, id: \.self) { p in
                    Button([p.name, p.address].compactMap { $0 }.joined(separator: " · ")) { draft.picked = p }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Chips

    private func placeLabel(_ words: String) -> String {
        if let picked = draft.picked { return picked.name }
        if case .choose? = draft.match { return "Which \(words)?" }
        return words
    }

    private func chip(_ id: CaptureChipID, icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Button {
                if id == .place, case .choose? = draft.match, draft.picked == nil { choosing = true }
                else { editText = ""; editing = id }
            } label: {
                HStack(spacing: 5) {
                    Text(icon).font(.system(size: 13))
                    Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.spring(response: 0.25)) { _ = draft.removed.insert(id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(muted)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color(hex: "D4A853").opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(hex: "D4A853").opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var editTitle: String {
        switch editing {
        case .place?: return "Where is it?"
        case .link?: return "How do you join?"
        case .early?: return "How early?"
        default: return "Change this"
        }
    }

    private var editPlaceholder: String {
        switch editing {
        case .place?: return "the one on 5th, online…"
        case .early?: return "20 min early"
        default: return "also bring my ID"
        }
    }

    private var whichTitle: String {
        if case .choose(let o)? = draft.match, let n = o.first?.name { return "Which \(n)?" }
        return "Which one?"
    }

    // MARK: Corrections (N3): parsed the same way as the message

    private func applyCorrection() async {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = editing
        editing = nil
        guard !text.isEmpty else { return }
        await apply(text, to: id)
    }

    private func applyWhere() async {
        let text = whereText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = true
        await apply(text, to: .place)
        working = false
        whereText = ""
    }

    private func apply(_ text: String, to id: CaptureChipID?) async {
        let lower = CaptureCode.squash(text)
        // One-word shortcuts don't need the model.
        if ["online", "virtual", "zoom", "teams", "on zoom", "on teams", "a call", "call"].contains(lower) {
            draft.removed.insert(.place)
            draft.result.attendance = .virtual
            draft.result.likelyNeedsTravel = false
            return
        }
        if id == .early, let m = CaptureCode.minutes(fromArriveEarly: text) {
            draft.result.arriveEarlyMinutes = m
            draft.result.arriveEarlyText = text
            draft.removed.remove(.early)
            return
        }
        let parsed = await CaptureParser.run(message: text, title: text)
        draft.result.items += parsed.items.filter { !draft.result.items.contains($0) }
        if let m = parsed.arriveEarlyMinutes { draft.result.arriveEarlyMinutes = m; draft.removed.remove(.early) }
        if id == .place || parsed.placeText != nil {
            // "the one on 5th" refines the search; anything else is new place words.
            let words: String
            if lower.hasPrefix("the one"), let old = draft.result.placeText {
                words = old + " " + text.replacingOccurrences(of: #"^(?i)the one\s+(on|at|in|near|by)?\s*"#, with: "", options: .regularExpression)
            } else {
                words = parsed.placeText ?? text
            }
            draft.result.placeText = words
            draft.result.placeIsStreetAddress = parsed.placeIsStreetAddress
            draft.result.attendance = .inPerson
            draft.result.likelyNeedsTravel = !PlaceMatching.isPersonal(words) || parsed.likelyNeedsTravel
            draft.removed.remove(.place)
            draft.picked = nil
            draft.match = nil
            onPlaceChanged(words)
        }
    }
}

/// Wraps chips onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: subviews.isEmpty ? 0 : y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
