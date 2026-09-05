import AppKit
import SwiftUI

/// Shared presentation rules for NotchShot's utility windows.
///
/// Liquid Glass is the functional layer: compact toolbars and a small number of
/// primary actions. Forms, images, canvases, reports, and warning content remain
/// stable underneath it.
enum NotchShotDesignSystem {
    static let minimumControlTarget: CGFloat = 36
    static let toolbarHorizontalPadding: CGFloat = 12
    static let toolbarVerticalPadding: CGFloat = 10
    static let chromeCornerRadius: CGFloat = 14

    static func usesLiquidGlass(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        !reduceTransparency && !increaseContrast
    }
}

/// Optical rules for the small activity stack that floats over the desktop or
/// lock-screen wallpaper. These cards are transient chrome with short labels,
/// so they can reveal the scene behind them; accessibility appearances replace
/// refraction with a stable opaque surface using the same geometry.
enum NotchActivityGlassPolicy {
    static let tintOpacity = 0.10
    static let highlightOpacity = 0.30
    static let shadowOpacity = 0.18

    static func usesLiquidGlass(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

/// Optical rules for the compact display-only player shown over the wallpaper
/// while loginwindow owns the secure Lock Screen.
enum LockedNowPlayingGlassPolicy {
    /// Even clear glass blurs a full-sized card at native strength. Composite
    /// only the background at this opacity so wallpaper detail stays visible;
    /// artwork, labels, and transport glyphs must remain fully opaque.
    static let materialOpacity = 0.22
    static let dimmingOpacity = 0.025
    static let highlightOpacity = 0.28

    static func usesLiquidGlass(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

/// Contrast rules shared by every colour drawn on the black island.
///
/// Album artwork already enforced a measured contrast floor, but calendar and
/// agent colours entered through separate paths and could remain too dark to
/// read. Keeping the calculation here prevents each activity from inventing a
/// different brightness clamp.
enum NotchShotColorPolicy {
    static let minimumTextContrast: CGFloat = 4.5

    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func readableAccentOnBlack(
        _ color: NSColor,
        minimumRatio: CGFloat = minimumTextContrast
    ) -> NSColor {
        guard contrastRatio(color, .black) < minimumRatio,
              let source = color.usingColorSpace(.sRGB)
        else { return color }

        // Blend only as far toward white as the contrast target requires. This
        // preserves far more of a calendar or app colour than a fixed
        // brightness clamp, especially for saturated blues.
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0 ..< 12 {
            let amount = (lower + upper) / 2
            let candidate = blendTowardWhite(source, amount: amount)
            if contrastRatio(candidate, .black) >= minimumRatio {
                upper = amount
            } else {
                lower = amount
            }
        }
        return blendTowardWhite(source, amount: upper)
    }

    static func foreground(on background: NSColor) -> NSColor {
        contrastRatio(.black, background) >= contrastRatio(.white, background)
            ? .black
            : .white
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let color = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private static func blendTowardWhite(_ color: NSColor, amount: CGFloat) -> NSColor {
        NSColor(
            srgbRed: color.redComponent + (1 - color.redComponent) * amount,
            green: color.greenComponent + (1 - color.greenComponent) * amount,
            blue: color.blueComponent + (1 - color.blueComponent) * amount,
            alpha: 1
        )
    }
}

/// Whether the playing island draws an edge at all.
///
/// The line itself is a neutral hairline: the artwork accent used to trace the
/// shell and cast a halo of its colour, which turned the island's corners a
/// different colour per album and read as a status signal. The opacity
/// constants that drove that tint are gone with it — what remains is the
/// question of whether an edge is drawn, which still has an accessibility
/// answer, since a hairline is exactly what Reduce Transparency and Increase
/// Contrast replace with a solid surface.
enum NotchMediaGlowPolicy {

    static func shouldShow(
        isMedia: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        isMedia && !reduceTransparency && !increaseContrast
    }
}

/// Shared motion values keep the app lively without making each feature invent
/// a different spring. Spatial motion disappears under Reduce Motion, while
/// short opacity changes preserve state continuity.
enum NotchShotMotion {
    static let hoverScale: CGFloat = 1.025
    static let hoverOffset: CGFloat = -1.5
    static let pressedScale: CGFloat = 0.95
    static let contentTravel: CGFloat = 8

    static func allowsSpatialAnimation(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func activeScale(
        isActive: Bool,
        reduceMotion: Bool,
        activeScale: CGFloat = hoverScale
    ) -> CGFloat {
        isActive && !reduceMotion ? activeScale : 1
    }

    static func activeOffset(
        isActive: Bool,
        reduceMotion: Bool,
        activeOffset: CGFloat = hoverOffset
    ) -> CGFloat {
        isActive && !reduceMotion ? activeOffset : 0
    }

    static func interaction(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.20, bounce: 0.20)
    }

    static func press(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.12, bounce: 0.10)
    }

    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: 0.24, bounce: 0.16)
    }

    static func content(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(duration: 0.30, bounce: 0.10)
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.985))
                .combined(with: .offset(y: contentTravel)),
            removal: .opacity
                .combined(with: .scale(scale: 0.995))
        )
    }
}

