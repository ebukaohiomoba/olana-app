//
//  FriendsViewModel.swift
//  Olana
//

import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
@Observable
final class FriendsViewModel {

    // MARK: - State
    var friends: [AppUser] = []
    var pendingRequests: [FriendRequestDoc] = []
    var isLoading = false
    var errorMessage: String?

    // MARK: - Private
    private weak var authManager: AuthenticationManager?
    nonisolated(unsafe) private var friendsListener: ListenerRegistration?

    // MARK: - Configuration

    func configure(with authManager: AuthenticationManager) {
        self.authManager = authManager
        guard let uid = authManager.currentUser?.uid else { return }
        startListeningToFriends(uid: uid)
        loadRequests(for: uid)
    }

    // MARK: - Data Loading

    func loadRequests(for uid: String) {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                pendingRequests = try await FirestoreService.shared.fetchFriendRequests(for: uid)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startListeningToFriends(uid: String) {
        friendsListener?.remove()
        friendsListener = FirestoreService.shared.listenToFriends(uid: uid) { [weak self] updatedFriends in
            self?.friends = updatedFriends
        }
    }

    // MARK: - Friend Request Handling

    func handleFriendRequest(_ request: FriendRequestDoc, action: FriendRequestAction) async throws {
        guard let uid = authManager?.currentUser?.uid else {
            throw FriendsError.invalidRequest
        }
        try await FirestoreService.shared.handleFriendRequest(request, action: action, currentUserId: uid)
        // Refresh pending requests after handling
        loadRequests(for: uid)
    }

    deinit {
        friendsListener?.remove()
    }
}

// MARK: - Errors

enum FriendsError: Error, LocalizedError {
    case invalidRequest
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid friend request."
        case .userNotFound:   return "User not found."
        }
    }
}
