import SwiftUI

/// Text that scrolls itself when it is too long for the space it has.
///
/// A long song title in a notch has nowhere to go: truncating hides the part
/// people usually want, and wrapping doesn't fit. This measures the text and
/// only animates when it genuinely overflows, so short titles stay perfectly
/// still — a marquee that runs constantly is far more annoying than an ellipsis.
public struct MarqueeText: View {
    private let text: String
    private let font: Font
    private let color: Color
    /// Points per second.
    private let speed: Double
    /// Pause at each end before reversing, in seconds.
    private let dwell: Double
    /// Blank space between the end of the text and its repeat.
    private let gap: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationToken = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        _ text: String,
        font: Font = .system(size: 12, weight: .semibold),
        color: Color = .white,
        speed: Double = 26,
        dwell: Double = 1.6,
        gap: CGFloat = 44
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.speed = speed
        self.dwell = dwell
        self.gap = gap
    }

    private var overflows: Bool {
        textWidth > containerWidth + 1 && containerWidth > 0
    }

    public var body: some View {
        GeometryReader { geometry in
            let content = Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: gap) {
                content
                // The repeat only exists while scrolling, so a static title
                // isn't secretly rendered twice.
                if overflows && !reduceMotion {
                    content
                }
            }
            .background {
                // Measure the natural width without affecting layout.
                content
                    .hidden()
                    .background {
                        GeometryReader { textGeometry in
                            Color.clear.onAppear { textWidth = textGeometry.size.width }
                                .onChange(of: text) { _, _ in
                                    textWidth = textGeometry.size.width
                                }
                        }
                    }
            }
            .offset(x: offset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            // Fade the edges so text slides out of view instead of being
            // guillotined at the boundary.
            .mask {
                if overflows && !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.96),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .onAppear {
                containerWidth = geometry.size.width
                restart()
            }
            .onChange(of: geometry.size.width) { _, newValue in
                containerWidth = newValue
                restart()
            }
            .onChange(of: text) { _, _ in restart() }
            .onChange(of: textWidth) { _, _ in restart() }
            .onChange(of: reduceMotion) { _, _ in restart() }
        }
        .accessibilityElement()
        // VoiceOver always gets the whole string, however it is displayed.
        .accessibilityLabel(text)
    }

    private func restart() {
        animationToken += 1
        let token = animationToken
        offset = 0

        guard overflows, !reduceMotion else { return }

        let distance = textWidth + gap
        let duration = Double(distance) / speed

        Task { @MainActor in
            // Let the title be readable from the start before it moves off.
            try? await Task.sleep(for: .seconds(dwell))
            guard token == animationToken else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offset = -distance
            }
        }
    }
}
