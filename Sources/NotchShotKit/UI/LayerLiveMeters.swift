import AppKit
import QuartzCore
import SwiftUI

// Things that move continuously while they are on screen — dashes travelling
// round a drop target, a lyric filling as it is sung, recording meters — as
// Core Animation layers. Driven from SwiftUI, each of these re-rendered the
// notch on every display frame for as long as it moved; see
// LayerLoopIndicators.swift for the measurement. Here SwiftUI hands over a
// target at most ten times a second and the render server moves toward it.

/// Dashes travelling round `shape`. Animatable through the shape, so the
/// dashes follow a shell that is still springing to its size.
struct LayerDashStroke<S: Shape>: NSViewRepresentable {
    var shape: S
    var color: Color
    var lineWidth: CGFloat
    var dash: [CGFloat]
    /// Points per second the dashes travel.
    var speed: Double
    /// Shows only the half of the stroke inside the shape, so a shell that
    /// clips its content draws the same border either way.
    var insideOnly = false

    var animatableData: S.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    func makeNSView(context: Context) -> LayerDashStrokeView {
        LayerDashStrokeView()
    }

    func updateNSView(_ view: LayerDashStrokeView, context: Context) {
        let shape = shape
        view.configure(
            path: { shape.path(in: $0).cgPath },
            style: .init(color: NSColor(color), lineWidth: lineWidth, dash: dash, speed: speed, insideOnly: insideOnly)
        )
    }
}

final class LayerDashStrokeView: NSView {
    struct Style: Equatable {
        var color: NSColor
        var lineWidth: CGFloat
        var dash: [CGFloat]
        var speed: Double
        var insideOnly: Bool
    }

    private let stroke = CAShapeLayer()
    private let inside = CAShapeLayer()
    private var makePath: ((CGRect) -> CGPath)?
    private var style: Style?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineCap = .round
        layer?.addSublayer(stroke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Top-left origin, the way SwiftUI's shape paths are measured. AppKit
    // keeps a flipped view's sublayers in its coordinates; a hosted layer
    // set to `isGeometryFlipped` inside SwiftUI's already-flipped hosting
    // view was flipped twice and drew upside down.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(path: @escaping (CGRect) -> CGPath, style: Style) {
        makePath = path
        layoutPath()
        guard style != self.style else { return }
        self.style = style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.strokeColor = style.color.cgColor
        stroke.lineWidth = style.lineWidth
        stroke.lineDashPattern = style.dash.map { NSNumber(value: Double($0)) }
        stroke.mask = style.insideOnly ? inside : nil
        CATransaction.commit()
        march()
    }

    override func layout() {
        super.layout()
        layoutPath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves its window.
        if window != nil { march() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [stroke, inside].forEach { $0.contentsScale = scale }
    }

    private func layoutPath() {
        guard let makePath else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = makePath(bounds)
        stroke.frame = bounds
        stroke.path = path
        inside.frame = bounds
        inside.path = path
        CATransaction.commit()
    }

    private func march() {
        stroke.removeAnimation(forKey: "march")
        guard let style, window != nil, style.speed > 0 else { return }
        let period = max(1, style.dash.reduce(0, +))
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = 0
        march.toValue = -period
        march.duration = Double(period) / style.speed
        march.repeatCount = .infinity
        march.timingFunction = CAMediaTimingFunction(name: .linear)
        march.isRemovedOnCompletion = false
        stroke.add(march, forKey: "march")
    }
}

/// Reveals `content` from the leading edge: `progress` of it now, gliding
/// to all of it over `remaining` seconds, or holding still when that is nil.
/// The content is drawn once by its own hosting view; only its mask moves.
struct LayerSweepReveal<Content: View>: NSViewRepresentable {
    var progress: Double
    var remaining: TimeInterval?
    /// A new key restarts the glide from `progress`; the same key keeps the
    /// one already running.
    var key: AnyHashable
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> LayerSweepRevealView<Content> {
        LayerSweepRevealView(rootView: content)
    }

