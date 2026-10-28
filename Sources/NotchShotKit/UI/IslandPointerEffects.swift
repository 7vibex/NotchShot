import SwiftUI

/// The closed island leans toward the pointer over it: it stretches a couple
/// of points on that side, pinned on the other, the way a drop of glass
/// would be pulled. Off while open (the content would swim under the
/// pointer), under Reduce Motion, and in Settings.
///
/// The lean lives in this modifier's own state, so a pointer moving over the
/// notch re-renders this transform alone, never the island's content.
struct IslandPointerLean: ViewModifier {
    var isEnabled: Bool
    /// The island's width, from its layout.
    var width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lean: CGFloat = 0

    /// Lean in eighths: fine enough to follow the pointer, coarse enough
    /// that a slow drag isn't a re-render per pixel.
    static func lean(atX x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, x.isFinite else { return 0 }
        let centred = min(max(x / width * 2 - 1, -1), 1)
        return (centred * 8).rounded() / 8
    }

    /// At most 2% wider: felt more than seen.
    static let maximumStretch: CGFloat = 0.02

    private var active: Bool { isEnabled && !reduceMotion }

    func body(content: Content) -> some View {
        content
            // Measured before the stretch, so the stretch can't feed back
            // into where the pointer appears to be.
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard active else { return }
                switch phase {
                case .active(let point):
                    let next = Self.lean(atX: point.x, width: width)
                    if next != lean { lean = next }
                case .ended:
                    lean = 0
                }
            }
            .scaleEffect(
                x: 1 + abs(active ? lean : 0) * Self.maximumStretch,
                y: 1,
                anchor: lean < 0 ? .trailing : .leading
            )
            .animation(NotchMotion.drag(reduceMotion: reduceMotion), value: lean)
            .onChange(of: active) { _, isActive in
                if !isActive { lean = 0 }
            }
    }
}

/// Where the pointer is over the open player's cover, in unit coordinates.
///
/// The hover is read where the cover is laid out, but in the multi-activity
/// island the cover itself is drawn in the shared-element layer above, so
/// the two halves meet here. Only the sheen reads it, so a moving pointer
/// redraws the sheen alone.
@MainActor
@Observable
final class ArtworkGlareState {
    static let shared = ArtworkGlareState()
    var point: UnitPoint?
}

/// Tracks the pointer over the cover's frame. Draws nothing.
struct ArtworkGlareTracker: View {
    private var state: ArtworkGlareState { .shared }

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        let point = UnitPoint(
                            x: location.x / max(proxy.size.width, 1),
                            y: location.y / max(proxy.size.height, 1)
                        )
                        if state.point == nil {
                            withAnimation(.easeOut(duration: 0.18)) { state.point = point }
                        } else {
                            state.point = point
                        }
                    case .ended:
                        withAnimation(.easeOut(duration: 0.3)) { state.point = nil }
                    }
                }
        }
        .onDisappear { state.point = nil }
        .accessibilityHidden(true)
    }
}

/// A soft highlight on the cover that follows the pointer, as light would
/// on glossy card stock. Drawn only while the pointer is over the cover, so
/// a resting player costs nothing.
struct ArtworkGlareSheen: View {
    var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: ArtworkGlareState { .shared }

    var body: some View {
        ZStack {
            if let point = state.point, !reduceMotion, ExtrasPreferences.shared.showsArtworkGlare {
                GeometryReader { proxy in
                    RadialGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.08), .clear],
                        center: point,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.75
                    )
                    .blendMode(.plusLighter)
                }
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
