import AppKit
import Foundation

/// Physical geometry of one display's notch (or the synthetic island we draw
/// on displays that don't have one).
public struct NotchMetrics: Sendable, Equatable {
    /// Cocoa-space frame of the whole display.
    public var screenFrame: CGRect
    /// True when the display reports a real hardware notch.
    public var hasPhysicalNotch: Bool
    /// Size in points of the region the black shell must cover, or of the
    /// synthetic island. On a physical display this can be one point taller
    /// than the safe-area cutout when the menu-bar band includes its separator.
    public var notchSize: CGSize
    /// Horizontal centre reported by the display's two auxiliary top areas.
    /// Odd-width hardware gaps can sit on a half point rather than exactly on
    /// `screenFrame.midX`.
    public var notchCenterX: CGFloat
    /// Height of the menu bar area, used to align the island with it.
    public var menuBarHeight: CGFloat

    public init(
        screenFrame: CGRect,
        hasPhysicalNotch: Bool,
        notchSize: CGSize,
        menuBarHeight: CGFloat,
        notchCenterX: CGFloat? = nil
    ) {
        self.screenFrame = screenFrame
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchSize = notchSize
        self.menuBarHeight = menuBarHeight
        self.notchCenterX = notchCenterX ?? screenFrame.midX
    }

