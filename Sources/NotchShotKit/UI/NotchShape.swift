import SwiftUI

/// Shared Liquid Glass policy for controls inside the black notch shell.
///
/// Only compact controls use glass. The shell and its media, status, warning,
/// and file content stay optically stable; accessibility appearances replace
/// refraction with a solid surface using the same shape.
enum NotchControlSurfacePolicy {
    static let usesLiquidGlass = true

    static func shouldUseLiquidGlass(
        reduceTransparency: Bool,
        increaseContrast: Bool,
        allowsLiquidGlass: Bool = true
    ) -> Bool {
        usesLiquidGlass
            && allowsLiquidGlass
            && NotchShotDesignSystem.usesLiquidGlass(
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
    }

    static func usesOpaqueSurface(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        reduceTransparency || increaseContrast
    }

    static func fillOpacity(increaseContrast: Bool, emphasized: Bool) -> Double {
        if increaseContrast { return emphasized ? 0.34 : 0.26 }
        return emphasized ? 0.18 : 0.10
    }

    static func strokeOpacity(increaseContrast: Bool, emphasized: Bool) -> Double {
        if increaseContrast { return emphasized ? 0.56 : 0.42 }
        return emphasized ? 0.28 : 0.16
    }
}

extension View {
    /// Stable control grouping for the notch. Increase Contrast is read here so
    /// individual call sites cannot accidentally omit its opaque treatment.
    func notchControlSurface<S: Shape>(
        in shape: S,
        reduceTransparency: Bool,
        tint: Color? = nil,
        emphasized: Bool = false,
        allowsLiquidGlass: Bool = true,
        interactive: Bool = true
    ) -> some View {
        modifier(NotchControlSurfaceModifier(
            shape: shape,
            reduceTransparency: reduceTransparency,
            tint: tint,
            emphasized: emphasized,
            allowsLiquidGlass: allowsLiquidGlass,
            interactive: interactive
        ))
    }
}

private struct NotchControlSurfaceModifier<S: Shape>: ViewModifier {
    var shape: S
    var reduceTransparency: Bool
    var tint: Color?
    var emphasized: Bool
    var allowsLiquidGlass: Bool
    var interactive: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if NotchControlSurfacePolicy.shouldUseLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            allowsLiquidGlass: allowsLiquidGlass
        ) {
            content
                .glassEffect(liquidGlass, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            content.background {
                shape
                    .fill(surfaceColor)
                    .overlay {
                        shape.stroke(
                            .white.opacity(NotchControlSurfacePolicy.strokeOpacity(
                                increaseContrast: increaseContrast,
                                emphasized: emphasized
                            )),
                            lineWidth: increaseContrast ? 1.25 : 1
                        )
                    }
            }
        }
    }

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var surfaceColor: Color {
        if let tint, emphasized {
            return tint.opacity(increaseContrast ? 1 : 0.86)
        }
        if !allowsLiquidGlass || NotchControlSurfacePolicy.usesOpaqueSurface(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        ) {
            return Color(
                white: emphasized ? (increaseContrast ? 0.32 : 0.24) : (increaseContrast ? 0.24 : 0.18)
            )
        }
        return .white.opacity(NotchControlSurfacePolicy.fillOpacity(
            increaseContrast: false,
            emphasized: emphasized
        ))
    }

    private var liquidGlass: Glass {
        var glass = Glass.regular
        if interactive {
            glass = glass.interactive()
        }
        if let tint {
            glass = glass.tint(tint.opacity(emphasized ? 0.82 : 0.32))
        }
        return glass
    }
}

/// The island outline. A physical MacBook notch flows out of the bezel with
/// inverted top fillets; a synthetic island is detached from the screen edge
/// and uses one concentric continuous radius on every corner.
public struct NotchShape: Shape {
    public var bottomRadius: CGFloat
    public var topRadius: CGFloat
    public var isFloating: Bool

    public init(
        bottomRadius: CGFloat,
        topRadius: CGFloat = 8,
        isFloating: Bool = false
    ) {
        self.bottomRadius = bottomRadius
        self.topRadius = topRadius
        self.isFloating = isFloating
    }

