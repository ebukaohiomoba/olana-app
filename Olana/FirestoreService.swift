//
//  FirestoreService.swift
//  Olana
//
//  CRUD operations for Firestore: users, friends, friend requests.
//

import Foundation
import FirebaseFirestore

final class FirestoreService {

    static let shared = FirestoreService()
    private let db = Firestore.firestore()

    private init() {}

    // MARK: - Users

    func createUser(_ user: AppUser) async throws {
        var data = try Firestore.Encoder().encode(user)
        // Ensure the id field is stored in the document as well
        data["id"] = user.id
        try await db.collection("users").document(user.id).setData(data)
    }

    func fetchUser(uid: String) async throws -> AppUser? {
        let snapshot = try await db.collection("users").document(uid).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return decodeAppUser(from: data, documentID: snapshot.documentID)
    }

    func updateUser(_ user: AppUser) async throws {
        var data = try Firestore.Encoder().encode(user)
        data["id"] = user.id
        try await db.collection("users").document(user.id).setData(data, merge: true)
    }

    /// Check if a username is already taken (exact match, case-insensitive).
    func isUsernameTaken(_ username: String) async throws -> Bool {
        let lower = username.lowercased()
        return try await withTimeout(seconds: 8) {
            let snapshot = try await self.db.collection("users")
                .whereField("username", isEqualTo: lower)
                .limit(to: 1)
                .getDocuments()
            return !snapshot.documents.isEmpty
        }
    }

    // Races an async operation against a timeout; throws URLError.timedOut if exceeded.
    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Update only the username field on a user document (creates the field if missing).
    func updateUsername(uid: String, username: String) async throws {
        let lower = username.lowercased()
        try await db.collection("users").document(uid).setData(["username": lower], merge: true)
    }

