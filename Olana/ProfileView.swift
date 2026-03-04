//
//  ProfileView.swift (OPTIMIZED - Fixed for dailyQuests)
//  Olana
//
//  Performance Optimizations + Correct property names
//

import SwiftUI

struct ProfileView: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var xpManager = XPManager.shared
    
    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ OPTIMIZATION: Solid color instead of gradient
                theme.colors.canvasStart
                    .ignoresSafeArea()
                
                ScrollView {
                    // ✅ OPTIMIZATION: LazyVStack for progressive loading
                    LazyVStack(spacing: 28, pinnedViews: []) {
                        // Your Progress Card
                        ProgressSection(
                            streakDays: xpManager.streakDays,
                            graceTokens: xpManager.graceTokens,
                            totalXP: xpManager.totalXP
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        // Earned Badges Section
                        EarnedBadgesSection(
                            badges: xpManager.badges.filter { $0.isUnlocked }
                        )
                        .padding(.horizontal)
                        
                        // Daily Quests Section
                        DailyQuestsSection(
                            quests: xpManager.dailyQuests
                        )
                        .padding(.horizontal)
                        
                        // Statistics Section
                        StatisticsSection()
                        .padding(.horizontal)
                        
                        // Bottom spacing
                        Spacer()
                            .frame(height: 40)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Rewards")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Notifications action
                    } label: {
                        Image(systemName: "bell")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(theme.colors.paper.opacity(0.5))
                            )
                            .overlay(
                                Circle()
                                    .stroke(theme.colors.cardBorder, lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Progress Section
private struct ProgressSection: View {
    @Environment(\.olanaTheme) private var theme
    let streakDays: Int
    let graceTokens: Int
    let totalXP: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Progress")
                    .font(.title2.weight(.bold))
                Spacer()
                Image(systemName: "trophy.fill")
                    .font(.title2)
                    .foregroundStyle(theme.colors.ribbon)
            }
            
            HStack(spacing: 0) {
                // Streak Days
                StatColumn(
                    icon: "flame.fill",
                    iconColor: .orange,
                    value: "\(streakDays)",
                    label: "Streak Days"
                )
                
                Divider()
                    .frame(height: 60)
                    .background(Color.white.opacity(0.2))
                
                // Grace Tokens
                StatColumn(
                    icon: "sparkles",
                    iconColor: theme.colors.ribbon,
                    value: "\(graceTokens)",
                    label: "Grace Tokens"
                )
                
                Divider()
                    .frame(height: 60)
                    .background(Color.white.opacity(0.2))
                
                // Total XP
                StatColumn(
                    icon: "star.fill",
                    iconColor: .yellow,
                    value: formatXP(totalXP),
                    label: "Total XP"
                )
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(theme.colors.paper.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(theme.colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.2), radius: 24, x: 0, y: 12)
        // ✅ OPTIMIZATION: Rasterize complex view
        .drawingGroup()
    }
    
    private func formatXP(_ xp: Int) -> String {
        if xp >= 10000 {
            return String(format: "%.1fk", Double(xp) / 1000.0)
        } else if xp >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: xp)) ?? "\(xp)"
        }
        return "\(xp)"
    }
}

private struct StatColumn: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(iconColor)
            
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(theme.colors.ink)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Earned Badges Section
private struct EarnedBadgesSection: View {
    @Environment(\.olanaTheme) private var theme
    let badges: [Badge]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Earned Badges")
                    .font(.title2.weight(.bold))
                
                Spacer()
                
                Text("\(badges.count)/13")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            
            if badges.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trophy")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    
                    Text("No badges yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text("Complete events to unlock badges!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(theme.colors.paper.opacity(0.3))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(badges, id: \.id) { badge in
                            BadgeCard(badge: badge)
                        }
                    }
                }
            }
        }
    }
}

