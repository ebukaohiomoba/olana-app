//
//  OlanaApp.swift
//  Olana
//

import SwiftUI
import SwiftData
import UserNotifications
import FirebaseCore

// MARK: - App Delegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Pull latest iCloud KV values immediately so NotificationSettings
        // reflects the most recent cross-device preferences on first access.
        NSUbiquitousKeyValueStore.default.synchronize()
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            NotificationEngine.shared.setupNotificationCategories()
        }

        // PRD §3.2 background run. Must register before launch ends.
        BackgroundRefresh.register()
        if application.applicationState != .background {
            FirstUnlock.writeMarker()
            GoogleOAuthManager.shared.upgradeKeychainAccessibility()
        }

        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DeliveryLedger.shared.noteSeen(notification.request.identifier, at: notification.date)
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DeliveryLedger.shared.noteSeen(response.notification.request.identifier, at: response.notification.date)
        let userInfo = response.notification.request.content.userInfo
        if let eventIdString = userInfo["eventId"] as? String,
           let eventId = UUID(uuidString: eventIdString) {
            Task { @MainActor in
                await NotificationEngine.shared.handleNotificationAction(
                    actionIdentifier: response.actionIdentifier,
                    eventId: eventId,
                    requestID: response.notification.request.identifier
                )
            }
        }
        completionHandler()
    }
}

// MARK: - Main App
@main
struct OlanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ThemePreference private var selectedTheme: ThemeVariant
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// When onboarding finished; the calendar-alerts tip waits a week from it.
    @AppStorage("olanaOnboardedAt_v1") private var onboardedAt: Double = 0

    init() {
        // Analytics and the Google Calendar client ID. No account: there's no login.
        FirebaseApp.configure()
    }

    @ViewBuilder
    private var appRoot: some View {
        if !hasCompletedOnboarding {
            OnboardingView {
                onboardedAt = Date().timeIntervalSince1970
                hasCompletedOnboarding = true
            }
            .homePalette()
        } else {
            ContentView()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let fixture = HomeFixtures.requested {
                    HomeFixtureScreen(which: fixture)
                } else {
                    appRoot
                }
                #else
                appRoot
                #endif
            }
            .olanaThemeProvider(variant: selectedTheme)
            .onAppear {
                #if DEBUG
                if HomeFixtures.requested != nil { return }
                #endif
                // Asked on home after first value (PRD §1.11 step 5), not at launch.
                Task { @MainActor in await NotificationEngine.shared.checkAuthorizationStatus() }
            }
        }
        .modelContainer(Persistence.shared.container)
    }
}
