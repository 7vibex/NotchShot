import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole notch, for one display.
///
/// The panel behind this view is a fixed, generous rectangle; everything here
/// draws inside it, anchored to the top centre, so state changes animate the
/// island rather than resizing a window.
public struct NotchRootView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var notificationStore = ProductivityNotificationStore.shared
    let context: NotchDisplayContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var isTargetedForDrop = false
    @State private var islandPress = IslandPressState()
    @State private var selectedFileDropAction: FileDropAction = .shelf
    @State private var fileDropItemCount = 0
    @State private var fileDropContext: FileDropContext = .files
    @State private var usesManualFileDropSelection = false
    @State private var fileDropPull: CGFloat = 0

    public init(coordinator: AppCoordinator, context: NotchDisplayContext) {
        self.coordinator = coordinator
        self.context = context
    }

    private var isActiveDisplay: Bool {
        coordinator.rendersAsActiveDisplay
            || coordinator.windowController?.activeDisplayID == context.displayID
    }

    private var isLockedSession: Bool { !coordinator.media.isSessionActive }

    private var lockedPresentationContent: LockedMediaPresentationPolicy.Content {
        LockedMediaPresentationPolicy.content(
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            hasMediaContent: coordinator.media.snapshot.hasContent,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
            hasActivityContent: notificationStore.lockScreenItem() != nil
                || coordinator.context.timer.current != nil
                || LockedChargingPolicy.reading() != nil,
            isPrimaryDisplay: context.isPrimary,
            hasChargingContent: LockedChargingPolicy.reading() != nil
        )
    }

    /// A non-active display shows media at most, never a capture UI.
    private var effectiveActivity: NotchActivity {
        if isLockedSession {
            return LockedMediaPresentationPolicy.effectiveActivity(
                sessionIsActive: false,
                currentActivity: coordinator.activity,
                mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
                hasMediaContent: coordinator.media.snapshot.hasContent,
                activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
                hasActivityContent: !notificationStore.activeItems.isEmpty
                    || coordinator.context.timer.current != nil
                    || LockedChargingPolicy.reading() != nil,
                isPrimaryDisplay: context.isPrimary,
                hasChargingContent: LockedChargingPolicy.reading() != nil
            )
        }
        if case .systemLevel(let level) = coordinator.activity,
           let displayID = level.displayID {
            return displayID == context.displayID ? coordinator.activity : .idle
        }
        if case .dictation(let snap) = coordinator.activity, let did = snap.displayID {
            return did == context.displayID ? coordinator.activity : .idle
        }
        if case .island(let descriptor) = coordinator.activity {
            return IslandDisplayPolicy.activity(
                for: descriptor,
                displayID: context.displayID,
                isActiveDisplay: isActiveDisplay,
                mirrorsPassiveContext: Preferences.shared.mirrorsPassiveContextOnAllDisplays
            )
        }
        guard !isActiveDisplay else { return coordinator.activity }
        if coordinator.activity == .media { return .media }
        if Preferences.shared.mirrorsPassiveContextOnAllDisplays,
           case .context = coordinator.activity {
            return coordinator.activity
        }
        return .idle
    }

    private var baseLayout: NotchLayout {
        let isPeekingForLayout: Bool
        if case .dictation(let snap) = effectiveActivity {
            isPeekingForLayout = snap.isHoverExpanded || (!isLockedSession && coordinator.isPeeking && isActiveDisplay)
        } else {
            isPeekingForLayout = !isLockedSession && coordinator.isPeeking && isActiveDisplay
        }
        return NotchLayout.layout(
            for: effectiveActivity,
            metrics: context.metrics,
            isPeeking: isPeekingForLayout,
            resultCount: coordinator.shelfItems.count,
            hasStack: coordinator.stack.isCollecting || !coordinator.stack.isEmpty,
            mediaPanelRows: coordinator.mediaPanelRowCount,
            shelfStyle: Preferences.shared.shelfPresentationStyle,
            privacyIndicators: showsPrivacyIndicators,
            isScrollingCapture: coordinator.isScrollingCaptureActive
        )
    }

    /// The camera band the open island's cards put their header in.
    private var cameraBand: IslandCameraBand {
        context.metrics.hasPhysicalNotch
            ? IslandCameraBand(
                notchWidth: context.metrics.notchSize.width,
                height: context.metrics.notchSize.height
            )
            : .floating
    }

    /// Mic or camera dots beside the camera. Physical notches only: a floating
    /// island on an external display sits away from the menu bar, where
    /// macOS's own indicator already is.
    private var showsPrivacyIndicators: Bool {
        !isLockedSession
            && context.metrics.hasPhysicalNotch
            && Preferences.shared.showsPrivacyIndicators
            && PrivacyIndicatorMonitor.shared.isActive
    }

    /// When capture, recording, a result, or an error outranks systemLevel in
    /// the activity arbiter, keep that UI in place and append a dedicated HUD
    /// strip. Native OSD is never suppressed without visible replacement.
    private var overlaidSystemLevel: SystemLevel? {
        guard !isLockedSession else { return nil }
        if case .systemLevel = effectiveActivity { return nil }
        // The island presents a level change as its own overlay.
        if case .island = effectiveActivity { return nil }
        guard let level = coordinator.arbiter.systemLevel else { return nil }
        if let displayID = level.displayID {
            return displayID == context.displayID ? level : nil
        }
        return isActiveDisplay ? level : nil
    }

    private var layout: NotchLayout {
        let base = baseLayout
        guard overlaidSystemLevel != nil else { return base }
        let hud = NotchLayout.layout(
            for: .systemLevel(SystemLevel(kind: .volume, value: 0, isMuted: false)),
            metrics: context.metrics,
            isPeeking: false,
            resultCount: 0
        )
        return NotchLayout(
            size: CGSize(
                width: max(base.size.width, hud.size.width),
                height: min(
                    NotchLayout.maximumSize.height,
                    max(hud.size.height, base.size.height + Self.overlaidHUDHeight)
                )
            ),
            cornerRadius: max(base.cornerRadius, 20),
            contentTopInset: base.contentTopInset,
            topInset: base.topInset
        )
        .wrappingCamera(base.wrapsCamera)
    }

    /// Vertical band the appended level strip occupies: its own 46pt plus the
    /// 5pt it is lifted off the bottom edge, rounded up for the shape's curve.
    private static let overlaidHUDHeight: CGFloat = 54

    @ViewBuilder
    public var body: some View {
        if isLockedSession, lockedPresentationContent == .activityStack {
            lockedActivityStack
        } else if isLockedSession, lockedPresentationContent == .compactMedia {
            // The panel has already moved out from under the notch for this —
            // see `LockedCardGeometry`.
            LockedNowPlayingCard(
                coordinator: coordinator,
                cardSize: LockedCardGeometry.cardSize(in: context.metrics.screenFrame)
            )
        } else if isLockedSession, lockedPresentationContent == .charging {
            LockedChargingCard(cardSize: LockedCardGeometry.cardSize(in: context.metrics.screenFrame))
        } else {
            standardPresentation
        }
    }

    private var standardPresentation: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: layout.topInset)
                .accessibilityHidden(true)
            island
            if showsPinnedLyric {
                LiveLyricLine(snapshot: coordinator.media.snapshot, ticks: pinnedLyricTicks) { line in
                    ZStack {
                        if let line {
                            PinnedLyricPill(text: line, maxWidth: max(layout.size.width + 120, 320))
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: line)
                }
                .padding(.top, 5)
            }
            if let tab = visibleTab {
                NotchTabBar(current: tab, coordinator: coordinator)
                    .padding(.top, NotchTabBarGeometry.gap)
                    // Glass at partial opacity reads as a grey smudge, so the
                    // pill never lingers half-faded: it leaves before the shell
                    // starts closing and arrives once the shell has mostly
                    // opened, coming into focus like the island's content.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: -8))
                            .combined(with: IslandMotion.blur(4))
                            .animation(NotchMotion.content(reduceMotion: false).delay(0.12)),
                        removal: .opacity
                            .animation(.easeIn(duration: 0.1))
                    ))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Shared elements draw above the clipped shell and its satellites, at
        // whichever anchor currently claims them. Resolved here, in the
        // panel's fixed frame, rather than on the island: the island's own
        // frame springs while it opens, and anchors resolved against it made
        // the cover's path the sum of two different springs.
        .overlayPreferenceValue(IslandGlyphAnchorKey.self) { anchors in
            if case .island(let descriptor) = effectiveActivity {
                IslandSharedElementLayer(
                    anchors: anchors,
                    // Only the primary's icon travels (compact ↔ expanded);
                    // satellites draw their own, so nothing flies across.
                    activities: coordinator.islandPresentation.primary.map { [$0] } ?? [],
                    level: descriptor.level,
                    isTracking: coordinator.islandGesture.isTracking,
                    coordinator: coordinator
                )
            }
        }
        .animation(shapeAnimation, value: visibleTab)
        // Hover is *not* handled here. SwiftUI's onHover fires for the whole
        // panel — which is far larger than the island — and fighting the window
        // controller's own hit test made the notch open on its own. The
        // controller is the single source of truth.
        .onChange(of: isTargetedForDrop) { _, targeted in
            coordinator.setDraggingFiles(targeted)
        }
    }

    /// The sung line under the closed notch, opted into in Settings → Extras.
    /// Only for the compact player on the display the user is on: an open
    /// notch has its own lyrics panel, and an overlay burst owns the space.
    private var showsPinnedLyric: Bool {
        guard ExtrasPreferences.shared.pinsLyricLine,
              Preferences.shared.lyricsEnabled,
              isActiveDisplay,
              !isLockedSession,
              coordinator.media.snapshot.isPlaying
        else { return false }
        switch effectiveActivity {
        case .media: return true
        case .island(let descriptor):
            return descriptor.primaryKind == .media && !descriptor.isExpanded && descriptor.overlay == nil
        default: return false
        }
    }

    private var pinnedLyricTicks: Bool {
        coordinator.media.snapshot.isPlaying && coordinator.media.areScreensAwake
    }

    /// The page pill under the open notch. Must match the window
    /// controller's `tabBarRect`, or the pill draws where clicks fall through.
    private var visibleTab: NotchTab? {
        guard Preferences.shared.showsNotchTabBar,
              !isLockedSession,
              NotchTabBarGeometry.topOffset(below: layout) != nil
        else { return nil }
        return NotchTab.current(for: effectiveActivity, in: Preferences.shared.notchTabs)
    }

    private var lockedActivityStack: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(context.metrics.notchSize.height + 12, 44))
                .accessibilityHidden(true)
            NotchActivityCardStack(
                coordinator: coordinator,
                store: notificationStore,
                isLocked: true,
                showsPlaceholders: false,
                showsMedia: false
            )
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchShot Lock Screen activities")
    }

    private var shape: NotchShape {
        NotchShape(
            bottomRadius: layout.cornerRadius,
            // The fillets only make sense against a real cutout; on an external
            // display the synthetic island is a complete floating pill.
            topRadius: context.metrics.hasPhysicalNotch ? 10 : layout.cornerRadius,
            isFloating: !context.metrics.hasPhysicalNotch
        )
    }

    private var shellIsSeeThrough: Bool {
        IslandGlassPolicy.isSeeThrough(
            enabled: Preferences.shared.islandGlassEnabled,
            isExpanded: effectiveActivity.isExpanded,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    /// Whether the glass shell is on at all, independent of whether this
    /// presentation is see-through. Constant while the island morphs, so the
    /// view structure that depends on it never swaps mid-animation.
    private var shellCanBeSeeThrough: Bool {
        IslandGlassPolicy.usesGlass(
            enabled: Preferences.shared.islandGlassEnabled,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    private var island: some View {
        ZStack(alignment: .top) {
            IslandShellFill(
                shape: shape,
                isExpanded: effectiveActivity.isExpanded,
                solidBandHeight: context.metrics.hasPhysicalNotch ? context.metrics.notchSize.height : 0
            )
                .overlay {
                    if isTargetedForDrop {
                        // Clipped to the shell below, so the visible half of a
                        // 3 pt stroke reads as the old 1.5 pt border.
                        MarchingDashStroke(shape: shape, color: .accentColor, lineWidth: 3, dash: [8, 6])
                    } else if !isRecording {
                        mediaShellKeyline
                    }
                }

            dictationCameraCore

            styledContent
                // Pinned to the shell's top centre at the shell's current
                // size. The content inside keeps its own fixed size, so this
                // frame tracking the spring re-places it rather than re-laying
                // it out.
                .frame(
                    width: layout.size.width,
                    height: layout.size.height,
                    alignment: .top
                )

            if let level = overlaidSystemLevel {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SystemLevelContent(level: level)
                        .frame(height: 46)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 5)
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityElement(children: .combine)
            }
        }
        .clipShape(shape)
        // The shadow lives outside the clip. Attached to the fill inside the
        // ZStack, `clipShape` cut it away entirely and the expanded island never
        // cast one. It only appears once the island is bigger than the cutout,
        // so a closed notch casts nothing onto the bezel.
        .background {
            shape
                .fill(.black)
                .shadow(
                    // Strength 0.5 is the original 0.45 opacity.
                    color: .black.opacity(
                        effectiveActivity.isExpanded ? Preferences.shared.islandShadowStrength * 0.9 : 0
                    ),
                    radius: 14 + 16 * Preferences.shared.islandShadowStrength,
                    y: 10
                )
                .modifier(ShadowCarrierCutout(
                    shape: shape,
                    isAvailable: shellCanBeSeeThrough,
                    cutsOut: shellIsSeeThrough
                ))
        }
        .frame(width: layout.size.width, height: layout.size.height)
        // Held down, the compact island gives a little under the pointer, as
        // the phone's does under a finger, and springs back on release. The
        // scoped animation touches only this scale: a plain `.animation`
        // here would also take over the open/close morph that a release
        // starts in the same transaction.
        .animation(reduceMotion ? nil : IslandMotion.press) { content in
            content.scaleEffect(islandPress.isPressed && !reduceMotion ? IslandMotion.pressedScale : 1, anchor: .top)
        }
        .environment(islandPress)
        .overlay {
            if case .island(let descriptor) = effectiveActivity {
                IslandSatelliteLayer(
                    descriptor: descriptor,
                    layout: layout,
                    coordinator: coordinator,
                    gesture: coordinator.islandGesture
                )
            }
        }
        // A lone satellite on an external display shifts the pair so the
        // group reads as centred.
        .offset(x: layout.clusterOffset)
        // A dragged file tugs the shell a few points toward the pointer. Kept
        // tiny on purpose, and absent under Reduce Motion.
        .scaleEffect(
            x: reduceMotion || !isTargetedForDrop ? 1 : 1 + abs(fileDropPull) * 0.018,
            y: 1,
            anchor: fileDropPull < 0 ? .trailing : .leading
        )
        .offset(x: reduceMotion || !isTargetedForDrop ? 0 : fileDropPull * 4)
        .animation(NotchMotion.drag(reduceMotion: reduceMotion), value: fileDropPull)
        .animation(shapeAnimation, value: layout.size)
        .animation(shapeAnimation, value: layout.satelliteDiameter)
        .animation(shapeAnimation, value: layout.clusterOffset)
        .animation(shapeAnimation, value: layout.cornerRadius)
        .animation(contentAnimation, value: effectiveActivity.presentationIdentity)
        .animation(contentAnimation, value: overlaidSystemLevel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchShot")
        .accessibilityValue(accessibilityDescription)
        .onDrop(
            of: [.fileURL],
            delegate: NotchFileDropDelegate(
                isTargeted: $isTargetedForDrop,
                selectedAction: $selectedFileDropAction,
                context: $fileDropContext,
                itemCount: $fileDropItemCount,
                usesManualSelection: $usesManualFileDropSelection,
                pointerPull: $fileDropPull,
                layoutSize: layout.size,
                supportsActionSelection: effectiveActivity == .fileDrop,
                onPerform: handleDrop
            )
        )
    }

    private var isShowingIsland: Bool {
        if case .island = effectiveActivity { return true }
        return false
    }

    private var isShowingDictation: Bool {
        if case .dictation = effectiveActivity { return true }
        return false
    }

    /// Views that lay out the band beside the camera themselves: dictation, and
    /// the capture menu on a physical notch.
    private var drawsInCameraBand: Bool {
        if isShowingDictation { return true }
        if baseLayout.wrapsCamera { return true }
        return effectiveActivity == .expanded && context.metrics.hasPhysicalNotch
    }

    private var contentTopOffset: CGFloat {
        drawsInCameraBand ? 0 : baseLayout.contentTopInset
    }

    private var contentFrameHeight: CGFloat {
        let available = drawsInCameraBand
            ? baseLayout.size.height
            : baseLayout.size.height - baseLayout.contentTopInset
        // The island can only grow to `NotchLayout.maximumSize.height`, so on a
        // tall activity — an expanded calendar, say — the appended level strip
        // has nowhere of its own to go and used to be drawn straight over the
        // last rows of the content. Give the strip its band back by shortening
        // the content instead of letting the two share pixels.
        guard overlaidSystemLevel != nil else { return max(1, available) }
        let ceiling = layout.size.height - baseLayout.contentTopInset - Self.overlaidHUDHeight
        return max(1, min(available, ceiling))
    }

    /// The complete shell is opaque black, matching the Dynamic Island's system
    /// background. Repainting the exact camera band also guards against future
    /// content treatments leaking into real hardware clearance.
    @ViewBuilder
    private var dictationCameraCore: some View {
        if drawsInCameraBand, context.metrics.hasPhysicalNotch {
            Rectangle()
                .fill(.black)
                .frame(
                    width: context.metrics.notchSize.width,
                    height: context.metrics.notchSize.height
                )
                .frame(
                    width: layout.size.width,
                    height: layout.size.height,
                    alignment: .top
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A neutral hairline, never the artwork's colour.
    ///
    /// The shell used to trace itself in the cover's accent and cast a halo of
    /// it, which turned the island's corners red for one album and green for
    /// the next — the colour read as a status signal the app never meant. The
    /// edge still needs definition against a bright wallpaper, so the line
    /// stays; only the tint is gone.
    @ViewBuilder
    private var mediaShellKeyline: some View {
        if NotchMediaGlowPolicy.shouldShow(
            isMedia: isShowingMedia,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        ) {
            shape
                .stroke(
                    Color.islandInk(NotchIsland.Ink.hairline),
                    lineWidth: NotchIsland.Stroke.hairline
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var isRecording: Bool {
        switch effectiveActivity {
        case .recording: return true
        case .island(let descriptor): return descriptor.primaryKind == .recording && descriptor.overlay == nil
        default: return false
        }
    }

    private var isShowingMedia: Bool {
        switch effectiveActivity {
        case .media: return true
        case .island(let descriptor): return descriptor.primaryKind == .media
        default: return false
        }
    }

    /// Coordinate the compact controls separately from the shell so adjacent
    /// effects merge without flattening its black-to-clear background.
    private var styledContent: some View {
        GlassEffectContainer(spacing: 6) {
            // Outgoing and incoming content overlap during a switch; both hang
            // from the top, as they do in the shell.
            ZStack(alignment: .top) {
                // A transition only runs on insertion and removal. On the
                // always-present container it never fired, so switching
                // activity fell back to a plain simultaneous crossfade. Keying
                // the content by its slot makes each switch a real
                // remove-and-insert.
                framedContent
                    .id(contentSlot)
                    .transition(contentTransition)
            }
        }
    }

    /// The content at the size of the shell it is going to. The frames sit
    /// inside the slot's identity on purpose: a switch inserts the new
    /// content already at its final size, and the outgoing content keeps the
    /// size it had, so neither is laid out again on every frame of the
    /// shell's spring. They used to sit outside it and spring with the shell,
    /// which re-laid out every row of the menu or shelf at each intermediate
    /// size — most of the main thread's work during an open or close.
    /// Within one slot (the island's levels, a media peek) the frame still
    /// animates, because that content choreographs its own resize.
    private var framedContent: some View {
        content
            .environment(\.islandCameraBand, cameraBand)
            .frame(
                width: baseLayout.size.width,
                height: contentFrameHeight,
                // The island lays its own content out from the top. Centring
                // made outgoing expanded content slide down as the shell
                // shrank underneath it during a collapse.
                alignment: drawsInCameraBand || isShowingIsland ? .top : .center
            )
            .offset(y: contentTopOffset)
            .frame(
                width: baseLayout.size.width,
                height: baseLayout.size.height,
                alignment: .top
            )
            // The island's own clip is `NotchShape`, whose top fillets
            // flare *outside* the island's rect to meet the bezel — so a
            // shape clip alone still lets content paint into those wings,
            // beside the camera. That is how the cover's accent glow ended
            // up outside the island. The shell may draw in the flare; its
            // contents may not.
            .clipped()
    }

    /// Coarser than `presentationIdentity`: that one changes with every volume
    /// step and dictation sub-state, and re-inserting the content on each of
    /// those would restart the transition dozens of times a second. The island
    /// keeps one slot because it choreographs its own levels internally.
    private var contentSlot: String {
        switch effectiveActivity {
        case .idle: "idle"
        case .media: "media"
        case .expanded: "expanded"
        case .fileDrop: "fileDrop"
        case .selecting: "selecting"
        case .countdown: "countdown"
        case .recording: "recording"
        case .processing: "processing"
        case .result: "result"
        case .systemLevel(let level): "systemLevel(\(level.kind.rawValue))"
        case .context(let snapshot): "context(\(snapshot.kind.rawValue))"
        case .systemNotification(let snapshot): "systemNotification(\(snapshot.id))"
        case .error: "error"
        case .dictation: "dictation"
        case .island: "island"
        }
    }

    /// Size changes get a spring with a little overshoot; content gets a
    /// shorter, softer curve so the two don't visibly fight.
    private var shapeAnimation: Animation? {
        // The multi-activity island settles without overshoot: with several
        // shapes and a travelling icon on screen, any bounce reads as jitter.
        if isShowingIsland {
            return NotchMotion.settle(reduceMotion: reduceMotion)
        }
        // The animation is read in the new state, so a non-expanded activity
        // means the shell is closing. Closing is quicker and doesn't overshoot
        // (except in the bouncy style), so the black shape doesn't bounce back
        // out past the cutout after the user has dismissed it.
        return effectiveActivity.isExpanded
            ? NotchMotion.expand(reduceMotion: reduceMotion)
            : NotchMotion.collapse(reduceMotion: reduceMotion)
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : NotchMotion.content(reduceMotion: false)
    }

    /// Incoming content arrives a beat after the shell starts growing, so text
    /// never appears outside the island it belongs to; outgoing content is gone
    /// quickly so the two never share the shell for long. The light blur on
    /// arrival is what makes the swap read as the shape morphing rather than a
    /// crossfade.
    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92, anchor: .top))
                .combined(with: .offset(y: -6))
                .combined(with: .modifier(
                    active: IslandContentBlur(radius: 6),
                    identity: IslandContentBlur(radius: 0)
                ))
                .animation(NotchMotion.content(reduceMotion: false).delay(0.06)),
            removal: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
                // No blur on the way out: blurring outgoing text forced it onto
                // the CPU for every frame of the close (see `IslandMotion.blur`).
                .animation(NotchMotion.contentExit(reduceMotion: false))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveActivity {
        case .idle:
            IdleContent(isPeeking: coordinator.isPeeking && isActiveDisplay, coordinator: coordinator)
        case .media:
            MediaContent(
                coordinator: coordinator,
                isPeeking: !isLockedSession && coordinator.isPeeking && isActiveDisplay,
                isFloating: !context.metrics.hasPhysicalNotch
            )
        case .expanded:
            CaptureMenuContent(coordinator: coordinator, metrics: context.metrics)
        case .fileDrop:
            FileDropActionTray(
                itemCount: fileDropItemCount,
                context: fileDropContext,
                selectedAction: $selectedFileDropAction,
                onManualSelection: { action in
                    selectedFileDropAction = action
                    usesManualFileDropSelection = true
                }
            )
        case .selecting(let intent):
            StatusContent(
                symbolName: intent.symbolName,
                title: intent.title,
                subtitle: "Esc to cancel"
            )
        case .countdown(let remaining, let intent):
            CountdownContent(remaining: remaining, intent: intent, coordinator: coordinator)
        case .recording:
            RecordingContent(coordinator: coordinator)
        case .processing(let message):
            ProcessingContent(message: message, coordinator: coordinator)
        case .result:
            ShelfContent(coordinator: coordinator)
        case .systemLevel(let level):
            SystemLevelContent(
                level: level,
                physicalNotchWidth: context.metrics.hasPhysicalNotch
                    ? context.metrics.notchSize.width
                    : nil
            )
        case .context(let snapshot):
            ContextContent(
                snapshot: snapshot,
                isPreviewing: coordinator.isPeeking && isActiveDisplay,
                physicalNotchWidth: context.metrics.hasPhysicalNotch
                    ? context.metrics.notchSize.width
                    : nil,
                coordinator: coordinator
            )
        case .systemNotification(let snapshot):
            SystemNotificationCard(
                snapshot: snapshot,
                onOpenSource: { coordinator.openSystemNotificationSource($0) },
                onReply: { coordinator.replyToSystemNotification($0) },
                onDismiss: { coordinator.dismissSystemNotification() }
            )
        case .error(let message):
            ErrorContent(message: message, coordinator: coordinator)
        case .dictation(let snapshot):
            DictationIslandContent(snapshot: snapshot, metrics: context.metrics, coordinator: coordinator)
        case .island(let descriptor):
            IslandActivityContainer(
                descriptor: descriptor,
                metrics: context.metrics,
                isActiveDisplay: isActiveDisplay,
                coordinator: coordinator,
                gesture: coordinator.islandGesture
            )
        }
    }

    private var accessibilityDescription: String {
        if let level = overlaidSystemLevel {
            if level.kind == .volume, level.isMuted {
                return "Muted"
            }
            return "\(level.kind.title) \(Int(level.value * 100)) percent"
        }
        return switch effectiveActivity {
        case .idle: "Idle"
        case .media: coordinator.media.snapshot.title.map { "Playing \($0)" } ?? "Media"
        case .expanded: "Capture menu"
        case .fileDrop:
            "File drop, " + selectedFileDropAction.title + " selected"
        case .selecting(let intent): intent.title
        case .countdown(let remaining, _): "Capturing in \(remaining) seconds"
        case .recording: "Recording, \(coordinator.recordingStatus.elapsedDescription)"
        case .processing(let message): message
        case .result: "\(coordinator.shelfItems.count) recent captures"
        case .systemLevel(let level):
            level.kind == .volume && level.isMuted
                ? "Muted"
                : "\(level.kind.title) \(Int(level.value * 100)) percent"
        case .context(let snapshot): snapshot.title
        case .systemNotification(let snapshot):
            snapshot.rows
                .map { "\($0.title), \($0.sourceName): \($0.body)" }
                .joined(separator: ". ")
        case .error(let message): "Error: \(message)"
        case .dictation(let snap): dictationAccessibilityDescription(snap)
        case .island(let descriptor): islandAccessibilityDescription(descriptor)
        }
    }

    private func islandAccessibilityDescription(_ descriptor: IslandLayoutDescriptor) -> String {
        let presentation = coordinator.islandPresentation
        var parts: [String] = []
        if let overlay = presentation.transientOverlay, descriptor.overlay != nil {
            switch overlay {
            case .systemLevel(let level):
                parts.append(level.kind == .volume && level.isMuted
                    ? "Muted"
                    : "\(level.kind.title) \(Int(level.value * 100)) percent")
            case .context(let snapshot): parts.append(snapshot.title)
            case .event(let event): parts.append(event.title)
            }
        }
        if let primary = presentation.primary, primary.id == descriptor.primaryID {
            parts.append(IslandAccessibility.value(for: primary, coordinator: coordinator))
        }
        let others = presentation.secondary.filter { [descriptor.leadingID, descriptor.trailingID].contains($0.id) }
        if !others.isEmpty {
            parts.append("Also: " + others.map(\.kind.title).joined(separator: ", "))
        }
        return parts.isEmpty ? "Idle" : parts.joined(separator: ". ")
    }

    // MARK: Interaction

    private func handleDrop(_ providers: [NSItemProvider], action: FileDropAction) {
        let expectedItemCount = providers.count
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else { continue }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                } else if let url = item as? NSURL {
                    urls.append(url as URL)
                }
            }
            await MainActor.run {
                coordinator.performFileDropAction(
                    action,
                    urls: urls,
                    expectedItemCount: expectedItemCount
                )
            }
        }
    }
}

// MARK: - Media

/// Cuts the shell's own area out of the black shadow carrier, so a
/// see-through shell shows what is behind it instead of the carrier.
///
/// The mask is an offscreen pass on every frame the shell's shape changes,
/// which is every frame of every open and close. With glass off the shell
/// is opaque and the cut-out removes nothing, so the pass is skipped.
/// While glass is on it stays in place either way, so the cut-out fades on
/// the shell's spring instead of swapping mid-animation.
private struct ShadowCarrierCutout: ViewModifier {
    var shape: NotchShape
    var isAvailable: Bool
    var cutsOut: Bool

    func body(content: Content) -> some View {
        if isAvailable {
            content.mask {
                Rectangle()
                    .padding(-80)
                    .overlay {
                        shape.fill(.black)
                            .opacity(cutsOut ? 1 : 0)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        } else {
            content
        }
    }
}
