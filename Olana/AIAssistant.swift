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
