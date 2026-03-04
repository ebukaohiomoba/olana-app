//
//  EventCompletionView.swift
//  Olana
//
//  Created by Chukwuebuka Ohiomoba on 11/30/25.
//


//
//  EventCompletionView.swift
//  Olana
//
//  Beautiful completion popup with XP rewards and positive reinforcement
//

import SwiftUI

// MARK: - Event Completion Popup
struct EventCompletionView: View {
    @Environment(\.olanaTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    
    let event: OlanaEvent
    let xpEarned: Int
    let rewards: [String]
    let newBadges: [Badge]
    
    @State private var showContent = false
    @State private var showXP = false
    @State private var showRewards = false
    @State private var showBadges = false
    @State private var confettiCounter = 0
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }
            
            // Main Card
            VStack(spacing: 0) {
                // Celebration Header
                CelebrationHeader(urgency: event.urgency)
                    .opacity(showContent ? 1 : 0)
                    .scaleEffect(showContent ? 1 : 0.5)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: showContent)
                
                // Event Title
                VStack(spacing: 12) {
                    Text("You completed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text(event.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.colors.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
                .animation(.spring(response: 0.6).delay(0.2), value: showContent)
                
                // XP Earned
                XPBadge(xp: xpEarned, urgency: event.urgency)
                    .padding(.top, 24)
                    .opacity(showXP ? 1 : 0)
                    .scaleEffect(showXP ? 1 : 0.5)
                    .animation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.4), value: showXP)
                
                // Rewards List
                if !rewards.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(Array(rewards.enumerated()), id: \.offset) { index, reward in
                            RewardRow(reward: reward)
                                .opacity(showRewards ? 1 : 0)
                                .offset(x: showRewards ? 0 : -20)
                                .animation(.spring(response: 0.6).delay(0.6 + Double(index) * 0.1), value: showRewards)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                }
                
                // New Badges
                if !newBadges.isEmpty {
                    VStack(spacing: 16) {
                        Text("🎖️ New Badge\(newBadges.count > 1 ? "s" : "") Unlocked!")
                            .font(.headline)
                            .foregroundStyle(theme.colors.ribbon)
                        
                        ForEach(newBadges) { badge in
                            NewBadgeCard(badge: badge)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                    .opacity(showBadges ? 1 : 0)
                    .scaleEffect(showBadges ? 1 : 0.8)
                    .animation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.8), value: showBadges)
                }
                
                // Positive Message
                MotivationalMessage(urgency: event.urgency)
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                    .opacity(showContent ? 1 : 0)
                    .animation(.easeIn.delay(1.0), value: showContent)
                
                // Done Button
                Button(action: {
                    dismiss()
                }) {
                    Text("Awesome!")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [theme.colors.ribbon, theme.colors.ribbon.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: theme.colors.ribbon.opacity(0.4), radius: 12, x: 0, y: 6)
                }
                .padding(24)
                .opacity(showContent ? 1 : 0)
                .animation(.easeIn.delay(1.2), value: showContent)
            }
            .frame(maxWidth: 500)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(
                        LinearGradient(
                            colors: [theme.colors.canvasStart, theme.colors.canvasEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 40, x: 0, y: 20)
            .padding(.horizontal, 32)
            .scaleEffect(showContent ? 1 : 0.8)
            .opacity(showContent ? 1 : 0)
            
            // Confetti
            ConfettiView(counter: $confettiCounter)
        }
        .onAppear {
            showContent = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showXP = true
                confettiCounter += 1
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showRewards = true
            }
            
            if !newBadges.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    showBadges = true
                    confettiCounter += 1
                }
            }
        }
    }
}

// MARK: - Celebration Header
private struct CelebrationHeader: View {
    @Environment(\.olanaTheme) private var theme
    let urgency: EventUrgency
    
    private var emoji: String {
        switch urgency {
        case .high: return "🎉"
        case .medium: return "✨"
        case .low: return "👏"
        }
    }
    
