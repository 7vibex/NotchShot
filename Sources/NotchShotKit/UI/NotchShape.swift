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
                    .font(.system(size: 8, weight: .medium))
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
