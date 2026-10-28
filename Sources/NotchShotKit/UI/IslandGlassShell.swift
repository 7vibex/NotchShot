import SwiftUI

/// How the open notch turns from the black of the camera cutout into Liquid
/// Glass.
///
/// The top of the open notch stays solid black: on a notched Mac it sits
/// against the cutout, where any transparency shows the hardware edge, and
/// the player's cover, titles and transport read best on black. Below that
/// the black eases out over a fixed distance into clear glass, so the
/// bottom edge shows the desktop through it.
///
/// Everything drawn on the shell is white ink, and clear glass over a white
/// window is pale grey. A black floor over the glass keeps that ink readable;
/// the glass level trades it against how much of the desktop shows through.
enum IslandGlassPolicy {
    static let defaultEnabled = true
    static let defaultLevel = 0.5

    /// Black over the glass below the fade, at level 1 and at level 0. At
    /// level 0 a white window comes through dark enough for the shell's
    /// secondary ink; at level 1 a wallpaper comes through nearly as bright
    /// as it is.
    static let floorOpacityRange: ClosedRange<Double> = 0.1...0.6

    /// How far the black takes to ease out, in points. A share of the shell's
    /// height stretched the ramp with every panel: muddy on tall ones, a hard
    /// edge on short ones.
    static let fadeLength: CGFloat = 56

    /// The share of the shell's height that stays solid black before the
    /// fade. On the player that is the cover, titles and position: the
    /// transport sits in the fade, and a list under it on glass.
    static let blackShare = 0.64

    /// While the shell is see-through its shadow is lighter. A dark halo
    /// round a translucent panel reads as dirt, and the glass bends it into
    /// its own edge.
    static let shadowScale = 0.5

    /// Black opacity at evenly spaced points through the fade. Eased at both
    /// ends: a straight ramp shows a line where it starts and where it stops.
    static let fadeCurve: [Double] = (0 ... 6).map { step in
        let t = Double(step) / 6
        return 1 - t * t * (3 - 2 * t)
    }

    struct Fade: Equatable {
        /// Points from the top that are solid black.
        var start: CGFloat
        /// Points from the top where the black has eased out. Lies below the
        /// shell's bottom edge on a shell too short for the whole ramp.
        var end: CGFloat
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
    ///   - bandHeight: the camera band, which never fades.
    ///   - shellHeight: the open shell's height.
    static func fade(bandHeight: CGFloat, shellHeight: CGFloat) -> Fade {
        let height = max(0, shellHeight)
        let start = max(min(max(0, bandHeight), height), height * blackShare)
        return Fade(start: start, end: start + fadeLength)
    }

    /// Black over the glass for a glass level from Settings: the higher the
    /// level, the more of the desktop shows through.
    static func floorOpacity(level: Double) -> Double {
        let level = min(1, max(0, level))
        return floorOpacityRange.upperBound
            - (floorOpacityRange.upperBound - floorOpacityRange.lowerBound) * level
    }

    /// The black's opacity from the top of the shell down to `fade.end`.
    static func stops(for fade: Fade) -> [Gradient.Stop] {
        guard fade.end > 0 else { return [.init(color: .clear, location: 0)] }
        let solid = min(1, max(0, fade.start / fade.end))
        let last = Double(fadeCurve.count - 1)
        return [.init(color: .black, location: 0)] + fadeCurve.enumerated().map { index, opacity in
            .init(color: .black.opacity(opacity), location: solid + (1 - solid) * Double(index) / last)
        }
    }

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

/// The island's background: all black while closed, black into glass while
/// open when glass is on.
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
                let fade = IslandGlassPolicy.fade(
                    bandHeight: solidBandHeight,
                    shellHeight: proxy.size.height
                )
                ZStack {
                    IslandGlassSurface(
                        shape: shape,
                        floorOpacity: IslandGlassPolicy.floorOpacity(level: preferences.islandGlassLevel)
                    )
                    // Drawn over the glass, not under it, so the top is true
                    // black rather than glass refracting black.
                    shape.fill(.black)
                        .mask(alignment: .top) {
                            LinearGradient(
                                stops: IslandGlassPolicy.stops(for: fade),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: fade.end)
                        }
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

/// The glass the open notch and the page pill under it are made of, so the
/// two read as one material.
struct IslandGlassSurface<S: Shape>: View {
    var shape: S
    var floorOpacity: Double

    var body: some View {
        ZStack {
            Color.clear.notchShotShellGlass(in: shape)
            shape.fill(.black.opacity(floorOpacity))
        }
    }
}
