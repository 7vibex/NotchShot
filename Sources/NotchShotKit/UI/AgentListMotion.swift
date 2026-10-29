import SwiftUI

/// How the agent list moves: rows arriving, the conversation panel pushing
/// in over the list, and a run's mark and title travelling between its row
/// and the run card when the card changes hands.
///
/// Reduce Motion keeps every change and drops the travel: rows and panels
/// fade, and the card swap crossfades in place.
enum AgentListMotion {
    /// A run arriving in the list drops in from the row above. Under Reduce
    /// Motion it only fades: `NotchMotion.selection` still animates there,
    /// with a short ease, so a move would still slide.
    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// Answer controls unfolding under a run that asks for something.
    static func answerTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// The conversation panel comes in from the trailing edge and leaves
    /// back towards it, as a pushed page does.
    static func conversationTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        return .asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading))
            .animation(NotchMotion.content(reduceMotion: false))
    }

    /// The list the panel covers: it gives way towards the leading edge and
    /// comes back from it.
    static func listTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        return .asymmetric(insertion: .push(from: .leading), removal: .push(from: .trailing))
            .animation(NotchMotion.content(reduceMotion: false))
    }
}

/// What travels between a run's row and the run card: the mark and the
/// title, which both places draw at the same size.
struct AgentRunMatchID: Hashable {
    enum Part: Hashable {
        case mark
        case title
    }

    var run: String
    var part: Part
}

extension View {
    /// Pairs this part of a run with the same part on the card or a row, so
    /// it travels between them when the card changes hands. Without a
    /// namespace (Reduce Motion) it stays put and the swap crossfades.
    @ViewBuilder
    func agentRunMatch(_ part: AgentRunMatchID.Part, run: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: AgentRunMatchID(run: run, part: part), in: namespace)
        } else {
            self
        }
    }
}

/// A run's mark shakes once, the way an app icon asks to be noticed, at the
/// moment the run starts needing the user. The mark is an app icon or the
/// crab's tile rather than an SF Symbol, so this is a rotation rather than
/// the symbol wiggle effect.
enum AgentMarkWiggle {
    /// What the mark's orange badge means: a question or an approval
    /// waiting, or the turn handed back.
    static func needsYou(state: AIActivityState, isAsking: Bool) -> Bool {
        isAsking || state == .waiting
    }

    /// Whether a run has just started needing the user, given the runs that
    /// needed them as of the last update. `before` is nil until the list has
    /// been drawn once, so opening the island on runs that already wait
    /// shakes nothing.
    static func startsNeedingYou(_ run: String, needsYou: Bool, before: Set<String>?) -> Bool {
        guard needsYou, let before else { return false }
        return !before.contains(run)
    }

    /// Degrees, each with the time taken to reach it from the one before:
    /// a shake that dies away and ends square.
    static let keyframes: [(degrees: Double, duration: TimeInterval)] = [
        (-8, 0.08), (7, 0.1), (-5, 0.1), (3, 0.1), (0, 0.12),
    ]

    static var duration: TimeInterval {
        keyframes.reduce(0) { $0 + $1.duration }
    }
}

/// Shakes its content once each time `cue` turns true, and on appearing
/// with `cue` already true: the run card's mark is created in the same
/// update in which its run starts needing the user and takes the card.
/// Under Reduce Motion it stays still.
struct AgentAttentionWiggle: ViewModifier {
    var cue: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wiggles = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { view, degrees in
                view.rotationEffect(.degrees(degrees))
            } keyframes: { _ in
                KeyframeTrack {
                    for keyframe in AgentMarkWiggle.keyframes {
                        CubicKeyframe(keyframe.degrees, duration: keyframe.duration)
                    }
                }
            }
            .onAppear { if cue { wiggle() } }
            .onChange(of: cue) { _, cue in
                if cue { wiggle() }
            }
    }

    private func wiggle() {
        guard !reduceMotion else { return }
        wiggles += 1
    }
}
