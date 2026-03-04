import SwiftUI

struct TMinusFiveBanner: View {
    @Environment(\.olanaTheme) private var theme

    var title: String
    var reasons: [String] = []
    var onStart: () -> Void
    var onSnooze: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lamp.desk.fill")
                .foregroundStyle(theme.colors.ribbon)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start now?")
                    .font(.headline.weight(.semibold))
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)
                if !reasons.isEmpty {
                    Text("because: " + reasons.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Start") { onStart() }
                .buttonStyle(.borderedProminent)
            Menu("Snooze") {
                Button("5 minutes") { onSnooze(5 * 60) }
                Button("10 minutes") { onSnooze(10 * 60) }
                Button("15 minutes") { onSnooze(15 * 60) }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.colors.paper)
                .shadow(color: theme.colors.pillShadow, radius: 12, x: 0, y: 6)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start now banner")
    }
}

#Preview {
    TMinusFiveBanner(title: "Review with Maya", reasons: ["starts in 5m", "attendee: Maya"], onStart: {}, onSnooze: { _ in })
        .environment(\.olanaTheme, OlanaTheme.light)
}
