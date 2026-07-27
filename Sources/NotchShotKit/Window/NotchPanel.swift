import AppKit
import SwiftUI

/// The window the notch lives in.
///
/// It is a *nonactivating* panel so clicking a capture button never steals key
/// focus from whatever the user is screenshotting — which matters because the
/// frontmost app is usually the subject of the capture.
public final class NotchPanel: NSPanel {

    /// Region, in this panel's coordinate space, that should accept clicks.
    /// Everything outside it is click-through so the panel doesn't shadow the
    /// menu bar or the app underneath.
    public var interactiveRect: CGRect = .zero

    public init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = NotchPanel.notchLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // The panel is the visible replacement for an optionally suppressed
        // native OSD. Command-H may hide auxiliary app windows, but it must
        // never hide this feedback surface while suppression remains active.
        canHide = false
        animationBehavior = .none

        // Visible on every Space, over fullscreen apps, and never cycled to.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        // Keeps NotchShot out of other apps' captures, and — combined with the
        // explicit window exclusion in the content filter — out of our own.
        sharingType = .none

        // Click-through by default; `interactiveRect` opens holes in it.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    /// Above the menu bar, below the screenshot/shield layer so selection
    /// overlays still draw on top of us.
    static var notchLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    // A borderless panel is not key by default, which would break text fields
    // in the annotation popovers and keyboard navigation of the shelf.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// Updates click-through from a point in *screen* coordinates.
    /// Returns whether the pointer is currently over the island.
    @discardableResult
    public func updateMouseTransparency(screenPoint: CGPoint) -> Bool {
        let local = CGPoint(x: screenPoint.x - frame.origin.x, y: screenPoint.y - frame.origin.y)
        let inside = interactiveRect.contains(local)
        if ignoresMouseEvents == inside {
            ignoresMouseEvents = !inside
        }
        return inside
    }

    public func setInteractiveRectFromScreenRect(_ screenRect: CGRect) {
        interactiveRect = CGRect(
            x: screenRect.origin.x - frame.origin.x,
            y: screenRect.origin.y - frame.origin.y,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}

/// Tracks the window numbers of every window NotchShot puts on screen, so the
/// capture pipeline can exclude them. Missing one here is the classic "my own
/// HUD is in the screenshot" bug, so every window we create registers itself.
@MainActor
public final class WindowExclusionRegistry {
    public static let shared = WindowExclusionRegistry()

    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// Windows the user has explicitly asked to keep *in* captures — currently
    /// only pinned floating screenshots someone wants to appear in a follow-up
    /// shot.
    private var opsInWindows: Set<ObjectIdentifier> = []

    public func register(_ window: NSWindow) {
        windows[ObjectIdentifier(window)] = window
    }

    public func unregister(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        windows.removeValue(forKey: key)
        opsInWindows.remove(key)
    }

    public func setIncludedInCaptures(_ included: Bool, for window: NSWindow) {
        let key = ObjectIdentifier(window)
        if included {
            opsInWindows.insert(key)
        } else {
            opsInWindows.remove(key)
        }
    }

    public func isIncludedInCaptures(_ window: NSWindow) -> Bool {
        opsInWindows.contains(ObjectIdentifier(window))
    }

    /// Window numbers to exclude from every capture and recording.
    ///
    /// Defaults to *everything this process owns*: missing one shows up as our
    /// own UI baked into the user's screenshot, which is far worse than
    /// over-excluding, since an excluded window just reveals what's behind it.
    public var excludedWindowNumbers: Set<CGWindowID> {
        var result = Set<CGWindowID>()
        let optedIn = Set(opsInWindows.compactMap { key in
            windows[key].flatMap(Self.captureID)
        })
        // `NSApp` is an implicitly unwrapped global and can still be nil in a
        // signed headless diagnostic. `shared` is safe in both that path and
        // the normal AppDelegate lifecycle.
        for window in NSApplication.shared.windows where window.isVisible {
            guard let number = Self.captureID(of: window) else { continue }
            if optedIn.contains(number) { continue }
            result.insert(number)
        }
        for window in windows.values {
            guard let number = Self.captureID(of: window) else { continue }
            if optedIn.contains(number) { continue }
            result.insert(number)
        }
        return result
    }

    /// A window's number as a `CGWindowID`, or nil when it has none.
    ///
    /// `NSWindow.windowNumber` is an `Int` and is **-1** for a window with no
    /// window device — one created with `defer: true` and not yet shown, for
    /// instance. `CGWindowID` is a `UInt32`, so converting that traps with
    /// "Negative value is not representable" and takes the whole app down.
    ///
    /// This getter runs on the way into every capture and recording, and the app
    /// is menu-bar-only, so the trap killed it with no window and no visible
    /// error — a capture that appeared to do nothing at all. Checking the range
    /// once, here, is the only place that needs to know about it: a window
    /// without a device is not on screen and so cannot be in a capture anyway.
    private static func captureID(of window: NSWindow) -> CGWindowID? {
        let number = window.windowNumber
        guard number > 0, number <= Int(CGWindowID.max) else { return nil }
        return CGWindowID(number)
    }
}
