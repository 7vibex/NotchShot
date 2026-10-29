import AppKit
import SwiftUI

/// Where each activity's shared element should currently be drawn.
///
/// Compact wings, expanded headers and satellites each place an invisible
/// anchor of the size they want. One glyph per activity is then drawn by
/// `IslandSharedElementLayer` at its anchor, above the clipped shell — so when
/// an anchor moves (compact → expanded, satellite → primary) the *same* view
/// travels and resizes instead of one copy fading out while another fades in.
///
/// Anchors are keyed by level as well as activity. During a compact ↔ expanded
/// change the outgoing content is still in the tree for its removal fade, so
/// both levels publish an anchor for the same activity at once; keyed by id
/// alone, whichever merged last won, and the cover could aim at the outgoing
/// slot for a few frames and then turn toward the real one mid-flight.
struct IslandGlyphAnchorKey: PreferenceKey {
    struct Slot: Hashable {
        var id: IslandActivityID
        var level: IslandPresentationLevel
    }

    static let defaultValue: [Slot: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Slot: Anchor<CGRect>],
        nextValue: () -> [Slot: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, newest in newest }
    }
}

extension View {
    /// Reserves this view's frame for an activity's shared element.
    func islandGlyphAnchor(_ id: IslandActivityID, level: IslandPresentationLevel) -> some View {
        anchorPreference(key: IslandGlyphAnchorKey.self, value: .bounds) {
            [IslandGlyphAnchorKey.Slot(id: id, level: level): $0]
        }
    }
}

/// An empty placeholder sized for a shared element.
struct IslandGlyphSlot: View {
    var id: IslandActivityID
    var level: IslandPresentationLevel = .expanded
    var size: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .islandGlyphAnchor(id, level: level)
            .accessibilityHidden(true)
    }
}

/// Draws every visible activity's shared element at its current anchor.
///
/// This must sit in a coordinate space that does not itself animate (the
/// panel, not the shell). Placed on the shell, the glyph's on-screen position
/// was the shell's springing origin *plus* its own spring toward the new local
/// anchor — two curves at different speeds — so while the notch opened the
/// cover first slid the wrong way, then hooked back. In a still space there is
/// one curve, and `IslandMotion.sharedElement` matches the shell's, so the
/// cover moves in step with the content around it.
struct IslandSharedElementLayer: View {
    var anchors: [IslandGlyphAnchorKey.Slot: Anchor<CGRect>]
    var activities: [IslandActivity]
    /// The level being presented; its anchor wins over an outgoing level's.
    var level: IslandPresentationLevel
    var isTracking: Bool
    @Bindable var coordinator: AppCoordinator

