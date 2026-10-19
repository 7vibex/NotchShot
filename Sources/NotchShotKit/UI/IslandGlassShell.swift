import SwiftUI

/// Where the open notch's black melts into Liquid Glass.
///
/// The top always stays solid black: on a notched Mac that band sits against
/// the camera cutout, and any transparency there shows the hardware edge.
/// Below it the black fades toward the bottom, but never to nothing. Notch
/// content is white ink designed for a dark shell, so the floor keeps it
/// readable over a white window.
enum IslandGlassPolicy {
    /// Black that remains at the bottom edge at level 0 and level 1.
    static let bottomOpacityRange: ClosedRange<Double> = 0.3...0.85
    /// Dark tint on the glass itself, for the same legibility reason.
    static let glassTintOpacity = 0.22

    struct Fade: Equatable {
        /// Fraction of the shell's height that is still solid black.
        var start: Double
        /// Black opacity left at the bottom edge.
        var bottomOpacity: Double
    }

    static func usesGlass(
        enabled: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        enabled && NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    /// - Parameters:
    ///   - level: 0...1 from Settings.
    ///   - solidBandFraction: the camera band's share of the shell height.
    static func fade(level: Double, solidBandFraction: Double) -> Fade {
        let level = min(1, max(0, level))
        let band = min(1, max(0, solidBandFraction))
        // Level 0 keeps black down to 60% of what is left below the band;
        // level 1 starts melting right under it.
        let start = band + (1 - band) * 0.6 * (1 - level)
        let range = bottomOpacityRange
        let bottom = range.upperBound * (1 - level) + range.lowerBound * level
        return Fade(start: start, bottomOpacity: bottom)
    }
}

/// The island's background: all black while closed, black-into-glass while
/// open when the user has turned glass on.
struct IslandShellFill<S: Shape>: View {
    var shape: S
    var isExpanded: Bool
    /// Height of the band that must stay opaque (the camera cutout), in points.
    var solidBandHeight: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let preferences = Preferences.shared
        if IslandGlassPolicy.usesGlass(
            enabled: preferences.islandGlassEnabled,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        ) {
            GeometryReader { proxy in
                let height = max(1, proxy.size.height)
                let fade = IslandGlassPolicy.fade(
                    level: preferences.islandGlassLevel,
                    solidBandFraction: Double(solidBandHeight / height)
                )
                ZStack {
                    Color.clear
                        .notchShotShellGlass(in: shape, tintOpacity: IslandGlassPolicy.glassTintOpacity)
                    shape.fill(LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: fade.start),
                            .init(color: .black.opacity(fade.bottomOpacity), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    // Closed, the notch must read as hardware. Fading this
                    // layer (rather than swapping views) lets the glass
                    // appear on the shell's own spring.
                    shape.fill(.black)
                        .opacity(isExpanded ? 0 : 1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            shape.fill(.black)
        }
    }
}

extension IslandGlassPolicy {
    /// Whether the shell is currently see-through, so the shadow carrier
    /// behind it must not show black through the glass.
    static func isSeeThrough(
        enabled: Bool,
        isExpanded: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        isExpanded && usesGlass(
            enabled: enabled,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}
