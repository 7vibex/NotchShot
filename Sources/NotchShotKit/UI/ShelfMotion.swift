import SwiftUI

/// How the shelf moves between captures and between its two layouts.
///
/// Reduce Motion keeps every change and drops the travel: pages and layouts
/// crossfade, and the selection ring moves at once.
enum ShelfMotion {
    /// The edge the next capture comes in from when the selection moves by
    /// `step`: a later capture from the trailing edge, an earlier one from
    /// the leading edge. ← and → wrap past either end and still turn the way
    /// the key points, as a carousel does. No step is no page turn.
    static func pageEdge(forStep step: Int) -> Edge? {
        if step > 0 { return .trailing }
        if step < 0 { return .leading }
        return nil
    }

    /// The selected capture's picture and details changing. A page turn
    /// pushes the old ones out towards one side as the next come in from the
    /// other; any other change (a new capture, one removed) crossfades.
    static func pageTransition(edge: Edge?, reduceMotion: Bool) -> AnyTransition {
        guard let edge, !reduceMotion else {
            return .opacity.animation(NotchMotion.fade(reduceMotion: reduceMotion))
        }
        return .push(from: edge).animation(NotchMotion.content(reduceMotion: false))
    }

    /// Grid ↔ Detail. Each layout keeps its own fixed size while the shell
    /// springs between them: the new one comes in with a slight grow, the
    /// old one is gone in a tenth of a second underneath it.
    static func layoutTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(NotchMotion.fade(reduceMotion: true)) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .animation(NotchMotion.content(reduceMotion: false)),
            removal: .opacity
                .animation(NotchMotion.contentExit(reduceMotion: false))
        )
    }

    /// The selection ring sliding to the next tile. Under Reduce Motion it
    /// moves at once.
    static func ringAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : NotchMotion.selection(reduceMotion: false)
    }
}

/// A page turn on its way. The direction lands in one update and the
/// selection moves in the next: a capture on its way out leaves with the
/// transition it was last drawn with, so a direction set in the same update
/// as the move only reached the capture coming in, and turning back the
/// other way sent the old one out on the wrong side.
struct ShelfPageTurn: Equatable {
    enum Move: Equatable {
        /// ← or →: by one, wrapping past either end.
        case step(Int)
        /// A thumbnail clicked.
        case to(Int)
    }

    var move: Move
    /// The side the next capture comes in from; nil when the move goes
    /// nowhere.
    var edge: Edge?
    /// Tells two turns the same way apart, so each one runs.
    var serial: Int

    init(move: Move, from current: Int, serial: Int) {
        self.move = move
        self.serial = serial
        let step = switch move {
        case .step(let step): step
        case .to(let index): index - current
        }
        edge = ShelfMotion.pageEdge(forStep: step)
    }
}

/// Where the selected tile is, so one ring can be drawn over a strip of
/// tiles and slide between them, instead of a ring per tile that jumped from
/// one to the next.
private struct ShelfSelectionAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this tile as the one the selection ring sits on.
    func shelfSelectionAnchor(isSelected: Bool) -> some View {
        anchorPreference(key: ShelfSelectionAnchorKey.self, value: .bounds) { isSelected ? $0 : nil }
    }

    /// One selection ring over a strip, drawn by `ring` at the bounds of the
    /// tile marked with `shelfSelectionAnchor`. It slides to the next tile on
    /// `NotchMotion.selection` when `selection` changes.
    func shelfSelectionRing<Selection: Equatable, Ring: View>(
        selection: Selection,
        reduceMotion: Bool,
        @ViewBuilder ring: @escaping () -> Ring
    ) -> some View {
        overlayPreferenceValue(ShelfSelectionAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    ring()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .animation(ShelfMotion.ringAnimation(reduceMotion: reduceMotion), value: selection)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// `islandArrivalFromScreen` while the newest capture is still arriving.
    /// Once a view switch has shown it, the other layout draws it in place
    /// rather than having it rise from the screen a second time.
    @ViewBuilder
    func shelfArrival<ID: Hashable>(id: ID, isArriving: Bool) -> some View {
        if isArriving {
            islandArrivalFromScreen(id: id)
        } else {
            self
        }
    }
}
