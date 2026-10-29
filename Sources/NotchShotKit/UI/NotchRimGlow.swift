import AppKit
import QuartzCore
import SwiftUI

/// What the closed island's edge is showing. Caps Lock wins over the song:
/// it is the one that changes what the next keystroke types.
enum NotchRimKind: Equatable {
    case capsLock
    case songProgress
}

enum NotchRimPolicy {
    static func kind(
        isOpen: Bool,
        isCapsLockOn: Bool,
        showsCapsLockGlow: Bool,
        isShowingCompactPlayer: Bool,
        showsSongProgress: Bool
    ) -> NotchRimKind? {
        guard !isOpen else { return nil }
        if isCapsLockOn, showsCapsLockGlow { return .capsLock }
        if isShowingCompactPlayer, showsSongProgress { return .songProgress }
        return nil
    }

    /// How far below the shell the rim may draw: room for the glow's soft
    /// edge on the menu bar.
    static let bleed: CGFloat = 6
}

/// A soft green light around the closed notch while Caps Lock is on, the
/// way the key's own light stays lit. Static, so it costs nothing once drawn;
/// faded out over the top half so it never lines the top of the screen.
struct NotchCapsLockRim: View {
    var shape: NotchShape

    var body: some View {
        ZStack {
            shape
                .stroke(Color.green.opacity(0.55), lineWidth: 5)
                .blur(radius: 4)
            shape
                .stroke(Color.green, lineWidth: 1.5)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(-NotchRimPolicy.bleed)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The song's progress as a thin white line along the closed player's bottom
/// edge. Reads the snapshot here, not in the root view, so a position tick
/// re-evaluates only this.
struct NotchSongProgressRim: View {
    var media: MediaCoordinator
    var bottomRadius: CGFloat

    var body: some View {
        let snapshot = media.snapshot
        let duration = snapshot.duration ?? 0
        if duration > 0 {
            let position = min(snapshot.interpolatedPosition() ?? 0, duration)
            LayerProgressRim(
                progress: position / duration,
                remaining: snapshot.isPlaying ? duration - position : nil,
                inset: bottomRadius
            )
            .accessibilityHidden(true)
        }
    }
}

/// One linear Core Animation glide to the end of the track, restarted only
/// when the song is paused, played, seeked or changed. SwiftUI never draws a
/// frame of it, so a playing song costs the app nothing per frame.
struct LayerProgressRim: NSViewRepresentable {
    var progress: Double
    /// Seconds left while playing; nil holds the line still.
    var remaining: TimeInterval?
    /// The straight run of the bottom edge starts after its corners.
    var inset: CGFloat

    func makeNSView(context: Context) -> LayerProgressRimView {
        LayerProgressRimView()
    }

    func updateNSView(_ view: LayerProgressRimView, context: Context) {
        view.configure(progress: progress, remaining: remaining, inset: inset)
    }
}

final class LayerProgressRimView: NSView {
    private let glow = CAShapeLayer()
    private let line = CAShapeLayer()
    private var progress: Double = 0
    private var remaining: TimeInterval?
    private var configuredAt = Date()
    private var inset: CGFloat = 0

    /// Off by more than this from where the line already is, and the glide
    /// restarts. About a second of a four-minute song: the 1 Hz position
    /// ticks of a song that is simply playing never restart it.
    static let resyncThreshold = 0.004

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        // Top-left origin for the sublayers, so the edge is measured from
        // the top the way SwiftUI lays the shell out.
        host.isGeometryFlipped = true
        layer = host
        wantsLayer = true
        glow.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        glow.lineWidth = 4
        line.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        line.lineWidth = 1.5
        for shape in [glow, line] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.strokeEnd = 0
            host.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(progress: Double, remaining: TimeInterval?, inset: CGFloat) {
        let insetChanged = inset != self.inset
        let playStateChanged = (remaining == nil) != (self.remaining == nil)
        let drift = abs(Self.value(at: Date(), from: self.progress, remaining: self.remaining, since: configuredAt) - progress)
        self.inset = inset
        if insetChanged { layoutLine() }
        guard playStateChanged || drift > Self.resyncThreshold || line.animation(forKey: "glide") == nil && remaining != nil else {
            return
        }
        self.progress = progress
        self.remaining = remaining
        configuredAt = Date()
        glide()
    }

    /// Where the line is `date` into a glide that started at `progress`.
    static func value(at date: Date, from progress: Double, remaining: TimeInterval?, since start: Date) -> Double {
        guard let remaining, remaining > 0 else { return progress }
        let elapsed = max(0, date.timeIntervalSince(start))
        return min(1, progress + (1 - progress) * elapsed / remaining)
    }

    private func glide() {
        let now = Date()
        let current = Self.value(at: now, from: progress, remaining: remaining, since: configuredAt)
        let left = remaining.map { max(0, $0 - now.timeIntervalSince(configuredAt)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [glow, line] {
            shape.removeAnimation(forKey: "glide")
            shape.strokeEnd = left.map { $0 > 0 ? 1 : current } ?? current
            if let left, left > 0 {
                let animation = CABasicAnimation(keyPath: "strokeEnd")
                animation.fromValue = current
                animation.toValue = 1
                animation.duration = left
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                shape.add(animation, forKey: "glide")
            }
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutLine()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves its window.
        if window != nil { glide() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [layer, glow, line].forEach { $0?.contentsScale = scale }
    }

    /// Along the shell's bottom edge, which is `bleed` above this view's own.
    private func layoutLine() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = bounds.height - NotchRimPolicy.bleed - line.lineWidth / 2
        let start = min(inset, bounds.midX)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: y))
        path.addLine(to: CGPoint(x: bounds.width - start, y: y))
        for shape in [glow, line] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }
}
