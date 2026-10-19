import AppKit
import QuartzCore

/// The path a fresh capture takes from where it was on screen up into the
/// notch.
///
/// Apple describes a Live Activity starting as the app swooping up into the
/// Dynamic Island, as if it physically moves into that space. A capture is
/// the Mac's version of that moment: the pixels the user just chose lift off
/// the screen and disappear under the island's black shell, where the shelf
/// thumbnail then arrives.
///
/// Pure values, so the geometry and timing are testable without a window.
struct CaptureSwoopPlan: Equatable {
    /// Cocoa global coordinates (bottom-left origin).
    var start: CGRect
    var end: CGRect
    var endCornerRadius: CGFloat
    /// Perceptual durations of the three springs. The horizontal one is the
    /// quickest, so the image lines up under the notch and then rises into it
    /// instead of travelling in a straight diagonal.
    var horizontalDuration: Double
    var verticalDuration: Double
    var sizeDuration: Double
    /// Seconds from the start. The image is hidden by the shell by the end of
    /// the fade anyway; the fade covers displays where nothing is drawn there.
    var fadeStart: Double
    var fadeEnd: Double
    /// When the image reaches the island, measured from the start: the moment
    /// the shelf thumbnail starts its own arrival.
    var landing: Double

    /// The largest part of the notch the image shrinks into, so it ends fully
    /// behind the shell.
    static let endFill = CGSize(width: 0.5, height: 0.7)

    static func make(
        source: CGRect,
        metrics: NotchMetrics,
        style: IslandAnimationStyle
    ) -> CaptureSwoopPlan? {
        guard source.width >= 1, source.height >= 1,
              source.minX.isFinite, source.minY.isFinite,
              source.intersects(metrics.screenFrame),
              metrics.notchSize.width > 0, metrics.notchSize.height > 0 else { return nil }

        let box = CGSize(
            width: metrics.notchSize.width * endFill.width,
            height: metrics.notchSize.height * endFill.height
        )
        let fit = min(box.width / source.width, box.height / source.height, 1)
        let size = CGSize(width: max(1, source.width * fit), height: max(1, source.height * fit))
        let center = CGPoint(
            x: metrics.notchCenterX,
            y: metrics.screenFrame.maxY - metrics.notchSize.height / 2
        )
        let end = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        // One timing family per animation style, like `NotchMotion`. Every
        // spring is critically damped: a tap starts this, there is no momentum
        // to carry through, and an overshoot would push the image back out of
        // the notch after it went in.
        let pace: Double = switch style {
        case .subtle: 0.85
        case .iPhone: 1
        case .bouncy: 1.1
        }
        let vertical = 0.5 * pace
        return CaptureSwoopPlan(
            start: source,
            end: end,
            // Ends as a capsule, the island's own shape.
            endCornerRadius: min(size.width, size.height) / 2,
            horizontalDuration: 0.4 * pace,
            verticalDuration: vertical,
            sizeDuration: 0.42 * pace,
            fadeStart: vertical * 0.62,
            fadeEnd: vertical,
            landing: vertical * 0.55
        )
    }
}

/// Plays `CaptureSwoopPlan`s in a click-through panel just below the notch
/// panel, so the image slides *under* the island's shell rather than over it.
///
/// Core Animation springs run on the render server, so the flight stays smooth
/// while the main actor encodes, saves and records the capture it shows.
@MainActor
final class CaptureSwoop {
    static let shared = CaptureSwoop()

    /// Media time at which the latest flight reaches the island.
    private var landingTime: CFTimeInterval = 0
    private var panels: [ObjectIdentifier: NSPanel] = [:]

    /// How long until the latest flight reaches the island, or 0 when none is
    /// in progress. The shelf thumbnail waits this long, so it arrives as the
    /// image goes in instead of before it gets there.
    var timeUntilLanding: Double {
        max(0, min(0.6, landingTime - CACurrentMediaTime()))
    }

    /// - Parameter framed: Draws a thin edge and rounds the corners. Off for
    ///   window captures, whose transparent shadow margin would show the edge.
    func play(
        _ image: CapturedImage,
        framed: Bool,
        metrics: NotchMetrics,
        style: IslandAnimationStyle = NotchMotion.style
    ) {
        let source = ScreenGeometry.cocoaRect(fromCG: image.sourceRect, primaryFrame: ScreenLookup.primaryFrame)
        guard let plan = CaptureSwoopPlan.make(source: source, metrics: metrics, style: style) else { return }

        let panel = makePanel(frame: metrics.screenFrame)
        let origin = metrics.screenFrame.origin
        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsGravity = .resize
        layer.contentsScale = NSScreen.screens.first { $0.frame == metrics.screenFrame }?.backingScaleFactor ?? 2
        // Mipmapped sampling: a whole Retina screen shrinks to a few dozen
        // points, and plain linear filtering shimmers on the way down.
        layer.minificationFilter = .trilinear
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        panel.contentView?.layer?.addSublayer(layer)

        let startCenter = CGPoint(x: plan.start.midX - origin.x, y: plan.start.midY - origin.y)
        let endCenter = CGPoint(x: plan.end.midX - origin.x, y: plan.end.midY - origin.y)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The model holds the resting state; the animations run from the start.
        layer.bounds = CGRect(origin: .zero, size: plan.end.size)
        layer.position = endCenter
        layer.cornerRadius = framed ? plan.endCornerRadius : 0
        layer.opacity = 0

        layer.add(Self.spring("position.x", from: startCenter.x, to: endCenter.x, duration: plan.horizontalDuration), forKey: "x")
        layer.add(Self.spring("position.y", from: startCenter.y, to: endCenter.y, duration: plan.verticalDuration), forKey: "y")
        layer.add(Self.spring("bounds.size", from: plan.start.size, to: plan.end.size, duration: plan.sizeDuration), forKey: "size")
        if framed {
            layer.add(Self.spring("cornerRadius", from: 0, to: plan.endCornerRadius, duration: plan.sizeDuration), forKey: "corner")
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            // The edge appears as the image lifts, so it reads against the
            // identical pixels it started on.
            let edge = CABasicAnimation(keyPath: "borderColor")
            edge.fromValue = NSColor.white.withAlphaComponent(0).cgColor
            edge.duration = 0.12
            edge.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(edge, forKey: "edge")
        }

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: plan.fadeStart / plan.fadeEnd), 1]
        fade.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]
        fade.duration = plan.fadeEnd
        layer.add(fade, forKey: "fade")
        CATransaction.commit()

        panel.orderFrontRegardless()
        // The capture path keeps the main actor busy right after this (recipe
        // rendering, encoding). Commit now so the flight starts on this frame.
        CATransaction.flush()

        landingTime = CACurrentMediaTime() + plan.landing
        let key = ObjectIdentifier(panel)
        panels[key] = panel
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(plan.fadeEnd + 0.05))
            self?.dismiss(key)
        }
    }

    private func dismiss(_ key: ObjectIdentifier) {
        guard let panel = panels.removeValue(forKey: key) else { return }
        panel.orderOut(nil)
        WindowExclusionRegistry.shared.unregister(panel)
    }

    private static func spring(_ keyPath: String, from: Any, to: Any, duration: Double) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One below the notch panel: above the menu bar and every app, and
        // under the island's shell, which is what the image disappears into.
        panel.level = NSWindow.Level(rawValue: NotchPanel.notchLevel.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never part of a capture, ours or anyone else's: a quick second
        // shot would otherwise catch the first one mid-flight.
        panel.sharingType = .none
        WindowExclusionRegistry.shared.register(panel)

        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.layer = CALayer()
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }
}
