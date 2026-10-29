import SwiftUI

/// The island's named curves. Every one-shot animation on the island picks one
/// of these instead of writing its own spring, so a hover, an expand and a
/// digit rolling over all belong to the same family, and the animation style
/// setting retunes them together.
///
/// Ambient loops (a pulsing dot, a breathing glow) are not in here: they are
/// decoration with their own period, not responses to a change.
///
/// Reduce Motion is handled here too: spatial curves return nil (the change
/// lands immediately) and fades collapse to a short ease.
enum NotchMotion {
    /// Mirrors `Preferences.islandAnimationStyle`. Kept as a plain static so the
    /// curves can be read from any view without threading the preference
    /// through; a style change applies from the next animation onward.
    nonisolated(unsafe) static var style: IslandAnimationStyle = .iPhone

    struct Tuning {
        var expandResponse: Double
        var expandDamping: Double
        var collapseResponse: Double
        var collapseDamping: Double
        var contentResponse: Double
        var contentDamping: Double
        var hoverBounce: Double
        var arrivalDamping: Double
    }

    static var tuning: Tuning { tuning(for: style) }

    static func tuning(for style: IslandAnimationStyle) -> Tuning {
        switch style {
        case .subtle:
            Tuning(
                expandResponse: 0.36, expandDamping: 1.0,
                collapseResponse: 0.30, collapseDamping: 1.0,
                contentResponse: 0.26, contentDamping: 1.0,
                hoverBounce: 0, arrivalDamping: 1.0
            )
        case .iPhone:
            Tuning(
                expandResponse: 0.42, expandDamping: 0.76,
                collapseResponse: 0.34, collapseDamping: 1.0,
                contentResponse: 0.30, contentDamping: 0.86,
                hoverBounce: 0.20, arrivalDamping: 0.74
            )
        case .bouncy:
            Tuning(
                expandResponse: 0.48, expandDamping: 0.62,
                collapseResponse: 0.38, collapseDamping: 0.88,
                contentResponse: 0.34, contentDamping: 0.74,
                hoverBounce: 0.32, arrivalDamping: 0.62
            )
        }
    }

    // MARK: Shell

    /// The shell growing into a larger presentation.
    static func expand(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let t = tuning
        return .spring(response: t.expandResponse, dampingFraction: t.expandDamping)
    }

    /// The shell shrinking back toward the cutout. Faster than `expand`, and
    /// only the bouncy style lets it overshoot at all.
    static func collapse(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let t = tuning
        return .spring(response: t.collapseResponse, dampingFraction: t.collapseDamping)
    }

    /// Several shapes moving at once (the multi-activity island). Any bounce
    /// there reads as jitter, so this never overshoots in any style.
    static func settle(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: tuning.expandResponse, dampingFraction: 1.0)
    }

    /// A pointer drag pulling on the shell.
    static func drag(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.8)
    }

    // MARK: Content

    /// Content that belongs to the new state arriving.
    static func content(reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return fade(reduceMotion: true) }
        let t = tuning
        return .spring(response: t.contentResponse, dampingFraction: t.contentDamping)
    }

    /// Content that belongs to the old state leaving. Always quick, so old and
    /// new never share the shell for long.
    static func contentExit(reduceMotion: Bool) -> Animation {
        .easeIn(duration: reduceMotion ? 0.08 : 0.1)
    }

    /// Plain opacity changes.
    static func fade(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.12 : 0.14)
    }

    /// Travelling elements (artwork, agent glyph) moving between anchors.
    /// The same curve as `settle`, which the island's shell uses: on its own
    /// faster spring the cover arrived before the header it sits in and
    /// visibly slid against it. Critically damped either way — an overshoot
    /// carried the glyph out of the shell.
    static func sharedElement(reduceMotion: Bool) -> Animation? {
        settle(reduceMotion: reduceMotion)
    }

    /// Something arriving from outside the island (a new capture, a satellite).
    static func arrival(reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return fade(reduceMotion: true) }
        return .spring(response: 0.46, dampingFraction: tuning.arrivalDamping)
    }

    /// A number or word changing in place.
    static func liveValue(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .snappy(duration: 0.28)
    }

    // MARK: Controls

    static func hover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.20, bounce: tuning.hoverBounce)
    }

    /// Something swapped in or brightened under the pointer: a row's time
    /// giving way to its buttons, a capsule's fill. It has no travel, so it
    /// runs the same under Reduce Motion.
    static let hoverSwap = Animation.easeOut(duration: 0.15)

    static func press(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.12, bounce: min(0.1, tuning.hoverBounce))
    }

    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: 0.24, bounce: min(0.2, tuning.hoverBounce * 0.8))
    }
}

/// A dashed outline whose dashes travel around the shape — the "drop here"
/// signal while a file is dragged over a target. Under Reduce Motion, or when
/// `isMarching` is false, the dashes stand still.
struct MarchingDashStroke<S: Shape>: View {
    var shape: S
    var color: Color
    var lineWidth: CGFloat = 1.5
    var dash: [CGFloat] = [6, 4]
    var isMarching = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Points per second the dashes travel.
    private static var speed: Double { 22 }

    var body: some View {
        if reduceMotion || !isMarching {
            stroke(phase: 0)
        } else {
            // Only ticks while this view is on screen, which is only while a
            // drag is over the target.
            TimelineView(.animation) { context in
                let period = dash.reduce(0, +)
                let travelled = context.date.timeIntervalSinceReferenceDate * Self.speed
                stroke(phase: -CGFloat(travelled.truncatingRemainder(dividingBy: Double(max(period, 1)))))
            }
        }
    }

    private func stroke(phase: CGFloat) -> some View {
        shape.stroke(
            color,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash, dashPhase: phase)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How SF Symbols change on the island. A glyph that stands for a state
/// (play and pause, a microphone and its slash) morphs into the next one, as
/// the system's own controls do, instead of being swapped for it.
enum NotchSymbolMotion {
    /// Magic Replace keeps what the two symbols share and draws the rest on
    /// or off: the slash across a microphone draws itself in.
    static func swap(reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace))
    }
}

/// Draws a symbol on the first time it appears, the way the system's own
/// confirmations arrive, rather than letting it pop in with the view around
/// it. A symbol whose view is inserted on its own can use
/// `.transition(.symbolEffect(.drawOn))` instead; this is for one that
/// arrives as part of a larger view.
struct SymbolDrawsOnAppear: ViewModifier {
    @State private var isDrawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .symbolEffect(.drawOff.nonReversed, isActive: !isDrawn && !reduceMotion)
            .onAppear { isDrawn = true }
    }
}
