import CoreGraphics
import Testing
@testable import NotchShotKit

/// Cocoa is bottom-left origin, CoreGraphics/ScreenCaptureKit is top-left.
/// Getting this wrong silently captures the wrong part of the wrong display,
/// so the conversions are pinned here.
@Suite("Screen geometry")
struct ScreenGeometryTests {

    /// A 1920×1200 primary display.
    let primary = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    @Test("Cocoa to CG flips the y axis around the primary display's top edge")
    func cocoaToCG() {
        // A 100×50 rect sitting at the very bottom-left in Cocoa space…
        let cocoa = CGRect(x: 10, y: 0, width: 100, height: 50)
        let cg = ScreenGeometry.cgRect(fromCocoa: cocoa, primaryFrame: primary)
        // …is at the very bottom in CG space too, but measured from the top.
        #expect(cg == CGRect(x: 10, y: 1150, width: 100, height: 50))
    }

    @Test("CG to Cocoa is the exact inverse")
    func roundTrip() {
        let original = CGRect(x: 42, y: 137, width: 300, height: 220)
        let cg = ScreenGeometry.cgRect(fromCocoa: original, primaryFrame: primary)
        let back = ScreenGeometry.cocoaRect(fromCG: cg, primaryFrame: primary)
        #expect(back == original)
    }

    @Test("A display above the primary has negative CG y")
    func displayAbovePrimary() {
        // Secondary display stacked on top: Cocoa y runs from 1200 to 2280.
        let cocoa = CGRect(x: 0, y: 1200, width: 1920, height: 1080)
        let cg = ScreenGeometry.cgRect(fromCocoa: cocoa, primaryFrame: primary)
        #expect(cg.origin.y == -1080)
        #expect(cg.maxY == 0)
    }

    @Test("A display left of the primary keeps its negative x")
    func displayLeftOfPrimary() {
        let cocoa = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let cg = ScreenGeometry.cgRect(fromCocoa: cocoa, primaryFrame: primary)
        #expect(cg.origin.x == -1440)
        #expect(cg.origin.y == 300) // 1200 - 900
    }

    @Test("Display-local conversion removes the display's origin")
    func displayLocal() {
        let displayBounds = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let global = CGRect(x: 2020, y: 100, width: 200, height: 150)
        let local = ScreenGeometry.displayLocalRect(
            globalCGRect: global,
            displayCGBounds: displayBounds
        )
        #expect(local == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("Pixel size respects the display's backing scale")
    func pixelSize() {
        let rect = CGRect(x: 0, y: 0, width: 100.4, height: 50.6)
        #expect(ScreenGeometry.pixelSize(forPointRect: rect, scale: 2) == CGSize(width: 201, height: 101))
        #expect(ScreenGeometry.pixelSize(forPointRect: rect, scale: 1) == CGSize(width: 100, height: 51))
    }

    @Test("Clamping keeps a selection inside its display")
    func clamping() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clamped = ScreenGeometry.clamp(CGRect(x: 80, y: 80, width: 50, height: 50), to: container)
        #expect(clamped == CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    @Test("A selection entirely off-display clamps to nil")
    func clampingOutside() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ScreenGeometry.clamp(CGRect(x: 200, y: 200, width: 10, height: 10), to: container) == nil)
    }

    @Test("A degenerate selection clamps to nil rather than a 0px capture")
    func clampingDegenerate() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ScreenGeometry.clamp(CGRect(x: 99.5, y: 10, width: 20, height: 20), to: container, minimumSide: 2) == nil)
    }

    @Test("Dragging in any direction produces a positive-sized rect")
    func dragNormalisation() {
        let expected = CGRect(x: 10, y: 20, width: 90, height: 80)
        #expect(ScreenGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 10, y: 20)) == expected)
        #expect(ScreenGeometry.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 100, y: 100)) == expected)
    }

    @Test("Aspect lock follows the larger dragged dimension")
    func aspectLock() {
        // Wide drag: width wins, height is derived.
        let wide = ScreenGeometry.rect(
            from: .zero,
            to: CGPoint(x: 400, y: 50),
            lockedAspectRatio: 2
        )
        #expect(wide == CGRect(x: 0, y: 0, width: 400, height: 200))

        // Tall drag: height wins.
        let tall = ScreenGeometry.rect(
            from: .zero,
            to: CGPoint(x: 50, y: 400),
            lockedAspectRatio: 2
        )
        #expect(tall == CGRect(x: 0, y: 0, width: 800, height: 400))
    }

    @Test("Aspect lock dragging up and left anchors on the origin")
    func aspectLockNegative() {
        let rect = ScreenGeometry.rect(
            from: CGPoint(x: 500, y: 500),
            to: CGPoint(x: 100, y: 450),
            lockedAspectRatio: 2
        )
        #expect(rect.maxX == 500)
        #expect(rect.maxY == 500)
        #expect(rect.width == 400)
        #expect(rect.height == 200)
    }
}