    /// Prefix-match search. Pass `type: .username` to search usernames (lowercase),
    /// or `type: .displayName` to search the displayName field.
    func searchUsers(by query: String, type: SearchType = .username) async throws -> [AppUser] {
        guard !query.isEmpty else { return [] }
        let field = type == .username ? "username" : "displayName"
        let snapshot = try await db.collection("users")
            .whereField(field, isGreaterThanOrEqualTo: query)
            .whereField(field, isLessThan: query + "\u{f8ff}")
            .limit(to: 20)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            decodeAppUser(from: doc.data(), documentID: doc.documentID)
        }
    }

    // MARK: - Friend Requests

    func sendFriendRequest(
        from sender: AppUser,
        to receiverId: String,
        message: String? = nil
    ) async throws {
        let requestId = UUID().uuidString
        var data: [String: Any] = [
            "id": requestId,
            "senderId": sender.id,
            "senderName": sender.displayName,
            "senderEmoji": sender.profileEmoji,
            "receiverId": receiverId,
            "status": "pending",
            "sentAt": Timestamp(date: Date())
        ]
        if let message { data["message"] = message }
        try await db.collection("friendRequests").document(requestId).setData(data)
    }

    func fetchFriendRequests(for uid: String) async throws -> [FriendRequestDoc] {
        let snapshot = try await db.collection("friendRequests")
            .whereField("receiverId", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        return snapshot.documents.compactMap { decodeFriendRequest(from: $0.data(), documentID: $0.documentID) }
    }

    func handleFriendRequest(
        _ request: FriendRequestDoc,
        action: FriendRequestAction,
        currentUserId: String
    ) async throws {
        let requestRef = db.collection("friendRequests").document(request.id)

        switch action {
        case .decline:
            try await requestRef.updateData(["status": "declined"])

        case .accept:
            try await requestRef.updateData(["status": "accepted"])

            // Fetch both users for denormalized friend entries
            async let senderFetch  = fetchUser(uid: request.senderId)
            async let selfFetch    = fetchUser(uid: currentUserId)
            let (sender, selfUser) = try await (senderFetch, selfFetch)

            guard let sender, let selfUser else { return }
            let now = Timestamp(date: Date())
            let batch = db.batch()

            // Add sender under current user's /friends subcollection
            let ref1 = db.collection("users").document(currentUserId)
                .collection("friends").document(sender.id)
            batch.setData([
                "displayName":  sender.displayName,
                "profileEmoji": sender.profileEmoji,
                "createdAt":    now
            ], forDocument: ref1)

            // Add current user under sender's /friends subcollection
            let ref2 = db.collection("users").document(sender.id)
                .collection("friends").document(currentUserId)
            batch.setData([
                "displayName":  selfUser.displayName,
                "profileEmoji": selfUser.profileEmoji,
                "createdAt":    now
            ], forDocument: ref2)

            try await batch.commit()
        }
    }

    // MARK: - Friends

    func fetchFriends(for uid: String) async throws -> [AppUser] {
        let snapshot = try await db.collection("users").document(uid)
            .collection("friends").getDocuments()

        let friendIds = snapshot.documents.map { $0.documentID }
        var friends: [AppUser] = []
        for friendId in friendIds {
            if let friend = try await fetchUser(uid: friendId) {
                friends.append(friend)
            }
        }
        return friends
    }

    /// Attaches a real-time listener to the friends subcollection.
    /// Returns a `ListenerRegistration` the caller must retain and call `.remove()` on when done.
    func listenToFriends(uid: String, onChange: @escaping ([AppUser]) -> Void) -> ListenerRegistration {
        db.collection("users").document(uid).collection("friends")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, let snapshot, error == nil else { return }
                let friendIds = snapshot.documents.map { $0.documentID }
                Task { [weak self] in
                    guard let self else { return }
                    var friends: [AppUser] = []
                    for friendId in friendIds {
                        if let friend = try? await self.fetchUser(uid: friendId) {
                            friends.append(friend)
                        }
                    }
                    await MainActor.run { onChange(friends) }
                }
            }
    }

    // MARK: - User Stats

    func fetchUserStats(uid: String) async throws -> UserStats? {
        let snapshot = try await db.collection("users").document(uid).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return UserStats(
            totalXP:               data["totalXP"]               as? Int ?? 0,
            streakDays:            data["streakDays"]            as? Int ?? 0,
            graceTokens:           data["graceTokens"]           as? Int ?? 2,
            lastActivityDate:      (data["lastActivityDate"]     as? Timestamp)?.dateValue(),
            totalEventsCompleted:  data["totalEventsCompleted"]  as? Int ?? 0,
            criticalEventsCompleted: data["criticalEventsCompleted"] as? Int ?? 0,
            earlyBirdEvents:       data["earlyBirdEvents"]       as? Int ?? 0,
            nightOwlEvents:        data["nightOwlEvents"]        as? Int ?? 0,
            eventsCompletedToday:  data["eventsCompletedToday"]  as? Int ?? 0
        )
    }

    func updateUserStats(
        uid: String,
        totalXP: Int,
        streakDays: Int,
        graceTokens: Int,
        lastActivityDate: Date?,
        totalEventsCompleted: Int,
        criticalEventsCompleted: Int,
        earlyBirdEvents: Int,
        nightOwlEvents: Int,
        eventsCompletedToday: Int
    ) async throws {
        var data: [String: Any] = [
            "totalXP":                 totalXP,
            "streakDays":              streakDays,
            "graceTokens":             graceTokens,
            "totalEventsCompleted":    totalEventsCompleted,
            "criticalEventsCompleted": criticalEventsCompleted,
            "earlyBirdEvents":         earlyBirdEvents,
            "nightOwlEvents":          nightOwlEvents,
            "eventsCompletedToday":    eventsCompletedToday,
            "lastActiveAt":            Timestamp(date: Date())
        ]
        if let date = lastActivityDate {
            data["lastActivityDate"] = Timestamp(date: date)
        }
        try await db.collection("users").document(uid).setData(data, merge: true)
    }

    // MARK: - Decoders

    private func decodeAppUser(from data: [String: Any], documentID: String) -> AppUser? {
        guard
            let id           = data["id"]           as? String ?? Optional(documentID),
            let username     = data["username"]     as? String,
            let displayName  = data["displayName"]  as? String,
            let email        = data["email"]        as? String,
            let profileEmoji = data["profileEmoji"] as? String,
            let streakDays   = data["streakDays"]   as? Int,
            let graceTokens  = data["graceTokens"]  as? Int,
            let totalXP      = data["totalXP"]      as? Int,
            let joinedAt     = (data["joinedAt"]    as? Timestamp)?.dateValue(),
            let lastActiveAt = (data["lastActiveAt"] as? Timestamp)?.dateValue()
        else { return nil }

        return AppUser(
            id: id,
            username: username,
            displayName: displayName,
            email: email,
            profileEmoji: profileEmoji,
            streakDays: streakDays,
            graceTokens: graceTokens,
            totalXP: totalXP,
            joinedAt: joinedAt,
            lastActiveAt: lastActiveAt
        )
    }

    private func decodeFriendRequest(from data: [String: Any], documentID: String) -> FriendRequestDoc? {
        guard
            let senderId    = data["senderId"]    as? String,
            let senderName  = data["senderName"]  as? String,
            let receiverId  = data["receiverId"]  as? String,
            let status      = data["status"]      as? String,
            let sentAt      = (data["sentAt"]     as? Timestamp)?.dateValue()
        else { return nil }

        return FriendRequestDoc(
            id: documentID,
            senderId: senderId,
            senderName: senderName,
            senderEmoji: data["senderEmoji"] as? String ?? "👤",
            receiverId: receiverId,
            status: status,
            sentAt: sentAt,
            message: data["message"] as? String
        )
    }
}
