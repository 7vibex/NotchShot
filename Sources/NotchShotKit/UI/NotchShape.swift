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
            content.glassEffect(liquidGlass, in: shape)
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

/// A compact, live waveform for the recording HUD. Every bar is a recent RMS
/// sample from the capture stream; silence is still instead of being animated
/// decoratively, and Reduce Motion disables interpolation between samples.
struct AudioLevelBar: View {
    var level: Float
    var samples: [Float]
    var isEnabled: Bool
    var isAvailable: Bool
    var symbolName: String
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 9))
                .foregroundStyle(iconColor)
                .frame(width: 12)

            if isEnabled, !isAvailable {
                Label("Meter unavailable", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(height: 14)
            } else {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(displayedSamples.indices, id: \.self) { index in
                        let sample = displayedSamples[index]
                        Capsule()
                            .fill(color(for: sample))
                            .frame(width: 2, height: barHeight(for: sample))
                    }
                }
                .frame(height: 14)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: displayedSamples)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var displayedSamples: [Float] {
        let recent = Array(samples.suffix(RecordingStatus.waveformSampleCount))
        if recent.count == RecordingStatus.waveformSampleCount { return recent }
        return Array(
            repeating: 0,
            count: RecordingStatus.waveformSampleCount - recent.count
        ) + recent
    }

    private var levelDescription: String {
        switch level {
        case ..<0.02: "silent"
        case ..<0.35: "low"
        case ..<0.75: "moderate"
        case ..<0.92: "high"
        default: "near clipping"
        }
    }

    private var accessibilityValue: String {
        if !isEnabled { return "off" }
        if !isAvailable { return "meter unavailable" }
        return levelDescription
    }

    private var iconColor: Color {
        if !isEnabled { return .white.opacity(0.3) }
        if !isAvailable { return .orange }
        return .white
    }

    private func barHeight(for sample: Float) -> CGFloat {
        guard isEnabled, isAvailable else { return 2 }
        let clamped = max(0, min(CGFloat(sample), 1))
        return 2 + 11 * clamped
    }

    private func color(for sample: Float) -> Color {
        guard isEnabled, isAvailable else { return .white.opacity(0.18) }
        if sample >= 0.9 { return .red }
        if sample >= 0.7 { return .yellow }
        return .green
    }
}

/// Small circular control used throughout the notch.
struct NotchIconButton: View {
    static let minimumHitSize = NotchShotDesignSystem.minimumControlTarget
    static let visualDiameter: CGFloat = 30
    static let disabledOpacity = 0.38
    static let usesLiquidGlass = true

    var systemName: String
    var label: String
    var tint: Color = .white
    var isProminent = false
    var visualScale: CGFloat = 1
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        // Sized, not transformed. The island's content is wrapped in a glass
        // effect container, which draws each glass shape from the geometry it
        // recorded for that element — a `scaleEffect` layered on top is
        // invisible to that pass. The circle came out at 72% while the glyph
        // stayed full size and pinned itself to the shrunken circle's
        // top-left, so `eye.slash` and the capture menu's `xmark` sat low and
        // right of their own buttons, spilling over the edge.
        let scale = visualScale * NotchShotMotion.activeScale(
            isActive: isHovered && isEnabled,
            reduceMotion: reduceMotion,
            activeScale: 1.07
        )
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : tint)
                .frame(
                    width: Self.visualDiameter * scale,
                    height: Self.visualDiameter * scale
                )
                .notchControlSurface(
                    in: Circle(),
                    reduceTransparency: reduceTransparency,
                    tint: isProminent ? tint : nil,
                    emphasized: isProminent || isHovered
                )
                .offset(y: NotchShotMotion.activeOffset(
                    isActive: isHovered && isEnabled,
                    reduceMotion: reduceMotion,
                    activeOffset: -1
                ))
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        // Plain buttons do not receive AppKit's standard disabled appearance.
        // Without this, an unavailable media command looks clickable but does
        // nothing, which reads as a broken hit target.
        .opacity(isEnabled ? 1 : Self.disabledOpacity)
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(isEnabled ? label : "\(label) unavailable")
        .accessibilityLabel(label)
    }

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
