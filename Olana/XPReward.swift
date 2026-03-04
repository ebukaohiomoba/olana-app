//
//  XPReward.swift
//  Olana
//
//  Created by Chukwuebuka Ohiomoba on 11/28/25.
//


//
//  XPManager.swift
//  Olana
//
//  Gamification system: XP, streaks, badges, quests
//

import Foundation
import SwiftUI
import Combine

// MARK: - XP Rewards
enum XPReward: Int {
    case eventCompleted = 50
    case criticalEventCompleted = 100
    case soonEventCompleted = 75
    case laterEventCompleted = 45
    case streakMaintained = 25
    case firstEventOfDay = 30
    case threeEventsInDay = 90
    case perfectWeek = 500
    case badgeEarned = 200
    case questCompleted = 150
    
    var description: String {
        switch self {
        case .eventCompleted: return "Event Completed"
        case .criticalEventCompleted: return "Critical Event Crushed!"
        case .soonEventCompleted: return "Soon Event Finished!"
        case .laterEventCompleted: return "Later Event Done!"
        case .streakMaintained: return "Streak Maintained"
        case .firstEventOfDay: return "First of the Day!"
        case .threeEventsInDay: return "3 Events Today!"
        case .perfectWeek: return "Perfect Week!"
        case .badgeEarned: return "Badge Earned"
        case .questCompleted: return "Quest Completed"
        }
    }
}

// MARK: - Badge Model
struct Badge: Identifiable, Codable, Equatable {
    let id: String
    let icon: String
    let name: String
    let description: String
    let color: CodableColor
    let requirement: BadgeRequirement
    var unlockedAt: Date?
    
    var isUnlocked: Bool { unlockedAt != nil }
    
    enum BadgeRequirement: Codable, Equatable {
        case streakDays(Int)
        case totalXP(Int)
        case eventsCompleted(Int)
        case criticalEventsCompleted(Int)
        case perfectWeeks(Int)
        case earlyBird(Int) // events completed before 9am
        case nightOwl(Int) // events completed after 9pm
    }
    
    static let allBadges: [Badge] = [
        Badge(id: "streak_7", icon: "flame.fill", name: "Streak Starter", description: "Maintain a 7-day streak", color: CodableColor(.orange), requirement: .streakDays(7)),
        Badge(id: "streak_30", icon: "flame.fill", name: "Streak Master", description: "Maintain a 30-day streak", color: CodableColor(.red), requirement: .streakDays(30)),
        Badge(id: "streak_100", icon: "flame.fill", name: "Streak Legend", description: "Maintain a 100-day streak", color: CodableColor(.purple), requirement: .streakDays(100)),
        
        Badge(id: "xp_500", icon: "star.fill", name: "Rising Star", description: "Earn 500 total XP", color: CodableColor(.yellow), requirement: .totalXP(500)),
        Badge(id: "xp_2000", icon: "star.fill", name: "XP Champion", description: "Earn 2,000 total XP", color: CodableColor(.orange), requirement: .totalXP(2000)),
        Badge(id: "xp_10000", icon: "star.fill", name: "XP Legend", description: "Earn 10,000 total XP", color: CodableColor(.purple), requirement: .totalXP(10000)),
        
        Badge(id: "events_10", icon: "checkmark.circle.fill", name: "Getting Started", description: "Complete 10 events", color: CodableColor(.green), requirement: .eventsCompleted(10)),
        Badge(id: "events_50", icon: "checkmark.circle.fill", name: "Productive", description: "Complete 50 events", color: CodableColor(.blue), requirement: .eventsCompleted(50)),
        Badge(id: "events_200", icon: "checkmark.circle.fill", name: "Super Achiever", description: "Complete 200 events", color: CodableColor(.purple), requirement: .eventsCompleted(200)),
        
        Badge(id: "early_bird", icon: "sunrise.fill", name: "Early Bird", description: "Complete 20 events before 9am", color: CodableColor(.cyan), requirement: .earlyBird(20)),
        Badge(id: "night_owl", icon: "moon.stars.fill", name: "Night Owl", description: "Complete 20 events after 9pm", color: CodableColor(.indigo), requirement: .nightOwl(20)),
        
        Badge(id: "critical_10", icon: "exclamationmark.triangle.fill", name: "Crisis Manager", description: "Complete 10 critical events", color: CodableColor(.red), requirement: .criticalEventsCompleted(10)),
        
        Badge(id: "perfect_week", icon: "calendar", name: "Perfect Week", description: "Complete events every day for a week", color: CodableColor(.mint), requirement: .perfectWeeks(1))
    ]
}