    /// Size used when no hardware notch exists. It represents the compact
    /// sensor core, while active content grows to the wider compact activity
    /// width in `NotchLayout`.
    public static let syntheticIslandSize = NotchIsland.Geometry.syntheticCoreSize

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
            let notchMinX = max(left.maxX, screenFrame.minX)
            let notchMaxX = min(right.minX, screenFrame.maxX)
            let width = notchMaxX - notchMinX
            if width > 1 {
                // `safeAreaInsets.top` describes the camera clearance, while
                // the visible menu-bar band can include another point at its
                // bottom edge. Cover the complete band so the wallpaper never
                // appears as a hairline below the physical notch.
                let coverageHeight = max(
                    safeAreaTop,
                    menuBarHeight,
                    left.height,
                    right.height
                )
                return NotchMetrics(
                    screenFrame: screenFrame,
                    hasPhysicalNotch: true,
                    notchSize: CGSize(width: width, height: coverageHeight),
                    menuBarHeight: coverageHeight,
                    notchCenterX: notchMinX + width / 2
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

    /// Cocoa-space rect of the complete physical notch coverage band.
    public var notchRect: CGRect {
        CGRect(
            x: notchCenterX - notchSize.width / 2,
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
    /// Distance below the screen edge for a synthetic, fully rounded island.
    /// A physical notch always remains attached to the bezel.
    public var topInset: CGFloat
    /// Diameter of the minimal satellite shells beside the primary island, or
    /// zero when none are shown. Satellites are separate shapes: `size` stays
    /// the primary shell so its morph is unaffected by them.
    public var satelliteDiameter: CGFloat
    /// Gap between the primary shell and a satellite.
    public var satelliteSpacing: CGFloat
    /// Extra width for a lone satellite that shows a short value beside its
    /// glyph ("4:12", "63%"), turning the circle into a pill. Zero otherwise.
    public var satelliteValueWidth: CGFloat = 0
    /// Horizontal shift of the primary shell. A synthetic island with a single
    /// satellite moves the pair so the group, not just the pill, is centred.
    /// Always zero on a physical notch, which must stay under the camera.
    public var clusterOffset: CGFloat = 0
    /// The content draws its own header in the camera band (see
    /// `IslandCameraBand`) instead of starting below it.
    public var wrapsCamera = false

    public init(
        size: CGSize,
        cornerRadius: CGFloat,
        contentTopInset: CGFloat = 0,
        topInset: CGFloat = 0,
        satelliteDiameter: CGFloat = 0,
        satelliteSpacing: CGFloat = 0
    ) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.contentTopInset = contentTopInset
        self.topInset = topInset
        self.satelliteDiameter = satelliteDiameter
        self.satelliteSpacing = satelliteSpacing
    }

    /// A copy with `wrapsCamera` set.
    public func wrappingCamera(_ wraps: Bool) -> NotchLayout {
        var copy = self
        copy.wrapsCamera = wraps
        return copy
    }

    /// Horizontal reach of the satellite band on each side of the primary,
    /// including the part of each satellite's hit target that is wider than
    /// the circle drawn. Symmetric, so the hit region stays centred.
    public var satelliteExtent: CGFloat {
        guard satelliteDiameter > 0 else { return 0 }
        let hitWidth = max(satelliteWidth, NotchShotDesignSystem.minimumControlTarget)
        return satelliteSpacing + satelliteWidth / 2 + hitWidth / 2
    }

    /// Drawn width of each satellite: its circle, or the pill when it carries
    /// a value.
    public var satelliteWidth: CGFloat {
        satelliteDiameter + satelliteValueWidth
    }

    /// Width the idle notch grows by on each side while the microphone or a
    /// camera is in use, or NotchShot has a mode on (Keep Awake, Instant
    /// Replay, a locked keyboard), to show small indicators beside the camera.
    public static let privacyIndicatorWing: CGFloat = 22

    /// Width reserved for a lone satellite's value.
    public static let satelliteValueSlot: CGFloat = 40

    /// Largest island the panel must be able to contain. The panel is sized to
    /// this plus shadow padding, once, so state changes never resize the window.
    public static let maximumSize = CGSize(width: 640, height: 440)

    /// Visible width either side of a physical cutout in the collapsed context
    /// strip.
    ///
    /// A physical notch is a hole, not a dark pixel: anything drawn behind it is
    /// gone, not dimmed. The collapsed strip therefore has only these two wings
    /// to work with, and its width is derived from them rather than the other
    /// way round. The previous 44pt could not hold a single word — a state label
    /// or a percentage ran straight under the camera — while the system-level
    /// HUD had already claimed 115pt for the same job. 75pt fits an agent glyph
    /// with a progress ring on one side and a short metric on the other, without
    /// making a strip that can persist for a 30-minute agent run as wide as a
    /// transient volume HUD.
    public static let compactContextWing: CGFloat = 75
    /// Slack around the island for shadows and spring overshoot.
    public static let shadowPadding: CGFloat = 40

    /// Height of the expanded player, including whichever list it has open —
    /// audio routes or Playing Next. Lists are capped at four rows: past that
    /// they stop reading as part of the island and start reading as a window
    /// hanging off the notch.
    static func mediaPeekContentHeight(panelRows: Int) -> CGFloat {
        // 4 + 56 artwork row + 22 scrubber + 40 transport + 12. The source and
        // meter sit above this, in the camera band.
        let player: CGFloat = 134
        guard panelRows > 0 else { return player }
        let visibleRows = min(panelRows, mediaPanelVisibleRowLimit)
        let rows = CGFloat(visibleRows) * mediaPanelRowHeight
        let gaps = CGFloat(visibleRows - 1) * mediaPanelRowSpacing
        return player + rows + gaps + mediaPanelListInset
    }

    /// Floor for the expanded player: below this the five-slot transport bar
    /// starts crowding, whatever the notch's own width is.
    static let mediaPeekMinimumWidth: CGFloat = 400

    static let mediaPanelRowHeight: CGFloat = 36
    static let mediaPanelRowSpacing: CGFloat = 5
    static let mediaPanelVisibleRowLimit = 4
    /// Header line plus the gaps above and below the list.
    static let mediaPanelListInset: CGFloat = 30

    /// Height of the capture shelf, derived from the rows `ShelfContent`
    /// actually draws.
    ///
    /// It used to be one of two constants. Neither matched: the detail layout
    /// adds a pager once a second capture arrives, so the island was ~22pt too
    /// short and clipped that row behind its own bottom edge, while the grid
    /// layout has no thumbnail block or pager at all and was left with ~40pt of
    /// empty island under the buttons.
    static func shelfContentHeight(
        style: ShelfPresentationStyle,
        itemCount: Int,
        hasStack: Bool
    ) -> CGFloat {
        let control = NotchShotDesignSystem.minimumControlTarget
        // `ShelfContent`: the count and view switch sit in the camera band;
        // below it 6 pt on top, 14 pt at the bottom, 10 pt between rows.
        let padding: CGFloat = 20
        let rowSpacing: CGFloat = 10
        var rows: [CGFloat] = []
        if style == .grid {
            // The 48 pt strip, then the action toolbar under it.
            rows.append(50)
            rows.append(control)
        } else {
            // The thumbnail beside its details, with the actions at the
            // bottom of the details column.
            rows.append(shelfDetailRowHeight)
        }
        if hasStack {
            // The stack strip pads its buttons by 5pt top and bottom.
            rows.append(control + 10)
        }
        // The pager only exists in the detail layout, and only once there is a
        // second capture to page to.
        if style == .detail, itemCount > 1 {
            rows.append(control)
        }
        return padding
            + rows.reduce(0, +)
            + rowSpacing * CGFloat(max(rows.count - 1, 0))
    }

    /// The detail layout's thumbnail height, which its details column and
    /// action toolbar share.
    static let shelfDetailRowHeight: CGFloat = 84

    /// A single banner keeps the original 78 pt card; each further sender
    /// adds a 52 pt row and its hairline. A lone message long enough for a
    /// second line grows by that line.
    static func systemNotificationContentHeight(
        rows: Int,
        hasOverflow: Bool,
        extraBodyLines: Int = 0
    ) -> CGFloat {
        // A row is 52 pt plus its hairline, with 10 pt under the last one so
        // it clears the bottom corners.
        10 + CGFloat(max(1, rows)) * 53 + (hasOverflow ? 18 : 0)
            + CGFloat(max(0, extraBodyLines)) * SystemNotificationCardLayout.secondLineHeight
    }

    /// Bottom lip under a status card that lives entirely in the camera band,
    /// so its corners have something to round.
    static let statusLip: CGFloat = 8

    /// Visible width either side of the camera for the recording card: the
    /// red dot, the time and its size on the left; the meters on the right.
    /// Each side of the camera in the idle hover bar.
    static let idlePeekWing: CGFloat = 156
    static let recordingWing: CGFloat = 150
    /// The meters and the three round controls, below the band.
    static let recordingBodyHeight: CGFloat = 58

    /// The message and, when a permission is missing, its fix.
    static let errorBodyHeight: CGFloat = 52

    static func processingBodyHeight(isScrolling: Bool) -> CGFloat {
        isScrolling ? 50 : statusLip
    }

    /// An expanded card whose header row sits in the camera band and whose
    /// body starts straight below the camera.
    static func bandedLayout(
        width: CGFloat,
        bodyHeight: CGFloat,
        cornerRadius: CGFloat,
        metrics: NotchMetrics,
        floatingTopInset: CGFloat
    ) -> NotchLayout {
        let band = metrics.hasPhysicalNotch
            ? max(metrics.notchSize.height, 1)
            : IslandCameraBand.floatingRowHeight + 4
        var layout = NotchLayout(
            size: CGSize(width: width, height: min(band + bodyHeight, maximumSize.height)),
            cornerRadius: cornerRadius,
            contentTopInset: 0,
            topInset: floatingTopInset
        )
        layout.wrapsCamera = true
        return layout
    }

    /// `heldHeight` keeps an open page at least that tall. Switching pages
    /// from the tab pill holds the height the pill was clicked at, so a
    /// shorter page doesn't pull the pill out from under the pointer and
    /// close the notch; the hold ends when the notch closes.
    public static func layout(
        for activity: NotchActivity,
        metrics: NotchMetrics,
        isPeeking: Bool,
        resultCount: Int,
        hasStack: Bool = false,
        mediaPanelRows: Int = 0,
        shelfStyle: ShelfPresentationStyle = .detail,
        indicatorWings: Bool = false,
        isScrollingCapture: Bool = false,
        heldHeight: CGFloat = 0
    ) -> NotchLayout {
        var layout = naturalLayout(
            for: activity,
            metrics: metrics,
            isPeeking: isPeeking,
            resultCount: resultCount,
            hasStack: hasStack,
            mediaPanelRows: mediaPanelRows,
            shelfStyle: shelfStyle,
            indicatorWings: indicatorWings,
            isScrollingCapture: isScrollingCapture
        )
        if heldHeight > layout.size.height {
            layout.size.height = min(heldHeight, maximumSize.height)
        }
        return layout
    }

    private static func naturalLayout(
        for activity: NotchActivity,
        metrics: NotchMetrics,
        isPeeking: Bool,
        resultCount: Int,
        hasStack: Bool,
        mediaPanelRows: Int,
        shelfStyle: ShelfPresentationStyle,
        indicatorWings: Bool,
        isScrollingCapture: Bool
    ) -> NotchLayout {
        let closed = CGSize(
            width: max(metrics.notchSize.width, 1),
            height: max(metrics.notchSize.height, 1)
        )
        let revealedContentInset = metrics.hasPhysicalNotch ? closed.height : 0
        let floatingTopInset = metrics.hasPhysicalNotch
            ? 0
            : NotchIsland.Geometry.floatingTopInset

        func closedLayout(cornerRadius: CGFloat) -> NotchLayout {
            NotchLayout(
                size: closed,
                cornerRadius: cornerRadius,
                topInset: floatingTopInset
            )
        }

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
                contentTopInset: revealedContentInset,
                topInset: floatingTopInset
            )
        }

        /// An expanded card whose header sits beside the camera. `bodyHeight`
        /// is everything below that header row.
        func banded(width: CGFloat, bodyHeight: CGFloat, cornerRadius: CGFloat) -> NotchLayout {
            bandedLayout(
                width: width,
                bodyHeight: bodyHeight,
                cornerRadius: cornerRadius,
                metrics: metrics,
                floatingTopInset: floatingTopInset
            )
        }

        /// Width for a card that only needs its two wings: enough either side
        /// of a physical camera for `wing`, or a pill of `floatingWidth`.
        func wingWidth(_ wing: CGFloat, floatingWidth: CGFloat) -> CGFloat {
            metrics.hasPhysicalNotch
                ? closed.width + IslandCameraBand.cameraClearance + 2 * wing
                : floatingWidth
        }

        switch activity {
        case .idle:
            if isPeeking {
                // The hover bar wraps the camera: Capture (and the user's
                // idle animation) to its left, Area and Record to its right,
                // instead of a row hung below an empty band.
                return banded(width: wingWidth(idlePeekWing, floatingWidth: 360), bodyHeight: statusLip, cornerRadius: 18)
            }
            if indicatorWings {
                // A strip either side of the camera, symmetric so the shell
                // stays centred under it: privacy dots in the trailing one,
                // NotchShot's own status glyphs in the leading one.
                return NotchLayout(
                    size: CGSize(width: closed.width + 2 * privacyIndicatorWing, height: closed.height),
                    cornerRadius: metrics.hasPhysicalNotch ? 12 : NotchIsland.Geometry.compactHeight / 2,
                    topInset: floatingTopInset
                )
            }
            return closedLayout(
                cornerRadius: metrics.hasPhysicalNotch
                    ? 12
                    : NotchIsland.Geometry.compactHeight / 2
            )
        case .media:
            // The closed island only needs artwork and a playback indicator.
            // Elapsed and total time appear in the scrubber after hover opens it.
            // Keep the compact artwork and playback wave tucked close to the
            // camera instead of floating at the outside edges of wide wings.
            let compactWidth = metrics.hasPhysicalNotch
                ? closed.width + 76
                : NotchIsland.Geometry.compactActivityWidth
            // Narrower than the capture surface on purpose. The stacked player
            // no longer competes for width with its own controls — the
            // transport sits on its own row — so the extra 120pt it used to
            // claim only spread five buttons further apart and made a hover
            // card that reached well past the notch on either side.
            let width = isPeeking
                ? max(closed.width + 170, Self.mediaPeekMinimumWidth)
                : compactWidth
            if isPeeking {
                // The source and meter in the band beside the camera, then
                // three stacked rows: artwork and titles, the scrubber with a
                // time either side, and a full-width transport bar.
                return banded(
                    width: width,
                    bodyHeight: mediaPeekContentHeight(panelRows: mediaPanelRows),
                    cornerRadius: 26
                )
            }
            // Compact media lives in the visible wings beside the camera and
            // intentionally shares the hardware notch's vertical band.
            return NotchLayout(
                size: CGSize(width: width, height: max(closed.height, 32)),
                cornerRadius: metrics.hasPhysicalNotch
                    ? 18
                    : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        case .expanded:
            // Dynamic-Island-style expansion: enough room for the three core
            // capture actions and one secondary command strip, but no large
            // dashboard floating from the camera cutout.
            // On a physical notch the preset, timer and close controls sit in
            // the band either side of the camera, so only the tiles and the
            // command strip need room below it.
            // Each wing needs room for a preset pill, or a timer pill and the
            // close button, so a wider cutout widens the menu with it.
            return revealed(
                width: metrics.hasPhysicalNotch
                    ? max(
                        NotchIsland.Geometry.expandedCaptureWidth,
                        closed.width + 2 * NotchIsland.Geometry.expandedCaptureWing
                    )
                    : NotchIsland.Geometry.expandedCaptureWidth,
                contentHeight: metrics.hasPhysicalNotch
                    ? NotchIsland.Geometry.expandedCaptureBodyHeight
                    : NotchIsland.Geometry.expandedCaptureHeight,
                cornerRadius: NotchIsland.Geometry.expandedCornerRadius
            )
        case .fileDrop:
            // One dashed destination tile per action, plus a compact
            // instruction line. The physical camera band is added by
            // `revealed`, keeping every target below real hardware while the
            // drag remains active.
            return revealed(width: 500, contentHeight: 168, cornerRadius: 24)
        case .selecting:
            // A status line needs no room below the camera: icon and title in
            // one wing, the hint in the other.
            return banded(width: wingWidth(130, floatingWidth: 340), bodyHeight: statusLip, cornerRadius: 18)
        case .countdown:
            return banded(width: wingWidth(110, floatingWidth: 280), bodyHeight: statusLip, cornerRadius: 18)
        case .recording:
            return banded(
                width: wingWidth(recordingWing, floatingWidth: 440),
                bodyHeight: recordingBodyHeight,
                cornerRadius: 26
            )
        case .processing:
            return banded(
                width: wingWidth(130, floatingWidth: 340),
                // Scrolling capture keeps its three controls in a row below.
                bodyHeight: processingBodyHeight(isScrolling: isScrollingCapture),
                cornerRadius: 18
            )
        case .result:
            let extra = min(max(resultCount - 1, 0), 4) * 12
            return banded(
                width: 500 + CGFloat(extra),
                bodyHeight: shelfContentHeight(
                    style: shelfStyle,
                    itemCount: resultCount,
                    hasStack: hasStack
                ),
                cornerRadius: 28
            )
        case .lookUp(let card):
            // Nothing found is one quiet status line beside the camera.
            guard !card.result.isEmpty else {
                return banded(width: wingWidth(130, floatingWidth: 340), bodyHeight: statusLip, cornerRadius: 18)
            }
            return banded(
                width: LookUpCardMetrics.width,
                bodyHeight: LookUpCardMetrics.bodyHeight(for: card),
                cornerRadius: 26
            )
        case .systemLevel:
            // A physical notch already provides the black centre of the HUD.
            // Keep feedback inside its two visible wings instead of growing a
            // rounded bubble below the camera. A notchless display still needs
            // a conventional pill because there is no hardware cutout to use.
            let width = max(closed.width + 230, 390)
            if metrics.hasPhysicalNotch {
                return NotchLayout(
                    size: CGSize(width: width, height: max(closed.height, 32)),
                    cornerRadius: 18
                )
            }
            return revealed(width: 360, contentHeight: 46, cornerRadius: 23)
        case .context(let snapshot):
            if PowerModePresentationPolicy.isLowBatteryAlert(snapshot) {
                // The ten-second alert exposes its Battery Settings handoff
                // immediately instead of hiding it behind a second expansion.
                return revealed(width: 410, contentHeight: 78, cornerRadius: 22)
            }
            if NetworkContextPolicy.isNetworkCard(snapshot) {
                // Losing the connection gets the headline plus a row of two
                // controls; regaining it is a single quiet row with nothing to
                // decide, so it must not reserve the button height.
                return NetworkContextPolicy.isOfflineAlert(snapshot)
                    ? revealed(width: 410, contentHeight: 128, cornerRadius: 24)
                    : revealed(width: 410, contentHeight: 74, cornerRadius: 22)
            }
            // An accessory announces itself in the compact wings — the device
            // and a charge ring — and only the hovered island opens to the
            // card with each bud and the case.
            if snapshot.kind == .audioRoute, isPeeking || snapshot.presentation == .expanded {
                return revealed(width: 420, contentHeight: 78, cornerRadius: 22)
            }
            if snapshot.presentation == .expanded {
                if snapshot.kind == .ai {
                    return revealed(width: 520, contentHeight: 320, cornerRadius: 24)
                }
                // Five event rows, the calendar strip, header, and actions must
                // fit without shrinking click targets or clipping at the
                // bottom of a physical camera cutout.
                return revealed(width: 520, contentHeight: 390, cornerRadius: 24)
            }
            if isPeeking {
                // An agent peek is one row: its mark, name, state and task.
                // At 430 pt the row stretched into a wide black bar.
                if snapshot.kind == .ai {
                    return revealed(width: 360, contentHeight: 60, cornerRadius: 20)
                }
                return revealed(width: 430, contentHeight: 70, cornerRadius: 18)
            }
            return NotchLayout(
                size: CGSize(
                    width: closed.width + compactContextWing * 2,
                    height: closed.height
                ),
                cornerRadius: metrics.hasPhysicalNotch
                    ? 14
                    : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        case .systemNotification(let snapshot):
            // The app and time beside the camera, then one row per sender,
            // stacked like the Dynamic Island's messages.
            return banded(
                width: SystemNotificationCardLayout.width,
                bodyHeight: systemNotificationContentHeight(
                    rows: snapshot.rows.count,
                    hasOverflow: snapshot.overflowCount > 0,
                    extraBodyLines: SystemNotificationCardLayout.bodyLineLimit(for: snapshot) - 1
                ),
                cornerRadius: 26
            )
        case .error:
            return banded(width: 460, bodyHeight: errorBodyHeight, cornerRadius: 24)
        case .dictation(let snapshot):
            return dictationLayout(
                for: snapshot,
                metrics: metrics,
                isPeeking: isPeeking,
                closed: closed,
                floatingTopInset: floatingTopInset,
                revealed: revealed
            )
        case .island(let descriptor):
            return islandLayout(
                for: descriptor,
                metrics: metrics,
                closed: closed,
                floatingTopInset: floatingTopInset,
                mediaPanelRows: mediaPanelRows,
                revealed: revealed
            )
        }
    }

    // MARK: Island

    /// Visible width either side of a physical cutout for a compact primary of
    /// each kind. Sized to what the compact presentation draws: a glyph on the
    /// leading wing and a short metric or indicator on the trailing wing.
    public static func compactIslandWing(for kind: IslandActivityKind) -> CGFloat {
        switch kind {
        case .media: 38
        case .recording, .call: 72
        case .timer: 60
        case .ai, .calendar: compactContextWing
        case .transfer: 58
        case .external, .voiceNote: 64
        }
    }

    /// Band appended below an expanded island for a level HUD or a burst: the
    /// strip's 46pt plus its 5pt lift, rounded for the curve.
    public static let islandOverlayBandHeight: CGFloat = 54

    static func islandLayout(
        for descriptor: IslandLayoutDescriptor,
        metrics: NotchMetrics,
        closed: CGSize,
        floatingTopInset: CGFloat,
        mediaPanelRows: Int,
        revealed: (CGFloat, CGFloat, CGFloat) -> NotchLayout
    ) -> NotchLayout {
        let physical = metrics.hasPhysicalNotch

        func compactLayout(for kind: IslandActivityKind) -> NotchLayout {
            NotchLayout(
                size: CGSize(
                    width: physical
                        ? closed.width + compactIslandWing(for: kind) * 2
                        : NotchIsland.Geometry.compactActivityWidth,
                    height: physical ? max(closed.height, 32) : NotchIsland.Geometry.compactHeight
                ),
                cornerRadius: physical ? 16 : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        }

        /// A row that wraps the camera instead of hanging below it. Content
        /// is laid out from the top edge (no camera inset): the views keep the
        /// cutout's width clear themselves.
        func wrappingRow(wing: CGFloat, floatingWidth: CGFloat, height: CGFloat) -> NotchLayout {
            NotchLayout(
                size: CGSize(width: physical ? closed.width + 2 * wing : floatingWidth, height: height),
                cornerRadius: height / 2,
                contentTopInset: 0,
                topInset: floatingTopInset
            )
        }

        func expandedLayout(for kind: IslandActivityKind) -> NotchLayout {
            switch kind {
            case .media:
                return bandedLayout(
                    width: max(closed.width + 170, mediaPeekMinimumWidth),
                    bodyHeight: mediaPeekContentHeight(panelRows: mediaPanelRows),
                    cornerRadius: 26,
                    metrics: metrics,
                    floatingTopInset: floatingTopInset
                )
            case .recording:
                return bandedLayout(
                    width: physical
                        ? closed.width + IslandCameraBand.cameraClearance + 2 * recordingWing
                        : 440,
                    bodyHeight: recordingBodyHeight,
                    cornerRadius: 26,
                    metrics: metrics,
                    floatingTopInset: floatingTopInset
                )
            case .timer:
                return wrappingRow(
                    wing: NotchIsland.Geometry.expandedTimerWing,
                    floatingWidth: NotchIsland.Geometry.expandedTimerFloatingWidth,
                    height: NotchIsland.Geometry.expandedRowHeight
                )
            case .call:
                return wrappingRow(
                    wing: NotchIsland.Geometry.expandedCallWing,
                    floatingWidth: NotchIsland.Geometry.expandedCallFloatingWidth,
                    height: NotchIsland.Geometry.expandedCallHeight
                )
            // Room for the usage rings plus one answer card without
            // scrolling; more agents scroll beneath.
            case .ai: return revealed(520, 400, 24)
            case .transfer: return revealed(400, 134, 24)
            case .external: return revealed(400, 124, 24)
            case .voiceNote: return revealed(440, 204, 24)
            case .calendar: return revealed(520, 390, 24)
            }
        }

        /// The stretched shell for a burst over a compact island.
        func burstLayout(_ overlay: IslandOverlayLayoutClass) -> NotchLayout {
            switch overlay {
            case .systemLevel:
                if physical {
                    return NotchLayout(
                        size: CGSize(width: max(closed.width + 230, 390), height: max(closed.height, 32)),
                        cornerRadius: 18
                    )
                }
                return revealed(360, 46, 23)
            case .event:
                if physical {
                    return NotchLayout(
                        size: CGSize(width: max(closed.width + 240, 400), height: max(closed.height, 32)),
                        cornerRadius: 18
                    )
                }
                return revealed(340, 46, 23)
            case .lowBattery: return revealed(410, 78, 22)
            case .networkOffline: return revealed(400, 152, 26)
            case .networkOnline: return revealed(410, 74, 22)
            case .audioRoute, .contextNotice:
                return NotchLayout(
                    size: CGSize(
                        width: closed.width + compactContextWing * 2,
                        height: physical ? closed.height : NotchIsland.Geometry.compactHeight
                    ),
                    cornerRadius: physical ? 14 : NotchIsland.Geometry.compactHeight / 2,
                    topInset: floatingTopInset
                )
            }
        }

        guard let kind = descriptor.primaryKind else {
            // A burst with nothing underneath.
            if let overlay = descriptor.overlay { return burstLayout(overlay) }
            return NotchLayout(
                size: closed,
                cornerRadius: physical ? 12 : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        }

        if descriptor.isExpanded {
            var layout = expandedLayout(for: kind)
            if let overlay = descriptor.overlay, overlay == .systemLevel || overlay == .event {
                layout.size.height = min(maximumSize.height, layout.size.height + islandOverlayBandHeight)
            }
            return layout
        }

        if let overlay = descriptor.overlay {
            let base = compactLayout(for: kind)
            let burst = burstLayout(overlay)
            // Never shrink under the burst: a wide compact recording keeps its
            // wings while a narrow HUD passes through.
            var layout = burst
            layout.size.width = max(burst.size.width, base.size.width)
            layout.size.height = max(burst.size.height, base.size.height)
            layout.topInset = burst.topInset
            return layout
        }

        var layout = compactLayout(for: kind)
        if descriptor.showsSatellites {
            layout.satelliteDiameter = physical
                ? max(24, layout.size.height - 2)
                : NotchIsland.Geometry.compactHeight
            // On a physical notch the shell's top fillets flare 10 pt beyond
            // its body, so the gap is measured from the flare, not the body.
            layout.satelliteSpacing = physical ? 16 : 10
            // With room for one satellite only, it keeps a short value beside
            // its glyph instead of shrinking to an icon, as a second Live
            // Activity does on iPhone. Music has no short value worth showing.
            if descriptor.satelliteCount == 1,
               let lone = descriptor.leadingID ?? descriptor.trailingID,
               lone.kind != .media {
                layout.satelliteValueWidth = NotchLayout.satelliteValueSlot
            }
            if !physical, descriptor.satelliteCount == 1 {
                let half = (layout.satelliteWidth + layout.satelliteSpacing) / 2
                layout.clusterOffset = descriptor.leadingID != nil ? half : -half
            }
        }
        return layout
    }

    /// Height of the pill's control row: waveform, timer, and the stop and
    /// cancel targets. It is sized from the minimum control target so those
    /// buttons cannot be clipped by the row that contains them.
    public static let dictationControlRowHeight: CGFloat = 38
    /// Inset either side of the dictation island's content.
    public static let dictationHorizontalPadding: CGFloat = 10
    /// Slack around the camera cutout so wing content never crowds the hardware.
    public static let dictationCameraClearance: CGFloat = 16
    /// Narrowest trace still worth drawing; below this the pill should carry a
    /// label instead of a waveform.
    public static let dictationMinimumWaveformWidth: CGFloat = 120

    /// Width one wing gets beside the physical cutout.
    ///
    /// The wings are the reason this is shared rather than inlined in the view:
    /// the previous island put a timer and two 36pt buttons into a wing this
    /// arithmetic gives only ~94pt of, and the island's clip shape silently ate
    /// the overflow.
    public func dictationWingWidth(notchWidth: CGFloat) -> CGFloat {
        let inner = size.width - 2 * Self.dictationHorizontalPadding
        return max(0, (inner - notchWidth - Self.dictationCameraClearance) / 2)
    }

    /// Width left for the trace once the fixed controls have taken their share.
    public func dictationWaveformWidth(controlsWidth: CGFloat) -> CGFloat {
        max(0, size.width - 2 * Self.dictationHorizontalPadding - controlsWidth)
    }
    /// One line of transcript plus its surface padding.
    public static let dictationTranscriptRowHeight: CGFloat = 28

    private static func dictationLayout(
        for snapshot: DictationSnapshot,
        metrics: NotchMetrics,
        isPeeking: Bool,
        closed: CGSize,
        floatingTopInset: CGFloat,
        revealed: (CGFloat, CGFloat, CGFloat) -> NotchLayout
    ) -> NotchLayout {
        let isHover = isPeeking || snapshot.isHoverExpanded
        let hasTranscript = !snapshot.combinedText.isEmpty
        // The wings either side of the camera carry only a status label and the
        // timer; every control lives in the row below, where a 36pt target
        // fits. The old layout put 106pt of controls into a 94pt wing and let
        // the shape clip the difference.
        let compactWidth = closed.width + 240
        let controlRow = dictationControlRowHeight + 8

        switch snapshot.state {
        case .idle:
            return NotchLayout(
                size: closed,
                cornerRadius: metrics.hasPhysicalNotch
                    ? 12
                    : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        case .requestingMicrophone:
            return revealed(closed.width + 200, controlRow, metrics.hasPhysicalNotch ? 22 : 28)
        case .preparingModel:
            return revealed(closed.width + 210, controlRow, metrics.hasPhysicalNotch ? 22 : 28)
        case .listening:
            // The pill grows only as far as it has something to show: a bare
            // waveform while the user is still finding their first word, one
            // line once there is a transcript, two while hovered for review.
            if isHover {
                return revealed(520, controlRow + dictationTranscriptRowHeight + 18, 28)
            }
            if hasTranscript {
                return revealed(compactWidth, controlRow + dictationTranscriptRowHeight, 26)
            }
            return revealed(compactWidth, controlRow, 26)
        case .finalizing:
            return revealed(
                compactWidth,
                hasTranscript ? controlRow + dictationTranscriptRowHeight : controlRow,
                26
            )
        case .inserting:
            return revealed(closed.width + 200, controlRow, 24)
        case .copied:
            return revealed(closed.width + 200, controlRow, 24)
        case .completed:
            return revealed(closed.width + 200, controlRow, 24)
        case .cancelled:
            return NotchLayout(
                size: closed,
                cornerRadius: metrics.hasPhysicalNotch
                    ? 12
                    : NotchIsland.Geometry.compactHeight / 2,
                topInset: floatingTopInset
            )
        case .failed:
            return revealed(430, controlRow + 44, 24)
        }
    }

    /// Cocoa-space rect of the island, anchored to the display's reported
    /// physical notch centre (or to the screen centre for a synthetic island).
    ///
    /// Includes the satellite band on both sides, because satellites are
    /// clickable parts of the island.
    public func islandRect(in metrics: NotchMetrics) -> CGRect {
        primaryRect(in: metrics).insetBy(dx: -satelliteExtent, dy: 0)
    }

    /// The primary shell alone. Hover-to-peek starts only here: reaching for a
    /// satellite must not expand the primary and push the satellite away.
    public func primaryRect(in metrics: NotchMetrics) -> CGRect {
        CGRect(
            x: metrics.notchCenterX - size.width / 2 + clusterOffset,
            y: metrics.screenFrame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
    }
}
