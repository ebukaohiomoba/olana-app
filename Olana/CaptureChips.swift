//
//  CaptureChips.swift
//  Olana
//
//  The read-back on the add flow (PRD v6 §1.7a): what Olana understood from the
//  message, as chips in one row after 📅 🕐 🕑 (passed in as `leading`).
//  `📍 Smile Dental` · `🔗 Zoom` · `🎒 Insurance card` · `✓ Review the deck` · `⏱ 15 min early`
//  While typing (`placeOnly`), the row shows just 📍 next to the date and time.
//
//  Tap a chip to correct it in words ("the one on 5th", "online", "also bring my
//  ID"), parsed the same way; × removes it and its words go back in the title.
//  Places with several matches show "Which …?" and get no leave-by until picked.
//

import SwiftUI

struct CaptureChips<Leading: View>: View {
    @Binding var draft: CaptureDraft
    let isTask: Bool
    /// Step 1: only the 📍 chip, no "Where is it?" line.
    var placeOnly = false
    /// Called after a correction changes the place, so the parent can re-resolve.
    var onPlaceChanged: (String) -> Void
    /// Chips that come first in the same row (📅 🕐 🕑).
    @ViewBuilder var leading: () -> Leading

    @Environment(\.homePalette) private var c

    @State private var editing: CaptureChipID?
    @State private var editText = ""
    @State private var whereText = ""
    @State private var choosing = false
    @State private var working = false

    var body: some View {
        let e = draft.effective
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 8) {
                leading()
                if !isTask, let place = draft.placeChip {
                    chip(.place, icon: "📍", label: place.label, detail: place.detail, dimmed: place.found == false)
                }
                if !placeOnly {
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
            }

            if !placeOnly, draft.asksWhere(isTask: isTask) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(c.muted).font(.footnote)
                    TextField("Where is it? (optional)", text: $whereText)
                        .font(.subheadline)
                        .foregroundStyle(c.text)
                        .submitLabel(.done)
                        .onSubmit { Task { await applyWhere() } }
                    if working { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(c.card2)
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

    private func chip(_ id: CaptureChipID, icon: String, label: String,
                      detail: String? = nil, dimmed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Button {
                if id == .place, case .choose? = draft.match, draft.picked == nil { choosing = true }
                else { editText = ""; editing = id }
            } label: {
                HStack(spacing: 5) {
                    Text(icon).font(.footnote)
                    Text(label).font(.footnote.weight(.semibold)).foregroundStyle(dimmed ? c.muted : c.text)
                        .lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(c.muted)
                            .lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel([label, detail].compactMap { $0 }.joined(separator: ", "))
            Button {
                withAnimation(.spring(response: 0.25)) { _ = draft.removed.insert(id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(c.muted)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(c.gold.opacity(dimmed ? 0.06 : 0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(c.gold.opacity(0.3), lineWidth: 1))
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

extension CaptureChips where Leading == EmptyView {
    init(draft: Binding<CaptureDraft>, isTask: Bool, placeOnly: Bool = false, onPlaceChanged: @escaping (String) -> Void) {
        self.init(draft: draft, isTask: isTask, placeOnly: placeOnly, onPlaceChanged: onPlaceChanged) { EmptyView() }
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