// Helper for storing Color in Codable
struct CodableColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double
    
    init(_ color: Color) {
        // Extract RGB components from Color (approximation for common colors)
        if color == .orange {
            (red, green, blue, opacity) = (1.0, 0.6, 0.0, 1.0)
        } else if color == .red {
            (red, green, blue, opacity) = (1.0, 0.0, 0.0, 1.0)
        } else if color == .purple {
            (red, green, blue, opacity) = (0.7, 0.0, 1.0, 1.0)
        } else if color == .yellow {
            (red, green, blue, opacity) = (1.0, 1.0, 0.0, 1.0)
        } else if color == .green {
            (red, green, blue, opacity) = (0.0, 1.0, 0.0, 1.0)
        } else if color == .blue {
            (red, green, blue, opacity) = (0.0, 0.5, 1.0, 1.0)
        } else if color == .cyan {
            (red, green, blue, opacity) = (0.0, 1.0, 1.0, 1.0)
        } else if color == .indigo {
            (red, green, blue, opacity) = (0.3, 0.0, 0.5, 1.0)
        } else if color == .mint {
            (red, green, blue, opacity) = (0.0, 1.0, 0.7, 1.0)
        } else {
            (red, green, blue, opacity) = (0.5, 0.5, 0.5, 1.0)
        }
    }
    
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

// MARK: - Quest Model
struct Quest: Identifiable, Codable {
    let id: String
    let icon: String
    let iconColor: CodableColor
    let title: String
    let description: String
    let xpReward: Int
    let requirement: QuestRequirement
    var progress: Int
    var completedAt: Date?
    let expiresAt: Date
    
    var isCompleted: Bool { completedAt != nil }
    var progressPercentage: Double {
        Double(progress) / Double(requirement.target)
    }
    
    enum QuestRequirement: Codable {
        case completeEvents(Int)
        case addEvents(Int)
        case maintainStreak
        case completeCritical(Int)
        
        var target: Int {
            switch self {
            case .completeEvents(let count): return count
            case .addEvents(let count): return count
            case .maintainStreak: return 1
            case .completeCritical(let count): return count
            }
        }
    }
}

// MARK: - XP Manager
@MainActor
class XPManager: ObservableObject {
    static let shared = XPManager()
    
    @Published var totalXP: Int = 0
    @Published var streakDays: Int = 0
    @Published var graceTokens: Int = 2
    @Published var lastActivityDate: Date?
    @Published var badges: [Badge] = Badge.allBadges
    @Published var dailyQuests: [Quest] = []
    
    // Statistics
    @Published var totalEventsCompleted: Int = 0
    @Published var criticalEventsCompleted: Int = 0
    @Published var earlyBirdEvents: Int = 0
    @Published var nightOwlEvents: Int = 0
    @Published var perfectWeeks: Int = 0
    @Published var eventsCompletedToday: Int = 0
    
    private let calendar = Calendar.current
    private var currentUID: String?

    private init() {
        loadFromUserDefaults()
        generateDailyQuests()
        checkStreak()
    }

    // MARK: - Firestore Sync

    /// Call after sign-in. `loadExisting: true` for returning users (pulls Firestore → local).
    /// `loadExisting: false` for brand-new users (pushes local → Firestore).
    func configure(uid: String, loadExisting: Bool) {
        currentUID = uid
        if loadExisting {
            Task { await loadFromFirestore() }
        } else {
            syncToFirestore()
        }
    }

    func loadFromFirestore() async {
        guard let uid = currentUID else { return }
        do {
            guard let stats = try await FirestoreService.shared.fetchUserStats(uid: uid) else { return }
            totalXP                  = stats.totalXP
            streakDays               = stats.streakDays
            graceTokens              = stats.graceTokens
            lastActivityDate         = stats.lastActivityDate
            totalEventsCompleted     = stats.totalEventsCompleted
            criticalEventsCompleted  = stats.criticalEventsCompleted
            earlyBirdEvents          = stats.earlyBirdEvents
            nightOwlEvents           = stats.nightOwlEvents
            eventsCompletedToday     = stats.eventsCompletedToday
            // Mirror to UserDefaults so local cache stays consistent
            saveToUserDefaults()
        } catch {
            print("XPManager: Firestore load failed — \(error)")
        }
    }

    private func syncToFirestore() {
        guard let uid = currentUID else { return }
        let s = (
            totalXP: totalXP, streakDays: streakDays, graceTokens: graceTokens,
            lastActivityDate: lastActivityDate, totalEventsCompleted: totalEventsCompleted,
            criticalEventsCompleted: criticalEventsCompleted, earlyBirdEvents: earlyBirdEvents,
            nightOwlEvents: nightOwlEvents, eventsCompletedToday: eventsCompletedToday
        )
        Task {
            do {
                try await FirestoreService.shared.updateUserStats(
                    uid: uid,
                    totalXP: s.totalXP,
                    streakDays: s.streakDays,
                    graceTokens: s.graceTokens,
                    lastActivityDate: s.lastActivityDate,
                    totalEventsCompleted: s.totalEventsCompleted,
                    criticalEventsCompleted: s.criticalEventsCompleted,
                    earlyBirdEvents: s.earlyBirdEvents,
                    nightOwlEvents: s.nightOwlEvents,
                    eventsCompletedToday: s.eventsCompletedToday
                )
            } catch {
                print("XPManager: Firestore sync failed — \(error)")
            }
        }
    }
    
