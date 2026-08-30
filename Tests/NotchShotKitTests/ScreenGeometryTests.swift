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

    @Test("Compact notch controls retain a usable pointer target")
    @MainActor
    func compactControlHitSize() {
        #expect(NotchIconButton.minimumHitSize >= 36)
        #expect(NotchIconButton.visualDiameter <= NotchIconButton.minimumHitSize)
        #expect(NotchShotDesignSystem.minimumControlTarget >= 36)
        #expect(NotchIconButton.disabledOpacity < 0.5)
        #expect(NotchIconButton.usesLiquidGlass)
    }

    @Test("Notch controls use glass normally and become opaque for accessibility")
    func accessibleIslandControls() {
        #expect(NotchControlSurfacePolicy.usesLiquidGlass)
        #expect(NotchControlSurfacePolicy.shouldUseLiquidGlass(
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchControlSurfacePolicy.shouldUseLiquidGlass(
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!NotchControlSurfacePolicy.shouldUseLiquidGlass(
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(!NotchControlSurfacePolicy.shouldUseLiquidGlass(
            reduceTransparency: false,
            increaseContrast: false,
            allowsLiquidGlass: false
        ))
        #expect(!NotchControlSurfacePolicy.usesOpaqueSurface(
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(NotchControlSurfacePolicy.usesOpaqueSurface(
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(NotchControlSurfacePolicy.usesOpaqueSurface(
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(NotchControlSurfacePolicy.fillOpacity(
            increaseContrast: true,
            emphasized: false
        ) > NotchControlSurfacePolicy.fillOpacity(
            increaseContrast: false,
            emphasized: false
        ))
        #expect(NotchControlSurfacePolicy.strokeOpacity(
            increaseContrast: false,
            emphasized: true
        ) > NotchControlSurfacePolicy.strokeOpacity(
            increaseContrast: false,
            emphasized: false
        ))
    }

    @Test("Capture expansion stays compact around the essential commands")
    func compactCaptureExpansion() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let layout = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.size == CGSize(width: 432, height: 201))
        #expect(layout.contentTopInset == 37)
        #expect(layout.cornerRadius == 32)
    }

    @Test("Expanded AI activity uses a compact workbench")
    func aiActivityLayout() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let activity = NotchActivity.context(ContextSnapshot(
            kind: .ai,
            title: "Codex · Working",
            presentation: .expanded
        ))
        let layout = NotchLayout.layout(
            for: activity,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.size == CGSize(width: 520, height: 357))
        #expect(layout.contentTopInset == 37)
    }

    @Test("Now Playing keeps pointer presence polling armed before the first click")
    @MainActor
    func mediaPresencePolling() {
        #expect(NotchWindowController.shouldPollPresence(
            activity: .media,
            isPeeking: false,
            isPointerOverIsland: false,
            hasHoveredDisplay: false
        ))
        #expect(!NotchWindowController.shouldPollPresence(
            activity: .idle,
            isPeeking: false,
            isPointerOverIsland: false,
            hasHoveredDisplay: false
        ))
        #expect(NotchWindowController.shouldPollPresence(
            activity: .idle,
            isPeeking: true,
            isPointerOverIsland: false,
            hasHoveredDisplay: false
        ))
        #expect(NotchWindowController.shouldPollPresence(
            activity: .context(ContextSnapshot(kind: .calendar, title: "Next")),
            isPeeking: false,
            isPointerOverIsland: false,
            hasHoveredDisplay: false
        ))
    }

    /// Media arms the poll for hours at a time, so the full rate is spent only
    /// where it can change the outcome — while the notch is engaged, or while
    /// the pointer is close enough to reach it before the next slow tick.
    @Test("The pointer poll drops to its backstop rate away from the notch")
    @MainActor
    func presencePollCadence() {
        #expect(NotchWindowController.presencePollInterval(
            isEngaged: false,
            isPointerNearNotch: false
        ) == NotchWindowController.idlePresencePollInterval)

        #expect(NotchWindowController.presencePollInterval(
            isEngaged: false,
            isPointerNearNotch: true
        ) == NotchWindowController.presencePollInterval)

        #expect(NotchWindowController.presencePollInterval(
            isEngaged: true,
            isPointerNearNotch: false
        ) == NotchWindowController.presencePollInterval)

        // The backstop must still be quicker than the peek delay, or a slow
        // tick could outlast the gesture it is meant to catch.
        #expect(NotchWindowController.idlePresencePollInterval > NotchWindowController.presencePollInterval)
        #expect(NotchWindowController.idlePresencePollInterval < 0.35)
    }

    @Test("A locked session shows only opted-in app-owned content and never accepts input")
    @MainActor
    func lockedMediaPresentationPolicy() {
        #expect(LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: true,
            activity: .result,
            mediaOptedIn: false,
            hasMediaContent: false
        ))
        #expect(LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: false,
            activity: .media,
            mediaOptedIn: true,
            hasMediaContent: true
        ))
        #expect(LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: false,
            activity: .result,
            mediaOptedIn: true,
            hasMediaContent: true
        ))
        #expect(!LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: false,
            activity: .media,
            mediaOptedIn: false,
            hasMediaContent: true
        ))
        #expect(LockedMediaPresentationPolicy.effectiveActivity(
            sessionIsActive: false,
            currentActivity: .result,
            mediaOptedIn: true,
            hasMediaContent: true
        ) == .media)
        #expect(LockedMediaPresentationPolicy.effectiveActivity(
            sessionIsActive: false,
            currentActivity: .media,
            mediaOptedIn: true,
            hasMediaContent: false
        ) == .idle)
        #expect(LockedMediaPresentationPolicy.content(
            mediaOptedIn: false,
            hasMediaContent: false,
            activityStackOptedIn: true,
            hasActivityContent: true
        ) == .activityStack)
        #expect(LockedMediaPresentationPolicy.effectiveActivity(
            sessionIsActive: false,
            currentActivity: .idle,
            mediaOptedIn: false,
            hasMediaContent: false,
            activityStackOptedIn: true,
            hasActivityContent: true
        ) == .media)
        #expect(!LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: false,
            activity: .idle,
            mediaOptedIn: false,
            hasMediaContent: false,
            activityStackOptedIn: false,
            hasActivityContent: true
        ))
        #expect(LockedMediaPresentationPolicy.canBecomeVisibleWithoutLogin(
            mediaOptedIn: false,
            activityStackOptedIn: true
        ))
        #expect(!LockedMediaPresentationPolicy.acceptsInput(sessionIsActive: false))
        #expect(LockedMediaPresentationPolicy.acceptsInput(sessionIsActive: true))
        #expect(NotchPanel.level(sessionIsActive: true) == NotchPanel.notchLevel)
        #expect(NotchPanel.level(sessionIsActive: false) == .screenSaver)
        #expect(NotchPanel.lockedMediaLevel.rawValue > NotchPanel.notchLevel.rawValue)
    }

    @Test("Only the physical cutout needs AppKit click bridging")
    @MainActor
    func triggerClickBridge() {
        let physical = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        #expect(NotchWindowController.shouldBridgeTriggerClick(
            at: CGPoint(x: physical.notchRect.midX, y: physical.notchRect.midY),
            metrics: physical
        ))
        #expect(!NotchWindowController.shouldBridgeTriggerClick(
            at: CGPoint(x: physical.notchRect.minX - 2, y: physical.notchRect.midY),
            metrics: physical
        ))

        var synthetic = physical
        synthetic.hasPhysicalNotch = false
        #expect(!NotchWindowController.shouldBridgeTriggerClick(
            at: CGPoint(x: synthetic.notchRect.midX, y: synthetic.notchRect.midY),
            metrics: synthetic
        ))
    }

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

    @Test("The physical shell covers and aligns with the complete reported notch band")
    func physicalNotchCoverage() {
        // Values measured on this 14-inch MacBook Pro. The safe-area and
        // auxiliary regions are 32pt tall, but the menu-bar band is 33pt. Its
        // odd-width 179pt gap is centred at x=735.5, not screen midX 735.
        let metrics = NotchMetrics.metrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_470, height: 956),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 924, width: 646, height: 32),
            auxiliaryTopRight: CGRect(x: 825, y: 924, width: 645, height: 32),
            menuBarHeight: 33
        )

        #expect(metrics.hasPhysicalNotch)
        #expect(metrics.notchSize == CGSize(width: 179, height: 33))
        #expect(metrics.notchCenterX == 735.5)
        #expect(metrics.notchRect == CGRect(x: 646, y: 923, width: 179, height: 33))

        let expanded = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(expanded.islandRect(in: metrics).midX == metrics.notchRect.midX)
        #expect(expanded.contentTopInset == 33)
        #expect(expanded.size.height - expanded.contentTopInset == NotchIsland.Geometry.expandedCaptureHeight)
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
        #expect(metrics.notchSize == CGSize(width: 126, height: 37))
    }

    @Test("A synthetic island floats below the edge and grows through Apple's size classes")
    func syntheticIslandPresentationGeometry() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            hasPhysicalNotch: false,
            notchSize: NotchMetrics.syntheticIslandSize,
            menuBarHeight: 24
        )

        let idle = NotchLayout.layout(
            for: .idle,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(idle.size == CGSize(width: 126, height: 37))
        #expect(idle.cornerRadius == 18.5)
        #expect(idle.topInset == 6)
        #expect(idle.islandRect(in: metrics).maxY == metrics.screenFrame.maxY - 6)

        let compact = NotchLayout.layout(
            for: .media,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(compact.size == CGSize(width: 230, height: 37))
        #expect(compact.cornerRadius == 18.5)

        let expanded = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(expanded.size == CGSize(width: 432, height: 164))
        #expect(expanded.cornerRadius == 32)
        #expect(expanded.topInset == idle.topInset)
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
            .processing("x"), .result,
            .systemNotification(SystemNotificationSnapshot(
                sourceName: "Mail",
                title: "Message",
                body: "Body"
            )),
            .error("x"),
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
        #expect(layout.contentTopInset == 0)
        #expect(layout.topInset == 0)
    }

    @Test("Compact system feedback stays inside the physical notch band")
    func revealedContentClearsNotch() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )

        let systemLevel = NotchLayout.layout(
            for: .systemLevel(SystemLevel(kind: .brightness, value: 0.5, isMuted: false)),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(systemLevel.contentTopInset == 0)
        #expect(systemLevel.size.height == 37)

        let mediaPeek = NotchLayout.layout(
            for: .media,
            metrics: metrics,
            isPeeking: true,
            resultCount: 0
        )
        #expect(mediaPeek.contentTopInset == 37)
        // 122pt of content plus the 37pt cutout band. The expanded player now
        // includes elapsed/total time and the public Core Audio output picker.
        #expect(mediaPeek.size.height == 159)
        // Whatever the content height, it must clear the camera.
        #expect(mediaPeek.size.height - mediaPeek.contentTopInset == 122)

        let compactMedia = NotchLayout.layout(
            for: .media,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(compactMedia.contentTopInset == 0)
        #expect(compactMedia.size.height == 37)
        #expect(compactMedia.size.width == metrics.notchSize.width + 76)
    }

    @Test("Notchless displays keep their existing content heights")
    func notchlessContentNeedsNoClearance() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            hasPhysicalNotch: false,
            notchSize: NotchMetrics.syntheticIslandSize,
            menuBarHeight: 24
        )
        let layout = NotchLayout.layout(
            for: .systemLevel(SystemLevel(kind: .volume, value: 0.5, isMuted: false)),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.contentTopInset == 0)
        #expect(layout.size.height == 46)
        #expect(layout.topInset == NotchIsland.Geometry.floatingTopInset)
    }

    /// `visibleFrame` excludes the Dock as well as the menu bar, so deriving the
    /// menu bar from the difference of *heights* counted the Dock too — 96pt
    /// instead of 33 on a 14" MacBook Pro with the Dock showing.
    @Test("The menu bar height ignores the Dock")
    func menuBarHeightExcludesDock() {
        // Real values measured on a 14" MacBook Pro with a visible Dock.
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let visible = CGRect(x: 0, y: 63, width: 1470, height: 860)

        let fromTops = max(frame.maxY - visible.maxY, 24)
        let fromHeights = max(frame.height - visible.height, 24)

        #expect(fromTops == 33)
        #expect(fromHeights == 96)
        // The notch itself is 32pt here, so the correct value stays close to it.
        #expect(abs(fromTops - 32) <= 2)
    }
}
