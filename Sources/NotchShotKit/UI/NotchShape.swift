import SwiftUI

/// The island outline: square at the top edge (it meets the bezel), rounded at
/// the bottom, with small inverted fillets on the top corners so it flows out of
/// the surrounding black rather than sitting on it as a separate rectangle.
public struct NotchShape: Shape {
    public var bottomRadius: CGFloat
    public var topRadius: CGFloat

    public init(bottomRadius: CGFloat, topRadius: CGFloat = 8) {
        self.bottomRadius = bottomRadius
        self.topRadius = topRadius
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
        var path = Path()
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)
        let top = min(topRadius, rect.height / 3, rect.width / 3)

        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        // Inverted fillet flaring out into the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + top),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + top, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// A level meter for the recording HUD.
struct AudioLevelBar: View {
    var level: Float
    var isEnabled: Bool
    var symbolName: String
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 9))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.3))
                .frame(width: 12)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(isEnabled ? level : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isEnabled ? "\(Int(level * 100)) percent" : "off")
    }

    /// Green through amber to red, so clipping is visible without a numeric
    /// readout in a 4-point-tall meter.
    private var meterColor: Color {
        switch level {
        case ..<0.7: .green
        case ..<0.9: .yellow
        default: .red
        }
    }
}

/// Small circular control used throughout the notch.
struct NotchIconButton: View {
    var systemName: String
    var label: String
    var tint: Color = .white
    var isProminent = false
    var action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : tint)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(
                            reduceTransparency ? AnyShapeStyle(Color.white.opacity(0.22))
                                               : AnyShapeStyle(.thinMaterial)
                        ))
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
