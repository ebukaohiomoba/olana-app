//
//  FriendsView.swift
//  Olana
//

import SwiftUI
import FirebaseAuth

struct FriendsView: View {
    @Environment(\.olanaTheme) private var theme
    @EnvironmentObject private var authManager: AuthenticationManager

    @State private var showingAddFriend = false
    @State private var selectedTab: FriendsTab = .friends
    @State private var viewModel = FriendsViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                BackgroundGradient()

                VStack(spacing: 0) {
                    FriendsTabSelector(selectedTab: $selectedTab)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    Group {
                        switch selectedTab {
                        case .friends:
                            FriendsListView(
                                friends: viewModel.friends,
                                isEmpty: viewModel.friends.isEmpty,
                                onAddFriend: { showingAddFriend = true }
                            )
                        case .requests:
                            FriendRequestsListView(
                                requests: viewModel.pendingRequests,
                                isEmpty: viewModel.pendingRequests.isEmpty,
                                onHandleRequest: handleFriendRequest
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                // FAB — matches HomeView style exactly
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showingAddFriend = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(LinearGradient(
                                    colors: [theme.colors.ribbon, theme.colors.ribbon.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                        )
                        .shadow(color: theme.colors.ribbon.opacity(0.3), radius: 12, x: 0, y: 6)
                        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
                }
                .padding(.trailing, 24)
                .padding(.bottom, 20)
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddFriend) {
                AddFriendView()
                    .environmentObject(authManager)
            }
        }
        .task {
            viewModel.configure(with: authManager)
        }
        .onChange(of: authManager.currentUser?.uid) { _, _ in
            viewModel.configure(with: authManager)
        }
    }

    private func handleFriendRequest(_ request: FriendRequestDoc, action: FriendRequestAction) {
        Task {
            do {
                try await viewModel.handleFriendRequest(request, action: action)
            } catch {
                print("Error handling friend request: \(error)")
            }
        }
    }
}

// MARK: - Friends Tab Selector

enum FriendsTab: String, CaseIterable {
    case friends  = "Friends"
    case requests = "Requests"
}

private struct FriendsTabSelector: View {
    @Environment(\.olanaTheme) private var theme
    @Binding var selectedTab: FriendsTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(FriendsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? .white : theme.colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            ZStack {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(theme.colors.ribbon)
                                        .shadow(color: theme.colors.ribbon.opacity(0.3), radius: 8, x: 0, y: 4)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 20))
    }
}

#Preview {
    FriendsView()
        .environmentObject(AuthenticationManager())
        .olanaThemeProvider(variant: .system)
}