    // MARK: - Event Completion
    func completeEvent(_ event: OlanaEvent) -> (xp: Int, rewards: [String], newBadges: [Badge]) {
        var earnedXP = 0
        var rewards: [String] = []
        var newBadges: [Badge] = []
        
        // Base XP based on urgency
        let baseXP: XPReward = switch event.urgency {
        case .high: .criticalEventCompleted
        case .medium: .soonEventCompleted
        case .low: .laterEventCompleted
        }
        
        earnedXP += baseXP.rawValue
        rewards.append(baseXP.description)
        
        // Bonus XP
        if eventsCompletedToday == 0 {
            earnedXP += XPReward.firstEventOfDay.rawValue
            rewards.append(XPReward.firstEventOfDay.description)
        }
        
        eventsCompletedToday += 1
        
        if eventsCompletedToday == 3 {
            earnedXP += XPReward.threeEventsInDay.rawValue
            rewards.append(XPReward.threeEventsInDay.description)
        }
        
        // Update statistics
        totalEventsCompleted += 1
        if event.urgency == .high {
            criticalEventsCompleted += 1
        }
        
        // Check time-based badges
        let hour = calendar.component(.hour, from: Date())
        if hour < 9 {
            earlyBirdEvents += 1
        } else if hour >= 21 {
            nightOwlEvents += 1
        }
        
        // Update streak
        updateStreak()
        
        // Add XP
        totalXP += earnedXP
        
        // Update quests
        updateQuests(eventCompleted: event)
        
        // Check for new badges
        newBadges = checkBadges()
        
        // Save
        saveToUserDefaults()
        
        return (earnedXP, rewards, newBadges)
    }
    
    // MARK: - Streak Management
    private func updateStreak() {
        let today = calendar.startOfDay(for: Date())
        
        if let lastActivity = lastActivityDate {
            let lastActivityDay = calendar.startOfDay(for: lastActivity)
            let daysBetween = calendar.dateComponents([.day], from: lastActivityDay, to: today).day ?? 0
            
            if daysBetween == 0 {
                // Same day, no change
            } else if daysBetween == 1 {
                // Consecutive day, increment streak
                streakDays += 1
            } else if daysBetween > 1 {
                // Streak broken, use grace token or reset
                if graceTokens > 0 {
                    graceTokens -= 1
                    streakDays += 1
                } else {
                    streakDays = 1
                }
            }
        } else {
            // First activity ever
            streakDays = 1
        }
        
        lastActivityDate = Date()
    }
    
    private func checkStreak() {
        guard let lastActivity = lastActivityDate else { return }
        
        let today = calendar.startOfDay(for: Date())
        let lastActivityDay = calendar.startOfDay(for: lastActivity)
        let daysBetween = calendar.dateComponents([.day], from: lastActivityDay, to: today).day ?? 0
        
        // Reset daily event counter if new day
        if daysBetween > 0 {
            eventsCompletedToday = 0
        }
    }
    
    // MARK: - Badge System
    private func checkBadges() -> [Badge] {
        var newlyUnlocked: [Badge] = []
        
        for index in badges.indices {
            if !badges[index].isUnlocked {
                if meetsRequirement(badges[index].requirement) {
                    badges[index].unlockedAt = Date()
                    newlyUnlocked.append(badges[index])
                    totalXP += XPReward.badgeEarned.rawValue
                }
            }
        }
        
        return newlyUnlocked
    }
    
    private func meetsRequirement(_ requirement: Badge.BadgeRequirement) -> Bool {
        switch requirement {
        case .streakDays(let required):
            return streakDays >= required
        case .totalXP(let required):
            return totalXP >= required
        case .eventsCompleted(let required):
            return totalEventsCompleted >= required
        case .criticalEventsCompleted(let required):
            return criticalEventsCompleted >= required
        case .perfectWeeks(let required):
            return perfectWeeks >= required
        case .earlyBird(let required):
            return earlyBirdEvents >= required
        case .nightOwl(let required):
            return nightOwlEvents >= required
        }
    }
    
