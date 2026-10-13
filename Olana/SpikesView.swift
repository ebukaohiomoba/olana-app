//
//  SpikesView.swift
//  Olana
//
//  DEBUG only. Settings › Developer › M0 spikes: results so far, the S2 and S4
//  buttons, and export of the log (spec v3 §2.1).
//

#if DEBUG
import SwiftUI
import UIKit

struct SpikesView: View {
    @EnvironmentObject private var store: EventStore
    @State private var entries: [SpikeLog.Entry] = []
    @State private var s4Running = false
    @State private var s4Progress = ""
    @State private var s2Status = ""
    @State private var bgLiveActivity = BackgroundRefresh.tryLiveActivityInBackground
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Text("Use the phone normally for 3 days with this build. Background runs log themselves. Export the log at the end.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("S1 · Background model budget") {
                row("Background runs", "\(runs.count)")
                row("Runs with ≥ 1 model call OK", runs.isEmpty ? "–" : "\(runsWithOK) (\(pct(runsWithOK, runs.count)))")
                row("Model calls per run (mean)", runs.isEmpty ? "–" : String(format: "%.1f", meanOK))
                row("Stopped by rateLimited", "\(stops("rateLimited"))")
                row("Stopped by time guard", "\(stops("time guard"))")
                row("Expired by the system", "\(entries.filter { $0.event == "expired" }.count)")
                row("Pass line", "≥ 1 OK call in ≥ 50% of runs")
            }

            Section {
                row("Runs that exited locked", "\(entries.filter { $0.spike == "s3" }.count)")
            } header: {
                Text("S3 · Locked since reboot")
            } footer: {
                Text("Restart the phone, don't unlock it, and leave it on the charger for an hour. Then unlock and check this count. Any reminders that were already scheduled should still have fired.")
            }

            Section {
                Button("Schedule a Live Activity to start in 2 min") { scheduleS2() }
                if !s2Status.isEmpty { Text(s2Status).font(.footnote).foregroundStyle(.secondary) }
                Toggle("Also try from background runs", isOn: $bgLiveActivity)
                    .onChange(of: bgLiveActivity) { _, on in BackgroundRefresh.tryLiveActivityInBackground = on }
                row("Background attempts OK / failed",
                    "\(count("s2", "background scheduled request ok")) / \(count("s2", "background scheduled request failed"))")
            } header: {
                Text("S2 · Scheduled Live Activity")
            } footer: {
                Text("Lock the phone after tapping. Note whether it appears on the Lock Screen at the 2 minute mark.")
            }

            Section {
                Button(s4Running ? "Running… \(s4Progress)" : "Run EventAssist on the next 30 events") {
                    Task { await runS4() }
                }
                .disabled(s4Running)
                let calls = entries.filter { $0.spike == "s4" }
                let ok = calls.filter { $0.fields["outcome"] == "ok" && $0.fields["cold"] != "true" }
                    .compactMap { Double($0.fields["secs"] ?? "") }.sorted()
                row("Calls", "\(calls.count)")
                row("p50 / p90 (warm)", ok.isEmpty ? "–" : String(format: "%.2f s / %.2f s", quantile(ok, 0.5), quantile(ok, 0.9)))
                row("Cold first call", calls.first(where: { $0.fields["cold"] == "true" })?.fields["secs"].map { "\($0) s" } ?? "–")
                row("Max input (estimate)", calls.compactMap { Int($0.fields["estTokens"] ?? "") }.max().map { "\($0) tokens" } ?? "–")
                row("Refusals", "\(calls.filter { $0.fields["outcome"] == "refusal" }.count)")
                row("Pass line", "≤ 700 tokens, p90 ≤ 2.5 s")
            } header: {
                Text("S4 · EventAssist latency")
            } footer: {
                Text("Uses your real upcoming events. Results stay in the log on this phone.")
            }

            Section("Card picks (week check)") {
                let picks = entries.filter { $0.spike == "card" }
                row("Changes logged", "\(picks.count)")
                ForEach(picks.suffix(8).reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.fields["title"] ?? "none").font(.subheadline)
                        Text("\(e.fields["line"] ?? "") · \(e.at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ShareLink(item: SpikeLog.url) { Label("Export log", systemImage: "square.and.arrow.up") }
                Button("Clear log", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("M0 spikes")
        .onAppear { entries = SpikeLog.read() }
        .refreshable { entries = SpikeLog.read() }
        .confirmationDialog("Clear the spike log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { SpikeLog.clear(); entries = [] }
        }
    }

    // MARK: Summary

    private var runs: [SpikeLog.Entry] { entries.filter { $0.spike == "s1" && $0.event == "run end" } }
    private var runsWithOK: Int { runs.filter { (Int($0.fields["ok"] ?? "") ?? 0) > 0 }.count }
    private var meanOK: Double {
        Double(runs.compactMap { Int($0.fields["ok"] ?? "") }.reduce(0, +)) / Double(max(runs.count, 1))
    }
    private func stops(_ s: String) -> Int { runs.filter { $0.fields["stop"] == s }.count }
    private func count(_ spike: String, _ event: String) -> Int {
        entries.filter { $0.spike == spike && $0.event == event }.count
    }
    private func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : "\(a * 100 / b)%" }
    private func quantile(_ xs: [Double], _ q: Double) -> Double {
        xs[min(xs.count - 1, Int((Double(xs.count - 1) * q).rounded()))]
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).monospacedDigit() }
            .font(.subheadline)
    }

    // MARK: Actions

    private func scheduleS2() {
        do {
            let id = try SpikeLiveActivity.requestScheduled(minutesFromNow: 2, label: "foreground")
            s2Status = "Scheduled. Lock the phone and watch the Lock Screen."
            SpikeLog.write("s2", "foreground scheduled request ok", ["activity": id])
        } catch {
            s2Status = "Failed: \(error.localizedDescription)"
            SpikeLog.write("s2", "foreground scheduled request failed", ["error": "\(error)"])
        }
        entries = SpikeLog.read()
    }

    private func runS4() async {
        s4Running = true
        defer { s4Running = false; entries = SpikeLog.read() }
        let now = Date()
        let events = store.events
            .filter { $0.start > now && !$0.isAllDay && !$0.isTask }
            .sorted { $0.start < $1.start }
            .prefix(30)
        SpikeLog.write("s4", "run start", ["events": "\(events.count)"])
        for (i, e) in events.enumerated() {
            s4Progress = "\(i + 1)/\(events.count)"
            _ = await AssistSpike.run(.init(title: e.title, calendar: e.calendarName,
                                            location: e.location, notes: e.notes), index: i)
        }
    }
}

// MARK: - Card log

extension View {
    /// Logs the card's pick whenever it changes, for the week check.
    func spikeCardLog(_ card: NextCard?) -> some View {
        task(id: card.map { "\($0.eventID)|\($0.line)|\($0.secondary ?? "")" } ?? "none") {
            SpikeLog.write("card", "changed", [
                "title": card?.title ?? "none",
                "line": card?.line ?? "",
                "secondary": card?.secondary ?? "",
                "phase": card.map { "\($0.phase)" } ?? "",
            ])
        }
    }
}
#endif
