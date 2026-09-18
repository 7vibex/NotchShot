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
    @State private var isRecordingPulsing = false
    @State private var selectedFileDropAction: FileDropAction = .shelf
    @State private var fileDropItemCount = 0
    @State private var usesManualFileDropSelection = false
    @State private var fileDropPull: CGFloat = 0

    public init(coordinator: AppCoordinator, context: NotchDisplayContext) {
        self.coordinator = coordinator
        self.context = context
    }

    private var isActiveDisplay: Bool {
        coordinator.windowController?.activeDisplayID == context.displayID
    }

    private var isLockedSession: Bool { !coordinator.media.isSessionActive }

    private var lockedPresentationContent: LockedMediaPresentationPolicy.Content {
        LockedMediaPresentationPolicy.content(
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            hasMediaContent: coordinator.media.snapshot.hasContent,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
            hasActivityContent: notificationStore.lockScreenItem() != nil
                || coordinator.context.timer.current != nil,
            isPrimaryDisplay: context.isPrimary
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
                    || coordinator.context.timer.current != nil,
                isPrimaryDisplay: context.isPrimary
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
            shelfStyle: Preferences.shared.shelfPresentationStyle
        )
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hover is *not* handled here. SwiftUI's onHover fires for the whole
        // panel — which is far larger than the island — and fighting the window
        // controller's own hit test made the notch open on its own. The
        // controller is the single source of truth.
        .onChange(of: isTargetedForDrop) { _, targeted in
            coordinator.setDraggingFiles(targeted)
        }
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

    private var island: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .overlay {
                    if isTargetedForDrop {
                        shape.stroke(Color.accentColor, lineWidth: 2)
                    } else if isRecording {
                        recordingKeyline
                    } else {
                        mediaShellKeyline
                    }
                }
                // The shadow only appears once the island is bigger than the
                // cutout, so a closed notch casts nothing onto the bezel.
                .shadow(
                    color: .black.opacity(effectiveActivity.isExpanded ? 0.45 : 0),
                    radius: 22,
                    y: 10
                )

            dictationCameraCore

            styledContent
                .frame(
                    width: baseLayout.size.width,
                    height: contentFrameHeight,
                    // The island lays its own content out from the top. Centring
                    // made outgoing expanded content slide down as the shell
                    // shrank underneath it during a collapse.
                    alignment: isShowingDictation || isShowingIsland ? .top : .center
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
                // Content fades in a beat after the shape has started growing,
                // so text never appears outside the island it belongs to.
                .transition(contentTransition)

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
        .frame(width: layout.size.width, height: layout.size.height)
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
        // Shared elements draw above the clipped shell and its satellites, at
        // whichever anchor currently claims them.
        .overlayPreferenceValue(IslandGlyphAnchorKey.self) { anchors in
            if case .island = effectiveActivity {
                IslandSharedElementLayer(
                    anchors: anchors,
                    // Only the primary's icon travels (compact ↔ expanded);
                    // satellites draw their own, so nothing flies across.
                    activities: coordinator.islandPresentation.primary.map { [$0] } ?? [],
                    isTracking: coordinator.islandGesture.isTracking,
                    coordinator: coordinator
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
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.8), value: fileDropPull)
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

    private var contentTopOffset: CGFloat {
        isShowingDictation ? 0 : baseLayout.contentTopInset
    }

    private var contentFrameHeight: CGFloat {
        let available = isShowingDictation
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
        if isShowingDictation, context.metrics.hasPhysicalNotch {
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

    /// A red edge while the screen is being recorded.
    ///
    /// This is the one status the island should be able to state without being
    /// read — the same reason the shell's *media* keyline was taken out: colour
    /// on the edge reads as a signal, so it should only ever mean something.
    /// Here it means the display is being captured right now.
    private var recordingKeyline: some View {
        shape
            .stroke(Color.red.opacity(isRecordingPulsing ? 0.95 : 0.5), lineWidth: 2)
            .shadow(color: .red.opacity(isRecordingPulsing ? 0.35 : 0.12), radius: 10)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: isRecordingPulsing
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { isRecordingPulsing = !reduceMotion }
            .onDisappear { isRecordingPulsing = false }
    }

    private var isShowingMedia: Bool {
        switch effectiveActivity {
        case .media: return true
        case .island(let descriptor): return descriptor.primaryKind == .media
        default: return false
        }
    }

    /// The shell stays opaque while compact control surfaces are coordinated so
    /// adjacent effects merge cleanly without tinting readable content.
    private var styledContent: some View {
        GlassEffectContainer(spacing: 6) {
            content
        }
    }

    /// Size changes get a spring with a little overshoot; content gets a
    /// shorter, softer curve so the two don't visibly fight.
    private var shapeAnimation: Animation? {
        guard NotchShotMotion.allowsSpatialAnimation(reduceMotion: reduceMotion) else {
            return nil
        }
        // The multi-activity island settles without overshoot: with several
        // shapes and a travelling icon on screen, any bounce reads as jitter.
        if isShowingIsland {
            return .spring(response: NotchIsland.Motion.shellResponse, dampingFraction: 1.0)
        }
        return .spring(
            response: NotchIsland.Motion.shellResponse,
            dampingFraction: NotchIsland.Motion.shellDamping
        )
    }

    private var contentAnimation: Animation? {
        reduceMotion
            ? nil
            : .spring(
                response: NotchIsland.Motion.contentResponse,
                dampingFraction: NotchIsland.Motion.contentDamping
            )
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.90, anchor: .top))
                .combined(with: .offset(y: -8)),
            removal: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
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
            CaptureMenuContent(coordinator: coordinator)
        case .fileDrop:
            FileDropActionTray(
                itemCount: fileDropItemCount,
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
                onOpenSource: { coordinator.openSystemNotificationSource(snapshot) },
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
            "Notification from \(snapshot.sourceName): \(snapshot.title) \(snapshot.body)"
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

struct PlaybackIndicator: View {
    var isPlaying: Bool
    var accentColor: Color = .white
    var animates = true
    /// The expanded player gives the meter more room than the compact strip;
    /// scaling keeps one set of bar rhythms instead of a second hard-coded set.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBouncing = false

    /// Short height, tall height, and beat, per bar — a small, a medium and a
    /// big one, each on a different clock.
    private let bars: [(low: CGFloat, high: CGFloat, duration: Double)] = [
        (3, 8, 0.42),
        (4, 12, 0.55),
        (3, 10, 0.34),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                let bar = bars[index]
                Capsule()
                    .fill(accentColor.opacity(isPlaying ? 0.95 : 0.4))
                    .frame(width: 2 * scale, height: (isBouncing ? bar.high : bar.low) * scale)
                    .animation(animation(bar.duration), value: isBouncing)
            }
        }
        .frame(height: 12 * scale, alignment: .center)
        .onAppear { isBouncing = isPlaying && animates && !reduceMotion }
        .onChange(of: isPlaying) { _, playing in
            isBouncing = playing && animates && !reduceMotion
        }
        .onChange(of: animates) { _, shouldAnimate in
            isBouncing = isPlaying && shouldAnimate && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduced in
            isBouncing = isPlaying && animates && !reduced
        }
        .accessibilityHidden(true)
    }

    /// Nil while paused, so the bars settle at their short height instead of
    /// being left mid-bounce by a cancelled repeating animation.
    private func animation(_ duration: Double) -> Animation? {
        guard isPlaying, animates, !reduceMotion else { return .easeOut(duration: 0.18) }
        return .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}
