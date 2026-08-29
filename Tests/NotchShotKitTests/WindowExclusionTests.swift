import AppKit
import Testing
@testable import NotchShotKit

@Suite("Window exclusion")
@MainActor
struct WindowExclusionTests {

    @Test("An empty ScreenCaptureKit inventory gets one bounded fresh retry")
    func captureInventoryRetryPolicy() {
        #expect(ShareableContentRetryPolicy.shouldRetry(afterAttempt: 1))
        #expect(!ShareableContentRetryPolicy.shouldRetry(afterAttempt: 2))
    }

    @Test("The notch panel accepts clicks only inside its interactive region")
    func panelClickThroughRegion() {
        let panel = NotchPanel(contentRect: CGRect(x: 100, y: 200, width: 300, height: 160))
        panel.setInteractiveRectFromScreenRect(CGRect(x: 140, y: 240, width: 100, height: 50))

        #expect(panel.updateMouseTransparency(screenPoint: CGPoint(x: 150, y: 250)))
        #expect(!panel.ignoresMouseEvents)
        #expect(!panel.updateMouseTransparency(screenPoint: CGPoint(x: 300, y: 300)))
        #expect(panel.ignoresMouseEvents)
    }

    /// A window built with `defer: true` has no window device yet, and AppKit
    /// reports its number as -1. Converting that to `CGWindowID` — a `UInt32` —
    /// traps, and this getter runs on the way into every capture, so the trap
    /// took the whole app down: menu-bar-only, no window, no error, a capture
    /// that simply appeared to do nothing.
    @Test("A window with no device is skipped rather than trapping")
    func deviceLessWindowIsSkipped() {
        let registry = WindowExclusionRegistry.shared
        let deviceLess = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        #expect(deviceLess.windowNumber <= 0, "precondition: no window device")

        registry.register(deviceLess)
        defer { registry.unregister(deviceLess) }

        // Both paths through the getter: plain registration, and the opted-in
        // set, which used to convert with no range check at all.
        _ = registry.excludedWindowNumbers
        registry.setIncludedInCaptures(true, for: deviceLess)
        let numbers = registry.excludedWindowNumbers

        // Nothing to exclude for a window that cannot appear on screen.
        #expect(!numbers.contains(0))
    }

    /// A real on-screen window still has to be excluded, or NotchShot's own UI
    /// ends up baked into the user's screenshot.
    @Test("A window that is on screen is still excluded")
    func onScreenWindowIsExcluded() throws {
        let registry = WindowExclusionRegistry.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer {
            registry.unregister(window)
            window.orderOut(nil)
        }
        try #require(window.windowNumber > 0)

        registry.register(window)
        #expect(registry.excludedWindowNumbers.contains(CGWindowID(window.windowNumber)))
    }

    /// Opting a pinned capture back in removes it from the exclusion set, so it
    /// appears in the next screenshot as the user asked.
    @Test("An opted-in window is not excluded")
    func optedInWindowIsNotExcluded() throws {
        let registry = WindowExclusionRegistry.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer {
            registry.unregister(window)
            window.orderOut(nil)
        }
        try #require(window.windowNumber > 0)

        registry.register(window)
        registry.setIncludedInCaptures(true, for: window)
        #expect(!registry.excludedWindowNumbers.contains(CGWindowID(window.windowNumber)))
    }
}
