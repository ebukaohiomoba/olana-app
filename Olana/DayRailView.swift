//
//  DayRailView.swift
//  Olana
//
//  The rest of today on one vertical timeline (spec_m0_m1_v2 §14.1, §14.5).
//  Replaces the day strip and the event list on home.
//
//  Spacing is proportional to time, with a minimum row height so short events
//  stay tappable, and long gaps compressed. Laid out as a stack of rows rather
//  than absolute positions so Dynamic Type can grow a row without overlapping
//  the next one.
//

import SwiftUI

struct DayRailView: View {
    let day: HomeDay
    /// An open day: the rail is drawn dotted, as free time.
    var freeTime = false
    var onSelect: (UUID) -> Void = { _ in }
    var onToggleDone: (UUID) -> Void = { _ in }
    var onDelete: (UUID, Bool) -> Void = { _, _ in }

    @Environment(\.homePalette) private var c
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showDone = false

    /// At accessibility sizes the time leaves its 42 pt column and joins the
    /// row's second line ("3:00 until 4:00"), so nothing truncates.
    private var inlineTimes: Bool { typeSize.isAccessibilitySize }

    /// Points per minute: 44 pt an hour, as in the mockup.
    static let perMinute: CGFloat = 0.74
    static let minRow: CGFloat = 44
    static let maxGap: CGFloat = 180 * perMinute
    /// Column geometry: 42 pt of time labels, the 10 pt bar at 52, text at 72.
    static let barX: CGFloat = 52
    static let textInset: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showDone { doneList }
            if !day.allDay.isEmpty {
                Text("All day · " + day.allDay.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(c.muted)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                nowRow
                ForEach(segments, id: \.id) { seg in
                    switch seg.kind {
                    case .gap(let label):
                        gapRow(label: label, height: seg.height)
                    case .prep(let item):
                        prepRow(urgency: item.urgency, height: seg.height)
                    case .event(let item, let prepAbove):
                        eventRow(item, height: seg.height, prepAbove: prepAbove)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { doneButton; Spacer(); bedLabel }
            VStack(alignment: .leading, spacing: 4) { doneButton; bedLabel }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var doneButton: some View {
        if !day.done.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() }
            } label: {
                Text(day.doneLabel)
                    .foregroundStyle(c.muted)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showDone ? "Hides them" : "Shows them")
        }
    }

    @ViewBuilder
    private var bedLabel: some View {
        if let bed = day.bed {
            Text(HomeFormat.bed(bed)).foregroundStyle(c.muted)
        }
    }

    private var doneList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(day.done) { d in
                HStack(spacing: 10) {
                    Text(HomeFormat.clock(d.time))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                    Text(d.title).font(.subheadline).strikethrough(d.isTask)
                    Spacer()
                    if d.isTask {
                        Button("Undo") { onToggleDone(d.id) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(c.goldText)
                    }
                }
                .foregroundStyle(c.muted)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(d.id) }
            }
        }
        .padding(.top, 10)
    }

    // MARK: Rows

    private var nowRow: some View {
        HStack(spacing: 0) {
            Text("now")
                .font(.caption.weight(.semibold))
                .foregroundStyle(c.text)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 42, alignment: .trailing)
            ZStack {
                Circle().fill(c.bg).frame(width: 18, height: 18)
                Circle().stroke(c.text, lineWidth: 2).frame(width: 16, height: 16)
            }
            .frame(width: 18)
            .padding(.leading, Self.barX + 5 - 9 - 42)
            Spacer()
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func gapRow(label: String?, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.textInset)
            if let label {
                Text(label)
                    .font(.caption.italic())
                    .foregroundStyle(c.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: height)
        .background(alignment: .topLeading) { line }
    }

    private func prepRow(urgency: EventUrgency, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.textInset)
            Text("prep")
                .font(.caption2)
                .foregroundStyle(c.faint)
            Spacer(minLength: 0)
        }
        .frame(height: height)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                line
                HatchFill(color: c.gold)
                    .frame(width: 10)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
                    .padding(.leading, Self.barX)
            }
        }
        .accessibilityHidden(true)
    }

    private func eventRow(_ item: RailItem, height: CGFloat, prepAbove: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(inlineTimes ? "" : item.isOverdueTask ? "earlier" : HomeFormat.clock(item.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(c.muted)
                .frame(width: 42, alignment: .trailing)
            Color.clear.frame(width: Self.textInset - 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(c.text)
                    .lineLimit(2)
                Text(secondLine(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(c.muted)
            }
            .offset(y: -3)
            Spacer(minLength: 0)
            if item.isTask {
                Button { onToggleDone(item.id) } label: {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(c.muted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(item.title) done")
                .offset(y: -12)
            }
        }
        .frame(minHeight: height, alignment: .top)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                line
                UnevenRoundedRectangle(topLeadingRadius: prepAbove ? 0 : 5, bottomLeadingRadius: 5,
                                       bottomTrailingRadius: 5, topTrailingRadius: prepAbove ? 0 : 5)
                    .fill(c.tier(item.urgency))
                    .frame(width: 10)
                    .padding(.leading, Self.barX)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item.id) }
        .contextMenu {
            if item.isTask {
                Button { onToggleDone(item.id) } label: { Label("Mark done", systemImage: "checkmark.circle") }
            }
            Button { onSelect(item.id) } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { onDelete(item.id, item.isRecurring) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(item.id) }
        // The done circle and the context menu aren't reachable inside one
        // element, so VoiceOver gets them as actions.
        .accessibilityActions {
            if item.isTask {
                Button("Mark done") { onToggleDone(item.id) }
            }
            Button("Delete") { onDelete(item.id, item.isRecurring) }
        }
    }

    private func secondLine(_ item: RailItem) -> String {
        if item.isTask { return inlineTimes && !item.isOverdueTask ? "\(HomeFormat.clock(item.start)), to do" : "to do" }
        let until = "until \(HomeFormat.clock(item.end))"
        return inlineTimes ? "\(HomeFormat.clock(item.start)) \(until)" : until
    }

    /// The rail's track, centered on the bar column.
    @ViewBuilder
    private var line: some View {
        if freeTime {
            GeometryReader { g in
                Path { p in
                    p.move(to: CGPoint(x: 1, y: 0))
                    p.addLine(to: CGPoint(x: 1, y: g.size.height))
                }
                .stroke(c.faint, style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
            }
            .frame(width: 2)
            .padding(.leading, Self.barX + 4)
        } else {
            Rectangle().fill(c.track).frame(width: 2).padding(.leading, Self.barX + 4)
        }
    }

    private func accessibilityLabel(_ item: RailItem) -> String {
        if item.isTask { return "\(item.title), task, not done" }
        return "\(item.title), \(HomeFormat.tierName(item.urgency)), \(HomeFormat.clock(item.start)) to \(HomeFormat.clock(item.end))"
    }

    // MARK: Segments

    private struct Segment {
        enum Kind { case gap(String?), prep(RailItem), event(RailItem, prepAbove: Bool) }
        let id: String
        let kind: Kind
        let height: CGFloat
    }

    private static func height(_ seconds: TimeInterval, min: CGFloat = 0) -> CGFloat {
        Swift.max(min, Swift.min(maxGap, CGFloat(seconds / 60) * perMinute))
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var cursor = day.now
        for item in day.rail {
            let top = item.prepFrom ?? item.start
            if top > cursor {
                let label = RailGap.label(from: cursor, to: top, windDown: false)
                out.append(Segment(id: "gap-\(item.id)", kind: .gap(label),
                                   height: Self.height(top.timeIntervalSince(cursor), min: label == nil ? 6 : 24)))
            }
            if let p = item.prepFrom {
                out.append(Segment(id: "prep-\(item.id)", kind: .prep(item),
                                   height: Self.height(item.start.timeIntervalSince(max(p, cursor)), min: 16)))
            }
            let visibleStart = max(item.start, day.now)
            out.append(Segment(id: "ev-\(item.id)", kind: .event(item, prepAbove: item.prepFrom != nil),
                               height: Self.height(item.end.timeIntervalSince(visibleStart), min: Self.minRow)))
            cursor = max(cursor, item.isTask ? item.start : item.end)
        }
        if let bed = day.bed, bed > cursor {
            let label = RailGap.label(from: cursor, to: bed, windDown: true)
            out.append(Segment(id: "bed", kind: .gap(label),
                               height: Self.height(bed.timeIntervalSince(cursor), min: 28)))
        }
        return out
    }
}
