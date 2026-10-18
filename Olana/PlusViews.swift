//
//  PlusViews.swift
//  Olana
//
//  Plus in the app (PRD v6 §1.10): the stored state, the beta's fake-door
//  paywall, the "what Plus did" screen after the preview, and the Apple
//  Intelligence gate screen (PRD v3 §1.11 step 2). Rules live in PlusModel.
//

import SwiftUI
import Combine

@MainActor
final class PlusStore: ObservableObject {
    static let shared = PlusStore()
    private let key = "olanaPlusState_v1"

    @Published private(set) var state: PlusState
    /// Set when the 5th moment lands; the app shows the summary once.
    @Published var showSummary = false
    @Published var showPaywall = false

    private init() {
        state = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(PlusState.self, from: $0) } ?? PlusState()
    }

    var gate: IntelligenceGate {
        switch AIAssistant.shared.state {
        case .available, .unknown: return .available
        case .unavailable(let reason): return IntelligenceGate.from(reason: reason)
        }
    }

    var hasPlus: Bool { PlusRules.hasPlus(state, gatePassed: gate.canSellPlus) }
    var inPreview: Bool { PlusRules.inPreview(state) }
    var momentsLeft: Int { max(0, PlusRules.previewMoments - state.moments.count) }

    /// A Plus moment the user experienced (acted on, not just scheduled).
    func record(_ kind: PlusMomentKind, eventKey: String) {
        let (next, ended) = PlusRules.record(PlusMoment(kind: kind, eventKey: eventKey, at: Date()), in: state)
        guard next != state else { return }
        save(next)
        if ended { showSummary = true }
    }

    /// Beta fake door: records intent, then unlocks with a thank-you.
    func tapGetPlus(plan: String) {
        var s = state
        s.fakeDoorAt = Date()
        save(s)
        OlanaAnalytics.plusIntent(plan: plan, momentsUsed: state.moments.count)
    }

    func markSummaryShown() {
        var s = state
        s.summaryShownAt = Date()
        save(s)
    }

    #if DEBUG
    func resetForTesting() { save(PlusState()) }
    #endif

    private func save(_ s: PlusState) {
        state = s
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Paywall (beta: fake door)

struct PlusPaywallView: View {
    @ObservedObject private var plus = PlusStore.shared
    @Environment(\.homePalette) private var c
    @Environment(\.dismiss) private var dismiss
    @State private var plan = "yearly"
    @State private var thanked = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Olana Plus").font(HomeType.serif(size: 32)).foregroundStyle(c.goldText)

            if !PlusRules.summary(plus.state).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PlusRules.summary(plus.state), id: \.self) { line in
                        Label(line, systemImage: "checkmark").foregroundStyle(c.text)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                feature("Leave-by times, get-ready and leave alerts")
                feature("When to start prepping, with steps and effort")
                feature("Your bring list")
                feature("Alarms for what can't be missed")
            }

            VStack(spacing: 10) {
                option("yearly", PlusRules.prices.yearly, note: "Best value")
                option("monthly", PlusRules.prices.monthly, note: nil)
                option("lifetime", PlusRules.prices.lifetime, note: nil)
            }

            if thanked {
                Text("Thank you. Plus is on for the beta, free.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(c.goldText)
            } else {
                Button {
                    plus.tapGetPlus(plan: plan)
                    withAnimation { thanked = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
                } label: {
                    Text("Get Plus").font(.body.weight(.semibold)).foregroundStyle(c.onGold)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(c.gold))
                }
                .buttonStyle(.plain)
            }

            Text("Sync, the timeline, your reminders, Join, Materials and Place stay free.")
                .font(.footnote).foregroundStyle(c.muted)
            Button("Not now") { dismiss() }.font(.subheadline).frame(maxWidth: .infinity)
        }
        .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.bg.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func feature(_ t: String) -> some View {
        Label(t, systemImage: "sparkle").font(.subheadline).foregroundStyle(c.text)
    }

    private func option(_ id: String, _ price: String, note: String?) -> some View {
        Button { plan = id } label: {
            HStack {
                Image(systemName: plan == id ? "largecircle.fill.circle" : "circle").foregroundStyle(c.goldText)
                Text(price).foregroundStyle(c.text)
                Spacer()
                if let note { Text(note).font(.caption.weight(.semibold)).foregroundStyle(c.goldText) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).stroke(plan == id ? c.gold : c.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(plan == id ? [.isSelected] : [])
    }
}

// MARK: - Apple Intelligence gate (PRD v3 §1.11 step 2)

struct IntelligenceGateView: View {
    let gate: IntelligenceGate
    var onContinue: () -> Void
    @Environment(\.homePalette) private var c
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: gate == .downloading ? "arrow.down.circle" : "apple.intelligence")
                .font(.system(size: 40)).foregroundStyle(c.goldText)
            Text(gate.title).font(HomeType.serif(size: 28)).foregroundStyle(c.text)
            Text(gate.message).font(.body).foregroundStyle(c.muted)
            Spacer()
            if gate == .turnedOff {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings").font(.body.weight(.semibold)).foregroundStyle(c.onGold)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(c.gold))
                }
                .buttonStyle(.plain)
            }
            Button(gate == .notEligible ? "Continue without it" : "Continue", action: onContinue)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(28)
        .background(c.bg.ignoresSafeArea())
    }
}
