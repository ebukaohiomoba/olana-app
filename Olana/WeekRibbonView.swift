//
//  WeekRibbonView.swift
//  Olana
//
//  The week above the day (olana_design/week_ribbon.html): Sun–Sat chips with
//  a dot per event that matters, in tier color. Today is the raised chip; a
//  picked day is gold, and today then keeps a gold ring. Tapping a day shows
//  its rail; tapping today goes back.
//

import SwiftUI

struct WeekRibbonView: View {
    let days: [RibbonDay]
    /// The day the rail shows (start of day).
    let selected: Date
    var onPick: (Date) -> Void = { _ in }

    @Environment(\.homePalette) private var c

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days) { d in chip(d) }
        }
    }

    private func chip(_ d: RibbonDay) -> some View {
        let isSelected = Calendar.current.isDate(d.date, inSameDayAs: selected)
        let picked = isSelected && !d.isToday
        return Button { onPick(d.date) } label: {
            VStack(spacing: 4) {
                Text(d.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(picked ? c.onGold : d.isToday ? c.goldText : d.isPast ? c.faint : c.muted)
                Text(d.date.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(picked ? c.onGold : d.isPast ? c.faint : c.text)
                HStack(spacing: 3) {
                    ForEach(Array(d.dots.enumerated()), id: \.offset) { _, u in
                        Circle()
                            .fill(c.tier(u))
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(c.onGold.opacity(picked ? 0.85 : 0), lineWidth: 1.5))
                    }
                }
                .frame(height: 6)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .frame(maxWidth: .infinity)
            .padding(.top, 5)
            .padding(.bottom, 6)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(picked ? c.gold : (d.isToday && isSelected) ? c.card : .clear)
                    .shadow(color: (d.isToday && isSelected) ? c.cardShadow : .clear, radius: 5, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(d.isToday ? (isSelected ? c.line : c.gold) : .clear, lineWidth: isSelected ? 1 : 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(d))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(_ d: RibbonDay) -> String {
        var s = d.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if d.isToday { s = "Today, " + s }
        if !d.dots.isEmpty {
            let names = d.dots.map(HomeFormat.tierName).joined(separator: ", ")
            s += ", \(d.dots.count) that \(d.dots.count == 1 ? "matters" : "matter"): \(names)"
        }
        return s
    }
}
