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
        NotchMotion.sharedElement(reduceMotion: reduceMotion)
    }

    /// Satellites arriving: grow into place without overshoot.
    static func satelliteArrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? NotchMotion.fade(reduceMotion: true) : NotchMotion.settle(reduceMotion: false)!
    }

    /// A satellite buds out of the primary shell and merges back into it: it
    /// starts at the shell's edge joined by a black neck, travels out, and the
    /// neck thins until it pinches off. Removal runs the same in reverse.
    static func satelliteTransition(
        reduceMotion: Bool,
        travel: CGFloat,
        gap: CGFloat,
        height: CGFloat,
        slot: IslandSlot
    ) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        func bud(_ progress: CGFloat) -> IslandSatelliteBud {
            IslandSatelliteBud(progress: progress, travel: travel, gap: gap, height: height, slot: slot)
        }
        return .asymmetric(
            insertion: .modifier(active: bud(0), identity: bud(1))
                .animation(satelliteArrival(reduceMotion: false)),
            removal: .modifier(active: bud(0), identity: bud(1))
                .animation(NotchMotion.collapse(reduceMotion: false) ?? .easeIn(duration: 0.16))
        )
    }

    /// Content coming into focus, the blur half of Apple's content-replace
    /// transition. Radii stay small: the island's content is a few dozen
    /// points tall, and a wide blur reads as smear, not focus.
    ///
    /// Only arrivals blur. A blurred subtree that holds animating text is
    /// rasterized on the CPU every frame, and outgoing content is gone in under
    /// a tenth of a second anyway, so blurring it cost frames during the close
    /// without being visible.
    static func blur(_ radius: CGFloat) -> AnyTransition {
        .modifier(active: IslandContentBlur(radius: radius), identity: IslandContentBlur(radius: 0))
    }

    /// Primary content swapping to a different activity. Content travels from
    /// the side the new primary came from and comes into focus on the way, the
    /// outgoing one blurs as it leaves; nothing fades the whole island.
    static func primarySwap(from edge: IslandSlot?, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion, let edge else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        let travel: CGFloat = 22
        let incoming: CGFloat = edge == .trailing ? travel : -travel
        return .asymmetric(
            insertion: .offset(x: incoming)
                .combined(with: .opacity)
                .combined(with: blur(4)),
            removal: .offset(x: -incoming * 0.6)
                .combined(with: .opacity)
        )
    }

    /// The one way content arrives in the island: out of the camera edge,
    /// growing from just under full size, a beat after the shell starts to
    /// open. A spring, so an interrupted open keeps its velocity.
    ///
    /// No blur: Apple's content-replace blurs a glyph or a line, but blurring
    /// a whole page rasterized it offscreen on every frame of the open — about
    /// a quarter of the open's cost, measured. Pages come into focus by their
    /// rows arriving in turn instead (`islandReveal(stage:)`).
    static func arrival(delay: Double, drop: CGFloat = 6) -> AnyTransition {
        .opacity
            .combined(with: .scale(scale: arrivalScale, anchor: .top))
            .combined(with: .offset(y: -drop))
            .animation(NotchMotion.content(reduceMotion: false).delay(delay))
    }

    static let arrivalScale: CGFloat = 0.94

    /// How far a page travels when the pill switches to its neighbour.
    static let pageTravel: CGFloat = 28

    /// How much taller the closed shell stretches at a full pull-down.
    static let pullOpenStretch: CGFloat = 0.28

    /// Compact ↔ expanded content: expanded content arrives slightly late and
    /// leaves immediately, so the shell visibly leads on the way in and settles
    /// last on the way out. Content grows out of the camera edge, the way the
    /// shell itself does.
    static func levelTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        // Outgoing content is gone before incoming content is visible, so the
        // compact and expanded versions of the same value never overlap.
        return .asymmetric(
            insertion: arrival(delay: 0.1, drop: 0),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .animation(.easeIn(duration: 0.07))
        )
    }

    /// A burst entering: comes into focus with a slight settle, never a bounce.
    static func burstTransition(severity: IslandEventSeverity, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97))
                .combined(with: blur(4))
                .animation(.easeOut(duration: 0.2).delay(0.04)),
            removal: .opacity
                .animation(.easeIn(duration: 0.12))
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
        NotchMotion.liveValue(reduceMotion: reduceMotion)
    }

    /// How far the compact island gives while held down. The phone's island
    /// visibly squeezes under a finger; a few percent is enough to feel it
    /// without the shell pulling far off the cutout.
    static let pressedScale: CGFloat = 0.96

    /// The squeeze and the release. Bouncy enough that letting go reads as
    /// the shell springing back, short enough to finish under the open.
    /// Damping 0.64 is a bounce of about 0.36, inside the 0.4 Apple gives as
    /// the most a UI spring should bounce.
    static let press: Animation = .spring(response: 0.28, dampingFraction: 0.64)

    /// The closed player letting go of a track-skip stretch: a skip springs
    /// back past rest once, a swipe that fell short settles without one.
    static let skipReleaseSpring = Spring(response: 0.42, dampingRatio: 0.6)
    static let pullSettleSpring = Spring(response: 0.3, dampingRatio: 0.9)
    static let skipRelease = Animation.spring(skipReleaseSpring)
    static let pullSettle = Animation.spring(pullSettleSpring)
    /// The most a track-skip swipe stretches the closed player.
    static let skipStretch: CGFloat = 0.06
}