extension View {
    /// A flat, scrollable macOS form. The bounded content width keeps every row
    /// inside its split-view detail pane without turning Sections into cards.
    func notchShotFormStyle() -> some View {
        formStyle(NotchShotFlatFormStyle())
    }

    /// A functional Liquid Glass layer for compact editor and inspector
    /// toolbars. Accessibility appearances use the same geometry with a solid
    /// system background and explicit boundary.
    func notchShotToolbarSurface(dividerEdge: VerticalEdge = .bottom) -> some View {
        modifier(NotchShotToolbarSurfaceModifier(dividerEdge: dividerEdge))
    }

    /// Prominent glass belongs on an action, not on the content it affects.
    /// Keep the standard solid prominent style when transparency or contrast
    /// accessibility settings are enabled.
    func notchShotPrimaryActionStyle() -> some View {
        modifier(NotchShotPrimaryActionModifier())
    }

    /// Pointer motion for compact actions. It changes only the rendered
    /// transform and never shifts surrounding layout.
    func notchShotHoverMotion(
        activeScale: CGFloat = NotchShotMotion.hoverScale,
        activeOffset: CGFloat = NotchShotMotion.hoverOffset
    ) -> some View {
        modifier(NotchShotHoverMotionModifier(
            activeScale: activeScale,
            activeOffset: activeOffset
        ))
    }

    /// Replaces abrupt detail/state changes with one shared transition. Reduce
    /// Motion keeps a short cross-fade but removes scale and travel.
    func notchShotContentSwap<Identity: Hashable>(id: Identity) -> some View {
        modifier(NotchShotContentSwapModifier(identity: id))
    }

    /// Coordinates the separate activity cards as one native Liquid Glass
    /// family while keeping their individual rounded silhouettes.
    func notchShotActivityGlassGroup(spacing: CGFloat) -> some View {
        GlassEffectContainer(spacing: spacing) {
            self
        }
    }

    /// Native macOS 26 Liquid Glass for wallpaper-level activity chrome. There
    /// is intentionally no opaque dark wash over the glass: the adaptive system
    /// material owns refraction and legibility.
    func notchShotActivityGlassSurface(
        cornerRadius: CGFloat,
        reduceTransparency: Bool
    ) -> some View {
        modifier(NotchShotActivityGlassSurfaceModifier(
            cornerRadius: cornerRadius,
            reduceTransparency: reduceTransparency
        ))
    }

    /// A single compact glass surface for the Lock Screen player. The opaque
    /// accessibility path uses the same silhouette and explicit border.
    func notchShotLockedNowPlayingSurface(
        cornerRadius: CGFloat,
        reduceTransparency: Bool
    ) -> some View {
        modifier(NotchShotLockedNowPlayingSurfaceModifier(
            cornerRadius: cornerRadius,
            reduceTransparency: reduceTransparency
        ))
    }
}