private struct BadgeCard: View {
    @Environment(\.olanaTheme) private var theme
    let badge: Badge
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: badge.icon)
                .font(.system(size: 36))
                .foregroundStyle(badge.color.color)
                .frame(width: 80, height: 80)
                .background(
                    Circle()
                        .fill(badge.color.color.opacity(0.1))
                )
                .overlay(
                    Circle()
                        .stroke(theme.colors.cardBorder, lineWidth: 1)
                )
                .shadow(color: badge.color.color.opacity(0.3), radius: 12, x: 0, y: 6)
            
            Text(badge.name)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.colors.ink)
            
            if let date = badge.unlockedAt {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.colors.paper.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(theme.colors.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.15), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Daily Quests Section
private struct DailyQuestsSection: View {
    @Environment(\.olanaTheme) private var theme
    let quests: [Quest]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daily Quests")
                .font(.title2.weight(.bold))
            
            let activeQuests = quests.filter { !$0.isCompleted }
            
            if activeQuests.isEmpty && !quests.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    
                    Text("All quests completed!")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text("Come back tomorrow for new quests")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.green.opacity(0.1))
                )
            } else {
                // ✅ OPTIMIZATION: LazyVStack for quest rows
                LazyVStack(spacing: 12) {
                    ForEach(quests, id: \.id) { quest in
                        QuestRow(quest: quest)
                    }
                }
            }
        }
    }
}

private struct QuestRow: View {
    @Environment(\.olanaTheme) private var theme
    let quest: Quest
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: quest.isCompleted ? "checkmark.circle.fill" : quest.icon)
                .font(.title2)
                .foregroundStyle(quest.isCompleted ? .green : quest.iconColor.color)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill((quest.isCompleted ? Color.green : quest.iconColor.color).opacity(0.12))
                )
                .overlay(
                    Circle()
                        .stroke(theme.colors.cardBorder, lineWidth: 0.5)
                )
                .shadow(color: (quest.isCompleted ? Color.green : quest.iconColor.color).opacity(0.2), radius: 6, x: 0, y: 3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(quest.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.colors.ink)
                    .strikethrough(quest.isCompleted)
                
                if quest.isCompleted {
                    Text("Completed! ✓")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(quest.progress), total: Double(quest.requirement.target))
                            .tint(quest.iconColor.color)
                            .frame(maxWidth: 100)
                        
                        Text("\(quest.progress)/\(quest.requirement.target)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if !quest.isCompleted {
                Text("+\(quest.xpReward) XP")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.yellow.opacity(0.15))
                    )
                    .foregroundStyle(.yellow)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.colors.paper.opacity(quest.isCompleted ? 0.3 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    quest.isCompleted ? Color.green.opacity(0.3) : Color.white.opacity(0.2),
                    lineWidth: quest.isCompleted ? 2 : 0.5
                )
        )
        .shadow(color: theme.colors.pillShadow.opacity(0.2), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Statistics Section
private struct StatisticsSection: View {
    @Environment(\.olanaTheme) private var theme
    @ObservedObject private var xpManager = XPManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Statistics")
                .font(.title2.weight(.bold))
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                StatCard(
                    icon: "checkmark.circle.fill",
                    label: "Total Events",
                    value: "\(xpManager.totalEventsCompleted)",
                    color: .green
                )
                
                StatCard(
                    icon: "flame.fill",
                    label: "Critical Events",
                    value: "\(xpManager.criticalEventsCompleted)",
                    color: .red
                )
                
                StatCard(
                    icon: "sunrise.fill",
                    label: "Early Bird",
                    value: "\(xpManager.earlyBirdEvents)",
                    color: .blue
                )
                
                StatCard(
                    icon: "moon.stars.fill",
                    label: "Night Owl",
                    value: "\(xpManager.nightOwlEvents)",
                    color: .purple
                )
            }
        }
    }
}

private struct StatCard: View {
    @Environment(\.olanaTheme) private var theme
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            Text(value)
                .font(.title.weight(.bold))
                .foregroundStyle(theme.colors.ink)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.colors.paper.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.colors.cardBorder, lineWidth: 0.5)
        )
    }
}

#Preview {
    ProfileView()
        .environmentObject(EventStore())
}
