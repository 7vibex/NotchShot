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
    /// Horizontal shift of the primary shell. A synthetic island with a single
    /// satellite moves the pair so the group, not just the pill, is centred.
    /// Always zero on a physical notch, which must stay under the camera.
    public var clusterOffset: CGFloat = 0

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

    /// Horizontal reach of the satellite band on each side of the primary,
    /// including the part of each satellite's hit target that is wider than
    /// the circle drawn. Symmetric, so the hit region stays centred.
    public var satelliteExtent: CGFloat {
        guard satelliteDiameter > 0 else { return 0 }
        let hitWidth = max(satelliteDiameter, NotchShotDesignSystem.minimumControlTarget)
        return satelliteSpacing + satelliteDiameter / 2 + hitWidth / 2
    }

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
        // 10 + 56 artwork row + 22 scrubber + 40 transport + 12.
        let player: CGFloat = 140
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
        // `ShelfContent`: 14pt padding all round, 10pt between rows.
        let padding: CGFloat = 28
        let rowSpacing: CGFloat = 10
        // The header's segmented control carries 2pt of padding either side.
        var rows: [CGFloat] = [control + 4]
        // A 48pt grid strip, or the 66pt thumbnail beside its details column.
        rows.append(style == .grid ? 50 : 66)
        rows.append(control)
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

    public static func layout(
        for activity: NotchActivity,
        metrics: NotchMetrics,
        isPeeking: Bool,
        resultCount: Int,
        hasStack: Bool = false,
        mediaPanelRows: Int = 0,
        shelfStyle: ShelfPresentationStyle = .detail
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

        switch activity {
        case .idle:
            if isPeeking {
                return revealed(
                    width: closed.width + 150,
                    contentHeight: 46,
                    cornerRadius: metrics.hasPhysicalNotch
                        ? 12
                        : NotchIsland.Geometry.compactHeight / 2
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
                // Three stacked rows — artwork and titles, the scrubber with a
                // time either side, then a full-width transport bar — rather
                // than the old single row with the controls squeezed in beside
                // the track name.
                return revealed(
                    width: width,
                    contentHeight: mediaPeekContentHeight(panelRows: mediaPanelRows),
                    cornerRadius: 22
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
            return revealed(
                width: NotchIsland.Geometry.expandedCaptureWidth,
                contentHeight: NotchIsland.Geometry.expandedCaptureHeight,
                cornerRadius: NotchIsland.Geometry.expandedCornerRadius
            )
        case .fileDrop:
            // One dashed destination tile per action, plus a compact
            // instruction line. The physical camera band is added by
            // `revealed`, keeping every target below real hardware while the
            // drag remains active.
            return revealed(width: 500, contentHeight: 168, cornerRadius: 24)
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
            return revealed(
                width: 470 + CGFloat(extra),
                contentHeight: shelfContentHeight(
                    style: shelfStyle,
                    itemCount: resultCount,
                    hasStack: hasStack
                ),
                cornerRadius: 24
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
                    ? revealed(width: 400, contentHeight: 152, cornerRadius: 26)
                    : revealed(width: 410, contentHeight: 74, cornerRadius: 22)
            }
            // An accessory card carries artwork, a name and up to three battery
            // readouts, so it gets a card rather than the compact wings the
            // other passive contexts use.
            if snapshot.kind == .audioRoute {
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
        case .systemNotification:
            // Source icon, sender, one-line message, time, and two full-size
            // actions in a compact shell inspired by native message banners.
            return revealed(width: 410, contentHeight: 78, cornerRadius: 22)
        case .error:
            return revealed(width: 360, contentHeight: 62, cornerRadius: 18)
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
        case .recording: 72
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

        func expandedLayout(for kind: IslandActivityKind) -> NotchLayout {
            switch kind {
            case .media:
                return revealed(
                    max(closed.width + 170, mediaPeekMinimumWidth),
                    mediaPeekContentHeight(panelRows: mediaPanelRows),
                    22
                )
            case .recording: return revealed(420, 96, 22)
            case .timer: return revealed(380, 118, 24)
            case .ai: return revealed(520, 320, 24)
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
            case .audioRoute: return revealed(420, 78, 22)
            case .contextNotice:
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
            if !physical, descriptor.satelliteCount == 1 {
                let half = (layout.satelliteDiameter + layout.satelliteSpacing) / 2
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
