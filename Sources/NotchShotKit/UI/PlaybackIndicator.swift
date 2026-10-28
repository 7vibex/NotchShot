import AppKit
import QuartzCore
import SwiftUI

/// The now-playing level meter: a few rounded bars that rise and fall while
/// audio plays and settle low when it stops.
///
/// The bars are Core Animation layers with keyframed heights, so the render
/// server runs the motion. The previous SwiftUI version animated `frame`
/// heights with `repeatForever`, which SwiftUI interpolates on the main thread
/// every frame: any main-thread work (a source poll, a layout pass, the
/// island's own spring) stalled all three bars at once, which is the stutter
/// that made the meter look laggy. Out-of-step keyframe loops of different
/// lengths also read as a live signal rather than a metronome.
struct PlaybackIndicator: NSViewRepresentable {
    var isPlaying: Bool
    var accentColor: Color = .white
    /// False while the screens sleep: no motion nobody can see.
    var animates = true
    /// The expanded player gives the meter more room than the compact wing;
    /// scaling keeps one rhythm instead of a second hard-coded set.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PlaybackMeterView {
        PlaybackMeterView(style: .playback, scale: scale, followsLiveAudio: true)
    }

    func updateNSView(_ view: PlaybackMeterView, context: Context) {
        let isActive = isPlaying && animates && !reduceMotion
        view.update(
            isActive: isActive,
            isPlaying: isPlaying,
            color: NSColor(accentColor)
        )
        // Read here so turning the setting on or off reaches meters already
        // on screen.
        view.setFollowingLiveAudio(isActive && ExtrasPreferences.shared.usesLiveAudioMeter && view.window != nil)
    }

    static func dismantleNSView(_ view: PlaybackMeterView, coordinator: ()) {
        view.setFollowingLiveAudio(false)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlaybackMeterView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Layer-hosting view behind `PlaybackIndicator` and the call waveform.
final class PlaybackMeterView: NSView {
    /// The meter's silhouette and rhythm.
    struct Style {
        /// Resting and peak heights in points at scale 1, per bar.
        var bars: [(rest: CGFloat, peak: CGFloat)]
        var barWidth: CGFloat
        var spacing: CGFloat
        var height: CGFloat
        /// Seconds per keyframe step; lower is busier.
        var stepDuration: Double = 0.15
        /// Per-bar colours, left to right. Empty means every bar takes the
        /// colour `update` is given.
        var palette: [NSColor] = []

        /// Now playing. The outer bars stay lower than the inner ones, so the
        /// meter keeps its silhouette.
        static let playback = Style(
            bars: [(3, 8), (4, 12), (3.5, 11), (3, 9)],
            barWidth: 2,
            spacing: 1.75,
            height: 12
        )

        /// A live call, as the phone draws it: a short, busy voice meter that
        /// runs green into orange. Decorative — NotchShot cannot read another
        /// app's call audio without opening the microphone itself.
        static let call = Style(
            bars: [(3, 9), (4, 13), (3, 14), (4, 12), (3, 13), (3, 8)],
            barWidth: 2.5,
            spacing: 2,
            height: 14,
            stepDuration: 0.11,
            palette: {
                let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
                let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
                return (0..<6).map { index in
                    green.blended(withFraction: CGFloat(index) / 5, of: orange) ?? green
                }
            }()
        )
    }

    private let style: Style
    private let scale: CGFloat
    /// Now-playing meters can follow the real audio; the call meter can't.
    private let followsLiveAudio: Bool
    private var barLayers: [CALayer] = []
    private var isActive = false
    private var isPlaying = false
    private var color: NSColor = .white
    /// Attached to `LiveAudioMeter` and receiving levels.
    private var isFollowingLiveAudio = false
    private var isShowingLiveLevels = false

    init(style: Style, scale: CGFloat, followsLiveAudio: Bool = false) {
        self.style = style
        self.scale = scale
        self.followsLiveAudio = followsLiveAudio
        super.init(frame: CGRect(origin: .zero, size: Self.size(style: style, scale: scale)))
        let host = CALayer()
        host.masksToBounds = false
        layer = host
        wantsLayer = true
        for _ in style.bars {
            let bar = CALayer()
            bar.cornerRadius = style.barWidth * scale / 2
            bar.cornerCurve = .continuous
            host.addSublayer(bar)
            barLayers.append(bar)
        }
        layoutBars()
        applyResting(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func size(style: Style, scale: CGFloat) -> CGSize {
        let count = CGFloat(style.bars.count)
        return CGSize(
            width: (count * style.barWidth + (count - 1) * style.spacing) * scale,
            height: style.height * scale
        )
    }

    override var intrinsicContentSize: NSSize { Self.size(style: style, scale: scale) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutBars()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves its window; restart them
        // on the way back in rather than leaving the bars frozen mid-height.
        if window != nil, isActive, !isShowingLiveLevels { startBouncing() }
        setFollowingLiveAudio(window != nil && isActive)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let backing = window?.backingScaleFactor ?? 2
        layer?.contentsScale = backing
        barLayers.forEach { $0.contentsScale = backing }
    }

    func update(isActive: Bool, isPlaying: Bool, color: NSColor) {
        if color != self.color || isPlaying != self.isPlaying {
            self.color = color
            self.isPlaying = isPlaying
            applyColor()
        }
        guard isActive != self.isActive else { return }
        self.isActive = isActive
        setFollowingLiveAudio(isActive && window != nil)
        if isActive {
            if !isShowingLiveLevels { startBouncing() }
        } else {
            isShowingLiveLevels = false
            applyResting(animated: true)
        }
    }

    // MARK: Live audio

    func setFollowingLiveAudio(_ follow: Bool) {
        let follow = follow && followsLiveAudio && ExtrasPreferences.shared.usesLiveAudioMeter
        guard follow != isFollowingLiveAudio else { return }
        isFollowingLiveAudio = follow
        if follow {
            LiveAudioMeter.shared.attach(self)
        } else {
            LiveAudioMeter.shared.detach(self)
            if isShowingLiveLevels { liveLevelsEnded() }
        }
    }

    /// One analysis frame: each bar goes straight to its band's height with
    /// a short ease, replacing the keyframed bounce while levels flow.
    func applyLiveLevels(_ levels: [Float]) {
        guard isFollowingLiveAudio, isActive else { return }
        if !isShowingLiveLevels {
            isShowingLiveLevels = true
            barLayers.forEach { $0.removeAnimation(forKey: "bounce") }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, bar) in barLayers.enumerated() {
            let spec = style.bars[index]
            let level = CGFloat(levels.isEmpty ? 0 : levels[index % levels.count])
            bar.bounds.size.height = (spec.rest + (spec.peak - spec.rest) * level) * scale
        }
        CATransaction.commit()
    }

    /// The tap stopped or never started: back to the keyframed bounce.
    func liveLevelsEnded() {
        guard isShowingLiveLevels else { return }
        isShowingLiveLevels = false
        if isActive { startBouncing() } else { applyResting(animated: true) }
    }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        for (index, bar) in barLayers.enumerated() {
            let x = (CGFloat(index) * (style.barWidth + style.spacing) + style.barWidth / 2) * scale
            bar.position = CGPoint(x: x, y: midY)
            bar.bounds.size.width = style.barWidth * scale
        }
        CATransaction.commit()
    }

    private func applyColor() {
        let alpha: CGFloat = isPlaying ? 0.95 : 0.4
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        for (index, bar) in barLayers.enumerated() {
            if style.palette.indices.contains(index) {
                bar.backgroundColor = style.palette[index].withAlphaComponent(alpha).cgColor
                continue
            }
            // Paused, the bars go neutral grey. Keeping the artwork's accent
            // at low alpha drew a row of dim red or green dots that read as a
            // warning rather than "stopped".
            guard isPlaying else {
                bar.backgroundColor = NSColor.white.withAlphaComponent(0.32).cgColor
                continue
            }
            // A slight lift toward the middle bars gives the meter depth
            // without introducing a second colour.
            let lift: CGFloat = index == 1 || index == 2 ? 0 : 0.12
            bar.backgroundColor = color.withAlphaComponent(alpha - lift * alpha).cgColor
        }
        CATransaction.commit()
    }

    /// Settles every bar at its resting height from wherever it is now, so a
    /// pause never snaps a bar from mid-bounce to the floor.
    private func applyResting(animated: Bool) {
        for (index, bar) in barLayers.enumerated() {
            let current = bar.presentation()?.bounds.size.height ?? bar.bounds.size.height
            bar.removeAnimation(forKey: "bounce")
            let rest = style.bars[index].rest * scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = rest
            CATransaction.commit()
            guard animated, current != rest else { continue }
            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = current
            settle.toValue = rest
            settle.duration = 0.22
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: "settle")
        }
    }

    private func startBouncing() {
        let now = CACurrentMediaTime()
        for (index, bar) in barLayers.enumerated() {
            let spec = style.bars[index]
            var generator = MeterRandom(seed: UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
            // Different loop lengths per bar so the combined pattern takes far
            // longer than any one loop to repeat.
            let steps = 14 + index * 3
            var values: [CGFloat] = []
            for step in 0..<steps {
                // Alternate low and high halves so each bar keeps moving
                // instead of dithering around one height.
                let high = step.isMultiple(of: 2)
                let unit = generator.next()
                let fraction = high ? 0.55 + 0.45 * unit : 0.05 + 0.35 * unit
                values.append((spec.rest + (spec.peak - spec.rest) * fraction) * scale)
            }
            values.append(values[0])

            let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
            bounce.values = values
            bounce.calculationMode = .cubic
            bounce.duration = Double(steps) * (style.stepDuration + 0.02 * Double(index % 2))
            bounce.repeatCount = .infinity
            bounce.isRemovedOnCompletion = false
            // Offset each bar into its loop so they never start in unison.
            bounce.beginTime = now - Double(index) * 0.11
            bar.removeAnimation(forKey: "settle")
            bar.add(bounce, forKey: "bounce")
        }
    }
}

/// Small deterministic generator, so the meter's pattern is stable between
/// launches and tests rather than drawn from the system RNG.
private struct MeterRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed }

    /// A value in 0...1.
    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 9_999
    }
}