/// Blur as a transition modifier. `.blurReplace` cannot be combined with the
/// scale and offset the island content also needs, so this carries the blur
/// into an ordinary `AnyTransition`.
struct IslandContentBlur: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// Whether the pointer is holding the compact island down. One per notch
/// view, so pressing the island on one display never squeezes another's.
@MainActor
@Observable
final class IslandPressState {
    var isPressed = false
}

/// Reports a button's pressed state to the island shell, which does the
/// squeezing — the shell gives, not just the content inside it.
struct IslandSquishButtonStyle: ButtonStyle {
    @Environment(IslandPressState.self) private var press: IslandPressState?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                press?.isPressed = isPressed
            }
            .onDisappear { press?.isPressed = false }
    }
}

/// One satellite part-way out of the primary shell. `progress` 0 is fully
/// merged (centred on the shell's edge), 1 is at rest. Between them a neck
/// joins the two; it pinches off at `pinchPoint`, which is what reads as the
/// island splitting rather than a circle fading in beside it.
struct IslandSatelliteBud: ViewModifier, Animatable {
    var progress: CGFloat
    /// Offset from the resting position back to the shell's edge.
    var travel: CGFloat
    /// Gap between shell and satellite at rest.
    var gap: CGFloat
    var height: CGFloat
    var slot: IslandSlot

    static let pinchPoint: CGFloat = 0.72

    /// Width as a fraction of the resting width: tucked in at the start,
    /// drawn out toward the shell up to the pinch, round again at rest.
    static func stretch(_ progress: CGFloat) -> CGFloat {
        let p = max(0, progress)
        guard p >= pinchPoint else { return 0.72 + 0.36 * (p / pinchPoint) }
        return 1.08 - 0.08 * min(1, (p - pinchPoint) / (1 - pinchPoint))
    }

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1.15)
        // Toward the primary: +x for a leading satellite, -x for a trailing one.
        let inward: CGFloat = slot == .leading ? 1 : -1
        let currentGap = max(0, gap * min(p, 1))
        let neckWidth = currentGap + 12
        let pinch = min(1, p / Self.pinchPoint)
        // `travel` is the gap plus half the satellite's drawn width.
        let bodyWidth = max(0, 2 * (abs(travel) - gap))
        let stretch = Self.stretch(p)
        // The black body is solid from the first frame: it is the shell
        // pulling apart, not a second shape fading in. Held by the neck it
        // stretches back toward the shell and thins, and once the neck
        // pinches off it rounds out. Only what is drawn on it fades in, so
        // the glyph doesn't slide out across the primary's own content.
        content
            .environment(\.islandSatelliteEmergence, Double(min(1, max(0, (p - 0.3) / 0.45))))
            .scaleEffect(
                x: stretch,
                y: (0.86 + 0.14 * min(p, 1)) * (1 - 0.6 * max(0, stretch - 1)),
                anchor: slot == .leading ? .leading : .trailing
            )
            .background {
                if pinch < 1 {
                    GeometryReader { proxy in
                        IslandNeckShape(waist: 1 - pinch)
                            .fill(.black)
                            .frame(width: neckWidth, height: height)
                            // In the gap, overlapping each body by 6 pt.
                            .position(
                                x: proxy.size.width / 2 + inward * (bodyWidth / 2 + neckWidth / 2 - 6),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .offset(x: travel * (1 - min(p, 1)))
    }
}

extension EnvironmentValues {
    /// How far a satellite has come out of the shell, 0 to 1. Its glyph and
    /// edge follow this, while its black body is there from the start.
    @Entry var islandSatelliteEmergence: Double = 1
}

/// A horizontal bridge whose top and bottom curve inward. `waist` 1 is a full
/// rectangle; 0 has pinched to nothing in the middle.
struct IslandNeckShape: Shape {
    var waist: CGFloat

    var animatableData: CGFloat {
        get { waist }
        set { waist = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let inset = rect.height / 2 * (1 - max(0, min(1, waist)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY + inset * 2)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.maxY - inset * 2)
        )
        path.closeSubpath()
        return path
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
        let animation = NotchMotion.arrival(reduceMotion: reduceMotion)
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

/// A changing discrete number (a level, bytes, a count) that rolls in place
/// without animating anything around it. Running clocks and live progress use
/// `IslandClockText`.
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

/// A running clock (elapsed or remaining time) that changes every second, in
/// place and without a transition, as the phone's own timers do. Rolling
/// digits render on the CPU for most of a second per change, so a clock that
/// rolled never stopped rendering: about 45% of a core during a call. Live
/// progress (an agent's, a download's, a transfer's percentage) changes as
/// often and uses this too: each roll cost 150–750 ms of rendering.
struct IslandClockText: View {
    var text: String
    var font: Font
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .contentTransition(.identity)
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
