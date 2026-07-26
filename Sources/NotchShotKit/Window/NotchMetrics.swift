import AppKit
import Foundation

/// Physical geometry of one display's notch (or the synthetic island we draw
/// on displays that don't have one).
public struct NotchMetrics: Sendable, Equatable {
    /// Cocoa-space frame of the whole display.
    public var screenFrame: CGRect
    /// True when the display reports a real hardware notch.
    public var hasPhysicalNotch: Bool
    /// Size in points of the notch cutout, or of the synthetic island.
    public var notchSize: CGSize
    /// Height of the menu bar area, used to align the island with it.
    public var menuBarHeight: CGFloat

    public init(screenFrame: CGRect, hasPhysicalNotch: Bool, notchSize: CGSize, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchSize = notchSize
        self.menuBarHeight = menuBarHeight
    }

    /// Size used when no hardware notch exists. Roughly notch-shaped so the
    /// same layout math and artwork work on external displays.
    public static let syntheticIslandSize = CGSize(width: 190, height: 32)

    /// Derives metrics from raw `NSScreen` values. Pure, so the multi-display
    /// permutations are unit-testable without hardware.
    ///
    /// A notched Mac reports a non-zero `safeAreaInsets.top` plus two auxiliary
    /// areas flanking the cutout; the gap between them is the notch itself.
    public static func metrics(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        menuBarHeight: CGFloat
    ) -> NotchMetrics {
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            let width = screenFrame.width - left.width - right.width
            if width > 1 {
                return NotchMetrics(
                    screenFrame: screenFrame,
                    hasPhysicalNotch: true,
                    notchSize: CGSize(width: width, height: safeAreaTop),
                    menuBarHeight: max(menuBarHeight, safeAreaTop)
                )
            }
        }
        return NotchMetrics(
            screenFrame: screenFrame,
            hasPhysicalNotch: false,
            notchSize: syntheticIslandSize,
            menuBarHeight: menuBarHeight
        )
    }

    @MainActor
    public static func metrics(for screen: NSScreen) -> NotchMetrics {
        metrics(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            // Difference of the *tops*, not of the heights: `visibleFrame` also
            // excludes the Dock, so subtracting heights reported the menu bar as
            // menu bar + Dock — 96pt instead of 33 on a 14" MacBook Pro.
            menuBarHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        )
    }

    /// Cocoa-space rect of the notch cutout itself.
    public var notchRect: CGRect {
        CGRect(
            x: screenFrame.midX - notchSize.width / 2,
            y: screenFrame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }
}

/// Content size the notch wants for a given activity. The panel itself stays a
/// fixed, generous rectangle; this is the size of the *drawn* island inside it,
/// and the region that accepts mouse events.
public struct NotchLayout: Sendable, Equatable {
    public var size: CGSize
    /// Corner radius of the island's bottom corners.
    public var cornerRadius: CGFloat
    /// Vertical space occupied by the physical camera cutout. Revealed content
    /// is laid out below this band instead of being centered behind hardware.
    public var contentTopInset: CGFloat

    public init(size: CGSize, cornerRadius: CGFloat, contentTopInset: CGFloat = 0) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.contentTopInset = contentTopInset
    }

    /// Largest island the panel must be able to contain. The panel is sized to
    /// this plus shadow padding, once, so state changes never resize the window.
    public static let maximumSize = CGSize(width: 640, height: 440)
    /// Slack around the island for shadows and spring overshoot.
    public static let shadowPadding: CGFloat = 40

    public static func layout(
        for activity: NotchActivity,
        metrics: NotchMetrics,
        isPeeking: Bool,
        resultCount: Int,
        hasStack: Bool = false
    ) -> NotchLayout {
        let closed = CGSize(
            width: max(metrics.notchSize.width, 1),
            height: max(metrics.notchSize.height, 1)
        )
        let revealedContentInset = metrics.hasPhysicalNotch ? closed.height : 0

        func revealed(
            width: CGFloat,
            contentHeight: CGFloat,
            cornerRadius: CGFloat
        ) -> NotchLayout {
            NotchLayout(
                size: CGSize(
                    width: width,
                    height: min(contentHeight + revealedContentInset, maximumSize.height)
                ),
                cornerRadius: cornerRadius,
                contentTopInset: revealedContentInset
            )
        }

        switch activity {
        case .idle:
            if isPeeking {
                return revealed(
                    width: closed.width + 150,
                    contentHeight: 46,
                    cornerRadius: metrics.hasPhysicalNotch ? 12 : 16
                )
            }
            return NotchLayout(size: closed, cornerRadius: metrics.hasPhysicalNotch ? 12 : 16)
        case .media:
            let width = isPeeking ? max(closed.width + 290, 470) : closed.width + 92
            if isPeeking {
                // Taller and wider than the bare progress bar needed: the
                // scrubber carries an elapsed and a total time either side of it.
                return revealed(width: width, contentHeight: 86, cornerRadius: 18)
            }
            // Compact media lives in the visible wings beside the camera and
            // intentionally shares the hardware notch's vertical band.
            return NotchLayout(
                size: CGSize(width: width, height: max(closed.height, 32)),
                cornerRadius: 18
            )
        case .expanded:
            return revealed(width: 520, contentHeight: 268, cornerRadius: 24)
        case .selecting:
            return revealed(width: 340, contentHeight: 54, cornerRadius: 18)
        case .countdown:
            return revealed(width: 260, contentHeight: 92, cornerRadius: 22)
        case .recording:
            return revealed(width: 420, contentHeight: 96, cornerRadius: 22)
        case .processing:
            return revealed(width: 320, contentHeight: 62, cornerRadius: 18)
        case .result:
            let extra = min(max(resultCount - 1, 0), 4) * 12
            let height: CGFloat = hasStack ? 226 : 186
            return revealed(width: 470 + CGFloat(extra), contentHeight: height, cornerRadius: 24)
        case .systemLevel:
            // Just wide enough for an icon and a bar: a volume nudge should
            // feel like the notch flexing, not like a panel opening.
            return revealed(
                width: max(closed.width + 230, 390),
                contentHeight: 46,
                cornerRadius: 20
            )
        case .error:
            return revealed(width: 360, contentHeight: 62, cornerRadius: 18)
        }
    }

    /// Cocoa-space rect of the island for a display, anchored to the top centre.
    public func islandRect(in metrics: NotchMetrics) -> CGRect {
        CGRect(
            x: metrics.screenFrame.midX - size.width / 2,
            y: metrics.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
