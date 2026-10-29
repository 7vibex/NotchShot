import AppKit
import QuartzCore

/// How a floating window arrives and leaves: a short fade with a slight scale
/// toward its own centre, the way macOS opens a popover. Under Reduce Motion
/// only the fade remains.
///
/// Pure values, so the timing and the Reduce Motion rule are testable without
/// a window.
struct FloatingWindowMotionPlan: Equatable {
    var startScale: CGFloat
    var endScale: CGFloat
    var scaleDuration: Double
    /// Only the arrival springs; leaving has nothing to settle into.
    var bounce: Double
    var fadeDuration: Double

    var scales: Bool { startScale != endScale }

    static func appear(reduceMotion: Bool) -> FloatingWindowMotionPlan {
        reduceMotion
            ? FloatingWindowMotionPlan(startScale: 1, endScale: 1, scaleDuration: 0, bounce: 0, fadeDuration: 0.16)
            : FloatingWindowMotionPlan(startScale: 0.94, endScale: 1, scaleDuration: 0.3, bounce: 0.12, fadeDuration: 0.2)
    }

    static func disappear(reduceMotion: Bool) -> FloatingWindowMotionPlan {
        reduceMotion
            ? FloatingWindowMotionPlan(startScale: 1, endScale: 1, scaleDuration: 0, bounce: 0, fadeDuration: 0.14)
            : FloatingWindowMotionPlan(startScale: 1, endScale: 0.96, scaleDuration: 0.18, bounce: 0, fadeDuration: 0.18)
    }

    /// A scale about the centre of `bounds`. AppKit anchors a view's backing
    /// layer at its origin, so a plain scale would shrink toward a corner.
    static func scaleTransform(_ scale: CGFloat, bounds: CGRect, anchorPoint: CGPoint) -> CATransform3D {
        guard scale != 1 else { return CATransform3DIdentity }
        let dx = (0.5 - anchorPoint.x) * bounds.width
        let dy = (0.5 - anchorPoint.y) * bounds.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}

/// Which fade-out still owns a window. Showing the window again, or starting
/// a newer fade, makes an older fade's completion a no-op, so a quick re-show
/// is never ordered out from under the user.
struct FloatingWindowPresentationState: Equatable {
    private(set) var generation = 0
    private(set) var isDismissing = false

    mutating func beginPresent() {
        generation &+= 1
        isDismissing = false
    }

    mutating func beginDismiss() -> Int {
        generation &+= 1
        isDismissing = true
        return generation
    }

    /// True when the fade that returned `token` is still the latest thing
    /// asked of the window, and it should now be ordered out.
    mutating func completeDismiss(_ token: Int) -> Bool {
        guard isDismissing, generation == token else { return false }
        isDismissing = false
        return true
    }
}

/// Plays `FloatingWindowMotionPlan` on a window.
///
/// The fade is the window's alpha, as `MenuBarPanelController` does it. The
/// scale is a Core Animation transform on the content view's layer, added as
/// an animation only: AppKit owns that layer's model geometry, and the
/// window's frame (the size the user chose) never changes.
@MainActor
final class FloatingWindowPresenter {
    private static let scaleKey = "notchshot.floatingWindowScale"
    private var state = FloatingWindowPresentationState()

    /// Orders `window` in with the appear motion, fading to `alpha`. A window
    /// already on screen is only brought forward; one that is fading out
    /// turns around from where it is.
    func present(
        _ window: NSWindow,
        alpha: CGFloat = 1,
        orderFront: (NSWindow) -> Void = { $0.orderFrontRegardless() }
    ) {
        let wasDismissing = state.isDismissing
        let wasShown = window.isVisible && !wasDismissing
        state.beginPresent()
        if !window.isVisible { window.alphaValue = 0 }
        orderFront(window)
        guard !wasShown else { return }

        let plan = FloatingWindowMotionPlan.appear(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if let view = window.contentView {
            view.wantsLayer = true
            if let layer = view.layer {
                if plan.scales {
                    let start = FloatingWindowMotionPlan.scaleTransform(
                        plan.startScale,
                        bounds: view.bounds,
                        anchorPoint: layer.anchorPoint
                    )
                    let spring = CASpringAnimation(perceptualDuration: plan.scaleDuration, bounce: plan.bounce)
                    spring.keyPath = "transform"
                    // Turning around mid-fade starts from the scale on screen.
                    spring.fromValue = NSValue(caTransform3D: wasDismissing
                        ? layer.presentation()?.transform ?? start
                        : start)
                    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                    // What remains of the spring past this is far below a
                    // pixel at these scales.
                    spring.duration = min(spring.settlingDuration, plan.scaleDuration)
                    layer.add(spring, forKey: Self.scaleKey)
                } else {
                    layer.removeAnimation(forKey: Self.scaleKey)
                }
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = plan.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        }
    }

    /// Plays the disappear motion, then orders `window` out and runs
    /// `completion` — unless the window was presented again first.
    func dismiss(
        _ window: NSWindow,
        animated: Bool = true,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let token = state.beginDismiss()
        guard animated, window.isVisible else {
            finishDismiss(window, token: token, completion: completion)
            return
        }
        let plan = FloatingWindowMotionPlan.disappear(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if plan.scales, let view = window.contentView, let layer = view.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: FloatingWindowMotionPlan.scaleTransform(
                plan.endScale,
                bounds: view.bounds,
                anchorPoint: layer.anchorPoint
            ))
            shrink.duration = plan.scaleDuration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Held at the end until the window is ordered out, so it does not
            // spring back to full size for the last frame.
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: Self.scaleKey)
        }
        // The window is captured strongly: a pin's manager lets go of it as the
        // fade starts, and it has to live long enough to be ordered out.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = plan.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishDismiss(window, token: token, completion: completion)
            }
        })
    }

    private func finishDismiss(
        _ window: NSWindow,
        token: Int,
        completion: (@MainActor () -> Void)?
    ) {
        guard state.completeDismiss(token) else { return }
        window.orderOut(nil)
        window.contentView?.layer?.removeAnimation(forKey: Self.scaleKey)
        completion?()
    }
}
