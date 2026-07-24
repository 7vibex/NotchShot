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
        case .area: "Drag to select · Space to move · ⇧ locks ratio · ⎋ cancels"
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
        isPresenting = true

        let showsFreeze = Preferences.shared.freezeScreenDuringSelection && !freezeFrames.isEmpty
        let showsMagnifier = Preferences.shared.showsMagnifier

        for screen in NSScreen.screens {
            guard let displayID = ScreenLookup.displayID(for: screen) else { continue }
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
            window.onSelectionChanged = { [weak self] rect, sourceDisplay in
                MainActor.assumeIsolated { self?.broadcastSelection(rect, from: sourceDisplay) }
            }
            if let initialRect {
                window.setInitialGlobalRect(initialRect)
            }
            WindowExclusionRegistry.shared.register(window)
            windows.append(window)
            window.orderFrontRegardless()
        }

        guard !windows.isEmpty else {
            isPresenting = false
            return .cancelled
        }

        // The overlay must take key focus to receive Escape and arrow keys, but
        // the app stays an accessory so the user's frontmost app is unchanged
        // in the resulting capture.
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    public func cancel() {
        guard isPresenting else { return }
        finish(.cancelled)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // 53 = Escape. Handled here so it works no matter which of the
            // per-display overlay windows currently holds focus.
            guard let self, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.finish(.cancelled) }
            return nil
        }
    }

    /// A drag that crosses onto another display has to keep drawing on both, so
    /// the originating window pushes its rect to its siblings.
    private func broadcastSelection(_ globalRect: CGRect?, from displayID: CGDirectDisplayID) {
        for window in windows where window.displayID != displayID {
            window.applyExternalSelection(globalRect)
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
        NSApp.hide(nil)

        continuation?.resume(returning: result)
        continuation = nil
    }
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
    private var hasDragged = false
    private var hoveredWindow: WindowInfo?
    private var freezeImage: CGImage?
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
            selection = local
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

        if let selection, selection.contains(point), !selection.isEmpty {
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

        if isMovingSelection, var selection {
            selection.origin = CGPoint(x: point.x - moveAnchor.x, y: point.y - moveAnchor.y)
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
            )
        }

        onSelectionChanged?(selection.map { globalCGRect($0) })
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if isMovingSelection {
            isMovingSelection = false
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

        onResult?(.area(globalCGRect(selection).integral, displayID))
    }

    override func rightMouseDown(with event: NSEvent) {
        onResult?(.cancelled)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if let selection, selection.width >= 4, selection.height >= 4 {
                onResult?(.area(globalCGRect(selection).integral, displayID))
            } else if let hoveredWindow {
                onResult?(.window(hoveredWindow))
            }
        case 123, 124, 125, 126: // arrows
            nudge(keyCode: event.keyCode, fine: event.modifierFlags.contains(.option))
        case 49: // space — grab the whole hovered window's frame as an area
            if let hoveredWindow {
                let local = localRect(fromGlobalCG: hoveredWindow.frame)
                selection = local.intersection(bounds)
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
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
        self.selection = selection
        onSelectionChanged?(globalCGRect(selection))
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if showsFreeze, let freezeImage {
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(freezeImage, in: bounds)
            context.restoreGState()
        }

        let active = selection ?? externalSelection
        let highlight = (mode.wantsWindowHighlight && selection == nil)
            ? hoveredWindow.map { localRect(fromGlobalCG: $0.frame).intersection(bounds) }
            : nil
        let clearRect = active ?? highlight

        // Dim everything but the selection.
        context.setFillColor(NSColor.black.withAlphaComponent(showsFreeze ? 0.45 : 0.28).cgColor)
        if let clearRect, !clearRect.isEmpty {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(clearRect)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        } else {
            context.fill(bounds)
        }

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

    private func drawSelectionChrome(_ rect: CGRect, in context: CGContext, isWindowHighlight: Bool) {
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(isWindowHighlight ? 3 : 2)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        if !isWindowHighlight {
            // Corner handles, purely as an affordance — resize is via re-drag.
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
            label = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        }
        drawBadge(label, near: CGPoint(x: rect.midX, y: rect.minY - 14), in: context)
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
        guard selection == nil else { return }
        let point = CGPoint(x: bounds.midX, y: bounds.maxY - 60)
        drawBadge(mode.instructions, near: point, in: context, prominent: true)
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
