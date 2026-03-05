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

    func scheduleAlarm(for event: OlanaEvent) async {
        guard isAuthorized else { return }

        await cancelAlarm(for: event.id)

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: event.title),
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
                    schedule: .fixed(event.start),
                    attributes: attributes
                )
            )
            print("✅ AlarmKitManager: Alarm set for '\(event.title)' at \(event.start)")
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