    private var color: Color {
        switch urgency {
        case .high: return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low: return theme.colors.urgencyLow
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text(emoji)
                .font(.system(size: 72))
            
            Text("Great Job!")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color, color.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .padding(.top, 32)
    }
}

// MARK: - XP Badge
private struct XPBadge: View {
    @Environment(\.olanaTheme) private var theme
    let xp: Int
    let urgency: EventUrgency
    
    private var color: Color {
        switch urgency {
        case .high: return theme.colors.urgencyHigh
        case .medium: return theme.colors.urgencyMedium
        case .low: return theme.colors.urgencyLow
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.title2)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("+\(xp)")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color, color.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("XP")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.3), lineWidth: 2)
                )
        )
        .shadow(color: color.opacity(0.3), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Reward Row
private struct RewardRow: View {
    @Environment(\.olanaTheme) private var theme
    let reward: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            
            Text(reward)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.colors.ink)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.colors.paper.opacity(0.5))
        )
    }
}

// MARK: - New Badge Card
private struct NewBadgeCard: View {
    @Environment(\.olanaTheme) private var theme
    let badge: Badge
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: badge.icon)
                .font(.system(size: 32))
                .foregroundStyle(badge.color.color)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(badge.color.color.opacity(0.15))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(badge.name)
                    .font(.headline)
                    .foregroundStyle(theme.colors.ink)
                
                Text(badge.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.colors.paper.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(badge.color.color.opacity(0.3), lineWidth: 2)
                )
        )
        .shadow(color: badge.color.color.opacity(0.2), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Motivational Message
private struct MotivationalMessage: View {
    let urgency: EventUrgency
    
    private var messages: [String] {
        switch urgency {
        case .high:
            return [
                "You crushed that critical task! 💪",
                "Nothing can stop you now!",
                "That was a big one - well done!",
                "You're on fire! Keep it up! 🔥"
            ]
        case .medium:
            return [
                "One step closer to your goals! ✨",
                "You're building great momentum!",
                "Keep up the excellent work!",
                "Progress looks good on you! 📈"
            ]
        case .low:
            return [
                "Every task completed counts! 🌟",
                "Small wins lead to big victories!",
                "You're making steady progress!",
                "Consistency is key - nice work! 🎯"
            ]
        }
    }
    
    var body: some View {
        Text(messages.randomElement() ?? "Great job!")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Confetti View
private struct ConfettiView: View {
    @Binding var counter: Int
    
    var body: some View {
        ZStack {
            ForEach(0..<50, id: \.self) { index in
                CompletionConfettiPiece(counter: counter, index: index)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CompletionConfettiPiece: View {
    let counter: Int
    let index: Int
    
    @State private var location: CGPoint = .zero
    @State private var opacity: Double = 0
    
    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
    
    var body: some View {
        Circle()
            .fill(colors[index % colors.count])
            .frame(width: 8, height: 8)
            .position(location)
            .opacity(opacity)
            .onChange(of: counter) { _, _ in
                animate()
            }
    }
    
    private func animate() {
        // Random start position at top
        let startX = CGFloat.random(in: 100...300)
        let startY: CGFloat = -20
        
        // Random end position
        let endX = startX + CGFloat.random(in: -100...100)
        let endY = CGFloat.random(in: 600...800)
        
        location = CGPoint(x: startX, y: startY)
        opacity = 1
        
        withAnimation(.easeOut(duration: 1.5).delay(Double(index) * 0.01)) {
            location = CGPoint(x: endX, y: endY)
            opacity = 0
        }
    }
}

// MARK: - Preview
#Preview {
    EventCompletionView(
        event: OlanaEvent(
            title: "Finish quarterly report",
            start: Date(),
            end: Date().addingTimeInterval(3600),
            urgency: .high
        ),
        xpEarned: 150,
        rewards: ["Critical Event Crushed!", "First of the Day!"],
        newBadges: [
            Badge(
                id: "streak_7",
                icon: "flame.fill",
                name: "Streak Starter",
                description: "Maintain a 7-day streak",
                color: CodableColor(.orange),
                requirement: .streakDays(7),
                unlockedAt: Date()
            )
        ]
    )
}
