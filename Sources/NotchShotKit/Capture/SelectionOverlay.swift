import AppKit
import CoreGraphics
import Foundation

public enum SelectionMode: Sendable, Equatable {
    case area
    /// Area selection that starts by highlighting windows, so a single click
    /// grabs a window and a drag grabs a region.
    case window
    case scrollingRegion
    case textRegion

    var wantsWindowHighlight: Bool { self == .window }

    var instructions: String {
        switch self {
        case .area: "Drag to select · Return captures · ⇧ locks ratio · ⎋ cancels"
        case .window: "Click a window · drag for an area · ⎋ cancels"
        case .scrollingRegion: "Select the scrollable region · ⎋ cancels"
        case .textRegion: "Select the text to recognise · ⎋ cancels"
        }
    }
}

public enum SelectionResult: Sendable, Equatable {
    /// Global CG-space (top-left origin) rect, in points.
    case area(CGRect, CGDirectDisplayID)
    case window(WindowInfo)
    case cancelled
}

/// Drives the full-screen selection UI across every display.
@MainActor
public final class SelectionOverlayController {
    public static let shared = SelectionOverlayController()

    private var windows: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var keyMonitor: Any?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    public private(set) var isPresenting = false

    public init() {}

    /// Presents the overlay and resolves once the user selects or cancels.
    /// `freezeFrames` is keyed by display id; supplying it both freezes the
    /// screen and gives the magnifier crisp pixels to sample.
    public func beginSelection(
        mode: SelectionMode,
        freezeFrames: [CGDirectDisplayID: CapturedImage],
        windows windowList: [WindowInfo],
        initialRect: CGRect? = nil
    ) async -> SelectionResult {
        if isPresenting { finish(.cancelled) }
        return await withCheckedContinuation { continuation in
            // Install the continuation before invoking AppKit. Window ordering,
            // focus, and app activation can deliver callbacks re-entrantly; the
            // result must always have exactly one live continuation to resume.
            self.continuation = continuation
            self.isPresenting = true

            let showsFreeze = Preferences.shared.freezeScreenDuringSelection
                && !freezeFrames.isEmpty
            let showsMagnifier = Preferences.shared.showsMagnifier

            for screen in NSScreen.screens {
                guard self.isPresenting,
                      let displayID = ScreenLookup.displayID(for: screen) else { continue }
                let window = SelectionOverlayWindow(
                    screen: screen,
                    displayID: displayID,
                    mode: mode,
                    freezeFrame: freezeFrames[displayID],
                    showsFreeze: showsFreeze,
                    showsMagnifier: showsMagnifier,
                    windows: windowList
                )
                window.onResult = { [weak self] result in
                    MainActor.assumeIsolated { self?.finish(result) }
                }
                if let initialRect {
                    window.setInitialGlobalRect(initialRect)
                }
                WindowExclusionRegistry.shared.register(window)
                self.windows.append(window)
                window.orderFrontRegardless()
            }

            guard self.isPresenting else { return }
            guard !self.windows.isEmpty else {
                self.finish(.cancelled)
                return
            }

            // Install Escape handling before focus/activation so a re-entrant
            // finish removes it instead of leaving a monitor behind.
            self.installKeyMonitor()
            guard self.isPresenting else { return }
            self.windows.first?.makeKeyAndOrderFront(nil)
            guard self.isPresenting else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func cancel() {
        guard isPresenting else { return }
        finish(.cancelled)
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // 53 = Escape. Handled here so it works no matter which of the
            // per-display overlay windows currently holds focus.
            guard let self, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.finish(.cancelled) }
            return nil
        }
    }

