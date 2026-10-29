import AppKit
import QuartzCore
import Testing
@testable import NotchShotKit

@Suite("Presenter overlay visibility")
struct RecordingPresenterVisibilityTests {
    /// The panel is part of the recording, so whatever it draws between
    /// shortcuts is in the video. It used to say "Shortcuts appear here".
    @Test("Without a camera the panel is invisible until a shortcut")
    func keysOnly() {
        let idle = RecordingPresenterVisibility(showsCamera: false, isShowingShortcut: false)
        #expect(!idle.isPanelVisible)
        #expect(!idle.isKeyAreaVisible)

        let shortcut = RecordingPresenterVisibility(showsCamera: false, isShowingShortcut: true)
        #expect(shortcut.isPanelVisible)
        #expect(shortcut.isKeyAreaVisible)
    }

    @Test("With a camera only the keystroke area comes and goes")
    func withCamera() {
        let idle = RecordingPresenterVisibility(showsCamera: true, isShowingShortcut: false)
        #expect(idle.isPanelVisible)
        #expect(!idle.isKeyAreaVisible)

        let shortcut = RecordingPresenterVisibility(showsCamera: true, isShowingShortcut: true)
        #expect(shortcut.isPanelVisible)
        #expect(shortcut.isKeyAreaVisible)
    }
}

@Suite("Floating window motion")
struct FloatingWindowMotionTests {
    @Test("Appear and disappear stay short and scale only slightly")
    func plans() {
        let appear = FloatingWindowMotionPlan.appear(reduceMotion: false)
        #expect(appear.startScale == 0.94)
        #expect(appear.endScale == 1)
        #expect(appear.scaleDuration <= 0.3)
        #expect(appear.fadeDuration <= 0.3)

        let disappear = FloatingWindowMotionPlan.disappear(reduceMotion: false)
        #expect(disappear.startScale == 1)
        #expect(disappear.endScale == 0.96)
        #expect(disappear.bounce == 0)
        #expect(disappear.scaleDuration <= 0.18)
        #expect(disappear.fadeDuration <= 0.18)
    }

    @Test("Reduce Motion leaves only the fade")
    func reduceMotion() {
        for plan in [
            FloatingWindowMotionPlan.appear(reduceMotion: true),
            FloatingWindowMotionPlan.disappear(reduceMotion: true),
        ] {
            #expect(!plan.scales)
            #expect(plan.fadeDuration > 0)
        }
    }

    /// AppKit anchors a backing layer at its origin; a plain scale there would
    /// shrink the window toward its bottom-left corner.
    @Test("The scale keeps the window's centre in place", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.5, y: 0.5),
    ])
    func scaleAboutCentre(anchor: CGPoint) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let transform = FloatingWindowMotionPlan.scaleTransform(0.94, bounds: bounds, anchorPoint: anchor)

        // Points are measured from the anchor, as Core Animation applies them.
        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x * transform.m11 + point.y * transform.m21 + transform.m41,
                y: point.x * transform.m12 + point.y * transform.m22 + transform.m42
            )
        }
        let centre = CGPoint(
            x: (0.5 - anchor.x) * bounds.width,
            y: (0.5 - anchor.y) * bounds.height
        )
        let movedCentre = apply(centre)
        #expect(abs(movedCentre.x - centre.x) < 0.001)
        #expect(abs(movedCentre.y - centre.y) < 0.001)

        // A corner does move in, by 3% of the size on each side.
        let corner = CGPoint(x: centre.x + 200, y: centre.y + 150)
        let movedCorner = apply(corner)
        #expect(abs(movedCorner.x - (centre.x + 188)) < 0.001)
        #expect(abs(movedCorner.y - (centre.y + 141)) < 0.001)

        #expect(CATransform3DIsIdentity(
            FloatingWindowMotionPlan.scaleTransform(1, bounds: bounds, anchorPoint: anchor)
        ))
    }

    @Test("A fade-out completes when nothing interrupts it")
    func plainDismiss() {
        var state = FloatingWindowPresentationState()
        state.beginPresent()
        let token = state.beginDismiss()
        let completed = state.completeDismiss(token)
        #expect(completed)
        // Only once.
        let completedAgain = state.completeDismiss(token)
        #expect(!completedAgain)
    }

    @Test("Showing the window again cancels a pending close")
    func reshowCancelsClose() {
        var state = FloatingWindowPresentationState()
        state.beginPresent()
        let token = state.beginDismiss()
        state.beginPresent()
        let completed = state.completeDismiss(token)
        #expect(!completed)
        #expect(!state.isDismissing)
    }

    @Test("Only the latest of two fade-outs orders the window out")
    func latestDismissWins() {
        var state = FloatingWindowPresentationState()
        let first = state.beginDismiss()
        let second = state.beginDismiss()
        let firstCompleted = state.completeDismiss(first)
        let secondCompleted = state.completeDismiss(second)
        #expect(!firstCompleted)
        #expect(secondCompleted)
    }
}

@Suite("Pinned capture menu")
@MainActor
struct PinnedCaptureMenuTests {
    private func makePin() -> FloatingCaptureWindow {
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/notchshot-pin-test.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 320, height: 200)
        )
        let image = NSImage(size: NSSize(width: 320, height: 200))
        // Never ordered in: nothing appears on screen during the test.
        return FloatingCaptureWindow(asset: asset, image: image, at: .zero)
    }

    private func clickEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// The menu used to be built in `rightMouseDown` only, which a
    /// Control-click and VoiceOver never reach.
    @Test("The content view answers menu(for:), and takes every click")
    func menuIsReachable() throws {
        let pin = makePin()
        let content = try #require(pin.contentView)
        let menu = try #require(content.menu(for: clickEvent(modifiers: .control)))
        #expect(menu.items.contains { $0.title == "Copy" })
        #expect(menu.items.contains { $0.title == "Close" })

        // The image view must not swallow the click before the menu lookup.
        let inside = CGPoint(x: content.frame.midX, y: content.frame.midY)
        #expect(content.hitTest(inside) === content)
        #expect(content.isAccessibilityElement())
    }

    @Test("A locked pin offers no pointer menu and cannot take focus")
    func lockedPin() throws {
        let pin = makePin()
        pin.setLocked(true)
        let content = try #require(pin.contentView)
        #expect(content.menu(for: try clickEvent(modifiers: .control)) == nil)
        #expect(!pin.canBecomeKey)
    }
}