    func updateNSView(_ view: LayerSweepRevealView<Content>, context: Context) {
        view.hosting.rootView = content
        view.configure(.init(progress: progress, remaining: remaining, key: key))
    }
}

final class LayerSweepRevealView<Content: View>: NSView {
    struct Sweep: Equatable {
        var progress: Double
        var remaining: TimeInterval?
        var key: AnyHashable

        /// Only what was asked for changes the glide. A progress that moved
        /// on its own while playing is already where the layer is.
        func restarts(from old: Sweep?) -> Bool {
            guard let old else { return true }
            return old.key != key || (old.remaining == nil) != (remaining == nil)
        }
    }

    let hosting: NSHostingView<Content>
    private let reveal = CALayer()
    private var sweep: Sweep?

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(hosting)
        reveal.backgroundColor = NSColor.white.cgColor
        reveal.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.mask = reveal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Sweep) {
        let restarts = new.restarts(from: sweep)
        sweep = new
        if restarts { glide() }
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reveal.bounds = CGRect(origin: .zero, size: bounds.size)
        reveal.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
        // Re-assert after AppKit lays the backing layer out.
        if layer?.mask !== reveal { layer?.mask = reveal }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { glide() }
    }

    private func glide() {
        guard let sweep else { return }
        let start = min(max(sweep.progress, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reveal.removeAnimation(forKey: "sweep")
        reveal.transform = CATransform3DMakeScale(start, 1, 1)
        if let remaining = sweep.remaining, remaining > 0, start < 1, window != nil {
            reveal.transform = CATransform3DIdentity
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = start
            animation.toValue = 1
            animation.duration = remaining
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            reveal.add(animation, forKey: "sweep")
        }
        CATransaction.commit()
    }
}

/// A level filling a capsule track from the leading edge, eased to each new
/// reading. The track is drawn by SwiftUI behind this view.
struct LayerLevelFill: NSViewRepresentable {
    var fraction: Double
    /// Left to right; one colour fills the bar plainly.
    var colors: [Color]
    var locations: [Double]? = nil
    /// The narrowest a non-zero level draws, so a whisper still shows.
    var minimumWidth: CGFloat = 6
    /// Seconds to ease to a new reading: about one reading's interval.
    var glide: Double = 0.08
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerLevelFillView {
        LayerLevelFillView()
    }

    func updateNSView(_ view: LayerLevelFillView, context: Context) {
        view.configure(
            fraction: fraction,
            style: .init(
                colors: colors.map { NSColor($0).cgColor },
                locations: locations,
                minimumWidth: minimumWidth,
                glide: reduceMotion ? 0 : glide
            )
        )
    }
}

final class LayerLevelFillView: NSView {
    struct Style {
        var colors: [CGColor]
        var locations: [Double]?
        var minimumWidth: CGFloat
        var glide: Double
    }

    private let gradient = CAGradientLayer()
    private let fill = CALayer()
    private var fraction: Double = 0
    private var style: Style?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        fill.backgroundColor = NSColor.white.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        gradient.mask = fill
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func fillWidth(fraction: Double, trackWidth: CGFloat, minimumWidth: CGFloat) -> CGFloat {
        let share = min(max(fraction, 0), 1)
        guard share > 0.01 else { return 0 }
        return min(trackWidth, max(minimumWidth, trackWidth * share))
    }

    func configure(fraction: Double, style: Style) {
        let restyled = self.style.map { $0.colors != style.colors || $0.locations != style.locations } ?? true
        self.fraction = fraction
        self.style = style
        if restyled {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = style.colors.count == 1 ? [style.colors[0], style.colors[0]] : style.colors
            gradient.locations = style.locations?.map { NSNumber(value: $0) }
            CATransaction.commit()
        }
        resizeFill(animated: true)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        resizeFill(animated: false)
    }

    private func resizeFill(animated: Bool) {
        guard let style else { return }
        let width = Self.fillWidth(fraction: fraction, trackWidth: bounds.width, minimumWidth: style.minimumWidth)
        CATransaction.begin()
        if animated, style.glide > 0 {
            CATransaction.setAnimationDuration(style.glide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        fill.cornerRadius = bounds.height / 2
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }
}

/// A row of thin bars, one per recent sample, each eased to its new height.
struct LayerBarMeter: NSViewRepresentable {
    var samples: [Float]
    var tint: Color
    var barCount = 8
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1.5
    var glide: Double = 0.1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerBarMeterView {
        LayerBarMeterView()
    }

    func updateNSView(_ view: LayerBarMeterView, context: Context) {
        view.configure(.init(
            samples: Array(samples.suffix(barCount)).map { CGFloat($0) },
            color: NSColor(tint).cgColor,
            barWidth: barWidth,
            spacing: spacing,
            glide: reduceMotion ? 0 : glide
        ))
    }
}

final class LayerBarMeterView: NSView {
    struct Bars {
        var samples: [CGFloat]
        var color: CGColor
        var barWidth: CGFloat
        var spacing: CGFloat
        var glide: Double
    }

    private var bars: [CALayer] = []
    private var configuration: Bars?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A sample's bar height: never below a 2 pt dot, never past the view.
    static func barHeight(sample: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(maxHeight, max(2, sample * maxHeight))
    }

    func configure(_ new: Bars) {
        configuration = new
        place(animated: true)
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    private func place(animated: Bool) {
        guard let configuration, let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while bars.count < configuration.samples.count {
            let bar = CALayer()
            bar.contentsScale = window?.backingScaleFactor ?? 2
            host.addSublayer(bar)
            bars.append(bar)
        }
        while bars.count > configuration.samples.count {
            bars.removeLast().removeFromSuperlayer()
        }
        let count = CGFloat(bars.count)
        let total = count * configuration.barWidth + max(0, count - 1) * configuration.spacing
        var x = (bounds.width - total) / 2 + configuration.barWidth / 2
        for bar in bars {
            bar.backgroundColor = configuration.color
            bar.cornerRadius = configuration.barWidth / 2
            bar.position = CGPoint(x: x, y: bounds.midY)
            x += configuration.barWidth + configuration.spacing
        }
        CATransaction.commit()

        CATransaction.begin()
        if animated, configuration.glide > 0 {
            CATransaction.setAnimationDuration(configuration.glide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (bar, sample) in zip(bars, configuration.samples) {
            let height = Self.barHeight(sample: sample, maxHeight: bounds.height)
            bar.bounds = CGRect(x: 0, y: 0, width: configuration.barWidth, height: height)
        }
        CATransaction.commit()
    }
}

/// A ring that drains through one second each time `tick` changes: the
/// capture countdown's seconds. One linear layer animation per tick; the
/// track is part of the same view.
struct LayerTickRing: NSViewRepresentable {
    var tick: Int
    var diameter: CGFloat
    var lineWidth: CGFloat
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerTickRingView {
        LayerTickRingView()
    }

    func updateNSView(_ view: LayerTickRingView, context: Context) {
        view.configure(.init(
            tick: tick,
            diameter: diameter,
            lineWidth: lineWidth,
            color: NSColor(tint),
            drains: !reduceMotion
        ))
    }
}

final class LayerTickRingView: NSView {
    struct Ring: Equatable {
        var tick: Int
        var diameter: CGFloat
        var lineWidth: CGFloat
        var color: NSColor
        var drains: Bool
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var ring: Ring?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Top-left origin, so the arc starts at twelve o'clock.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Ring) {
        let ticked = new.tick != ring?.tick
        ring = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = new.color.withAlphaComponent(0.18).cgColor
        arc.strokeColor = new.color.cgColor
        track.lineWidth = new.lineWidth
        arc.lineWidth = new.lineWidth
        CATransaction.commit()
        layoutRing()
        if ticked { drain() }
    }

    override func layout() {
        super.layout()
        layoutRing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { drain() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [track, arc].forEach { $0.contentsScale = scale }
    }

    private func layoutRing() {
        guard let ring else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = (ring.diameter - ring.lineWidth) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    private func drain() {
        guard let ring else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.removeAnimation(forKey: "drain")
        arc.strokeEnd = ring.drains ? 0 : 1
        if ring.drains, window != nil {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = 1
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(animation, forKey: "drain")
        }
        CATransaction.commit()
    }
}