    // MARK: - Quest System
    private func generateDailyQuests() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        
        dailyQuests = [
            Quest(
                id: "complete_3",
                icon: "checkmark.circle.fill",
                iconColor: CodableColor(.green),
                title: "Complete 3 events",
                description: "Finish 3 events today",
                xpReward: 100,
                requirement: .completeEvents(3),
                progress: eventsCompletedToday,
                expiresAt: tomorrow
            ),
            Quest(
                id: "add_event",
                icon: "plus.circle.fill",
                iconColor: CodableColor(.blue),
                title: "Log a new task",
                description: "Add at least one event",
                xpReward: 50,
                requirement: .addEvents(1),
                progress: 0,
                expiresAt: tomorrow
            ),
            Quest(
                id: "maintain_streak",
                icon: "flame.fill",
                iconColor: CodableColor(.orange),
                title: "Maintain your streak",
                description: "Complete an event today",
                xpReward: 75,
                requirement: .maintainStreak,
                progress: eventsCompletedToday > 0 ? 1 : 0,
                expiresAt: tomorrow
            )
        ]
    }
    
    private func updateQuests(eventCompleted: OlanaEvent) {
        for index in dailyQuests.indices {
            if !dailyQuests[index].isCompleted {
                switch dailyQuests[index].requirement {
                case .completeEvents:
                    dailyQuests[index].progress = eventsCompletedToday
                    if dailyQuests[index].progress >= dailyQuests[index].requirement.target {
                        dailyQuests[index].completedAt = Date()
                        totalXP += dailyQuests[index].xpReward
                    }
                case .maintainStreak:
                    dailyQuests[index].progress = 1
                    dailyQuests[index].completedAt = Date()
                    totalXP += dailyQuests[index].xpReward
                case .completeCritical(let required):
                    if eventCompleted.urgency == .high {
                        dailyQuests[index].progress += 1
                        if dailyQuests[index].progress >= required {
                            dailyQuests[index].completedAt = Date()
                            totalXP += dailyQuests[index].xpReward
                        }
                    }
                default:
                    break
                }
            }
        }
    }
    
    // MARK: - Persistence
    private func saveToUserDefaults() {
        // Snapshot values on the main thread, then write off it
        let snapshot = (
            totalXP: totalXP,
            streakDays: streakDays,
            graceTokens: graceTokens,
            lastActivityDate: lastActivityDate,
            totalEventsCompleted: totalEventsCompleted,
            criticalEventsCompleted: criticalEventsCompleted,
            earlyBirdEvents: earlyBirdEvents,
            nightOwlEvents: nightOwlEvents,
            eventsCompletedToday: eventsCompletedToday,
            badges: badges,
            dailyQuests: dailyQuests
        )
        DispatchQueue.global(qos: .utility).async {
            let ud = UserDefaults.standard
            ud.set(snapshot.totalXP, forKey: "totalXP")
            ud.set(snapshot.streakDays, forKey: "streakDays")
            ud.set(snapshot.graceTokens, forKey: "graceTokens")
            ud.set(snapshot.lastActivityDate, forKey: "lastActivityDate")
            ud.set(snapshot.totalEventsCompleted, forKey: "totalEventsCompleted")
            ud.set(snapshot.criticalEventsCompleted, forKey: "criticalEventsCompleted")
            ud.set(snapshot.earlyBirdEvents, forKey: "earlyBirdEvents")
            ud.set(snapshot.nightOwlEvents, forKey: "nightOwlEvents")
            ud.set(snapshot.eventsCompletedToday, forKey: "eventsCompletedToday")
            if let data = try? JSONEncoder().encode(snapshot.badges) {
                ud.set(data, forKey: "badges")
            }
            if let data = try? JSONEncoder().encode(snapshot.dailyQuests) {
                ud.set(data, forKey: "dailyQuests")
            }
        }
        syncToFirestore()
    }
    
    private func loadFromUserDefaults() {
        totalXP = UserDefaults.standard.integer(forKey: "totalXP")
        streakDays = UserDefaults.standard.integer(forKey: "streakDays")
        graceTokens = UserDefaults.standard.integer(forKey: "graceTokens")
        lastActivityDate = UserDefaults.standard.object(forKey: "lastActivityDate") as? Date
        totalEventsCompleted = UserDefaults.standard.integer(forKey: "totalEventsCompleted")
        criticalEventsCompleted = UserDefaults.standard.integer(forKey: "criticalEventsCompleted")
        earlyBirdEvents = UserDefaults.standard.integer(forKey: "earlyBirdEvents")
        nightOwlEvents = UserDefaults.standard.integer(forKey: "nightOwlEvents")
        eventsCompletedToday = UserDefaults.standard.integer(forKey: "eventsCompletedToday")
        
        if let badgesData = UserDefaults.standard.data(forKey: "badges"),
           let savedBadges = try? JSONDecoder().decode([Badge].self, from: badgesData) {
            badges = savedBadges
        }
        
        if let questsData = UserDefaults.standard.data(forKey: "dailyQuests"),
           let savedQuests = try? JSONDecoder().decode([Quest].self, from: questsData) {
            dailyQuests = savedQuests
        }
    }
}