    private func finish(_ result: SelectionResult) {
        guard isPresenting else { return }
        isPresenting = false

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in windows {
            WindowExclusionRegistry.shared.unregister(window)
            window.orderOut(nil)
        }
        windows.removeAll()

        // Hand focus back so the capture's subject app is frontmost again.
        //
        // `NSApp.hide` would do that, but it also orders out *every* window we
        // own — including the notch panels, which then stay hidden until the
        // next screen-parameters change. Deactivating gives back focus without
        // touching our own windows.
        NSApp.deactivate()
        if let policy = previousActivationPolicy {
            NSApp.setActivationPolicy(policy)
            previousActivationPolicy = nil
        }
        onDismiss?()

        if let continuation {
            // Cleared before resuming so a re-entrant `finish` reached from the
            // resumed caller cannot resume the same continuation twice.
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }

    /// Called after the overlay tears down, so the notch can re-assert itself.
    public var onDismiss: (() -> Void)?
}

// MARK: - Overlay window

final class SelectionOverlayWindow: NSPanel {
    let displayID: CGDirectDisplayID
    var onResult: ((SelectionResult) -> Void)?
    var onSelectionChanged: ((CGRect?, CGDirectDisplayID) -> Void)?

    private let overlayView: SelectionOverlayView

    init(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        mode: SelectionMode,
        freezeFrame: CapturedImage?,
        showsFreeze: Bool,
        showsMagnifier: Bool,
        windows: [WindowInfo]
    ) {
        self.displayID = displayID
        self.overlayView = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame,
            displayID: displayID,
            mode: mode,
            freezeFrame: freezeFrame,
            showsFreeze: showsFreeze,
            showsMagnifier: showsMagnifier,
            windows: windows,
            scale: screen.backingScaleFactor
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the notch panel and the menu bar, below nothing — this is a
        // modal capture surface.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)

        contentView = overlayView
        overlayView.onResult = { [weak self] in self?.onResult?($0) }
        overlayView.onSelectionChanged = { [weak self] rect in
            guard let self else { return }
            self.onSelectionChanged?(rect, self.displayID)
        }
    }

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setInitialGlobalRect(_ rect: CGRect) {
        overlayView.setInitialGlobalRect(rect)
    }

    func applyExternalSelection(_ globalRect: CGRect?) {
        overlayView.applyExternalSelection(globalRect)
    }
}

// MARK: - Overlay view

final class SelectionOverlayView: NSView {
    static let resizeHandleHitSize = NotchShotDesignSystem.minimumControlTarget

    enum ResizeHandle: CaseIterable {
        case bottomLeft
        case bottomRight
        case topLeft
        case topRight
    }

    var onResult: ((SelectionResult) -> Void)?
    var onSelectionChanged: ((CGRect?) -> Void)?

    private let screenFrame: CGRect
    private let displayID: CGDirectDisplayID
    private let mode: SelectionMode
    private let freezeFrame: CapturedImage?
    private let showsFreeze: Bool
    private let showsMagnifier: Bool
    private let allWindows: [WindowInfo]
    private let scale: CGFloat

    private var dragOrigin: CGPoint?
    /// Selection in this view's local Cocoa space.
    private var selection: CGRect?
    /// A selection that originated on another display, in local space.
    private var externalSelection: CGRect?
    private var mouseLocation: CGPoint = .zero
    private var isMovingSelection = false
    private var moveAnchor: CGPoint = .zero
    private var activeResizeHandle: ResizeHandle?
    private var resizeStartRect: CGRect?
    private var hasDragged = false
    private var hoveredWindow: WindowInfo?
    private var freezeImage: CGImage?
    private var cachedDimmedFreeze: CGImage?
    private var trackingArea: NSTrackingArea?

    private var lockedAspectRatio: CGFloat? {
        NSEvent.modifierFlags.contains(.shift) ? currentShiftRatio : nil
    }
    /// Shift locks to whatever ratio the drag had when Shift went down; a plain
    /// square lock is rarely what people want for screenshots.
    private var currentShiftRatio: CGFloat?

