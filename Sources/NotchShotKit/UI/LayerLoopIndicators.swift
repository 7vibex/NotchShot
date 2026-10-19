import AppKit
import QuartzCore
import SwiftUI

// The island's ambient loops — a spinning arc, a pulsing dot, a sweeping
// progress segment — as Core Animation layers.
//
// SwiftUI runs `repeatForever` animations and `TimelineView(.animation)` on the
// main thread: every display frame it updates the view graph, lays the hosting
// view out and commits a transaction, for as long as the loop is on screen.
// Measured in the notch, a 15 pt spinner kept the main thread close to fully
// busy, so the island's own open and close springs had no frame budget left
// and stuttered. Layer animations are handed to the render server once and
// cost the app nothing per frame, the same reason `PlaybackMeterView` exists.

/// A short arc turning around a dimmed track: the island's progress spinner.
struct LayerSpinner: NSViewRepresentable {
    var diameter: CGFloat
    var lineWidth: CGFloat
    var tint: Color = .white
    /// Opacity of the full-circle track behind the arc. Zero draws no track.
    var trackOpacity: Double = 0.18
    /// Fraction of the circle the arc covers.
    var arcLength: CGFloat = 0.28
    /// Seconds per turn.
    var period: Double = 0.9
    /// True keeps the whole stroke inside `diameter`. False centres the
    /// stroke on the edge, the way SwiftUI's `Circle().stroke` draws.
    var insetsStroke = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerSpinnerView {
        LayerSpinnerView()
    }

