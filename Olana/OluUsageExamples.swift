import SwiftUI
import Combine

// ─────────────────────────────────────────────
// MARK: — Example: Home Screen
// ─────────────────────────────────────────────

struct OluExampleHomeView: View {
    @StateObject private var olu = OluManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // ── Header with Olu ──
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Olanna")
                            .font(.custom("PlayfairDisplay-SemiBold", size: 28))
                        Text(greetingText)
                            .font(.custom("DMSans-Light", size: 13))
                            .italic()
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Drop Olu in anywhere with one line
                    OluView(state: $olu.state, size: 58)
                }
                .padding(.horizontal, 24)

                // ── Task list ──
                TaskListView(onTaskComplete: {
                    // Trigger celebration when a task is finished
                    olu.celebrate()
                })
            }
        }
        // Tell Olu when user is actively scrolling
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in olu.userDidInteract() }
        )
        // Update for time of day when app comes to foreground
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            olu.updateForTimeOfDay()
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12:  return "Good morning, Adaeze ✦"
        case 12..<17: return "Good afternoon, Adaeze ✦"
        case 17..<21: return "Good evening, Adaeze ✦"
        default:      return "Rest well, Adaeze 🌙"
        }
    }
}

// ─────────────────────────────────────────────
// MARK: — Olu in other contexts
// ─────────────────────────────────────────────

// Friend card — show each friend's Olu at a smaller size
struct FriendOluView: View {
    let friendName: String
    let isActive: Bool
    @State private var state: OluState = .resting

    var body: some View {
        VStack(spacing: 8) {
            OluView(state: $state, size: 44)
            Text(friendName)
                .font(.custom("DMSans-Medium", size: 11))
            Circle()
                .fill(isActive ? Color(hex: "F0A500") : Color(hex: "F0E6CC"))
                .frame(width: 7, height: 7)
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
    }
}

// Nudge banner — mini Olu
struct NudgeBannerView: View {
    let message: String
    @State private var oluState: OluState = .resting

    var body: some View {
        HStack(spacing: 11) {
            OluView(state: $oluState, size: 36)
            Text(message)
                .font(.custom("DMSans-Regular", size: 12.5))
                .foregroundColor(Color(hex: "5C3D1E"))
                .lineSpacing(4)
            Spacer()
        }
        .padding(12)
        .background(Color(hex: "FFF8E7"))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(hex: "F0A500").opacity(0.28), lineWidth: 1.5)
        )
        .cornerRadius(18)
    }
}

// ─────────────────────────────────────────────
// MARK: — Placeholder (replace with your real task list)
// ─────────────────────────────────────────────

struct TaskListView: View {
    var onTaskComplete: () -> Void
    var body: some View {
        Button("Complete a task") { onTaskComplete() }
    }
}
