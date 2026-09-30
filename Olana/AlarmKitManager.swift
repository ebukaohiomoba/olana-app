//
//  AlarmKitManager.swift
//  Olana
//
//  Full-screen alarm support via AlarmKit (iOS 26+).
//  No special entitlement required — only NSAlarmKitUsageDescription in Info.plist.
//

import Foundation
import SwiftUI
import Combine
import AlarmKit

// MARK: - Alarm Metadata

/// Empty metadata type required by AlarmKit's generic AlarmAttributes.
nonisolated struct OlanaAlarmMetadata: AlarmMetadata, Codable, Hashable, Sendable {}

// MARK: - Auth state (own enum avoids importing AlarmKit's internal type name)

enum AlarmKitAuthState {
    case notDetermined, authorized, denied
}

// MARK: - AlarmKitManager

@MainActor
final class AlarmKitManager: ObservableObject {

    static let shared = AlarmKitManager()

    private let manager = AlarmManager.shared

    @Published var authorizationState: AlarmKitAuthState = .notDetermined

    var isAuthorized: Bool { authorizationState == .authorized }

    private init() {
        syncState()
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let state = try await manager.requestAuthorization()
            syncState(from: state)
            return authorizationState == .authorized
        } catch {
            print("❌ AlarmKitManager: Authorization error – \(error)")
            return false
        }
    }

    func refreshState() {
        syncState()
    }

    // MARK: - Scheduling

    /// Schedule a full-screen alarm for an event.
    ///
    /// `at` is when the alarm fires, which is not always when the event starts.
    /// For anything requiring preparation it is the moment the person needs to
    /// begin, so a presentation on Thursday can ring on Monday. That gap is the
    /// only reason this app rings at a time no other calendar would.
    ///
    /// `label` becomes the text on the lock screen. For a prep-advanced alarm it
    /// should say what to start, not merely name the event, because "Presentation
    /// to the board" ringing three days early reads as a bug without it.
    func scheduleAlarm(
        for event: OlanaEvent,
        at fireDate: Date? = nil,
        label: String? = nil
    ) async {
        guard isAuthorized else { return }

        let when = fireDate ?? event.start

        // Never schedule into the past. AlarmKit would reject it, and a stale
        // alarm firing immediately on launch is the worst possible first impression.
        guard when > Date() else {
            print("⏭️ AlarmKitManager: skipped '\(event.title)' — fire date is in the past")
            return
        }

        await cancelAlarm(for: event.id)

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: label ?? event.title),
            stopButton: AlarmButton(
                text: "Dismiss",
                textColor: .white,
                systemImageName: "xmark"
            )
        )

        let attributes = AlarmAttributes<OlanaAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: .red
        )

        do {
            try await manager.schedule(
                id: event.id,
                configuration: .alarm(
                    schedule: .fixed(when),
                    attributes: attributes
                )
            )
            print("✅ AlarmKitManager: Alarm set for '\(event.title)' at \(when)")
        } catch {
            print("❌ AlarmKitManager: Failed to schedule alarm – \(error)")
        }
    }

    /// Schedule an alarm at a custom time — used for re-alarming after a snooze.
    func scheduleReAlarm(eventId: UUID, title: String, at date: Date) async {
        guard isAuthorized else { return }

        try? await manager.cancel(id: eventId)

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(
                text: "Dismiss",
                textColor: .white,
                systemImageName: "xmark"
            )
        )
        let attributes = AlarmAttributes<OlanaAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: .red
        )
        do {
            try await manager.schedule(
                id: eventId,
                configuration: .alarm(
                    schedule: .fixed(date),
                    attributes: attributes
                )
            )
            print("✅ AlarmKitManager: Re-alarm set for '\(title)' at \(date)")
        } catch {
            print("❌ AlarmKitManager: Failed to schedule re-alarm – \(error)")
        }
    }

    // MARK: - Cancellation

    func cancelAlarm(for eventId: UUID) async {
        try? await manager.cancel(id: eventId)
    }

    // MARK: - Private

    private func syncState() {
        switch manager.authorizationState {
        case .notDetermined: authorizationState = .notDetermined
        case .authorized:    authorizationState = .authorized
        case .denied:        authorizationState = .denied
        @unknown default:    authorizationState = .denied
        }
    }

    private func syncState(from state: some Equatable) {
        // requestAuthorization() returns the same enum — re-read from manager
        // so we don't need to match the framework's type directly.
        syncState()
    }
}