    /// Lets the shape animate along with the island's size changes.
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set {
            bottomRadius = newValue.first
            topRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        if isFloating {
            return RoundedRectangle(
                cornerRadius: min(bottomRadius, rect.height / 2, rect.width / 2),
                style: .continuous
            )
            .path(in: rect)
        }

        var path = Path()
        let top = min(topRadius, rect.height / 3, rect.width / 3)
        // A continuous corner runs `reach` radii along each edge. Past the
        // point where it would meet the top fillet, or the opposite corner,
        // the outline would cross itself, so the radius stops there.
        let reach = Self.continuousReach
        let bottom = max(0, min(bottomRadius, (rect.height - top) / reach, rect.width / (2 * reach)))

        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        // Inverted fillet flaring out into the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + top),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom * reach))
        Self.addContinuousCorner(
            to: &path,
            corner: CGPoint(x: rect.minX, y: rect.maxY),
            radius: bottom,
            inwardX: 1,
            verticalFirst: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottom * reach, y: rect.maxY))
        Self.addContinuousCorner(
            to: &path,
            corner: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: bottom,
            inwardX: -1,
            verticalFirst: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + top, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    /// How far along each edge a continuous corner of radius 1 reaches.
    static let continuousReach: CGFloat = 1.528665

    /// The bottom corners use Apple's continuous ("squircle") curve, the one
    /// the Dynamic Island itself is cut to. A circular or quadratic corner
    /// starts abruptly where the straight edge ends, which is what made the
    /// open shell read as a rounded rectangle rather than the island.
    ///
    /// The control points are SwiftUI's own `.continuous` rounded-rectangle
    /// curve for a unit radius, as offsets from the corner toward the inside.
    /// The curve is symmetric about the diagonal, so walking it the other way
    /// round only swaps the axes.
    private static let continuousCurve: [(c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
        (CGPoint(x: 0, y: 1.088490), CGPoint(x: 0, y: 0.868407), CGPoint(x: 0.074911, y: 0.631494)),
        (CGPoint(x: 0.169060, y: 0.372824), CGPoint(x: 0.372824, y: 0.169060), CGPoint(x: 0.631494, y: 0.074911)),
        (CGPoint(x: 0.868407, y: 0), CGPoint(x: 1.088490, y: 0), CGPoint(x: 1.528665, y: 0)),
    ]

    /// Adds one bottom corner, starting from the current point.
    /// - Parameters:
    ///   - inwardX: +1 when the inside of the shape lies to the corner's right.
    ///   - verticalFirst: true when arriving down a side edge, false when
    ///     arriving along the bottom edge.
    private static func addContinuousCorner(
        to path: inout Path,
        corner: CGPoint,
        radius: CGFloat,
        inwardX: CGFloat,
        verticalFirst: Bool
    ) {
        guard radius > 0 else {
            path.addLine(to: corner)
            return
        }
        // (along the bottom edge, up the side edge), both measured inward.
        func point(_ offset: CGPoint) -> CGPoint {
            let along = verticalFirst ? offset.x : offset.y
            let up = verticalFirst ? offset.y : offset.x
            return CGPoint(x: corner.x + inwardX * along * radius, y: corner.y - up * radius)
        }
        for segment in continuousCurve {
            path.addCurve(to: point(segment.end), control1: point(segment.c1), control2: point(segment.c2))
        }
    }
}

/// The metrics of the notch's small circular controls.
enum NotchIconButton {
    static let minimumHitSize = NotchShotDesignSystem.minimumControlTarget
    static let visualDiameter: CGFloat = 30
    static let disabledOpacity = 0.38
    static let usesLiquidGlass = true
}

/// Gives the notch's plain controls immediate pointer feedback without adding
/// layout movement or persistent decoration.
struct NotchPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(NotchShotMotion.activeScale(
                isActive: configuration.isPressed,
                reduceMotion: reduceMotion,
                activeScale: NotchShotMotion.pressedScale
            ))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                NotchShotMotion.press(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}
