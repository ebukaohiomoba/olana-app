//
//  FriendsViewComponents.swift
//  Olana
//

import SwiftUI

// MARK: - Main List Components

struct FriendsListView: View {
    @Environment(\.olanaTheme) private var theme
    let friends: [AppUser]
    let isEmpty: Bool
    let onAddFriend: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isEmpty {
                    EmptyFriendsState(onAddFriend: onAddFriend)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(friends) { friend in
                            FriendCard(friend: friend)
                        }
                    }
                }
                Spacer(minLength: 40)
            }
            .padding(.top, 16)
            .padding(.horizontal)
        }
    }
}

struct FriendRequestsListView: View {
    @Environment(\.olanaTheme) private var theme
    let requests: [FriendRequestDoc]
    let isEmpty: Bool
    let onHandleRequest: (FriendRequestDoc, FriendRequestAction) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isEmpty {
                    EmptyRequestsState()
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(requests) { request in
                            FriendRequestCard(request: request, onHandle: onHandleRequest)
                        }
                    }
                }
                Spacer(minLength: 40)
            }
            .padding(.top, 16)
            .padding(.horizontal)
        }
    }
}

// MARK: - Card Components

struct FriendCard: View {
    @Environment(\.olanaTheme) private var theme
    let friend: AppUser

    var body: some View {
        HStack(spacing: 16) {
            ProfileEmoji(emoji: friend.profileEmoji, size: 24, frameSize: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.displayName)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)

                Text("@\(friend.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                StatMini(
                    icon: "flame.fill",
                    iconColor: .orange,
                    value: "\(friend.streakDays)",
                    label: "Streak"
                )
                StatMini(
                    icon: "star.fill",
                    iconColor: theme.colors.ribbon,
                    value: "\(friend.totalXP)",
                    label: "XP"
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.colors.cardBorder, lineWidth: 0.5)
                )
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.1), radius: 12, x: 0, y: 6)
    }
}

struct FriendRequestCard: View {
    @Environment(\.olanaTheme) private var theme
    let request: FriendRequestDoc
    let onHandle: (FriendRequestDoc, FriendRequestAction) -> Void

    var body: some View {
        HStack(spacing: 16) {
            ProfileEmoji(emoji: request.senderEmoji, size: 20, frameSize: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(request.senderName)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)

                Text("Wants to be friends")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(request.sentAt.timeAgoDisplay)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onHandle(request, .decline)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)

                Button {
                    onHandle(request, .accept)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.colors.cardBorder, lineWidth: 0.5)
                )
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.1), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Reusable Components

struct BackgroundGradient: View {
    @Environment(\.olanaTheme) private var theme

    var body: some View {
        LinearGradient(
            colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct AddFriendButton: View {
    @Environment(\.olanaTheme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.badge.plus")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(theme.colors.cardBorder, lineWidth: 0.5))
                )
        }
    }
}

struct ProfileEmoji: View {
    @Environment(\.olanaTheme) private var theme
    let emoji: String
    let size: CGFloat
    let frameSize: CGFloat

    var body: some View {
        Text(emoji)
            .font(.system(size: size))
            .frame(width: frameSize, height: frameSize)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(theme.colors.cardBorder, lineWidth: 1))
            )
            .shadow(color: theme.colors.ribbon.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct EmptyFriendsState: View {
    @Environment(\.olanaTheme) private var theme
    let onAddFriend: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.ribbon.opacity(0.5))

            VStack(spacing: 8) {
                Text("No Friends Yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)

                Text("Add friends to see their progress and badges")
                    .font(.body)
                    .foregroundStyle(theme.colors.slate)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(theme.colors.paper)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.colors.cardBorder, lineWidth: 1))
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 16, x: 0, y: 8)
    }
}

struct EmptyRequestsState: View {
    @Environment(\.olanaTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope")
                .font(.system(size: 48))
                .foregroundStyle(theme.colors.ribbon.opacity(0.5))

            VStack(spacing: 8) {
                Text("No Pending Requests")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)

                Text("Friend requests will appear here")
                    .font(.body)
                    .foregroundStyle(theme.colors.slate)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(theme.colors.paper)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.colors.cardBorder, lineWidth: 1))
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Helper Components

private struct StatMini: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.colors.ink)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 32)
    }
}

// MARK: - Date Extension
extension Date {
    var timeAgoDisplay: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
