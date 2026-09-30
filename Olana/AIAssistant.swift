//
//  AIAssistant.swift
//  Olana
//
//  Single entry point for Apple Intelligence (Foundation Models) calls.
//  All availability gating, session lifecycle, and fallback semantics live
//  here so the rest of the app can treat FM as "either it answers, or it
//  doesn't" — never a crash, never a throw bubbling into UI.
//
//  Surfaces (one session each, see PRD §6.2):
//   - capture       — Phase 1 natural-language event parsing
//   - urgencyAug    — Phase 2 (added later)
//   - oluVoice      — Phase 3 (added later)
//

import Foundation
import Combine
import FoundationModels

@MainActor
final class AIAssistant: ObservableObject {

    static let shared = AIAssistant()

    // MARK: - Public state

    enum State: Equatable {
        case available
        case unavailable(reason: String)
        case unknown
    }

    @Published private(set) var state: State = .unknown

    var isAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    // MARK: - Sessions

    private var captureSession: LanguageModelSession?

    // MARK: - Init

    private init() {
        refreshAvailability()
    }

    // MARK: - Availability

    /// Re-read system model state. Call on init and whenever the app foregrounds —
    /// users can flip Apple Intelligence on/off in Settings while we're backgrounded.
    func refreshAvailability() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            state = .available
        case .unavailable(let reason):
            state = .unavailable(reason: Self.describe(reason))
            captureSession = nil
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .deviceNotEligible:           return "deviceNotEligible"
        case .modelNotReady:               return "modelNotReady"
        @unknown default:                  return "unknown"
        }
    }

    /// Touch sessions so the model loads in the background. Skips on Low Power Mode
    /// per PRD energy guidance.
    func prewarmIfEligible() {
        guard isAvailable else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        _ = captureSessionLazy()
    }

    // MARK: - Phase 1: Capture

    /// Parse free-form text into a validated event draft. Returns nil for any
    /// failure mode (unavailable, validation failure, generation error). Callers
    /// fall back to the manual form on nil — this method never throws.
    func parseEventText(_ text: String, now: Date = Date()) async -> ResolvedEventDraft? {
        guard isAvailable else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let session = captureSessionLazy()
        do {
            let response = try await session.respond(
                to: Self.capturePrompt(for: trimmed, now: now),
                generating: EventDraft.self
            )
            let draft = response.content
            guard draft.validate(now: now) else { return nil }
            return draft.resolve()
        } catch {
            return nil
        }
    }

    private func captureSessionLazy() -> LanguageModelSession {
        if let existing = captureSession { return existing }
        let session = LanguageModelSession(instructions: Self.captureInstructions)
        captureSession = session
        return session
    }

    // MARK: - Phase 2: Semantics

    /// Extract the stable semantic properties of an event. Runs once per event and
    /// the result is cached on OlanaEvent, so this is never on a render path.
    ///
    /// `nonisolated` on purpose: extraction runs across a whole calendar and must
    /// not serialise behind the main actor.
    ///
    /// A fresh session per call is also deliberate. LanguageModelSession accumulates
    /// a transcript and the context window is 4096 tokens, so reusing one session
    /// across a calendar overflows it after a few dozen events.
    ///
    /// Returns nil on any failure. Most callers want `semantics(title:)`, which
    /// also says why.
    nonisolated func extractSemantics(
        title: String,
        calendarName: String? = nil
    ) async -> EventSemantics? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prompt = EventSemanticsPrompt.prompt(title: trimmed, calendarName: calendarName)
        // Greedy sampling makes this deterministic. Verified at 100% field agreement
        // over three passes on 35 events; default sampling is not.
        let options = GenerationOptions(sampling: .greedy)

        // One retry on failure, with a fresh session.
        //
        // The safety guardrail raises Refusal sporadically rather than per-title:
        // measured, "Payday" was refused three times inside a 58-event run and not
        // once when the same title was sent on its own. A refusal is therefore a
        // transient condition under sustained extraction, not a verdict about the
        // event, and it is worth asking again before giving up.
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: EventSemanticsPrompt.instructions)
            do {
                return try await session.respond(
                    to: prompt, generating: EventSemantics.self, options: options
                ).content
            } catch {
                if attempt == 0 {
                    // Brief pause: retrying immediately tends to reproduce it.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    /// Why an event did or did not get semantics. The cases are handled
    /// differently, which is why this is not an optional.
    enum SemanticsOutcome: Sendable {
        /// The model judged it.
        case judged(EventSemantics)
        /// The title is a placeholder ("Hold", "OOO"). Permanent: never retry.
        case placeholder
        /// Apple Intelligence is off, still downloading, or unsupported here.
        /// Nothing was attempted, so try again once it becomes available.
        case unavailable
        /// The model was asked and failed twice. Usually a transient refusal.
        case failed
    }

    /// Semantics for an event, or the reason there are none.
    ///
    /// There is deliberately no keyword fallback. Only the model's judgement is
    /// allowed to rank an event or ring an alarm; without it the event stays in
    /// chronological order and silent.
    nonisolated func semantics(title: String, calendarName: String? = nil) async -> SemanticsOutcome {
        // A placeholder title cannot be classified honestly, by the model or anyone.
        guard !EventSemantics.isLowInformation(title: title) else { return .placeholder }
        guard case .available = SystemLanguageModel.default.availability else { return .unavailable }

        if let s = await extractSemantics(title: title, calendarName: calendarName) {
            return .judged(s)
        }
        return .failed
    }

    /// Short, user-facing reason Olu cannot suggest urgency, or nil when it can.
    var unavailableMessage: String? {
        guard case .unavailable(let reason) = state else { return nil }
        switch reason {
        case "appleIntelligenceNotEnabled":
            return "Turn on Apple Intelligence in Settings for Olu's suggestions."
        case "modelNotReady":
            return "Apple Intelligence is still getting ready. Olu's suggestions will start soon."
        default:
            return "Olu's suggestions need a device with Apple Intelligence."
        }
    }

    // MARK: - Smoke test

    /// Returns a one-line status string. Debug-only — wire to a temporary button
    /// or call from LLDB to verify FM is reachable on a given device before
    /// any UI is wired up.
    func smokeTest() async -> String {
        switch state {
        case .available:
            if let parsed = await parseEventText("test event tomorrow at 3pm") {
                return "OK — parsed: \(parsed.title) @ \(parsed.start)"
            } else {
                return "Available, but parse returned nil"
            }
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        case .unknown:
            return "Unknown — refreshAvailability() not called"
        }
    }

    // MARK: - Prompts

    private static let captureInstructions: String = """
    You convert short natural-language descriptions of calendar events into structured drafts.
    - Infer start time from phrases like "tomorrow", "next Tuesday", "in 2 hours" relative to the supplied current time.
    - Leave end null unless the user explicitly mentions a duration ("for an hour") or a range ("2 to 3pm"). Do not invent a duration.
    - Choose urgency from explicit cues ("urgent", "kinda urgent", "no rush"). If unstated, use medium.
    - Choose recurrenceRule from explicit cues ("every week", "daily"). If unstated, use none.
    - Keep the title short. Strip leading verbs like "add", "schedule", "remind me to".
    - Do not invent attendees or locations the user did not mention.
    """

    private static func capturePrompt(for text: String, now: Date) -> String {
        let nowFormatted = ISO8601DateFormatter().string(from: now)
        return """
        Current time: \(nowFormatted)

        Convert this into an EventDraft:
        \(text)
        """
    }
}