    func updateNSView(_ view: LayerSpinnerView, context: Context) {
        view.configure(.init(
            diameter: diameter,
            lineWidth: lineWidth,
            color: NSColor(tint),
            trackOpacity: trackOpacity,
            arcLength: arcLength,
            period: period,
            insetsStroke: insetsStroke,
            spins: !reduceMotion
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerSpinnerView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class LayerSpinnerView: NSView {
    struct Configuration: Equatable {
        var diameter: CGFloat
        var lineWidth: CGFloat
        var color: NSColor
        var trackOpacity: Double
        var arcLength: CGFloat
        var period: Double
        var insetsStroke: Bool
        var spins: Bool
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var configuration: Configuration?

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        layer = host
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            host.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        let restarts = new.period != configuration?.period || new.spins != configuration?.spins
        configuration = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = new.color.withAlphaComponent(new.trackOpacity).cgColor
        track.isHidden = new.trackOpacity <= 0
        arc.strokeColor = new.color.cgColor
        track.lineWidth = new.lineWidth
        arc.lineWidth = new.lineWidth
        arc.strokeEnd = new.arcLength
        // Static under Reduce Motion: the arc stays, it just does not turn.
        arc.opacity = new.spins ? 1 : 0.6
        CATransaction.commit()
        layoutShapes()
        if restarts { restartSpin() }
    }

    override func layout() {
        super.layout()
        layoutShapes()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves its window.
        if window != nil { restartSpin() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [layer, track, arc].forEach { $0?.contentsScale = scale }
    }

    private func layoutShapes() {
        guard let configuration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let inset = configuration.insetsStroke ? configuration.lineWidth / 2 : 0
        let radius = max(0, side / 2 - inset)
        let center = CGPoint(x: side / 2, y: side / 2)
        // One full circle starting at twelve o'clock; `strokeEnd` trims it to
        // the arc. Drawn the same way on either geometry, since only the turn
        // direction depends on flipping.
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, arc] {
            shape.bounds = CGRect(origin: .zero, size: frame.size)
            shape.position = CGPoint(x: frame.midX, y: frame.midY)
            shape.path = path
        }
        CATransaction.commit()
    }

    private func restartSpin() {
        arc.removeAnimation(forKey: "spin")
        guard let configuration, configuration.spins, window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise on screen, whichever way this layer's geometry runs.
        let turn: CGFloat = arc.contentsAreFlipped() ? 2 * .pi : -2 * .pi
        spin.fromValue = 0
        spin.toValue = turn
        spin.duration = max(0.1, configuration.period)
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

/// A filled dot whose opacity breathes: the recording indicator, an agent's
/// working light.
struct LayerPulsingDot: NSViewRepresentable {
    var diameter: CGFloat
    var color: Color = .red
    /// Opacity at rest, and at the start of each breath.
    var restingOpacity: Float = 1
    /// Opacity at the far end of each breath.
    var pulseOpacity: Float = 0.35
    /// Seconds from rest to the far end (and the same back).
    var halfPeriod: Double = 0.9
    var pulses = true
    /// A ring around the dot, centred on its edge as `Circle().stroke` draws.
    var outlineColor: Color?
    var outlineWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerPulsingDotView {
        LayerPulsingDotView()
    }

    func updateNSView(_ view: LayerPulsingDotView, context: Context) {
        view.configure(.init(
            color: NSColor(color),
            restingOpacity: restingOpacity,
            pulseOpacity: pulseOpacity,
            halfPeriod: halfPeriod,
            pulses: pulses && !reduceMotion,
            outlineColor: outlineColor.map { NSColor($0) },
            outlineWidth: outlineColor == nil ? 0 : outlineWidth
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerPulsingDotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class LayerPulsingDotView: NSView {
    struct Configuration: Equatable {
        var color: NSColor
        var restingOpacity: Float
        var pulseOpacity: Float
        var halfPeriod: Double
        var pulses: Bool
        var outlineColor: NSColor?
        var outlineWidth: CGFloat
    }

    private let dot = CALayer()
    private var configuration: Configuration?

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        layer = host
        wantsLayer = true
        host.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        let restarts = new.pulses != configuration?.pulses
            || new.restingOpacity != configuration?.restingOpacity
            || new.pulseOpacity != configuration?.pulseOpacity
            || new.halfPeriod != configuration?.halfPeriod
        configuration = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = new.color.cgColor
        dot.borderColor = new.outlineColor?.cgColor
        dot.borderWidth = new.outlineWidth
        dot.opacity = new.restingOpacity
        CATransaction.commit()
        needsLayout = true
        if restarts { restartPulse() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A layer's border lies inside its bounds, so the layer grows by the
        // outline's width to centre the ring on the dot's edge.
        let side = min(bounds.width, bounds.height) + (configuration?.outlineWidth ?? 0)
        dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.cornerRadius = side / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartPulse() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        dot.contentsScale = scale
    }

    private func restartPulse() {
        dot.removeAnimation(forKey: "pulse")
        guard let configuration, configuration.pulses, window != nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = configuration.restingOpacity
        pulse.toValue = configuration.pulseOpacity
        pulse.duration = max(0.1, configuration.halfPeriod)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: "pulse")
    }
}

/// A short segment sweeping back and forth along a track: progress with no
/// number to show. The track itself is drawn by SwiftUI behind this view.
struct LayerProgressSweep: NSViewRepresentable {
    var tint: Color
    /// The segment's share of the track's width.
    var segment: CGFloat = 0.28
    /// Seconds for one pass, either way.
    var pass: Double = 1.1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerProgressSweepView {
        LayerProgressSweepView()
    }

    func updateNSView(_ view: LayerProgressSweepView, context: Context) {
        view.configure(.init(color: NSColor(tint), segment: segment, pass: pass, sweeps: !reduceMotion))
    }
}

final class LayerProgressSweepView: NSView {
    struct Configuration: Equatable {
        var color: NSColor
        var segment: CGFloat
        var pass: Double
        var sweeps: Bool
    }

    private let bar = CALayer()
    private var configuration: Configuration?
    /// The sweep's phase origin. Restarting against the same origin after a
    /// resize keeps the segment where it was in its pass instead of snapping
    /// back to the start — the track resizes on every frame of an open.
    private var phaseOrigin = CACurrentMediaTime()
    private var laidOutWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        host.masksToBounds = true
        layer = host
        wantsLayer = true
        host.addSublayer(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        configuration = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.backgroundColor = new.color.cgColor
        CATransaction.commit()
        laidOutWidth = -1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let configuration, abs(bounds.width - laidOutWidth) > 0.25 || bar.animation(forKey: "sweep") == nil else {
            return
        }
        laidOutWidth = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = bounds.width * configuration.segment
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        bar.cornerRadius = bounds.height / 2
        let start = CGPoint(x: bounds.minX + width / 2, y: bounds.midY)
        bar.position = start
        CATransaction.commit()

        bar.removeAnimation(forKey: "sweep")
        guard configuration.sweeps, window != nil, bounds.width > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = start.x
        sweep.toValue = bounds.maxX - width / 2
        sweep.duration = max(0.1, configuration.pass)
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.beginTime = phaseOrigin
        sweep.isRemovedOnCompletion = false
        bar.add(sweep, forKey: "sweep")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            laidOutWidth = -1
            needsLayout = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        bar.contentsScale = scale
    }
}

/// Content that drifts gently up and down for as long as it is on screen.
///
/// The content is drawn once by its own hosting view and the layer carrying
/// it moves; a SwiftUI `repeatForever` offset re-rendered the whole notch on
/// every frame of the drift instead.
struct LayerDrift<Content: View>: NSViewRepresentable {
    /// Points either side of rest.
    var amplitude: CGFloat
    /// Seconds from one end to the other.
    var halfPeriod: Double
    /// Seconds before the drift begins.
    var delay: Double = 0
    var drifts = true
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerDriftView<Content> {
        LayerDriftView(rootView: content)
    }

    func updateNSView(_ view: LayerDriftView<Content>, context: Context) {
        view.hosting.rootView = content
        view.configure(.init(
            amplitude: amplitude,
            halfPeriod: halfPeriod,
            delay: delay,
            drifts: drifts && !reduceMotion
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerDriftView<Content>, context: Context) -> CGSize? {
        nsView.hosting.fittingSize
    }
}

final class LayerDriftView<Content: View>: NSView {
    struct Configuration: Equatable {
        var amplitude: CGFloat
        var halfPeriod: Double
        var delay: Double
        var drifts: Bool
    }

    let hosting: NSHostingView<Content>
    private var configuration: Configuration?

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.wantsLayer = true
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        configuration = new
        restartDrift()
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartDrift() }
    }

    private func restartDrift() {
        guard let layer = hosting.layer else { return }
        layer.removeAnimation(forKey: "drift")
        guard let configuration, configuration.drifts, window != nil, configuration.amplitude > 0 else { return }
        // Starts low and rises first, whichever way this layer's geometry runs.
        let down: CGFloat = layer.contentsAreFlipped() ? configuration.amplitude : -configuration.amplitude
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = down
        drift.toValue = -down
        drift.duration = max(0.1, configuration.halfPeriod)
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drift.beginTime = CACurrentMediaTime() + configuration.delay
        drift.fillMode = .backwards
        drift.isRemovedOnCompletion = false
        layer.add(drift, forKey: "drift")
    }
}