    init(
        frame: CGRect,
        screenFrame: CGRect,
        displayID: CGDirectDisplayID,
        mode: SelectionMode,
        freezeFrame: CapturedImage?,
        showsFreeze: Bool,
        showsMagnifier: Bool,
        windows: [WindowInfo],
        scale: CGFloat
    ) {
        self.screenFrame = screenFrame
        self.displayID = displayID
        self.mode = mode
        self.freezeFrame = freezeFrame
        self.showsFreeze = showsFreeze
        self.showsMagnifier = showsMagnifier
        self.allWindows = windows
        self.scale = scale
        self.freezeImage = freezeFrame?.cgImage
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screen capture selection")
        setAccessibilityHelp(
            "Create a centered selection, move or resize it with the arrow keys, then confirm."
        )
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Create centered selection") { [weak self] in
                self?.createCenteredSelection() ?? false
            },
            NSAccessibilityCustomAction(name: "Select next window") { [weak self] in
                self?.cycleWindow(forward: true) ?? false
            },
            NSAccessibilityCustomAction(name: "Confirm selection") { [weak self] in
                self?.confirmSelection() ?? false
            },
            NSAccessibilityCustomAction(name: "Cancel selection") { [weak self] in
                self?.onResult?(.cancelled)
                return self != nil
            },
        ])
        updateAccessibilityValue(announce: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        // A crosshair everywhere, except over the moving hand.
        addCursorRect(bounds, cursor: isMovingSelection ? .closedHand : .crosshair)
    }

    // MARK: Coordinate helpers

    /// Local Cocoa point → global CG (top-left) point.
    private func globalCGPoint(_ local: CGPoint) -> CGPoint {
        let cocoaGlobal = CGPoint(x: screenFrame.origin.x + local.x, y: screenFrame.origin.y + local.y)
        return ScreenGeometry.cgPoint(fromCocoa: cocoaGlobal, primaryFrame: ScreenLookup.primaryFrame)
    }

    private func globalCGRect(_ local: CGRect) -> CGRect {
        let cocoaGlobal = local.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        return ScreenGeometry.cgRect(fromCocoa: cocoaGlobal, primaryFrame: ScreenLookup.primaryFrame)
    }

    private func localRect(fromGlobalCG rect: CGRect) -> CGRect {
        let cocoa = ScreenGeometry.cocoaRect(fromCG: rect, primaryFrame: ScreenLookup.primaryFrame)
        return cocoa.offsetBy(dx: -screenFrame.origin.x, dy: -screenFrame.origin.y)
    }

    func setInitialGlobalRect(_ rect: CGRect) {
        let local = localRect(fromGlobalCG: rect)
        if bounds.intersects(local) {
            selection = local.intersection(bounds)
            updateAccessibilityValue()
            needsDisplay = true
        }
    }

    func applyExternalSelection(_ globalRect: CGRect?) {
        externalSelection = globalRect.map { localRect(fromGlobalCG: $0) }
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if mode.wantsWindowHighlight, selection == nil {
            let global = globalCGPoint(mouseLocation)
            let candidate = allWindows.first { $0.frame.contains(global) }
            if candidate?.id != hoveredWindow?.id {
                hoveredWindow = candidate
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point
        hasDragged = false
        currentShiftRatio = nil

        if let selection,
           let handle = resizeHandle(at: point, in: selection) {
            activeResizeHandle = handle
            resizeStartRect = selection
            if event.modifierFlags.contains(.shift) {
                currentShiftRatio = selection.height > 0 ? selection.width / selection.height : 1
            }
        } else if let selection, selection.contains(point), !selection.isEmpty {
            // Clicking inside an existing selection starts a move.
            isMovingSelection = true
            moveAnchor = CGPoint(x: point.x - selection.origin.x, y: point.y - selection.origin.y)
        } else {
            dragOrigin = point
            selection = CGRect(origin: point, size: .zero)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point
        hasDragged = true

        if let handle = activeResizeHandle,
           let start = resizeStartRect {
            if NSEvent.modifierFlags.contains(.shift), currentShiftRatio == nil {
                currentShiftRatio = start.height > 0 ? start.width / start.height : 1
            } else if !NSEvent.modifierFlags.contains(.shift) {
                currentShiftRatio = nil
            }
            selection = Self.resizedRect(
                start,
                handle: handle,
                to: point,
                bounds: bounds,
                lockedAspectRatio: lockedAspectRatio
            )
        } else if isMovingSelection, var selection {
            selection.origin = CGPoint(x: point.x - moveAnchor.x, y: point.y - moveAnchor.y)
            selection.origin.x = min(max(selection.origin.x, bounds.minX), bounds.maxX - selection.width)
            selection.origin.y = min(max(selection.origin.y, bounds.minY), bounds.maxY - selection.height)
            self.selection = selection
        } else if let dragOrigin {
            if NSEvent.modifierFlags.contains(.shift), currentShiftRatio == nil {
                let width = abs(point.x - dragOrigin.x)
                let height = abs(point.y - dragOrigin.y)
                currentShiftRatio = height > 0 ? max(width / height, 0.05) : 1
            } else if !NSEvent.modifierFlags.contains(.shift) {
                currentShiftRatio = nil
            }
            selection = ScreenGeometry.rect(
                from: dragOrigin,
                to: point,
                lockedAspectRatio: lockedAspectRatio
            ).intersection(bounds)
        }

        onSelectionChanged?(selection.map { globalCGRect($0) })
        updateAccessibilityValue()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if isMovingSelection || activeResizeHandle != nil {
            isMovingSelection = false
            activeResizeHandle = nil
            resizeStartRect = nil
            currentShiftRatio = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }

        defer {
            dragOrigin = nil
            currentShiftRatio = nil
        }

        // A click without a drag in window mode picks the window under it.
        if mode.wantsWindowHighlight, !hasDragged, let hoveredWindow {
            onResult?(.window(hoveredWindow))
            return
        }

        guard let selection, selection.width >= 4, selection.height >= 4 else {
            // Too small to be intentional: treat as a cancel rather than
            // producing a 2-pixel screenshot.
            self.selection = nil
            onSelectionChanged?(nil)
            needsDisplay = true
            return
        }

        // Keep the completed selection visible so its handles are real controls
        // rather than decoration. Return, Enter, or a double-click confirms it.
        if event.clickCount >= 2, selection.contains(point) {
            onResult?(.area(globalCGRect(selection).integral, displayID))
        } else {
            updateAccessibilityValue()
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onResult?(.cancelled)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            _ = confirmSelection()
        case 48: // Tab / Shift-Tab cycles shareable windows.
            _ = cycleWindow(forward: !event.modifierFlags.contains(.shift))
        case 123, 124, 125, 126: // arrows
            if selection == nil { _ = createCenteredSelection() }
            if event.modifierFlags.contains(.shift) {
                resize(keyCode: event.keyCode, fine: event.modifierFlags.contains(.option))
            } else {
                nudge(keyCode: event.keyCode, fine: event.modifierFlags.contains(.option))
            }
        case 49: // Space focuses a movable selection instead of changing its target.
            if selection == nil { _ = createCenteredSelection() }
            isMovingSelection = false
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        case 15: // R resets to a centered keyboard-accessible selection.
            _ = createCenteredSelection()
        default:
            super.keyDown(with: event)
        }
    }

    static func resizedRect(
        _ start: CGRect,
        handle: ResizeHandle,
        to point: CGPoint,
        bounds: CGRect,
        lockedAspectRatio: CGFloat? = nil
    ) -> CGRect {
        let opposite: CGPoint = switch handle {
        case .bottomLeft: CGPoint(x: start.maxX, y: start.maxY)
        case .bottomRight: CGPoint(x: start.minX, y: start.maxY)
        case .topLeft: CGPoint(x: start.maxX, y: start.minY)
        case .topRight: CGPoint(x: start.minX, y: start.minY)
        }
        var resized = ScreenGeometry.rect(
            from: opposite,
            to: point,
            lockedAspectRatio: lockedAspectRatio
        ).intersection(bounds)
        if resized.width < 4 { resized.size.width = 4 }
        if resized.height < 4 { resized.size.height = 4 }
        resized.origin.x = min(max(resized.origin.x, bounds.minX), bounds.maxX - resized.width)
        resized.origin.y = min(max(resized.origin.y, bounds.minY), bounds.maxY - resized.height)
        return resized
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        let hitSide = Self.resizeHandleHitSize
        for handle in ResizeHandle.allCases {
            let corner: CGPoint = switch handle {
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
            let hitRect = CGRect(
                x: corner.x - hitSide / 2,
                y: corner.y - hitSide / 2,
                width: hitSide,
                height: hitSide
            )
            if hitRect.contains(point) { return handle }
        }
        return nil
    }

    private func nudge(keyCode: UInt16, fine: Bool) {
        let step: CGFloat = fine ? 1 : 10
        guard var selection else { return }
        switch keyCode {
        case 123: selection.origin.x -= step
        case 124: selection.origin.x += step
        case 125: selection.origin.y -= step
        case 126: selection.origin.y += step
        default: break
        }
        selection.origin.x = min(max(selection.origin.x, bounds.minX), bounds.maxX - selection.width)
        selection.origin.y = min(max(selection.origin.y, bounds.minY), bounds.maxY - selection.height)
        self.selection = selection
        onSelectionChanged?(globalCGRect(selection))
        updateAccessibilityValue()
        needsDisplay = true
    }

    private func resize(keyCode: UInt16, fine: Bool) {
        let step: CGFloat = fine ? 1 : 10
        guard var selection else { return }
        switch keyCode {
        case 123: selection.size.width -= step
        case 124: selection.size.width += step
        case 125: selection.size.height -= step
        case 126: selection.size.height += step
        default: break
        }
        selection.size.width = min(max(selection.width, 4), bounds.maxX - selection.minX)
        selection.size.height = min(max(selection.height, 4), bounds.maxY - selection.minY)
        self.selection = selection
        onSelectionChanged?(globalCGRect(selection))
        updateAccessibilityValue()
        needsDisplay = true
    }

    @discardableResult
    func createCenteredSelection() -> Bool {
        guard bounds.width >= 4, bounds.height >= 4 else { return false }
        let width = max(4, min(bounds.width * 0.5, 960))
        let height = max(4, min(bounds.height * 0.5, 640))
        selection = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        ).integral
        hoveredWindow = nil
        onSelectionChanged?(selection.map { globalCGRect($0) })
        updateAccessibilityValue()
        needsDisplay = true
        return true
    }

    @discardableResult
    private func cycleWindow(forward: Bool) -> Bool {
        guard mode.wantsWindowHighlight, !allWindows.isEmpty else { return false }
        let current = hoveredWindow.flatMap { current in
            allWindows.firstIndex { $0.id == current.id }
        }
        let next: Int
        if let current {
            next = (current + (forward ? 1 : allWindows.count - 1)) % allWindows.count
        } else {
            next = forward ? 0 : allWindows.count - 1
        }
        hoveredWindow = allWindows[next]
        selection = nil
        updateAccessibilityValue()
        needsDisplay = true
        return true
    }

    @discardableResult
    private func confirmSelection() -> Bool {
        if let selection, selection.width >= 4, selection.height >= 4 {
            onResult?(.area(globalCGRect(selection).integral, displayID))
            return true
        }
        if let hoveredWindow {
            onResult?(.window(hoveredWindow))
            return true
        }
        return false
    }

    override func accessibilityPerformPress() -> Bool { confirmSelection() }
    override func accessibilityPerformConfirm() -> Bool { confirmSelection() }
    override func accessibilityPerformCancel() -> Bool {
        onResult?(.cancelled)
        return true
    }

    private func updateAccessibilityValue(announce: Bool = true) {
        let value: String
        if let selection {
            let pixelsWide = Int((selection.width * scale).rounded())
            let pixelsHigh = Int((selection.height * scale).rounded())
            value = "Selected area, \(pixelsWide) by \(pixelsHigh) pixels"
        } else if let hoveredWindow {
            value = "Window: \(hoveredWindow.displayTitle)"
        } else {
            value = "No selection. Use Create centered selection or Select next window."
        }
        setAccessibilityValue(value)
        if announce {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let active = selection ?? externalSelection
        let highlight = (mode.wantsWindowHighlight && selection == nil)
            ? hoveredWindow.map { localRect(fromGlobalCG: $0.frame).intersection(bounds) }
            : nil
        let clearRect = active ?? highlight

        drawBackdrop(clearing: clearRect, in: context)

        if let clearRect, !clearRect.isEmpty {
            drawSelectionChrome(clearRect, in: context, isWindowHighlight: active == nil)
        }

        if selection == nil && externalSelection == nil {
            drawCrosshair(in: context)
        }

        if showsMagnifier, freezeImage != nil, !isMovingSelection {
            drawMagnifier(in: context)
        }

        drawInstructions(in: context)
    }

    /// Paints the frozen screen and the dimming that isolates the selection.
    ///
    /// This runs on every mouse move, so it is the one place in the overlay
    /// where drawing cost is felt directly as pointer lag. The obvious
    /// implementation — blit the freeze frame, then fill everything outside the
    /// selection with translucent black — spends almost all of its time in the
    /// translucent fill: Core Graphics blends a full-screen alpha fill at around
    /// 200 MB/s, which is roughly 37 ms per redraw on a 16-inch Retina display,
    /// against 1.2 ms for the identical fill at alpha 1. Both branches below
    /// therefore avoid blending a full-screen region entirely, and both produce
    /// byte-identical output to the straightforward version.
    private func drawBackdrop(clearing clearRect: CGRect?, in context: CGContext) {
        let hole = clearRect.flatMap { $0.isEmpty ? nil : $0 }

        // Frozen: the dim is a constant black composite over an opaque bitmap,
        // so it can be baked once and blitted. The undimmed selection is then
        // restored by drawing the original frame clipped to the hole — clipping
        // rather than cropping keeps it aligned to the same pixel grid as the
        // backdrop even when the selection has fractional edges. The baked copy
        // costs one extra full-screen bitmap, freed with the overlay.
        if showsFreeze, let freezeImage, let dimmed = dimmedFreezeImage() {
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(dimmed, in: bounds)
            if let hole {
                context.saveGState()
                context.clip(to: hole)
                context.draw(freezeImage, in: bounds)
                context.restoreGState()
            }
            context.restoreGState()
            return
        }

        // Live: there is no bitmap to bake the dim into, but the backing store
        // is cleared before every draw, so there is nothing underneath to blend
        // with either. `.copy` writes the premultiplied colour straight out and
        // leaves the hole transparent, which is what the even-odd fill produced.
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(NSColor.black.withAlphaComponent(showsFreeze ? 0.45 : 0.28).cgColor)
        if let hole {
            context.addRect(bounds)
            context.addRect(hole)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    /// The freeze frame with the dim already composited in, built on first use.
    private func dimmedFreezeImage() -> CGImage? {
        if let cachedDimmedFreeze { return cachedDimmedFreeze }
        guard let freezeImage else { return nil }
        guard let context = CGContext(
            data: nil,
            width: freezeImage.width,
            height: freezeImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let imageRect = CGRect(x: 0, y: 0, width: freezeImage.width, height: freezeImage.height)
        context.interpolationQuality = .none
        context.draw(freezeImage, in: imageRect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(imageRect)
        cachedDimmedFreeze = context.makeImage()
        return cachedDimmedFreeze
    }

    private func drawSelectionChrome(_ rect: CGRect, in context: CGContext, isWindowHighlight: Bool) {
        // Keep the original compact selection treatment. The clear-versus-dim
        // backdrop already defines the edge, so stacked black and white
        // keylines only make the capture boundary look heavy.
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(isWindowHighlight ? 3 : 2)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        if !isWindowHighlight {
            // The compact visual handles retain larger invisible hit targets
            // in `resizeHandle(at:in:)` for easy resizing.
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            let handle: CGFloat = 6
            for corner in [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
            ] {
                context.fillEllipse(in: CGRect(
                    x: corner.x - handle / 2,
                    y: corner.y - handle / 2,
                    width: handle,
                    height: handle
                ))
            }
        }

        let label: String
        if isWindowHighlight, let hoveredWindow {
            label = hoveredWindow.displayTitle
        } else {
            // Report pixels, which is what the file will contain.
            let dimensions = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
            let ratio = Self.ratioDescription(rect.width / max(rect.height, 1))
            label = [dimensions, ratio, showsFreeze ? "Frozen" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        drawBadge(label, near: CGPoint(x: rect.midX, y: rect.minY - 14), in: context)
    }

    private static func ratioDescription(_ ratio: CGFloat) -> String {
        let common: [(CGFloat, String)] = [
            (16.0 / 9.0, "16:9"),
            (4.0 / 3.0, "4:3"),
            (3.0 / 2.0, "3:2"),
            (1.0, "1:1"),
            (9.0 / 16.0, "9:16"),
        ]
        if let match = common.first(where: { abs($0.0 - ratio) < 0.015 }) {
            return match.1
        }
        return String(format: "%.2f:1", ratio)
    }

    private func drawCrosshair(in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: mouseLocation.x + 0.5, y: 0))
        context.addLine(to: CGPoint(x: mouseLocation.x + 0.5, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: mouseLocation.y + 0.5))
        context.addLine(to: CGPoint(x: bounds.width, y: mouseLocation.y + 0.5))
        context.strokePath()
    }

    /// Zoomed, pixel-grid view of the freeze frame under the cursor, plus the
    /// exact colour value — the thing that makes pixel-accurate selection
    /// possible on a Retina display.
    private func drawMagnifier(in context: CGContext) {
        guard let freezeImage else { return }
        let magnification: CGFloat = 8
        let sampleSide: CGFloat = 15 // pixels sampled, odd so there is a centre
        let side = sampleSide * magnification

        let pixelX = (mouseLocation.x * scale).rounded(.down)
        // CGImage rows run top-down; the view is bottom-up.
        let pixelY = ((bounds.height - mouseLocation.y) * scale).rounded(.down)
        let sampleRect = CGRect(
            x: pixelX - (sampleSide / 2).rounded(.down),
            y: pixelY - (sampleSide / 2).rounded(.down),
            width: sampleSide,
            height: sampleSide
        )
        guard let cropped = freezeImage.cropping(to: sampleRect) else { return }

        // Keep the loupe on screen when the cursor is near an edge.
        var origin = CGPoint(x: mouseLocation.x + 20, y: mouseLocation.y - side - 20)
        if origin.x + side > bounds.maxX { origin.x = mouseLocation.x - side - 20 }
        if origin.y < bounds.minY { origin.y = mouseLocation.y + 20 }
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        context.saveGState()
        context.setShadow(offset: .zero, blur: 12, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(frame)
        context.restoreGState()

        context.saveGState()
        context.clip(to: frame)
        context.interpolationQuality = .none
        context.draw(cropped, in: frame)

        // Pixel grid.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1)
        context.beginPath()
        for step in stride(from: CGFloat(0), through: side, by: magnification) {
            context.move(to: CGPoint(x: frame.minX + step, y: frame.minY))
            context.addLine(to: CGPoint(x: frame.minX + step, y: frame.maxY))
            context.move(to: CGPoint(x: frame.minX, y: frame.minY + step))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + step))
        }
        context.strokePath()

        // Centre pixel reticle.
        let centre = CGRect(
            x: frame.midX - magnification / 2,
            y: frame.midY - magnification / 2,
            width: magnification,
            height: magnification
        )
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(centre)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(frame)

        let global = globalCGPoint(mouseLocation)
        drawBadge(
            "\(Int(global.x)), \(Int(global.y))",
            near: CGPoint(x: frame.midX, y: frame.minY - 12),
            in: context
        )
    }

    private func drawInstructions(in context: CGContext) {
        let point = CGPoint(x: bounds.midX, y: bounds.maxY - 60)
        let text = selection == nil
            ? mode.instructions
            : "Drag inside to move · drag corners to resize · Return captures"
        drawBadge(text, near: point, in: context, prominent: true)
    }

    private func drawBadge(
        _ text: String,
        near point: CGPoint,
        in context: CGContext,
        prominent: Bool = false
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: prominent ? 13 : 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding: CGFloat = prominent ? 10 : 6
        var box = CGRect(
            x: point.x - textSize.width / 2 - padding,
            y: point.y - textSize.height / 2 - padding / 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        box.origin.x = min(max(box.origin.x, bounds.minX + 8), bounds.maxX - box.width - 8)
        box.origin.y = min(max(box.origin.y, bounds.minY + 8), bounds.maxY - box.height - 8)

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        attributed.draw(at: CGPoint(
            x: box.midX - textSize.width / 2,
            y: box.midY - textSize.height / 2
        ))
        NSGraphicsContext.restoreGraphicsState()
    }
}