@Suite("Notch metrics")
struct NotchMetricsTests {

    @Test("A notched MacBook reports the gap between the auxiliary areas")
    func physicalNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let metrics = NotchMetrics.metrics(
            screenFrame: screen,
            safeAreaTop: 37,
            auxiliaryTopLeft: CGRect(x: 0, y: 945, width: 631, height: 37),
            auxiliaryTopRight: CGRect(x: 881, y: 945, width: 631, height: 37),
            menuBarHeight: 24
        )
        #expect(metrics.hasPhysicalNotch)
        #expect(metrics.notchSize == CGSize(width: 250, height: 37))
        // The menu bar is at least as tall as the notch on these machines.
        #expect(metrics.menuBarHeight == 37)
    }

    @Test("An external display falls back to a synthetic island")
    func externalDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let metrics = NotchMetrics.metrics(
            screenFrame: screen,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            menuBarHeight: 24
        )
        #expect(!metrics.hasPhysicalNotch)
        #expect(metrics.notchSize == NotchMetrics.syntheticIslandSize)
    }

    @Test("Auxiliary areas that cover the full width mean no notch")
    func degenerateAuxiliaryAreas() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let metrics = NotchMetrics.metrics(
            screenFrame: screen,
            safeAreaTop: 30,
            auxiliaryTopLeft: CGRect(x: 0, y: 670, width: 500, height: 30),
            auxiliaryTopRight: CGRect(x: 500, y: 670, width: 500, height: 30),
            menuBarHeight: 24
        )
        #expect(!metrics.hasPhysicalNotch)
    }

    @Test("The notch rect is centred at the top of its display")
    func notchRect() {
        let screen = CGRect(x: 100, y: 200, width: 1000, height: 700)
        let metrics = NotchMetrics(
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 200, height: 32),
            menuBarHeight: 32
        )
        #expect(metrics.notchRect == CGRect(x: 500, y: 868, width: 200, height: 32))
    }

    @Test("Every island fits inside the panel it is drawn in")
    func layoutsFitThePanel() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let activities: [NotchActivity] = [
            .idle, .media, .expanded, .selecting(.area),
            .countdown(remaining: 3, intent: .area), .recording,
            .processing("x"), .result, .error("x"),
        ]
        for activity in activities {
            for peeking in [true, false] {
                let layout = NotchLayout.layout(
                    for: activity,
                    metrics: metrics,
                    isPeeking: peeking,
                    resultCount: 5
                )
                #expect(layout.size.width <= NotchLayout.maximumSize.width)
                #expect(layout.size.height <= NotchLayout.maximumSize.height)
            }
        }
    }

    @Test("The closed idle island is exactly the hardware notch")
    func closedIdleMatchesNotch() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let layout = NotchLayout.layout(for: .idle, metrics: metrics, isPeeking: false, resultCount: 0)
        #expect(layout.size == metrics.notchSize)
    }
}
