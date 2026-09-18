import SwiftUI

/// Choreography for the multi-activity island.
///
/// Three layers move at different rates, so a change reads as one gesture
/// rather than a crossfade:
/// 1. the **shell** (black shape) — the most elastic, and the last to settle;
/// 2. **shared elements** (artwork, agent glyph, timer ring, recording dot) —
///    travel between their compact, expanded and satellite anchors;
/// 3. **content** that only exists at one level — enters after the shell has
///    started growing (secondary controls, then details) and leaves first.
///
/// Reduce Motion keeps every state change but drops spatial travel, bounce and
/// rubber-banding: geometry changes land immediately, content crossfades.
enum IslandMotion {
    /// Shared elements travel on a critically damped curve. Any overshoot
    /// carried the glyph past its compact anchor and out through the top of
    /// the shell during a collapse; the shell supplies the elasticity.
    static func sharedElement(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 1.0)
    }

    /// Satellites arriving: grow into place without overshoot.
    static func satelliteArrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.36, dampingFraction: 1.0)
    }

    static func satelliteTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.14)) }
        return .asymmetric(
            insertion: .scale(scale: 0.6)
                .combined(with: .opacity)
                .animation(satelliteArrival(reduceMotion: false)),
            removal: .scale(scale: 0.6)
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.16))
        )
    }

    /// Primary content swapping to a different activity. Content travels from
    /// the side the new primary came from; nothing fades the whole island.
    static func primarySwap(from edge: IslandSlot?, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion, let edge else { return .opacity.animation(.easeOut(duration: 0.14)) }
        let travel: CGFloat = 22
        let incoming: CGFloat = edge == .trailing ? travel : -travel
        return .asymmetric(
            insertion: .offset(x: incoming).combined(with: .opacity),
            removal: .offset(x: -incoming * 0.6).combined(with: .opacity)
        )
    }

    /// Compact ↔ expanded content: expanded content arrives slightly late and
    /// leaves immediately, so the shell visibly leads on the way in and settles
    /// last on the way out.
    static func levelTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.14)) }
        // Outgoing content is gone before incoming content is visible, so the
        // compact and expanded versions of the same value never overlap.
        return .asymmetric(
            insertion: .opacity
                .animation(.easeOut(duration: 0.18).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.07))
        )
    }

    /// A burst entering: a plain fade with a slight settle, never a bounce.
    static func burstTransition(severity: IslandEventSeverity, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeOut(duration: 0.14)) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97))
                .animation(.easeOut(duration: 0.2).delay(0.04)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }

    /// Delay before each reveal stage inside an expanded card.
    static func revealDelay(stage: Int) -> Double {
        switch stage {
        case ...0: 0
        case 1: 0.07
        default: 0.13
        }
    }

    /// Localized value changes: a digit rolls, the card stays still.
    static func liveValue(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .snappy(duration: 0.28)
    }
}

/// How far a dragged file pulls the shell toward the pointer: -1 at the left
/// edge, 1 at the right, 0 in the middle, with a dead zone so a drag held
/// still over the centre does not twitch the island.
enum FileDropPullPolicy {
    static let deadZone: CGFloat = 0.15

    static func pull(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, x.isFinite else { return 0 }
        let normalized = min(1, max(-1, (x - width / 2) / (width / 2)))
        guard abs(normalized) > deadZone else { return 0 }
        let sign: CGFloat = normalized < 0 ? -1 : 1
        return sign * (abs(normalized) - deadZone) / (1 - deadZone)
    }
}

/// A new result appears to rise from the screen into the notch: it starts a
/// little larger and lower, then settles into its slot. There is no reliable
/// on-screen source rectangle for every capture path, so this is a deliberate
/// approximation rather than a window-geometry hack.
private struct IslandArrivalFromScreen<ID: Hashable>: ViewModifier {
    var id: ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hasArrived || reduceMotion ? 1 : 1.35, anchor: .top)
            .offset(y: hasArrived || reduceMotion ? 0 : 28)
            .opacity(hasArrived ? 1 : 0)
            .onAppear { arrive() }
            .onChange(of: id) { _, _ in
                hasArrived = false
                arrive()
            }
    }

    private func arrive() {
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.46, dampingFraction: 0.74)
        withAnimation(animation) { hasArrived = true }
    }
}

/// Staged entry for content that only exists at the expanded level:
/// stage 1 for secondary controls, stage 2 for details.
private struct IslandStagedReveal: ViewModifier {
    var stage: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 5)
            .onAppear {
                guard !isVisible else { return }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .easeOut(duration: 0.24).delay(IslandMotion.revealDelay(stage: stage))
                withAnimation(animation) { isVisible = true }
            }
    }
}

extension View {
    func islandReveal(stage: Int) -> some View {
        modifier(IslandStagedReveal(stage: stage))
    }

    func islandArrivalFromScreen<ID: Hashable>(id: ID) -> some View {
        modifier(IslandArrivalFromScreen(id: id))
    }
}

/// A changing number (timer, elapsed time, percentage, bytes) that rolls in
/// place without animating anything around it.
struct IslandNumericText: View {
    var text: String
    var countsDown = false
    var font: Font
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: countsDown))
            .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: text)
    }
}

/// A short changing word ("Working" → "Finished") replaced in place.
struct IslandStateText: View {
    var text: String
    var font: Font
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .opacity : .interpolate)
            .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: text)
    }
}
