import SwiftUI
import Combine
import Lottie

// ─────────────────────────────────────────────
// MARK: — Olu States
// ─────────────────────────────────────────────

enum OluState {
    case resting    // default — app open, no activity
    case idle       // user actively engaging
    case sleep      // night mode (9pm–6am)
    case celebrate  // task completed or friend checks in

    var filename: String {
        switch self {
        case .resting:   return "olu_resting"
        case .idle:      return "olu_idle"
        case .sleep:     return "olu_sleep"
        case .celebrate: return "olu_celebrate"
        }
    }

    var looping: LottieLoopMode {
        switch self {
        case .celebrate: return .playOnce   // plays once then returns to resting
        default:         return .loop
        }
    }

    /// Automatically determine state based on time of day
    static var timeBasedState: OluState {
        let hour = Calendar.current.component(.hour, from: Date())
        return (hour >= 21 || hour < 6) ? .sleep : .resting
    }
}

// ─────────────────────────────────────────────
// MARK: — OluView (SwiftUI)
// ─────────────────────────────────────────────

struct OluView: View {
    @Binding var state: OluState
    var size: CGFloat = 58
    var onCelebrationComplete: (() -> Void)? = nil

    var body: some View {
        ZStack {
            OluLottieView(
                state: state,
                size: size,
                onCelebrationComplete: onCelebrationComplete
            )
            .frame(width: size, height: size)

            if state == .sleep {
                SleepZzzView(size: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: state == .sleep)
    }
}

// ─────────────────────────────────────────────
// MARK: — Sleep Z's
// ─────────────────────────────────────────────

private struct SleepZzzView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // smallest z — lowest, nearest the head
            FloatingZ(text: "z", fontSize: size * 0.09, delay: 0.0)
                .offset(x: size * 0.24, y: -(size * 0.22))
            // medium z
            FloatingZ(text: "z", fontSize: size * 0.12, delay: 0.9)
                .offset(x: size * 0.29, y: -(size * 0.30))
            // large Z — highest
            FloatingZ(text: "Z", fontSize: size * 0.15, delay: 1.8)
                .offset(x: size * 0.33, y: -(size * 0.38))
        }
        .allowsHitTesting(false)
    }
}

private struct FloatingZ: View {
    let text: String
    let fontSize: CGFloat
    let delay: Double

    @State private var animate = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(Color(hex: "9A4902").opacity(0.55))
            .opacity(animate ? 0 : 1)
            .scaleEffect(animate ? 1.1 : 0.9)
            .offset(y: animate ? -32 : 0)
            .onAppear {
                withAnimation(
                    Animation.easeOut(duration: 2.4)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    animate = true
                }
            }
            .onDisappear { animate = false }
    }
}

// ─────────────────────────────────────────────
// MARK: — UIKit bridge (LottieAnimationView)
// ─────────────────────────────────────────────

struct OluLottieView: UIViewRepresentable {
    let state: OluState
    let size: CGFloat
    var onCelebrationComplete: (() -> Void)?

    // Returns a plain UIView container. LottieAnimationView's intrinsic content
    // size (matching its 1024×1024 canvas) fights SwiftUI layout when returned
    // directly — the container has no intrinsic size so sizeThatFits drives it.
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        // CoreAnimation renderer offloads animation compositing to the GPU,
        // dramatically reducing CPU usage and eliminating overheating.
        let config = LottieConfiguration(renderingEngine: .coreAnimation)
        let lottieView = LottieAnimationView(configuration: config)
        lottieView.contentMode = .scaleAspectFit
        lottieView.backgroundBehavior = .pauseAndRestore
        lottieView.backgroundColor = .clear
        lottieView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lottieView)
        NSLayoutConstraint.activate([
            lottieView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lottieView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lottieView.topAnchor.constraint(equalTo: container.topAnchor),
            lottieView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.lottieView = lottieView
        load(state: state, into: lottieView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        guard coord.currentState != state,
              let lottieView = coord.lottieView,
              !coord.isTransitioning else { return }
        coord.currentState = state
        crossfade(to: state, lottieView: lottieView, container: uiView, coordinator: coord)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    // Initial load — no fade, plays immediately on first appearance.
    private func load(state: OluState, into view: LottieAnimationView) {
        view.stop()
        view.animation = LottieAnimation.named(state.filename)
                      ?? LottieAnimation.named("olu_resting")
        play(state: state, on: view)
    }

    // State transitions — fade out, swap, fade in.
    private func crossfade(to newState: OluState,
                           lottieView: LottieAnimationView,
                           container: UIView,
                           coordinator: Coordinator) {
        coordinator.isTransitioning = true

        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn, animations: {
            container.alpha = 0
        }) { _ in
            lottieView.stop()
            lottieView.animation = LottieAnimation.named(newState.filename)
                                ?? LottieAnimation.named("olu_resting")
            self.play(state: newState, on: lottieView)

            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
                container.alpha = 1
            }) { _ in
                coordinator.isTransitioning = false
            }
        }
    }

    private func play(state: OluState, on view: LottieAnimationView) {
        switch state {
        case .celebrate:
            view.play { finished in
                if finished { onCelebrationComplete?() }
            }
        default:
            view.loopMode = state.looping
            view.play()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    class Coordinator {
        var currentState: OluState
        var lottieView: LottieAnimationView?
        var isTransitioning = false
        init(state: OluState) { self.currentState = state }
    }
}

// ─────────────────────────────────────────────
// MARK: — OluManager (state logic)
// ─────────────────────────────────────────────

@MainActor
class OluManager: ObservableObject {
    @Published var state: OluState = .timeBasedState

    private var inactivityTimer: Timer?
    private var timeObserverTimer: Timer?
    private let inactivityThreshold: TimeInterval = 10 // seconds
    private var lastInteractTime: Date = .distantPast  // throttle for 60fps gestures

    init() {
        startTimeObserver()
    }

    deinit {
        inactivityTimer?.invalidate()
        timeObserverTimer?.invalidate()
    }

    // Call this when the user starts interacting (scrolling, tapping)
    func userDidInteract() {
        guard state != .celebrate else { return }
        // Throttle: DragGesture fires at ~60fps — only restart timer every 0.5s
        let now = Date()
        guard now.timeIntervalSince(lastInteractTime) >= 0.5 else { return }
        lastInteractTime = now
        cancelInactivityTimer()
        setState(.idle)
        startInactivityTimer()
    }

    // Call this when a task is completed or a friend checks in
    func celebrate(then completion: (() -> Void)? = nil) {
        setState(.celebrate)
        // After celebration, return to time-based state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.setState(.timeBasedState)
            completion?()
        }
    }

    /// Called 15 minutes before an imminent event. Shifts Olu to .idle so the user
    /// notices the nudge banner without a jarring animation.
    func imminentNudge() {
        guard state != .celebrate else { return }
        cancelInactivityTimer()
        setState(.idle)
        startInactivityTimer()
    }

    // Call this to manually set night mode
    func updateForTimeOfDay() {
        guard state != .celebrate && state != .idle else { return }
        setState(.timeBasedState)
    }

    private func setState(_ newState: OluState) {
        guard state != newState else { return }
        state = newState
    }

    private func startInactivityTimer() {
        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: inactivityThreshold,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setState(.timeBasedState)
            }
        }
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func startTimeObserver() {
        // Check time of day every minute
        timeObserverTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateForTimeOfDay()
            }
        }
    }
}
