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
        /// Below the camera on a physical notch, where the menu's title row
        /// moves up into the band beside the camera instead of stacking under it.
        static let expandedCaptureBodyHeight: CGFloat = 118
        /// The least room either side of a physical camera for the menu's
        /// top-row controls, padding and camera clearance included.
        static let expandedCaptureWing: CGFloat = 125
        static let expandedCornerRadius: CGFloat = 32

        /// Single-row expansions (a timer, a call) wrap the camera the way the
        /// phone's do: their controls sit in the band beside the cutout, so
        /// the open island has no empty black "forehead" above them. The
        /// heights put a 40 pt control 12 pt from the bottom edge, and the
        /// corner radius is half the height, so the controls are concentric
        /// with the corners (radius − margin = the control's own radius).
        static let expandedRowHeight: CGFloat = 64
        static let expandedCallHeight: CGFloat = 68
        /// Visible width each side of a physical camera for those rows: the
        /// wider of the two sides' content, plus clearance from the camera.
        static let expandedTimerWing: CGFloat = 158
        static let expandedCallWing: CGFloat = 206
        /// The same rows on a display with no cutout, where nothing sits
        /// between the two sides.
        static let expandedTimerFloatingWidth: CGFloat = 330
        static let expandedCallFloatingWidth: CGFloat = 430

        /// Inset for content inside the synthetic island's rounded ends.
        ///
        /// A physical notch is a hole in the bezel: its "edge" is invisible, so
        /// 6pt of padding reads as generous. The synthetic island is a drawn
        /// pill with a radius of half its height, and at the top and bottom of
        /// a 20pt tile that curve comes within 3pt of the artwork — which is
        /// what makes cover art look pressed against the border on an external
        /// display while looking fine on the notch.
        static let floatingContentInset: CGFloat = 10

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

    /// A card or tile inside the open island. The island's content frame
    /// declares the shell as its container shape, so a tile's corners are the
    /// shell's radius less the tile's distance from the edge: a tile tucked
    /// into the bottom corner curves with the shell, one further in settles
    /// on `Radius.control`. Every card on every page follows the same rule
    /// instead of picking its own number.
    static var cardShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.control)), isUniform: true)
    }

    /// Text sizes, in whole points. Half sizes crept in one feature at a time
    /// until a single page carried five sizes a point apart; every label now
    /// picks a role. `badge` is for counts and glyphs inside a mark, never
    /// for prose.
    enum TextSize {
        static let title: CGFloat = 13
        static let body: CGFloat = 12
        static let meta: CGFloat = 11
        static let caption: CGFloat = 10
        static let badge: CGFloat = 9
    }

    /// The leading mark of a row (an app icon, an agent tile, an alert glyph)
    /// is one size everywhere, so stacked rows of different kinds share a
    /// text column.
    enum Mark {
        static let size: CGFloat = 34
    }

    /// The opacity ladder for white-on-black. Text below `tertiary` fails
    /// contrast on the island's fill, so these are the floor for anything
    /// readable — decoration only, below that.
    enum Ink {
        static let primary: Double = 1.0
        /// A row's message line: dimmer than its title, brighter than meta.
        static let body: Double = 0.82
        static let secondary: Double = 0.68
        static let tertiary: Double = 0.48
        /// The unfilled part of any progress bar or scrubber.
        static let track: Double = 0.2
        static let hairline: Double = 0.12
        static let fill: Double = 0.08
        static let recessed: Double = 0.24
    }

    enum Stroke {
        static let hairline: CGFloat = 1
    }

    /// Fills for controls drawn on the island: near-black with a trace of
    /// grey, so a pill or tile reads as a shape without turning into a grey
    /// slab next to the shell's black. The edge is what defines the shape.
    enum Surface {
        static let control: Double = 0.065
        static let hover: Double = 0.11
        static let selected: Double = 0.14
        static let edge: Double = 0.08
        /// A secondary capsule button (Reply, Pause, Hide). Brighter than a
        /// control tile because it has no edge to define it.
        static let capsule: Double = 0.15
        static let capsuleHover: Double = 0.22
    }

    // Motion lives in `NotchMotion`: the shell is still more elastic than
    // its content, but the numbers now depend on the animation style.

    /// Hit targets. `control` is the floor for anything clickable; a smaller
    /// number here is always a bug, not a density choice.
    enum Hit {
        static let control = NotchShotDesignSystem.minimumControlTarget
    }
}

extension View {
    /// The island's one control surface: a near-black fill and a hairline.
    func islandControlSurface<S: InsettableShape>(_ shape: S, isHovered: Bool = false) -> some View {
        background(
            shape.fill(Color.islandInk(isHovered ? NotchIsland.Surface.hover : NotchIsland.Surface.control))
        )
        .overlay(
            shape.strokeBorder(Color.islandInk(NotchIsland.Surface.edge), lineWidth: NotchIsland.Stroke.hairline)
        )
    }
}

extension Color {
    /// White at a named ink level. Reads better at call sites than a bare
    /// `.white.opacity(0.68)` and keeps the ladder greppable.
    static func islandInk(_ level: Double) -> Color {
        Color.white.opacity(level)
    }
}
