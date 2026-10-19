import AppKit
import QuartzCore
import SwiftUI

/// Text that scrolls itself when it is too long for the space it has.
///
/// A long song title in a notch has nowhere to go: truncating hides the part
/// people usually want, and wrapping doesn't fit. This measures the text and
/// only animates when it genuinely overflows, so short titles stay perfectly
/// still — a marquee that runs constantly is far more annoying than an ellipsis.
///
/// The scroll itself is a Core Animation loop over a picture of the text. It
/// used to be a SwiftUI `repeatForever` offset, which SwiftUI advances on the
/// main thread every frame: the expanded player shows two marquees, so the
/// main thread was redrawing the notch at the display's full rate for as long
/// as the card stayed open, and the island's own springs stuttered against
/// it. It also restarted on every width change, which is every frame of an
/// open or close.
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
    /// Drawn once per text, not per update: the body runs on every frame
    /// the container is resizing.
    @State private var strip: MarqueeScroller.Strip?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

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

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                // Until the picture of this exact text exists, the plain
                // label stands in, so a new title never flashes blank or old.
                if overflows, !reduceMotion, let strip, strip.key == stripKey {
                    MarqueeScroller(
                        strip: strip,
                        distance: textWidth + gap,
                        speed: speed,
                        dwell: dwell
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    label
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                }
            }
            .background {
                // Measure the natural width without affecting layout.
                label
                    .hidden()
                    .background {
                        GeometryReader { textGeometry in
                            Color.clear.onAppear { textWidth = textGeometry.size.width }
                                .onChange(of: textGeometry.size.width) { _, width in
                                    textWidth = width
                                }
                        }
                    }
            }
            .onAppear {
                containerWidth = geometry.size.width
                refreshStrip()
            }
            // Only decides whether to scroll at all. The loop does not depend
            // on the width, so a container springing open does not restart it.
            .onChange(of: geometry.size.width) { _, newValue in
                containerWidth = newValue
            }
            .onChange(of: stripKey) { _, _ in refreshStrip() }
            .onChange(of: overflows) { _, _ in refreshStrip() }
            .onChange(of: reduceMotion) { _, _ in refreshStrip() }
        }
        .accessibilityElement()
        // VoiceOver always gets the whole string, however it is displayed.
        .accessibilityLabel(text)
    }

    private var stripKey: String {
        "\(text)|\(textWidth)|\(displayScale)|\(gap)"
    }

    /// The text, a gap and the text again, drawn once. Scrolling this picture
    /// by one text-plus-gap and starting over is a seamless loop. Only drawn
    /// while the text overflows, so a short title never pays for it.
    private func refreshStrip() {
        guard overflows, !reduceMotion else { return }
        let key = stripKey
        guard strip?.key != key else { return }
        let renderer = ImageRenderer(content: HStack(spacing: gap) { label; label })
        renderer.scale = max(1, displayScale)
        renderer.isOpaque = false
        guard let image = renderer.cgImage else {
            strip = nil
            return
        }
        strip = MarqueeScroller.Strip(
            image: image,
            size: CGSize(
                width: CGFloat(image.width) / renderer.scale,
                height: CGFloat(image.height) / renderer.scale
            ),
            scale: renderer.scale,
            key: key
        )
    }
}

/// The layer that carries the scrolling picture.
private struct MarqueeScroller: NSViewRepresentable {
    struct Strip: Equatable {
        var image: CGImage
        var size: CGSize
        var scale: CGFloat
        /// What the picture shows; a new key restarts the scroll.
        var key: String

        static func == (lhs: Strip, rhs: Strip) -> Bool { lhs.key == rhs.key }
    }

    var strip: Strip
    var distance: CGFloat
    var speed: Double
    var dwell: Double

    func makeNSView(context: Context) -> MarqueeLayerView {
        MarqueeLayerView()
    }

    func updateNSView(_ view: MarqueeLayerView, context: Context) {
        view.configure(strip: strip, distance: distance, speed: speed, dwell: dwell)
    }
}

private final class MarqueeLayerView: NSView {
    private let strip = CALayer()
    private let fade = CAGradientLayer()
    private var key: String?
    private var distance: CGFloat = 0
    private var speed: Double = 26
    private var dwell: Double = 1.6

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        host.masksToBounds = true
        layer = host
        wantsLayer = true
        host.addSublayer(strip)
        // Fade the edges so text slides out of view instead of being
        // guillotined at the boundary.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.04, 0.96, 1]
        host.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(strip newStrip: MarqueeScroller.Strip, distance: CGFloat, speed: Double, dwell: Double) {
        let restarts = newStrip.key != key || distance != self.distance || speed != self.speed || dwell != self.dwell
        guard restarts else { return }
        key = newStrip.key
        self.distance = distance
        self.speed = speed
        self.dwell = dwell
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contents = newStrip.image
        strip.contentsScale = newStrip.scale
        strip.bounds = CGRect(origin: .zero, size: newStrip.size)
        CATransaction.commit()
        layoutLayers()
        restartScroll()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves its window.
        if window != nil { restartScroll() }
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        // Top-aligned, where the static label sits, whichever way this
        // layer's geometry runs.
        let flipped = layer?.contentsAreFlipped() ?? false
        strip.anchorPoint = CGPoint(x: 0, y: flipped ? 0 : 1)
        strip.position = CGPoint(x: 0, y: flipped ? bounds.minY : bounds.maxY)
        CATransaction.commit()
    }

    private func restartScroll() {
        strip.removeAnimation(forKey: "scroll")
        guard key != nil, window != nil, distance > 0, speed > 0 else { return }
        let scroll = CABasicAnimation(keyPath: "position.x")
        scroll.fromValue = 0
        scroll.toValue = -distance
        scroll.duration = Double(distance) / speed
        scroll.repeatCount = .infinity
        // Let the title be readable from the start before it moves off.
        scroll.beginTime = CACurrentMediaTime() + dwell
        scroll.fillMode = .backwards
        scroll.isRemovedOnCompletion = false
        strip.add(scroll, forKey: "scroll")
    }
}