private struct NotchShotFlatFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                configuration.content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NotchShotToolbarSurfaceModifier: ViewModifier {
    var dividerEdge: VerticalEdge

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesLiquidGlass {
            content
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: NotchShotDesignSystem.chromeCornerRadius)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            content
                .background {
                    RoundedRectangle(
                        cornerRadius: NotchShotDesignSystem.chromeCornerRadius,
                        style: .continuous
                    )
                    .fill(Color(nsColor: .windowBackgroundColor))
                }
                .overlay(alignment: .top) {
                    if dividerEdge == .top {
                        separator
                    }
                }
                .overlay(alignment: .bottom) {
                    if dividerEdge == .bottom {
                        separator
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }

    private var usesLiquidGlass: Bool {
        NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorSchemeContrast == .increased ? 0.28 : 0.12))
            .frame(height: colorSchemeContrast == .increased ? 1.5 : 1)
            .accessibilityHidden(true)
    }
}

private struct NotchShotPrimaryActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        ) {
            content
                .buttonStyle(.glassProminent)
                .notchShotHoverMotion(activeScale: 1.018, activeOffset: -1)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .notchShotHoverMotion(activeScale: 1.018, activeOffset: -1)
        }
    }
}

private struct NotchShotHoverMotionModifier: ViewModifier {
    var activeScale: CGFloat
    var activeOffset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(NotchShotMotion.activeScale(
                isActive: isHovered && isEnabled,
                reduceMotion: reduceMotion,
                activeScale: activeScale
            ))
            .offset(y: NotchShotMotion.activeOffset(
                isActive: isHovered && isEnabled,
                reduceMotion: reduceMotion,
                activeOffset: activeOffset
            ))
            .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
    }
}

private struct NotchShotContentSwapModifier<Identity: Hashable>: ViewModifier {
    var identity: Identity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .id(identity)
            .transition(NotchShotMotion.contentTransition(reduceMotion: reduceMotion))
            .animation(NotchShotMotion.content(reduceMotion: reduceMotion), value: identity)
    }
}

private struct NotchShotActivityGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var reduceTransparency: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if usesLiquidGlass {
            content
                .glassEffect(
                    .regular.tint(.black.opacity(NotchActivityGlassPolicy.tintOpacity)),
                    in: shape
                )
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(NotchActivityGlassPolicy.highlightOpacity),
                                    .white.opacity(0.08),
                                    .white.opacity(0.18),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .shadow(
                    color: .black.opacity(NotchActivityGlassPolicy.shadowOpacity),
                    radius: 12,
                    y: 5
                )
        } else {
            content
                .background {
                    shape
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay {
                            shape.strokeBorder(
                                .white.opacity(increaseContrast ? 0.46 : 0.24),
                                lineWidth: increaseContrast ? 1.5 : 1
                            )
                        }
                }
        }
    }

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var usesLiquidGlass: Bool {
        NotchActivityGlassPolicy.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

private struct NotchShotLockedNowPlayingSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var reduceTransparency: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if usesLiquidGlass {
            content
                // Contrast belongs to the foreground, rather than an opaque
                // wash over the wallpaper. Keep this outside the glass layer.
                .shadow(color: .black.opacity(0.32), radius: 1, y: 1)
                .background {
                    shape
                        .fill(.black.opacity(LockedNowPlayingGlassPolicy.dimmingOpacity))
                    shape
                        .fill(.clear)
                        .glassEffect(.clear, in: shape)
                        .opacity(LockedNowPlayingGlassPolicy.materialOpacity)
                }
                .overlay { border(shape) }
        } else {
            content
                .background {
                    shape.fill(
                        Color(white: increaseContrast ? 0.08 : 0.12)
                    )
                }
                .overlay { border(shape) }
        }
    }

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var usesLiquidGlass: Bool {
        LockedNowPlayingGlassPolicy.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    private func border(_ shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(LockedNowPlayingGlassPolicy.highlightOpacity),
                        .white.opacity(0.05),
                        .white.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: increaseContrast ? 1.5 : 1
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