    private func slot(for id: IslandActivityID) -> (level: IslandPresentationLevel, anchor: Anchor<CGRect>)? {
        if let current = anchors[.init(id: id, level: level)] { return (level, current) }
        return anchors.first { $0.key.id == id }.map { ($0.key.level, $0.value) }
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(activities.filter { slot(for: $0.id) != nil }) { activity in
                if let slot = slot(for: activity.id) {
                    IslandTravellingGlyph(
                        activity: activity,
                        placement: .init(level: slot.level, rect: proxy[slot.anchor]),
                        isTracking: isTracking,
                        coordinator: coordinator
                    )
                    .transition(.opacity.animation(NotchMotion.fade(reduceMotion: false)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One shared element, drawn where its slot is.
///
/// A slot sits inside content that is itself animating (the shell springing
/// open, the content's own transition), so its rect changes on every frame of
/// an open or close. The glyph follows it exactly. It used to animate toward
/// each new rect instead, which restarted a spring every frame toward a moving
/// target: the cover trailed far behind, hanging outside the shell on close
/// and sliding over the title well after the card had opened.
///
/// The one move that needs its own curve is changing slots (compact ↔
/// expanded): the glyph blends from where it was to the *live* new slot, so it
/// lands exactly as the content around it does.
private struct IslandTravellingGlyph: View {
    struct Placement: Equatable {
        var level: IslandPresentationLevel
        var rect: CGRect
    }

    var activity: IslandActivity
    var placement: Placement
    var isTracking: Bool
    @Bindable var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin: CGRect?
    @State private var progress: CGFloat = 1

    var body: some View {
        IslandActivityGlyph(activity: activity, coordinator: coordinator)
            .modifier(IslandGlyphTravel(origin: origin ?? placement.rect, target: placement.rect, progress: progress))
            .onChange(of: placement) { old, new in
                guard old.level != new.level else { return }
                guard !isTracking, let curve = IslandMotion.sharedElement(reduceMotion: reduceMotion) else {
                    origin = nil
                    progress = 1
                    return
                }
                // Starts from where it is drawn now, which is mid-flight when
                // a close interrupts an open.
                origin = IslandGlyphTravel.blend(origin ?? old.rect, old.rect, progress)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = 0 }
                withAnimation(curve) { progress = 1 }
            }
    }
}

/// Places a glyph part-way from `origin` to `target`. Only `progress`
/// animates; the target is read live every frame.
private struct IslandGlyphTravel: ViewModifier, Animatable {
    var origin: CGRect
    var target: CGRect
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    nonisolated static func blend(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        guard t < 1 else { return b }
        return CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    func body(content: Content) -> some View {
        let rect = Self.blend(origin, target, progress)
        content
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            // Only `progress` may animate; a transaction animating the shell
            // must not also tween the live rect.
            .animation(nil, value: target)
    }
}

/// The one visual that represents an activity at every level. It fills
/// whatever frame it is given, so the same view can be 16 pt in a satellite
/// and 56 pt in an expanded header.
struct IslandActivityGlyph: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.accentHex) ?? .systemBlue
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            content(side: side)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func content(side: CGFloat) -> some View {
        switch activity.kind {
        case .media:
            IslandArtworkGlyph(coordinator: coordinator, side: side)
        case .recording:
            IslandRecordingGlyph(isPaused: activity.lifecycle == .paused, side: side)
        case .ai:
            // The agent's own icon, whole, with no ring: progress and state
            // are the trailing wing's job, and a ring squeezed the icon to a
            // speck inside a dim provider-coloured track.
            if let agent = IslandActivityAdapters.headlineAgent(coordinator.context.islandAIActivities) {
                AgentVibeIdentity(source: agent.source, size: side * 1.12)
            } else {
                symbol(side: side)
            }
        case .timer:
            // The phone's timer ring shows what is left, so it empties as the
            // countdown runs rather than filling up.
            IslandRingGlyph(
                progress: activity.progress.fraction.map { .determinate(1 - $0) } ?? activity.progress,
                lifecycle: activity.lifecycle,
                accent: accent,
                side: side
            ) {
                symbol(side: side)
            }
        case .external:
            IslandRingGlyph(
                progress: activity.progress,
                lifecycle: activity.lifecycle,
                accent: accent,
                side: side
            ) {
                symbol(side: side)
            }
        case .transfer:
            // Like AirDrop on the phone: the service's mark on its own here,
            // and the progress ring on the far side of the camera.
            symbol(side: side * 1.6)
        case .voiceNote, .calendar:
            symbol(side: side * 1.35)
        case .call:
            Image(systemName: "phone.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(IslandCallStyle.green)
                .frame(width: side * 0.72, height: side * 0.72)
        }
    }

    private func symbol(side: CGFloat) -> some View {
        Image(systemName: terminalSymbol ?? activity.symbolName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(symbolColor)
            .frame(width: side * 0.46, height: side * 0.46)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: terminalSymbol)
    }

    private var terminalSymbol: String? {
        switch activity.lifecycle {
        case .succeeded: "checkmark"
        case .failed: "exclamationmark"
        default: nil
        }
    }

    private var symbolColor: Color {
        switch activity.lifecycle {
        case .succeeded: .green
        case .failed: .red
        default: accent
        }
    }
}

/// A progress ring around a centre glyph. Determinate progress draws exactly
/// the reported fraction; an indeterminate source spins a short arc and never
/// implies a number.
struct IslandRingGlyph<Center: View>: View {
    var progress: IslandProgress
    var lifecycle: IslandLifecycle
    var accent: Color
    var side: CGFloat
    @ViewBuilder var center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineWidth: CGFloat { max(2, side * 0.12) }

    private var tint: Color {
        switch lifecycle {
        case .succeeded: .green
        case .failed: .red
        case .waiting: .orange
        default: accent
        }
    }

    var body: some View {
        ZStack {
            // The track is the ring's own colour, dimmed, as on the phone —
            // a grey track made every ring read as disabled.
            Circle()
                .stroke(tint.opacity(0.26), lineWidth: lineWidth)
            ring
            center()
        }
        .padding(lineWidth / 2)
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private var ring: some View {
        switch progress {
        case .determinate(let fraction):
            Circle()
                .trim(from: 0, to: lifecycle == .succeeded ? 1 : fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // The ring is the only thing a percentage animates.
                .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: fraction)
                .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: lifecycle)
        case .indeterminate where lifecycle == .active:
            // A layer animation: the ring rides on a glyph that is often on
            // screen for minutes, and a SwiftUI `repeatForever` turn redrew
            // the notch on the main thread every frame of that.
            LayerSpinner(
                diameter: side - lineWidth,
                lineWidth: lineWidth,
                tint: tint,
                trackOpacity: 0,
                arcLength: 0.28,
                period: 1.1,
                insetsStroke: false
            )
        case .none, .indeterminate:
            // A waiting activity with no number still needs to read as
            // "your turn", not as an empty track.
            if lifecycle.isTerminal || lifecycle == .waiting {
                Circle().stroke(tint, lineWidth: lineWidth)
            }
        }
    }
}

struct IslandRecordingGlyph: View {
    var isPaused: Bool
    var side: CGFloat

    var body: some View {
        ZStack {
            if isPaused {
                Image(systemName: "pause.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.red)
                    .frame(width: side * 0.5, height: side * 0.5)
            } else {
                // Breathes on the render server for the whole recording.
                LayerPulsingDot(diameter: side * 0.5, color: .red, pulseOpacity: 0.4, halfPeriod: 0.9)
                    .frame(width: side * 0.5, height: side * 0.5)
                // A record button's ring, drawn on once as the recording
                // starts and still after that.
                Image(systemName: "circle")
                    .resizable()
                    .fontWeight(.semibold)
                    .scaledToFit()
                    .foregroundStyle(.red)
                    .frame(width: side * 0.9, height: side * 0.9)
                    .modifier(SymbolDrawsOnAppear())
            }
        }
        .frame(width: side, height: side)
    }
}

/// The cover travelling between the compact wing (20 pt), a satellite and the
/// expanded header (56 pt).
///
/// It is laid out once at the largest size and scaled to the frame it is
/// given. Laying it out at the animated size instead resized the image view
/// on every frame of the travel, and the GPU resampled the cover from scratch
/// each time, so it shimmered and its corners stepped as it grew. A scale is
/// a transform on one already-drawn layer, which is what the system's own
/// shared-element transitions do.
struct IslandArtworkGlyph: View {
    @Bindable var coordinator: AppCoordinator
    var side: CGFloat

    static let baseSide: CGFloat = 56

    var body: some View {
        let base = Self.baseSide
        let shape = RoundedRectangle(cornerRadius: base / 5, style: .continuous)
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else {
                ZStack {
                    Color.islandInk(NotchIsland.Ink.fill * 2)
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .padding(base * 0.26)
                }
            }
        }
        .frame(width: base, height: base)
        .clipShape(shape)
        // A track change crossfades the cover rather than cutting to it.
        .id(coordinator.media.artwork.map(ObjectIdentifier.init))
        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
        .artworkPresence(
            isPlaying: coordinator.media.snapshot.isPlaying,
            accent: Color(nsColor: coordinator.media.artworkAccentColor),
            cornerRadius: base / 5,
            // Only the open player has room for the glow; on the compact
            // wing it would bleed into the camera band.
            glows: side >= 40
        )
        .overlay {
            if side >= 40 { ArtworkGlareSheen(cornerRadius: base / 5) }
        }
        .scaleEffect(max(side, 1) / base)
        .frame(width: side, height: side)
    }
}

/// The cover's two quiet states: a soft glow of its own colour behind it
/// while it plays, and stepping back — smaller, dimmer, less saturated —
/// while paused, the way the phone's player does. Both are static between
/// changes; nothing here loops, and the glow's blur radius never animates.
struct ArtworkPresenceModifier: ViewModifier {
    var isPlaying: Bool
    var accent: Color
    var cornerRadius: CGFloat
    var glows: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let extras = ExtrasPreferences.shared
        let dims = extras.dimsArtworkWhenPaused && !isPlaying
        content
            .background {
                if glows, extras.showsArtworkGlow {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(accent)
                        .blur(radius: 12)
                        .scaleEffect(0.94)
                        .offset(y: 3)
                        .opacity(isPlaying ? 0.6 : 0.18)
                        .accessibilityHidden(true)
                }
            }
            .saturation(dims ? 0.55 : 1)
            .opacity(dims ? 0.74 : 1)
            .scaleEffect(dims ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: dims)
            .animation(.easeInOut(duration: 0.35), value: isPlaying)
    }
}

extension View {
    func artworkPresence(isPlaying: Bool, accent: Color, cornerRadius: CGFloat, glows: Bool) -> some View {
        modifier(ArtworkPresenceModifier(
            isPlaying: isPlaying,
            accent: accent,
            cornerRadius: cornerRadius,
            glows: glows
        ))
    }
}
