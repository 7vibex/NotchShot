import AppKit
import CoreGraphics
import Foundation

/// Coordinate conversion between the three spaces NotchShot works in:
///
/// - **Cocoa global**: bottom-left origin, y grows up, origin at the primary
///   display's bottom-left. What `NSScreen.frame` uses.
/// - **CoreGraphics global**: top-left origin, y grows down, origin at the
///   primary display's top-left. What `CGDisplayBounds`, ScreenCaptureKit and
///   `CGWindowListCopyWindowInfo` use.
/// - **Display-local pixels**: origin at a display's top-left, in backing pixels.
///
/// Getting this wrong is the single most common source of off-by-a-display bugs
/// on multi-monitor setups, so it lives here, pure and unit-tested.
public enum ScreenGeometry {

    /// Height of the full Cocoa global coordinate space, i.e. the top edge of
    /// the primary display. Cocoa's y-flip pivots around this value.
    public static func globalHeight(primaryFrame: CGRect) -> CGFloat {
        primaryFrame.maxY
    }

    /// Cocoa (bottom-left) → CoreGraphics (top-left).
    public static func cgRect(fromCocoa rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: globalHeight(primaryFrame: primaryFrame) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// CoreGraphics (top-left) → Cocoa (bottom-left).
    public static func cocoaRect(fromCG rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: globalHeight(primaryFrame: primaryFrame) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func cgPoint(fromCocoa point: CGPoint, primaryFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: globalHeight(primaryFrame: primaryFrame) - point.y)
    }

    public static func cocoaPoint(fromCG point: CGPoint, primaryFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: globalHeight(primaryFrame: primaryFrame) - point.y)
    }

    /// Converts a global CG rect into the display's local point space, then to
    /// backing pixels. ScreenCaptureKit's `sourceRect` wants *points* relative
    /// to the display; the resulting pixel size is what the output should be.
    public static func displayLocalRect(
        globalCGRect rect: CGRect,
        displayCGBounds: CGRect
    ) -> CGRect {
        rect.offsetBy(dx: -displayCGBounds.origin.x, dy: -displayCGBounds.origin.y)
    }

    /// Pixel size for a point-space rect captured on a display with `scale`.
    /// Rounded to whole pixels so the encoder never sees a fractional buffer.
    public static func pixelSize(forPointRect rect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(
            width: (rect.width * scale).rounded(),
            height: (rect.height * scale).rounded()
        )
    }

    /// Clamps a rect to a container, returning nil when there is no overlap or
    /// the result would be degenerate.
    public static func clamp(_ rect: CGRect, to container: CGRect, minimumSide: CGFloat = 1) -> CGRect? {
        let intersection = rect.intersection(container)
        guard !intersection.isNull,
              intersection.width >= minimumSide,
              intersection.height >= minimumSide else { return nil }
        return intersection.integral
    }

    /// Normalises a drag between two points into a positive-sized rect.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Applies an aspect-ratio lock while dragging, anchored at `origin`.
    /// The larger of the two dragged dimensions wins so the rect follows the
    /// pointer rather than snapping backwards.
    public static func rect(
        from origin: CGPoint,
        to current: CGPoint,
        lockedAspectRatio ratio: CGFloat?
    ) -> CGRect {
        guard let ratio, ratio > 0 else { return rect(from: origin, to: current) }
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        var width = abs(dx)
        var height = abs(dy)
        if width / ratio >= height {
            height = width / ratio
        } else {
            width = height * ratio
        }
        let x = dx < 0 ? origin.x - width : origin.x
        let y = dy < 0 ? origin.y - height : origin.y
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
public enum ScreenLookup {
    public static var primaryFrame: CGRect {
        NSScreen.screens.first?.frame ?? .zero
    }

    /// `NSScreen` carries its `CGDirectDisplayID` in deviceDescription.
    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    public static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    /// Screen containing a Cocoa-space point, falling back to the main screen.
    public static func screen(containingCocoaPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Screen containing a CG-space (top-left) point.
    public static func screen(containingCGPoint point: CGPoint) -> NSScreen? {
        let cocoa = ScreenGeometry.cocoaPoint(fromCG: point, primaryFrame: primaryFrame)
        return screen(containingCocoaPoint: cocoa)
    }

    /// CG-space bounds of a screen.
    public static func cgBounds(of screen: NSScreen) -> CGRect {
        ScreenGeometry.cgRect(fromCocoa: screen.frame, primaryFrame: primaryFrame)
    }

    /// Screen whose CG bounds contain the largest part of `rect`.
    public static func screen(bestMatchingCGRect rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let l = cgBounds(of: lhs).intersection(rect)
            let r = cgBounds(of: rhs).intersection(rect)
            let lArea = l.isNull ? 0 : l.width * l.height
            let rArea = r.isNull ? 0 : r.width * r.height
            return lArea < rArea
        }
    }
}
