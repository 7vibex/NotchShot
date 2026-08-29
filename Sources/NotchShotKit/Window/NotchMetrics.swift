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
            // The closed island only needs artwork and a playback indicator.
            // Elapsed and total time appear in the scrubber after hover opens it.
            // Keep the compact artwork and playback wave tucked close to the
            // camera instead of floating at the outside edges of wide wings.
            let width = isPeeking ? max(closed.width + 290, 470) : closed.width + 76
            if isPeeking {
                // Taller and wider than the bare progress bar needed: the
                // scrubber carries an elapsed and a total time either side of it.
                return revealed(width: width, contentHeight: 122, cornerRadius: 18)
            }
            // Compact media lives in the visible wings beside the camera and
            // intentionally shares the hardware notch's vertical band.
            return NotchLayout(
                size: CGSize(width: width, height: max(closed.height, 32)),
                cornerRadius: 18
            )
        case .expanded:
            // Dynamic-Island-style expansion: enough room for the three core
            // capture actions and one secondary command strip, but no large
            // dashboard floating from the camera cutout.
            return revealed(width: 480, contentHeight: 190, cornerRadius: 24)
        case .fileDrop:
            // Four equal drop destinations plus a compact instruction line.
            // The physical camera band is added by `revealed`, keeping every
            // target below real hardware while the drag remains active.
            return revealed(width: 500, contentHeight: 164, cornerRadius: 24)
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
            let height: CGFloat = hasStack ? 246 : 202
            return revealed(width: 470 + CGFloat(extra), contentHeight: height, cornerRadius: 24)
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
            return revealed(width: width, contentHeight: 46, cornerRadius: 20)
        case .context(let snapshot):
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
                cornerRadius: 14
            )
        case .error:
            return revealed(width: 360, contentHeight: 62, cornerRadius: 18)
        case .dictation(let snapshot):
            return dictationLayout(for: snapshot, metrics: metrics, isPeeking: isPeeking, closed: closed, revealed: revealed)
        }
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
            return NotchLayout(size: closed, cornerRadius: metrics.hasPhysicalNotch ? 12 : 16)
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
            return NotchLayout(size: closed, cornerRadius: metrics.hasPhysicalNotch ? 12 : 16)
        case .failed:
            return revealed(430, controlRow + 44, 24)
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
