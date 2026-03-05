//
//  OlanaApp.swift
//  Olana
//

import SwiftUI
import SwiftData
import UserNotifications
import BackgroundTasks
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

        // Background Live Activity: wake the app before imminent events so the
        // countdown appears on Lock Screen and Dynamic Island even when suspended.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.olana.liveActivityCheck",
            using: nil
        ) { task in
            self.handleLiveActivityCheck(task as! BGAppRefreshTask)
        }

        return true
    }

    private func handleLiveActivityCheck(_ task: BGAppRefreshTask) {
        // Immediately reschedule so the next event is also covered.
        NotificationEngine.scheduleLiveActivityCheck()

        let work = Task { @MainActor in
            NotificationEngine.shared.startLiveActivitiesFromCache()
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: true)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let eventIdString = userInfo["eventId"] as? String,
           let eventId = UUID(uuidString: eventIdString) {
            Task { @MainActor in
                await NotificationEngine.shared.handleNotificationAction(
                    actionIdentifier: response.actionIdentifier,
                    eventId: eventId
                )
            }
        }
        completionHandler()
    }
}

// MARK: - Launch View

private struct LaunchView: View {
    @Environment(\.olanaTheme) private var theme
    @State private var oluState: OluState = .celebrate

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                OluView(state: $oluState, size: 180)

                VStack(spacing: 8) {
                    Text("Olana")
                        .font(.system(size: 38, weight: .bold, design: .serif))
                        .foregroundStyle(theme.colors.ink)

                    Text("Your personal productivity companion")
                        .font(.subheadline)
                        .foregroundStyle(theme.colors.slate)
                }
            }
        }
    }
}

// MARK: - Main App
@main
struct OlanaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ThemePreference private var selectedTheme: ThemeVariant
    @StateObject private var authManager = AuthenticationManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var splashTimerDone = false

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Splash shows for exactly 3 ms then yields — never gated on
                // isLoading so a slow/offline Firestore can never keep it stuck.
                if !splashTimerDone {
                    LaunchView()
                        .onAppear {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000)
                                splashTimerDone = true
                            }
                        }
                } else if authManager.currentUser == nil {
                    LoginView()
                } else if authManager.isLoading || authManager.appUser == nil {
                    // Firebase user is known but the Firestore profile fetch is still
                    // in-flight (or hasn't started yet). Hold on the splash rather than
                    // flashing UsernameSetupView.
                    LaunchView()
                } else if authManager.appUser?.username.isEmpty != false {
                    UsernameSetupView()
                } else if !hasCompletedOnboarding {
                    OnboardingContainerView()
                } else {
                    ContentView()
                }
            }
            .environmentObject(authManager)
            .olanaThemeProvider(variant: selectedTheme)
            .onAppear {
                Task { @MainActor in
                    if NotificationEngine.shared.authorizationStatus == .notDetermined {
                        _ = await NotificationEngine.shared.requestAuthorization()
                    } else {
                        await NotificationEngine.shared.checkAuthorizationStatus()
                    }
                }
            }
        }
        .modelContainer(Persistence.shared.container)
    }
}
