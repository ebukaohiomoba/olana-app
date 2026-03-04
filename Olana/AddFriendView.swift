//
//  AddFriendView.swift
//  Olana
//

import SwiftUI
import FirebaseAuth

struct AddFriendView: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthenticationManager

    @State private var searchText = ""
    @State private var selectedSearchType: SearchType = .username
    @State private var searchResults: [AppUser] = []
    @State private var isSearching = false
    @State private var showingSuccess = false
    @State private var successMessage = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var sentRequestIds: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    searchTypeSelector.padding(.horizontal)
                    searchField.padding(.horizontal)

                    if searchText.isEmpty {
                        emptySearchState
                    } else if isSearching {
                        ProgressView()
                            .tint(theme.colors.ribbon)
                            .padding(.top, 32)
                    } else if searchResults.isEmpty {
                        noResultsState
                    } else {
                        searchResultsList
                    }

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.colors.ink)
                }
            }
            .alert("Friend Request Sent", isPresented: $showingSuccess) {
                Button("OK") {}
            } message: {
                Text(successMessage)
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(query: newValue)
        }
    }

    // MARK: - Search

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            // Debounce
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            var results = try await FirestoreService.shared.searchUsers(
                by: query.lowercased(),
                type: selectedSearchType
            )
            if let uid = authManager.currentUser?.uid {
                results = results.filter { $0.id != uid }
            }
            searchResults = results
        } catch {
            searchResults = []
        }
    }

    // MARK: - Send Request

    private func sendFriendRequest(to recipient: AppUser) {
        guard let sender = authManager.appUser else { return }
        sentRequestIds.insert(recipient.id)
        Task {
            do {
                try await FirestoreService.shared.sendFriendRequest(from: sender, to: recipient.id)
                successMessage = "Friend request sent to \(recipient.displayName)!"
                showingSuccess = true
            } catch {
                sentRequestIds.remove(recipient.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var searchTypeSelector: some View {
        HStack(spacing: 8) {
            ForEach(SearchType.allCases, id: \.self) { type in
                Button {
                    selectedSearchType = type
                    if !searchText.isEmpty { scheduleSearch(query: searchText) }
                } label: {
                    Text(type.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(selectedSearchType == type ? .white : theme.colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                if selectedSearchType == type {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(theme.colors.ribbon)
                                        .shadow(color: theme.colors.ribbon.opacity(0.3), radius: 6, x: 0, y: 3)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.cardBorder, lineWidth: 0.5))
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Search by \(selectedSearchType.displayName.lowercased())...", text: $searchText)
                .font(.body)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.colors.cardBorder, lineWidth: 0.5))
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(searchResults) { user in
                    SearchResultCard(
                        user: user,
                        requestSent: sentRequestIds.contains(user.id)
                    ) { sendFriendRequest(to: user) }
                        .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var emptySearchState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("Find Friends")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)

                Text("Search by \(selectedSearchType.displayName.lowercased()) to find and add friends")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.5)), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.colors.cardBorder, lineWidth: 0.5))
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 12, x: 0, y: 6)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("No Results")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)

                Text("No users found matching '\(searchText)'")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.5)), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.colors.cardBorder, lineWidth: 0.5))
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 12, x: 0, y: 6)
        .padding(.horizontal)
    }
}

// MARK: - Search Result Card

private struct SearchResultCard: View {
    @Environment(\.olanaTheme) private var theme
    let user: AppUser
    let requestSent: Bool
    let onSendRequest: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(user.profileEmoji)
                .font(.system(size: 32))
                .frame(width: 48, height: 48)
                .glassEffect(.regular.tint(theme.colors.ribbon.opacity(0.1)), in: .circle)
                .overlay(Circle().stroke(theme.colors.cardBorder, lineWidth: 0.5))
                .shadow(color: theme.colors.ribbon.opacity(0.2), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                    .lineLimit(1)

                Text("@\(user.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 16) {
                    QuickStat(icon: "flame.fill", color: .orange, value: user.streakDays)
                    QuickStat(icon: "star.fill", color: .yellow, value: user.totalXP)
                }
            }

            Spacer(minLength: 0)

            Button(action: onSendRequest) {
                Group {
                    if requestSent {
                        Label("Sent", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.colors.slate)
                    } else {
                        Text("Add")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(requestSent ? theme.colors.slate.opacity(0.15) : theme.colors.ribbon)
                )
            }
            .buttonStyle(.plain)
            .disabled(requestSent)
        }
        .padding(16)
        .glassEffect(.regular.tint(theme.colors.paper.opacity(0.6)), in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.3), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.2), radius: 12, x: 0, y: 6)
    }
}

private struct QuickStat: View {
    let icon: String
    let color: Color
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text("\(value)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    AddFriendView()
        .environmentObject(AuthenticationManager())
        .olanaThemeProvider(variant: .system)
}
