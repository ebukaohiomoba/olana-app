import Foundation

// MARK: - AppUser (Firestore-backed, replaces OlanaUser @Model)
struct AppUser: Codable, Identifiable {
    var id: String           // Firebase Auth UID (also used as Firestore doc ID)
    var username: String
    var displayName: String
    var email: String
    var profileEmoji: String
    var streakDays: Int
    var graceTokens: Int
    var totalXP: Int
    var joinedAt: Date
    var lastActiveAt: Date
}

// MARK: - FriendRequestDoc (Firestore-backed, replaces FriendRequest @Model)
struct FriendRequestDoc: Codable, Identifiable {
    var id: String           // Firestore document ID
    var senderId: String
    var senderName: String
    var senderEmoji: String
    var receiverId: String
    var status: String       // "pending" | "accepted" | "declined"
    var sentAt: Date
    var message: String?
}

// MARK: - Friend Request Action
enum FriendRequestAction {
    case accept, decline
}

// MARK: - Search Type (used in AddFriendView + FirestoreService)
enum SearchType: CaseIterable {
    case username, displayName

    var displayName: String {
        switch self {
        case .username:    return "Username"
        case .displayName: return "Display Name"
        }
    }
}

// MARK: - Badge Category (kept for local XP/badge logic)
public enum BadgeCategory: String, Codable, CaseIterable {
    case streak = "streak"
    case productivity = "productivity"
    case milestone = "milestone"
    case social = "social"
    case achievement = "achievement"

    public var displayName: String {
        switch self {
        case .streak:       return "Streak"
        case .productivity: return "Productivity"
        case .milestone:    return "Milestone"
        case .social:       return "Social"
        case .achievement:  return "Achievement"
        }
    }
}

// MARK: - Status Enums (kept for any future use)
public enum FriendshipStatus: String, Codable {
    case pending  = "pending"
    case accepted = "accepted"
    case blocked  = "blocked"
}

public enum FriendRequestStatus: String, Codable {
    case pending  = "pending"
    case accepted = "accepted"
    case declined = "declined"
}

// MARK: - User Stats (Firestore-backed XP/streak data)
struct UserStats {
    var totalXP: Int
    var streakDays: Int
    var graceTokens: Int
    var lastActivityDate: Date?
    var totalEventsCompleted: Int
    var criticalEventsCompleted: Int
    var earlyBirdEvents: Int
    var nightOwlEvents: Int
    var eventsCompletedToday: Int
}
