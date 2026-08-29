import SwiftUI

/// Interior measurements for the island's content.
///
/// `NotchShotDesignSystem` governs NotchShot's *windows* — settings, the editor,
/// history. The island is a different surface: it draws on black, at small
/// sizes, against a hardware cutout, so it needs its own scale rather than
/// borrowing one tuned for a resizable window.
///
/// Everything here is a tier on a 2pt grid. The point is not the individual
/// numbers but that a row, a badge, and a tile pick from the same ladder, so
/// two features built months apart still line up.
enum NotchIsland {
    /// Geometry derived from Apple's compact and expanded Dynamic Island
    /// presentations, then adapted for a pointer-driven Mac surface. The
    /// synthetic core matches the sensor region implied by Apple's 230pt
    /// compact layout, while the expanded capture surface keeps desktop-sized
    /// controls inside a substantially tighter shell.
    enum Geometry {
        static let compactHeight: CGFloat = 37
        static let compactActivityWidth: CGFloat = 230
        static let syntheticCoreWidth: CGFloat = 126
        static let floatingTopInset: CGFloat = 6
        static let expandedCaptureWidth: CGFloat = 432
        static let expandedCaptureHeight: CGFloat = 164
        static let expandedCornerRadius: CGFloat = 32

        static let syntheticCoreSize = CGSize(
            width: syntheticCoreWidth,
            height: compactHeight
        )
    }

    /// Spacing tiers. `row` is the default gap between sibling rows; `gutter`
    /// is the inset from the island's own edge.
    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let element: CGFloat = 8
        static let row: CGFloat = 10
        static let group: CGFloat = 12
        static let gutter: CGFloat = 14
    }

    /// Corner radii. Nested shapes should step down by one tier so a badge
    /// inside a card reads as concentric rather than as a second card.
    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 13
    }

    /// The opacity ladder for white-on-black. Text below `tertiary` fails
    /// contrast on the island's fill, so these are the floor for anything
    /// readable — decoration only, below that.
    enum Ink {
        static let primary: Double = 1.0
        static let secondary: Double = 0.68
        static let tertiary: Double = 0.48
        static let hairline: Double = 0.12
        static let fill: Double = 0.08
        static let recessed: Double = 0.24
    }

    enum Stroke {
        static let hairline: CGFloat = 1
    }

    /// The shell is deliberately more elastic than its content. This makes the
    /// black shape feel alive without letting text and controls wobble as live
    /// values update.
    enum Motion {
        static let shellResponse = 0.42
        static let shellDamping = 0.76
        static let contentResponse = 0.30
        static let contentDamping = 0.86
    }

    /// Hit targets. `control` is the floor for anything clickable; a smaller
    /// number here is always a bug, not a density choice.
    enum Hit {
        static let control = NotchShotDesignSystem.minimumControlTarget
    }
}

extension Color {
    /// White at a named ink level. Reads better at call sites than a bare
    /// `.white.opacity(0.68)` and keeps the ladder greppable.
    static func islandInk(_ level: Double) -> Color {
        Color.white.opacity(level)
    }
}
