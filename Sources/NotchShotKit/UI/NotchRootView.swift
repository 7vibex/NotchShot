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
            hasActivityContent: !notificationStore.activeItems.isEmpty
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
                showsMedia: context.isPrimary
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
                    alignment: isShowingDictation ? .top : .center
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
        .animation(shapeAnimation, value: layout.size)
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
                layoutSize: layout.size,
                supportsActionSelection: effectiveActivity == .fileDrop,
                onPerform: handleDrop
            )
        )
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
        if case .recording = effectiveActivity { return true }
        return false
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
        if case .media = effectiveActivity { return true }
        return false
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
        }
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

/// The entire island is one drop destination. Mapping its horizontal quarters
/// here avoids nested drop handlers fighting over the same Finder drag while
/// still making each visible option a real release target.
private struct NotchFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var selectedAction: FileDropAction
    @Binding var itemCount: Int
    @Binding var usesManualSelection: Bool

    var layoutSize: CGSize
    var supportsActionSelection: Bool
    var onPerform: ([NSItemProvider], FileDropAction) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !fileProviders(in: info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else { return }
        isTargeted = true
        itemCount = providers.count
        usesManualSelection = false
        updateSelection(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else { return DropProposal(operation: .forbidden) }
        itemCount = providers.count
        updateSelection(for: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        reset()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else {
            reset()
            return false
        }
        updateSelection(for: info)
        let action = supportsActionSelection ? selectedAction : .shelf
        reset()
        onPerform(providers, action)
        return true
    }

    private func fileProviders(in info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.fileURL])
    }

    private func updateSelection(for info: DropInfo) {
        guard !usesManualSelection else { return }
        selectedAction = supportsActionSelection
            ? FileDropActionSelection.action(atX: info.location.x, width: layoutSize.width)
            : .shelf
    }

    private func reset() {
        isTargeted = false
        itemCount = 0
        selectedAction = .shelf
        usesManualSelection = false
    }
}

/// A compact destination row modelled after AirDrop: the destination under the
/// pointer lifts and brightens, then owns the action when the user releases.
private struct FileDropActionTray: View {
    let itemCount: Int
    @Binding var selectedAction: FileDropAction
    let onManualSelection: (FileDropAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: NotchIsland.Spacing.element) {
            HStack(spacing: NotchIsland.Spacing.snug) {
                Image(systemName: itemCount == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)

                Text(itemCountDescription)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))

                Spacer(minLength: NotchIsland.Spacing.element)

                Text("Release over a destination")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }

            HStack(spacing: NotchIsland.Spacing.element) {
                ForEach(FileDropAction.allCases) { action in
                    actionTarget(action)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .focusable()
        // Arrow-key selection without the blue focus ring drawing over the
        // drop targets. See `ShelfContent` for the same reason.
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                onManualSelection(FileDropActionSelection.adjacent(
                    to: selectedAction,
                    delta: -1
                ))
            case .right:
                onManualSelection(FileDropActionSelection.adjacent(
                    to: selectedAction,
                    delta: 1
                ))
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File drop actions")
        .accessibilityValue(selectedAction.title + " selected")
        .accessibilityHint("Use left or right to choose a destination, then release the files")
        .accessibilityAdjustableAction { direction in
            onManualSelection(FileDropActionSelection.adjacent(
                to: selectedAction,
                delta: direction == .increment ? 1 : -1
            ))
        }
        .accessibilityAction(named: "Keep on Shelf") { onManualSelection(.shelf) }
        .accessibilityAction(named: "Send with AirDrop") { onManualSelection(.airDrop) }
        .accessibilityAction(named: "Open Share Menu") { onManualSelection(.share) }
        .accessibilityAction(named: "Create ZIP Archive") { onManualSelection(.compress) }
    }

    private var itemCountDescription: String {
        let count = max(itemCount, 1)
        return String(count) + " " + (count == 1 ? "file" : "files") + " ready"
    }

    /// A destination tile rather than a labelled circle.
    ///
    /// The dashed edge is the standard "drop here" affordance, and it does the
    /// work the old circle could not: an idle target now looks like somewhere
    /// files go, and the one under the pointer fills with its own accent
    /// instead of merely inverting a glyph.
    private func actionTarget(_ action: FileDropAction) -> some View {
        let isSelected = action == selectedAction
        let accent = accent(for: action)
        return VStack(spacing: NotchIsland.Spacing.snug) {
            Image(systemName: action.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.islandInk(NotchIsland.Ink.secondary))

            VStack(spacing: NotchIsland.Spacing.hairline) {
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)

                Text(action.subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, NotchIsland.Spacing.tight)

            // The target under the pointer restates what it is about to
            // receive, so a mis-aimed release is visible before it happens.
            Text(itemCountChip)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, NotchIsland.Spacing.snug)
                .padding(.vertical, 2)
                .background(accent, in: Capsule(style: .continuous))
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.vertical, NotchIsland.Spacing.row)
        .frame(maxWidth: .infinity, minHeight: 108)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card + 3, style: .continuous)
                .fill(
                    isSelected
                        ? accent.opacity(reduceTransparency ? 0.28 : 0.18)
                        : Color.islandInk(reduceTransparency ? 0.10 : 0.05)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card + 3, style: .continuous)
                .strokeBorder(
                    isSelected ? accent : Color.islandInk(NotchIsland.Ink.recessed),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 1.6 : 1,
                        dash: isSelected ? [] : [4, 3]
                    )
                )
        }
        .shadow(color: isSelected ? accent.opacity(0.34) : .clear, radius: 12, y: 4)
        .scaleEffect(isSelected && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title + ", " + action.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { onManualSelection(action) }
    }

    private var itemCountChip: String {
        let count = max(itemCount, 1)
        return count == 1 ? "1 file" : "\(count) files"
    }

    private func accent(for action: FileDropAction) -> Color {
        switch action {
        case .shelf: .cyan
        case .airDrop: .blue
        case .share: .purple
        case .localSend: .green
        case .compress: .orange
        }
    }
}

private struct ContextContent: View {
    var snapshot: ContextSnapshot
    var isPreviewing: Bool
    /// The cutout this display routes content around, or `nil` when the island
    /// is synthetic and every pixel of it is actually visible.
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if PowerModePresentationPolicy.isLowBatteryAlert(snapshot) {
            BatteryAlertCard(
                snapshot: snapshot,
                onOpenBatterySettings: { coordinator.openBatterySettings() }
            )
        } else if NetworkContextPolicy.isNetworkCard(snapshot) {
            NetworkStatusCard(
                snapshot: snapshot,
                onDismiss: { coordinator.dismissContextAlert() },
                onOpenNetworkSettings: { coordinator.openNetworkSettings() }
            )
        } else if snapshot.kind == .audioRoute, snapshot.presentation != .expanded {
            AudioAccessoryCard(snapshot: snapshot)
        } else if snapshot.presentation == .expanded {
            expanded
        } else if isPreviewing {
            if let agent = headlineAgent {
                if hasLiveVibeSurface {
                    AgentVibePeekHeader(
                        activity: agent,
                        activityCount: vibeActivityCount
                    ) { coordinator.setContextExpanded(true) }
                } else {
                    AgentPeekHeader(activity: agent) { coordinator.setContextExpanded(true) }
                }
            } else {
                preview
            }
        } else {
            if let agent = headlineAgent {
                if hasLiveVibeSurface {
                    AgentVibeCompactStrip(
                        activity: agent,
                        activityCount: vibeActivityCount,
                        physicalNotchWidth: physicalNotchWidth
                    ) { coordinator.setContextExpanded(true) }
                } else {
                    AgentCompactStrip(
                        activity: agent,
                        otherAgentCount: max(0, snapshot.aiActivities.count - 1),
                        physicalNotchWidth: physicalNotchWidth
                    ) {
                        coordinator.setContextExpanded(true)
                    }
                }
            } else {
                compact
            }
        }
    }

    /// The agent a collapsed or peeking island stands for. Only the `.ai` kind
    /// has one; every other context keeps the generic symbol-and-metric strip.
    private var headlineAgent: AIActivitySnapshot? {
        guard snapshot.kind == .ai else { return nil }
        return snapshot.aiActivities.first ?? coordinator.context.claude.sessions.first?.aiActivity
    }

    private var hasLiveVibeSurface: Bool {
        snapshot.kind == .ai
            && (!snapshot.aiActivities.isEmpty || !coordinator.context.claude.sessions.isEmpty)
    }

    private var vibeActivityCount: Int {
        let directClaudeIDs = Set(coordinator.context.claude.sessions.map(\.id))
        let genericCount = snapshot.aiActivities.filter {
            $0.source != .claude || !directClaudeIDs.contains($0.id)
        }.count
        return max(1, genericCount + coordinator.context.claude.sessions.count)
    }

    private var accentNSColor: NSColor {
        NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemGreen
        )
    }

    private var accent: Color {
        Color(nsColor: accentNSColor)
    }

    private var accentForeground: Color {
        Color(nsColor: NotchShotColorPolicy.foreground(on: accentNSColor))
    }

    private var compact: some View {
        Button {
            coordinator.setContextExpanded(true)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: snapshot.kind.symbolName)
                    .foregroundStyle(accent)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A bare Spacer let the two ends share the whole strip, so a
                // longer metric drifted into the camera cutout and vanished.
                // Reserving the cutout keeps both ends in the visible wings.
                if let physicalNotchWidth {
                    Color.clear
                        .frame(width: physicalNotchWidth)
                        .accessibilityHidden(true)
                } else {
                    Spacer(minLength: 0)
                }

                Text(snapshot.metric ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.metric ?? snapshot.subtitle ?? "")
    }

    private var preview: some View {
        Button {
            coordinator.setContextExpanded(true)
        } label: {
            previewHeader
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.subtitle ?? snapshot.metric ?? "")
    }

    private var previewHeader: some View {
        HStack(spacing: 10) {
            if let agent = headlineAgent {
                AgentGlyph(source: agent.source, size: 24)
            } else {
                Image(systemName: snapshot.kind.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = snapshot.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(snapshot.metric ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The live AI card owns its source, state, task and progress
            // header. Repeating the generic context header above it made the
            // compact card feel like a row inside a settings panel instead of
            // the focused agent surface it is.
            if snapshot.kind != .ai {
                previewHeader
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(snapshot.title)
                    .accessibilityValue(snapshot.subtitle ?? snapshot.metric ?? "")
                Divider().overlay(.white.opacity(0.14))
            }
            if snapshot.kind == .calendar {
                HStack(alignment: .top, spacing: 14) {
                    eventList
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider().overlay(.white.opacity(0.14))
                    monthOverview
                        .frame(width: 160)
                }
            } else if snapshot.kind == .ai {
                if hasLiveVibeSurface {
                    AgentVibeActivitySurface(
                        activities: snapshot.aiActivities,
                        recent: snapshot.aiRecentActivities,
                        subtitle: snapshot.subtitle,
                        claudeSessions: coordinator.context.claude.sessions,
                        onApprovePermission: { coordinator.approveClaudePermission(sessionID: $0) },
                        onDenyPermission: { coordinator.denyClaudePermission(sessionID: $0) },
                        onDismiss: { activity in
                            if activity.source == .claude,
                               coordinator.context.claude.session(for: activity.id) != nil {
                                coordinator.context.claude.dismiss(sessionID: activity.id)
                            } else {
                                coordinator.dismissAIActivity(activity)
                            }
                        },
                        onClearHistory: { coordinator.clearAIActivityHistory() }
                    )
                } else {
                    AgentActivityList(
                        activities: snapshot.aiActivities,
                        recent: snapshot.aiRecentActivities,
                        subtitle: snapshot.subtitle,
                        onDismiss: { coordinator.dismissAIActivity($0) },
                        onClearHistory: { coordinator.clearAIActivityHistory() },
                        claudeSessions: coordinator.context.claude.sessions,
                        onApprovePermission: { coordinator.approveClaudePermission(sessionID: $0) },
                        onDenyPermission: { coordinator.denyClaudePermission(sessionID: $0) }
                    )
                }
            } else if snapshot.kind == .timer {
                focusTimerControls
            } else if snapshot.kind == .voiceNote {
                voiceNoteControls
            } else {
                eventList
            }
            Spacer(minLength: 0)
            HStack {
                if snapshot.kind == .power {
                    Text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode is on" : "Low Power Mode is off")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Button("Dismiss") { coordinator.setContextExpanded(false) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                    .contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    @ViewBuilder
    private var focusTimerControls: some View {
        if let timer = snapshot.focusTimer {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: min(1, timer.elapsed / max(1, timer.duration)))
                    .tint(accent)
                    .accessibilityLabel("Timer progress")
                HStack(spacing: 8) {
                    if timer.state == .running {
                        Button("Pause") { coordinator.pauseFocusTimer() }
                            .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                            .contentShape(Rectangle())
                    } else if timer.state == .paused {
                        Button("Resume") { coordinator.resumeFocusTimer() }
                            .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                            .contentShape(Rectangle())
                    }
                    Button(timer.state == .completed ? "Done" : "Cancel") {
                        coordinator.cancelFocusTimer()
                    }
                    .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                    .contentShape(Rectangle())
                    Spacer()
                    Text(FocusTimerPolicy.formatted(timer.remaining))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var voiceNoteControls: some View {
        if let note = snapshot.voiceNote {
            VStack(alignment: .leading, spacing: 10) {
                if note.state == .recording {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Recording & transcribing locally")
                        Spacer()
                        Text(FocusTimerPolicy.formatted(note.elapsed)).monospacedDigit()
                    }
                    let hasTranscript = !(note.transcript ?? "").isEmpty
                    if let transcript = note.transcript, hasTranscript {
                        Text(transcript)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .accessibilityLabel("Live transcript")
                            .accessibilityValue(transcript)
                    }
                    if let errorMessage = note.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.86))
                    } else if !hasTranscript {
                        Text("Listening for speech…")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Button("Stop & Finish") { coordinator.stopVoiceNote() }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                } else if note.state == .transcribing {
                    ProgressView().controlSize(.small)
                    Text("Finalizing the on-device transcript…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    if let transcript = note.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.caption)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    if let url = note.fileURL {
                        Button("Reveal Voice Note") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                    }
                    Button("Dismiss") { coordinator.dismissVoiceNote() }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        if snapshot.events.isEmpty {
            Text(snapshot.subtitle ?? snapshot.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        } else {
            VStack(spacing: 4) {
                ForEach(snapshot.events.prefix(5)) { event in
                    Button {
                        coordinator.openCalendarEvent(event)
                    } label: {
                        HStack(spacing: 8) {
                            Capsule().fill(Color(nsColor: NSColor(hex: event.colorHex) ?? .systemBlue))
                                .frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(event.timingDescription())
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                    .accessibilityLabel(event.title)
                    .accessibilityValue(event.timingDescription())
                    .accessibilityHint("Opens this event in Calendar")
                }
            }
        }
    }

    private var monthOverview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Date().formatted(.dateTime.month(.wide).year()))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                spacing: 4
            ) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .accessibilityHidden(true)
                }
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let isToday = Calendar.autoupdatingCurrent.isDateInToday(date)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? accentForeground : .white)
                            .frame(width: 18, height: 18)
                            .background(isToday ? accent : .clear, in: Circle())
                            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    } else {
                        Color.clear
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    private var monthCells: [Date?] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now),
              let days = calendar.range(of: .day, in: .month, for: now) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells = Array<Date?>(repeating: nil, count: leading)
        cells.append(contentsOf: days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month.start)
        })
        cells.append(contentsOf: repeatElement(nil, count: max(0, 42 - cells.count)))
        return Array(cells.prefix(42))
    }
}

// MARK: - Idle

private struct IdleContent: View {
    var isPeeking: Bool
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if isPeeking {
            HStack(spacing: 10) {
                Button {
                    coordinator.toggleExpanded()
                } label: {
                    Label("Capture", systemImage: "camera.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Divider().frame(height: 14).overlay(.white.opacity(0.2))

                NotchIconButton(systemName: "square.dashed", label: "Capture area", visualScale: 0.8) {
                    coordinator.capture(.area)
                }

                NotchIconButton(systemName: "record.circle", label: "Record", visualScale: 0.8) {
                    coordinator.startRecording()
                }
            }
            .padding(.horizontal, 14)
        } else {
            // AppKit also bridges clicks from the physical cutout's trigger
            // band, because hardware pixels themselves cannot be hit-tested.
            Button {
                coordinator.toggleExpanded()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Open NotchShot")
        }
    }
}

// MARK: - Media

private struct MediaContent: View {
    @Bindable var coordinator: AppCoordinator
    var isPeeking: Bool
    /// True on a display with no hardware cutout, where the island is a drawn
    /// pill and its curved ends have to be cleared by hand.
    var isFloating = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()
    @State private var audioOutputs: [AudioRouteReading] = []
    @State private var upcoming: [MediaQueueEntry] = []
    @State private var isLoadingQueue = false
    @State private var queueUnavailable = false
    @State private var modes: MediaPlaybackModes?
    @State private var currentAudioOutputID: UInt32?
    @State private var artworkMotion = false

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        Group {
            if isPeeking {
                expanded
            } else {
                compact
            }
        }
        // The timer exists only while something is playing, so a paused notch
        // stops waking the CPU once a second. An autoconnected publisher held in
        // a property could not do that: it fires for as long as the view lives,
        // whatever the playback state.
        .task(id: snapshot.isPlaying && coordinator.media.areScreensAwake) {
            guard snapshot.isPlaying, coordinator.media.areScreensAwake else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        .task(id: isPeeking) {
            guard isPeeking else { return }
            refreshAudioOutputs()
        }
        .task(id: snapshot.isPlaying && !reduceMotion && coordinator.media.areScreensAwake) {
            artworkMotion = false
            guard snapshot.isPlaying, !reduceMotion, coordinator.media.areScreensAwake else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            artworkMotion = true
        }
    }

    /// The artwork tile is square and full-height-ish, so it meets the pill's
    /// curve where the curve is widest. The meter is three thin bars centred on
    /// the same line, so it needs a little more than the artwork to look level
    /// with it.
    private var compactLeadingInset: CGFloat {
        isFloating ? NotchIsland.Geometry.floatingContentInset : 6
    }

    private var compactTrailingInset: CGFloat {
        isFloating ? NotchIsland.Geometry.floatingContentInset + 2 : 8
    }

    private var compact: some View {
        Button {
            coordinator.setPeeking(true)
            coordinator.windowController?.focusActivePanel()
        } label: {
            HStack(spacing: 0) {
                artwork(size: 20)
                    .padding(.leading, compactLeadingInset)
                Spacer(minLength: 0)
                PlaybackIndicator(
                    isPlaying: snapshot.isPlaying,
                    accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                    animates: coordinator.media.areScreensAwake
                )
                .padding(.trailing, compactTrailingInset)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show now playing controls")
    }

    /// Reference-style stacked player: cover and titles, then the position bar
    /// with a time either side, then a transport bar that spans the island.
    ///
    /// The previous single row had to share its width between the track name
    /// and five controls, so the name had almost none of it and the buttons sat
    /// at half their comfortable size.
    private var expanded: some View {
        VStack(spacing: 0) {
            header

            MediaScrubber(snapshot: snapshot, now: now) { position in
                coordinator.media.send(.seek(position))
            }

            controlBar

            openPanel
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.top, NotchIsland.Spacing.row)
        .padding(.bottom, NotchIsland.Spacing.group)
        .animation(NotchShotMotion.content(reduceMotion: reduceMotion), value: coordinator.mediaPanel)
        // A track change while Playing Next is open would otherwise leave the
        // previous track's queue on screen.
        .task(id: queueRefreshKey) {
            guard coordinator.mediaPanel == .playingNext else { return }
            await refreshQueue()
        }
        // Re-read on every track change as well as on open: shuffle and repeat
        // can be changed in the player itself while this card is closed.
        .task(id: playbackModeRefreshKey) {
            await refreshPlaybackModes()
        }
        // `now` is read so the progress bar re-evaluates on each tick. It must
        // not become a view identity — keying the view on it rebuilt the whole
        // subtree every second and restarted the marquee mid-scroll.
        .opacity(now == .distantPast ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.group) {
            artwork(size: 56)

            VStack(alignment: .leading, spacing: NotchIsland.Spacing.hairline) {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    // Scrolls itself when the title is longer than the space, so
                    // a long track name is fully readable rather than truncated.
                    MarqueeText(
                        snapshot.title ?? "Not Playing",
                        font: .system(size: 15, weight: .bold),
                        color: .islandInk(NotchIsland.Ink.primary)
                    )
                    .frame(height: 19)

                    if snapshot.isExplicit {
                        MediaTitleBadge(letter: "E", label: "Explicit")
                    }
                    if snapshot.isLossless {
                        MediaTitleBadge(letter: "L", label: "Lossless")
                    }
                }
                .frame(height: 19)

                MarqueeText(
                    snapshot.artist ?? snapshot.applicationName ?? "",
                    font: .system(size: 12, weight: .medium),
                    color: .islandInk(NotchIsland.Ink.secondary),
                    speed: 22
                )
                .frame(height: 15)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            headerChrome
        }
        .frame(height: 56)
    }

    /// The meter and the capture button. Playback controls all live in the row
    /// below; this side of the header is chrome only.
    private var headerChrome: some View {
        HStack(spacing: 0) {
            PlaybackIndicator(
                isPlaying: snapshot.isPlaying,
                accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                animates: coordinator.media.areScreensAwake,
                scale: 1.4
            )
            .padding(.trailing, NotchIsland.Spacing.snug)

            MediaControlButton(
                systemName: "camera.viewfinder",
                label: "Open capture tools",
                diameter: 26,
                symbolSize: 13,
                opacity: NotchIsland.Ink.secondary
            ) {
                coordinator.toggleExpanded()
            }
        }
    }

    /// Transport between the modes and the panel openers, with the two gaps
    /// equal.
    ///
    /// Two spacers rather than a centred layer: centring the trio on the card
    /// made the gap to shuffle wider than the gap to repeat, because the
    /// trailing side carries one more control. Equal spacers put the same
    /// distance on both sides of the transport, which is the spacing the eye
    /// actually reads — the trio then sits slightly left of the card's centre.
    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchIsland.Spacing.snug) {
                if supportsQueue {
                    MediaControlButton(
                        systemName: "list.bullet",
                        label: "Playing next",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: coordinator.mediaPanel == .playingNext
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: coordinator.mediaPanel == .playingNext,
                        action: toggleQueueList
                    )
                }

                if supportsPlaybackModes {
                    MediaControlButton(
                        systemName: "shuffle",
                        label: "Shuffle",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: modes?.isShuffling == true
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: modes?.isShuffling == true,
                        accessibilityValue: modes?.isShuffling == true ? "On" : "Off",
                        action: toggleShuffle
                    )
                }
            }

            Spacer(minLength: 0)

            transportControls

            Spacer(minLength: 0)

            HStack(spacing: NotchIsland.Spacing.snug) {
                if supportsPlaybackModes {
                    MediaControlButton(
                        systemName: repeatMode.symbolName,
                        label: "Repeat",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: repeatMode.isOn
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: repeatMode.isOn,
                        accessibilityValue: repeatMode.accessibilityDescription,
                        action: cycleRepeat
                    )
                }

                MediaControlButton(
                    systemName: currentAudioOutput?.selectorSymbolName ?? "airplayaudio",
                    label: "Audio output",
                    diameter: 30,
                    symbolSize: 14,
                    opacity: coordinator.mediaPanel == .audioRoutes
                        ? NotchIsland.Ink.primary
                        : NotchIsland.Ink.tertiary,
                    isSelected: coordinator.mediaPanel == .audioRoutes,
                    accessibilityValue: currentAudioOutputName,
                    action: toggleRouteList
                )
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
    }

    private var transportControls: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            MediaControlButton(
                systemName: "backward.fill",
                label: "Previous track",
                diameter: 34,
                symbolSize: 16
            ) {
                coordinator.media.send(.previousTrack)
            }
            .disabled(!coordinator.media.supports(.previousTrack))

            MediaControlButton(
                systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                label: snapshot.isPlaying ? "Pause" : "Play",
                diameter: 40,
                symbolSize: 22
            ) {
                coordinator.media.send(.togglePlayPause)
            }
            .disabled(!coordinator.media.supports(.togglePlayPause))

            MediaControlButton(
                systemName: "forward.fill",
                label: "Next track",
                diameter: 34,
                symbolSize: 16
            ) {
                coordinator.media.send(.nextTrack)
            }
            .disabled(!coordinator.media.supports(.nextTrack))
        }
    }

    private var supportsPlaybackModes: Bool {
        MediaPlaybackModeService.supportsModes(bundleID: snapshot.applicationBundleID)
    }

    private var repeatMode: MediaRepeatMode { modes?.repeatMode ?? .off }

    /// Read from the player rather than remembered here: the user can hit
    /// shuffle in Spotify itself, and a shadow copy would then disagree with
    /// the button they are looking at.
    private func refreshPlaybackModes() async {
        guard supportsPlaybackModes else {
            modes = nil
            return
        }
        modes = await MediaPlaybackModeService.shared.modes(
            for: snapshot.applicationBundleID
        )
    }

    private func toggleShuffle() {
        let enabled = !(modes?.isShuffling ?? false)
        // Optimistic, then corrected by whatever the player confirms — the
        // Apple Event round trip is slow enough to feel like a dead button.
        modes = MediaPlaybackModes(isShuffling: enabled, repeatMode: repeatMode)
        Task {
            let confirmed = await MediaPlaybackModeService.shared.setShuffle(
                enabled,
                for: snapshot.applicationBundleID
            )
            if let confirmed { modes = confirmed }
        }
    }

    private func cycleRepeat() {
        let current = repeatMode
        let optimistic = MediaPlaybackModeService.next(
            after: current,
            supportsSingleTrack: snapshot.applicationBundleID == "com.apple.Music"
        )
        modes = MediaPlaybackModes(
            isShuffling: modes?.isShuffling ?? false,
            repeatMode: optimistic
        )
        Task {
            let confirmed = await MediaPlaybackModeService.shared.cycleRepeat(
                from: current,
                for: snapshot.applicationBundleID
            )
            if let confirmed { modes = confirmed }
        }
    }

    /// A list opens inside the island rather than in a popover: a popover is a
    /// second window with its own shadow and arrow, which reads as a menu
    /// escaping the notch instead of the player growing.
    @ViewBuilder
    private var openPanel: some View {
        switch coordinator.mediaPanel {
        case .none:
            EmptyView()
        case .audioRoutes:
            panel(title: "Audio Output", onRefresh: refreshAudioOutputs) {
                if audioOutputs.isEmpty {
                    emptyPanelRow("No audio outputs found")
                } else {
                    panelList(rowCount: audioOutputs.count) {
                        ForEach(audioOutputs) { output in
                            AudioOutputDeviceRow(
                                output: output,
                                isSelected: output.deviceID == currentAudioOutputID,
                                action: { selectAudioOutput(output) }
                            )
                        }
                    }
                }
            }
        case .playingNext:
            panel(title: "Playing Next", onRefresh: { Task { await refreshQueue() } }) {
                if upcoming.isEmpty {
                    emptyPanelRow(queueEmptyMessage)
                } else {
                    panelList(rowCount: upcoming.count) {
                        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, entry in
                            MediaQueueRow(entry: entry, position: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func panel<Content: View>(
        title: String,
        onRefresh: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
            HStack(spacing: NotchIsland.Spacing.element) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))

                Spacer(minLength: NotchIsland.Spacing.group)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .help("Refresh \(title.lowercased())")
                .accessibilityLabel("Refresh \(title.lowercased())")
            }
            .frame(height: 18)

            content()
        }
        .padding(.top, NotchIsland.Spacing.element)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private func emptyPanelRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: NotchLayout.mediaPanelRowHeight)
    }

    private func panelList<Content: View>(
        rowCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: NotchLayout.mediaPanelRowSpacing) {
                content()
            }
        }
        .scrollIndicators(
            rowCount > NotchLayout.mediaPanelVisibleRowLimit ? .visible : .hidden
        )
        .frame(height: Self.panelListHeight(rowCount: rowCount))
    }

    private static func panelListHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, 1), NotchLayout.mediaPanelVisibleRowLimit)
        return CGFloat(rows) * NotchLayout.mediaPanelRowHeight
            + CGFloat(rows - 1) * NotchLayout.mediaPanelRowSpacing
    }

    /// Identity for the queue refresh: the track and which panel is open.
    private var queueRefreshKey: String {
        "\(coordinator.mediaPanel == .playingNext)—\(snapshot.title ?? "")—\(snapshot.artist ?? "")"
    }

    private var playbackModeRefreshKey: String {
        "\(isPeeking)—\(snapshot.applicationBundleID ?? "")—\(snapshot.title ?? "")"
    }

    private var supportsQueue: Bool {
        MediaQueueService.supportsQueue(bundleID: snapshot.applicationBundleID)
    }

    private func toggleRouteList() {
        guard coordinator.mediaPanel != .audioRoutes else {
            coordinator.setMediaPanel(.none)
            return
        }
        refreshAudioOutputs()
        coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count))
        coordinator.windowController?.focusActivePanel()
    }

    private func toggleQueueList() {
        guard coordinator.mediaPanel != .playingNext else {
            coordinator.setMediaPanel(.none)
            return
        }
        // Opened at one row so the island has somewhere to put the progress
        // line while Apple Events answers, then resized once the rows arrive.
        coordinator.setMediaPanel(.playingNext, rowCount: max(1, upcoming.count))
        coordinator.windowController?.focusActivePanel()
        // The refresh itself is left to the keyed task below, which already
        // reacts to the panel opening — asking here as well would send two
        // Apple Events for one click.
    }

    /// Apple Events are synchronous on the player's side and can take most of
    /// their two-second timeout, so this only runs when the panel is open —
    /// never on the playback tick.
    private func refreshQueue() async {
        guard supportsQueue else {
            upcoming = []
            queueUnavailable = true
            return
        }
        isLoadingQueue = upcoming.isEmpty
        let entries = await MediaQueueService.shared.upcoming(
            for: snapshot.applicationBundleID
        )
        isLoadingQueue = false
        queueUnavailable = entries == nil
        upcoming = entries ?? []
        if coordinator.mediaPanel == .playingNext {
            coordinator.setMediaPanel(.playingNext, rowCount: max(1, upcoming.count))
        }
    }

    /// "Nothing queued" would be a lie when the real answer is that Music never
    /// replied — most often because Automation is still denied.
    private var queueEmptyMessage: String {
        if isLoadingQueue { return "Reading the queue…" }
        if queueUnavailable { return "Music didn't answer — check Automation access" }
        return "Nothing queued after this track"
    }

    private var currentAudioOutput: AudioRouteReading? {
        audioOutputs.first(where: { $0.deviceID == currentAudioOutputID })
    }

    private var currentAudioOutputName: String {
        currentAudioOutput?.name ?? "Audio Output"
    }

    private func refreshAudioOutputs() {
        audioOutputs = AudioOutputDeviceService.availableOutputs()
        currentAudioOutputID = AudioOutputDeviceService.currentOutput()?.deviceID
        if coordinator.mediaPanel == .audioRoutes {
            coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count))
        }
    }

    private func selectAudioOutput(_ output: AudioRouteReading) {
        guard output.deviceID != currentAudioOutputID else {
            coordinator.setMediaPanel(.none)
            return
        }
        do {
            try AudioOutputDeviceService.select(output.deviceID)
            refreshAudioOutputs()
            coordinator.setMediaPanel(.none)
        } catch {
            coordinator.present(error: error)
        }
    }

    /// Cover art, with the owning app's own icon badged into the corner so the
    /// player says where the audio is coming from without a second text line.
    /// The icon is read from the copy installed on this Mac; none is bundled.
    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 5)
                    .fill(Color.islandInk(NotchIsland.Ink.fill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size / 2.4))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if size >= 40, let icon = coordinator.media.sourceApplicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size / 3, height: size / 3)
                    .clipShape(RoundedRectangle(cornerRadius: size / 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: size / 12, y: size / 12)
            }
        }
        .scaleEffect(artworkMotion ? 1.035 : 0.99)
        .rotationEffect(.degrees(artworkMotion ? 0.65 : -0.35))
        .shadow(
            color: Color(nsColor: coordinator.media.artworkAccentColor).opacity(artworkMotion ? 0.46 : 0.18),
            radius: artworkMotion ? 12 : 4
        )
        .animation(
            reduceMotion || !snapshot.isPlaying
                ? .easeOut(duration: 0.16)
                : .easeInOut(duration: 2.8).repeatForever(autoreverses: true),
            value: artworkMotion
        )
        .accessibilityHidden(true)
    }
}

/// A flat transport glyph. The reference player draws its controls straight on
/// the island rather than inside a capsule, so the surface only appears under
/// the pointer or while the control's own panel is open.
private struct MediaControlButton: View {
    var systemName: String
    var label: String
    var diameter: CGFloat
    var symbolSize: CGFloat
    var opacity: Double = NotchIsland.Ink.primary
    var isSelected = false
    var accessibilityValue: String?
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        if isSelected { return NotchIsland.Ink.hairline }
        return isHovered && isEnabled ? NotchIsland.Ink.fill : 0
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(Color.islandInk(opacity))
                .contentTransition(.symbolEffect(.replace))
                .animation(NotchShotMotion.selection(reduceMotion: reduceMotion), value: systemName)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(Color.islandInk(backgroundOpacity))
                }
                .frame(
                    width: max(diameter, NotchIsland.Hit.control),
                    height: max(diameter, NotchIsland.Hit.control)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        // Plain buttons get no disabled appearance from AppKit, so an
        // unavailable command would look identical to an available one.
        .opacity(isEnabled ? 1 : NotchIconButton.disabledOpacity)
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered && isEnabled,
            reduceMotion: reduceMotion,
            activeScale: 1.06
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(isEnabled ? label : "\(label) unavailable")
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? "")
    }
}

/// The small capitalised marker Apple Music puts beside a track name.
private struct MediaTitleBadge: View {
    var letter: String
    var label: String

    var body: some View {
        Text(letter)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 13, height: 13)
            .background(Color.islandInk(NotchIsland.Ink.secondary), in: RoundedRectangle(
                cornerRadius: 3,
                style: .continuous
            ))
            .accessibilityLabel(label)
    }
}

/// One upcoming track. There is deliberately no artwork: fetching cover art per
/// queued track costs one Apple Event apiece for rows the user is only
/// glancing at, and the position number carries the ordering just as well.
private struct MediaQueueRow: View {
    var entry: MediaQueueEntry
    var position: Int

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.row) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .frame(width: 22, height: 22)
                .background(Color.islandInk(NotchIsland.Ink.fill), in: RoundedRectangle(
                    cornerRadius: NotchIsland.Radius.control - 4,
                    style: .continuous
                ))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !entry.artist.isEmpty {
                    Text(entry.artist)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: NotchIsland.Spacing.element)
        }
        .padding(.horizontal, NotchIsland.Spacing.row)
        .frame(maxWidth: .infinity, minHeight: NotchLayout.mediaPanelRowHeight)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.islandInk(NotchIsland.Ink.fill))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position). \(entry.title)\(entry.artist.isEmpty ? "" : ", \(entry.artist)")")
    }
}

private struct AudioOutputDeviceRow: View {
    var output: AudioRouteReading
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // Control Center's own sound list: a glyph, the device name, and a
            // radio dot at the trailing edge. Rows carry no card of their own —
            // only the selected or hovered row is tinted — so four devices read
            // as one list instead of four stacked tiles.
            HStack(spacing: NotchIsland.Spacing.row) {
                Image(systemName: output.selectorSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary
                    ))
                    .frame(width: 22, height: 22)

                Text(output.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary
                    ))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: NotchIsland.Spacing.element)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: isSelected ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.recessed
                    ))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, NotchIsland.Spacing.element)
            .frame(maxWidth: .infinity, minHeight: NotchLayout.mediaPanelRowHeight)
            .background {
                RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                    .fill(Color.islandInk(
                        isSelected
                            ? NotchIsland.Ink.hairline
                            : (isHovered ? NotchIsland.Ink.fill : 0)
                    ))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered,
            reduceMotion: reduceMotion,
            activeScale: 1.012
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityLabel(output.name)
        .accessibilityValue(isSelected ? "Selected" : "Available")
    }
}

/// Position bar with elapsed and total time, draggable to seek.
///
/// This replaced a plain `ProgressView`, which showed no times and could not be
/// dragged — the bar moved and that was all it did.
private struct MediaScrubber: View {
    var snapshot: MediaSnapshot
    /// Ticks once a second so the elapsed time advances between source polls.
    var now: Date
    var onSeek: (TimeInterval) -> Void

    /// Where the user just dragged to, and when. Held briefly after release —
    /// see `displayedFraction`.
    @State private var pending: (fraction: Double, at: Date)?

    private var duration: TimeInterval? {
        guard let duration = snapshot.duration, duration > 0, duration.isFinite else { return nil }
        return duration
    }

    private var canSeek: Bool {
        duration != nil && snapshot.supportedCommands.contains(.seek)
    }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.row) {
            timeLabel(elapsed, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.islandInk(NotchIsland.Ink.recessed))
                        .frame(height: 5)
                    Capsule()
                        .fill(.white.opacity(canSeek ? 0.95 : 0.6))
                        .frame(width: max(5, geometry.size.width * displayedFraction), height: 5)
                    if canSeek {
                        Circle()
                            .fill(.white)
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, geometry.size.width * displayedFraction - 4.5))
                    }
                }
                // The bar is 3pt tall but the whole row is grabbable, or seeking
                // would demand pixel-accurate aim at a hairline.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geometry.size.width))
            }
            .frame(height: 22)

            // The reference player counts down rather than showing the track
            // length, which is the number you actually want mid-listen: how
            // much of this track is left.
            timeLabel(remaining, alignment: .trailing, isCountdown: duration != nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(canSeek ? "Adjust up or down to seek" : "Seeking is unavailable")
        .accessibilityRespondsToUserInteraction(canSeek)
        .accessibilityAdjustableAction { direction in
            guard canSeek, let duration else { return }
            let step = max(5, duration * 0.05)
            let target = min(max((elapsed ?? 0) + (direction == .increment ? step : -step), 0), duration)
            pending = (target / duration, Date())
            onSeek(target)
        }
    }

    @ViewBuilder
    private func timeLabel(
        _ time: TimeInterval?,
        alignment: Alignment,
        isCountdown: Bool = false
    ) -> some View {
        Text(isCountdown ? "-\(Self.formatted(time))" : Self.formatted(time))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            .monospacedDigit()
            // Hour-long media needs more than the old fixed 32pt slot. A
            // minimum preserves alignment for short tracks without clipping.
            .frame(minWidth: 32, alignment: alignment)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        // `minimumDistance: 0` so a plain tap jumps to that point, as it does in
        // every other player.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canSeek, width > 0 else { return }
                pending = (Self.clamped(value.location.x / width), Date())
            }
            .onEnded { value in
                guard canSeek, width > 0, let duration else { return }
                let fraction = Self.clamped(value.location.x / width)
                pending = (fraction, Date())
                onSeek(fraction * duration)
            }
    }

    /// The fraction to draw: the dragged one until the player confirms it.
    ///
    /// The Apple Events source only polls every couple of seconds, so clearing
    /// the dragged value on release makes the bar snap back to where the track
    /// was and then jump forward — it reads as the seek having failed.
    private var displayedFraction: Double {
        guard let pending, let duration else { return snapshot.progress }
        let target = pending.fraction * duration
        if let position = snapshot.interpolatedPosition(at: now), abs(position - target) < 1.5 {
            return snapshot.progress
        }
        // Give up waiting rather than showing a stale position forever if the
        // player ignored the seek.
        if Date().timeIntervalSince(pending.at) > 3 { return snapshot.progress }
        return pending.fraction
    }

    private var elapsed: TimeInterval? {
        if let duration { return displayedFraction * duration }
        // No duration — a live stream, or a player that does not report one.
        // The elapsed time is still worth showing.
        return snapshot.interpolatedPosition(at: now)
    }

    /// Time left in the track, or nil when the source reports no duration.
    private var remaining: TimeInterval? {
        guard let duration, let elapsed else { return nil }
        return max(0, duration - elapsed)
    }

    private var accessibilityValue: String {
        guard let duration else { return Self.formatted(elapsed) }
        return "\(Self.formatted(elapsed)) of \(Self.formatted(duration)), \(Self.formatted(remaining)) remaining"
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }

    static func formatted(_ time: TimeInterval?) -> String {
        guard let time, time.isFinite, time >= 0 else { return "--:--" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Three bars that bounce while audio is playing.
///
/// Each bar animates its own height between a short and a tall value, on its own
/// duration, so they drift out of step and read as a level meter rather than
/// three things moving together. Driving a shared phase through `sin` does not
/// work here: SwiftUI interpolates the resulting height, not the phase, so a
/// phase running 0 → 2π starts and ends at the same height and nothing appears
/// to move at all.
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

// MARK: - Capture menu

private struct CaptureMenuContent: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var recipeStore = CaptureRecipeStore.shared
    @State private var timer: CaptureTimer = .none
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let primaryIntents: [CaptureIntent] = [.area, .window, .display]
    private let secondaryIntents: [CaptureIntent] = [.scrolling, .ocr, .previousArea]

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Label("Capture", systemImage: "camera.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()

                Menu {
                    ForEach(recipeStore.recipes) { recipe in
                        Button {
                            recipeStore.activeRecipeID = recipe.id
                        } label: {
                            if recipe.id == recipeStore.activeRecipeID {
                                Label(recipe.name, systemImage: "checkmark")
                            } else {
                                Text(recipe.name)
                            }
                        }
                    }
                } label: {
                    Label(recipeStore.activeRecipe.name, systemImage: "wand.and.stars")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 120)
                .help(recipeStore.activeRecipe.detail)

                Menu {
                    ForEach(CaptureTimer.allCases) { option in
                        Button {
                            timer = option
                        } label: {
                            if timer == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label(timer.title, systemImage: "timer")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 82)
                .help("Capture delay")

                // The island's corner radius curves in behind this row, so a
                // control flush against the trailing edge reads as sitting
                // outside the shell. The inset keeps the whole circle on the
                // flat part of the shape.
                NotchIconButton(
                    systemName: "xmark",
                    label: "Close",
                    visualScale: 0.8
                ) {
                    coordinator.collapse()
                }
                .padding(.trailing, NotchIsland.Spacing.snug)
            }
            .padding(.top, NotchIsland.Spacing.tight)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                spacing: 7
            ) {
                ForEach(primaryIntents) { intent in
                    CaptureIntentButton(intent: intent) {
                        coordinator.capture(intent, timer: timer)
                    }
                }
            }

            HStack(spacing: 7) {
                Menu {
                    Section("More Capture Modes") {
                        ForEach(secondaryIntents) { intent in
                            Button {
                                coordinator.capture(intent, timer: timer)
                            } label: {
                                Label(intent.title, systemImage: intent.symbolName)
                            }
                        }
                    }
                    Section("Focus Timer") {
                        ForEach([5, 15, 25, 45], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                coordinator.startFocusTimer(minutes: minutes)
                            }
                        }
                    }
                    Divider()
                    Button {
                        coordinator.startVoiceNote()
                    } label: {
                        Label("Voice Note", systemImage: "waveform.and.mic")
                    }
                    Divider()
                    Button {
                        coordinator.openProductivity()
                    } label: {
                        Label("Productivity Center", systemImage: "square.grid.2x2")
                    }
                    Divider()
                    Button {
                        coordinator.onOpenSettings?()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    commandLabel(
                        "More",
                        systemImage: "ellipsis"
                    )
                }
                .menuStyle(.borderlessButton)
                .help("More capture modes, activities, and settings")

                Menu {
                    ForEach(RecordingTargetMode.allCases) { target in
                        Button {
                            coordinator.startRecording(mode: target)
                        } label: {
                            Label(target.title, systemImage: target.symbolName)
                        }
                    }
                } label: {
                    commandLabel(
                        "Record",
                        systemImage: "record.circle",
                        iconTint: .red
                    )
                }
                .menuStyle(.borderlessButton)

                Button {
                    coordinator.onOpenHistory?()
                } label: {
                    commandLabel(
                        "History",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(NotchPressButtonStyle())

                // The shelf had no route back once it timed out or was
                // dismissed. It is the surface a capture actually lands on, so
                // it belongs in the notch's own strip and not only in the
                // menu bar.
                Button {
                    coordinator.showShelf()
                } label: {
                    commandLabel(
                        "Shelf",
                        systemImage: "tray.full"
                    )
                }
                .buttonStyle(NotchPressButtonStyle())
                .disabled(!coordinator.canShowShelf)
                .help(
                    coordinator.canShowShelf
                        ? "Show the captures parked on the shelf"
                        : "Nothing is on the shelf yet"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A menu or button in the command strip. Hover is not decoration here: the
    /// three tiles above it lift under the pointer, and a strip that stayed
    /// inert next to them read as disabled rather than as a different shape of
    /// control.
    private func commandLabel(
        _ title: String,
        systemImage: String,
        iconTint: Color = .white.opacity(0.88)
    ) -> some View {
        CaptureCommandLabel(
            title: title,
            systemImage: systemImage,
            iconTint: iconTint,
            reduceTransparency: reduceTransparency
        )
    }
}

/// Split out so each command owns its own hover state; a shared `@State` on the
/// menu would light all three at once.
private struct CaptureCommandLabel: View {
    var title: String
    var systemImage: String
    var iconTint: Color
    var reduceTransparency: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .notchControlSurface(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            reduceTransparency: reduceTransparency,
            emphasized: isHovered
        )
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered,
            reduceMotion: reduceMotion,
            activeScale: 1.03
        ))
        .offset(y: NotchShotMotion.activeOffset(
            isActive: isHovered,
            reduceMotion: reduceMotion
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityLabel(title)
    }
}

/// Makes the entire visible capture tile clickable. With a plain macOS button,
/// relying on only the icon and text for hit testing made clicks in the empty
/// parts of Area, Window, and Screen appear to do nothing.
private struct CaptureIntentButton: View {
    var intent: CaptureIntent
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: intent.symbolName)
                    .font(.system(size: 17, weight: .medium))
                Text(intent.shortTitle)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .notchControlSurface(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                reduceTransparency: reduceTransparency,
                emphasized: isHovered
            )
            .scaleEffect(NotchShotMotion.activeScale(
                isActive: isHovered,
                reduceMotion: reduceMotion,
                activeScale: 1.03
            ))
            .offset(y: NotchShotMotion.activeOffset(
                isActive: isHovered,
                reduceMotion: reduceMotion
            ))
        }
        .buttonStyle(NotchPressButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(intent.title)
        .accessibilityLabel(intent.title)
    }
}

// MARK: - Status / countdown / processing / error

private struct StatusContent: View {
    var symbolName: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.68))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

private struct CountdownContent: View {
    var remaining: Int
    var intent: CaptureIntent
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.cancelCurrentOperation()
        } label: {
            VStack(spacing: 4) {
                Text("\(remaining)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                Text(intent.shortTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel capture. Capturing in \(remaining) seconds.")
    }
}

private struct ProcessingContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    private var isScrolling: Bool {
        message.contains("frame") || message.contains("Scroll")
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)

            if isScrolling {
                NotchIconButton(
                    systemName: "camera.fill",
                    label: "Capture frame now",
                    visualScale: 0.8
                ) {
                    coordinator.captureScrollingFrame()
                }

                NotchIconButton(
                    systemName: "checkmark",
                    label: "Finish scrolling capture",
                    visualScale: 0.8
                ) {
                    coordinator.finishScrollingCapture()
                }
                .keyboardShortcut(.return, modifiers: [])

                NotchIconButton(systemName: "xmark", label: "Cancel", visualScale: 0.8) {
                    coordinator.cancelCurrentOperation()
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct ErrorContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)

            if coordinator.permissions.pendingRemediation != nil {
                Button(coordinator.permissions.requiresScreenRecordingRelaunch
                       ? "Quit & Reopen" : "Open Settings") {
                    if coordinator.permissions.requiresScreenRecordingRelaunch {
                        coordinator.permissions.relaunchApplication()
                    } else if let kind = coordinator.permissions.pendingRemediation {
                        coordinator.permissions.openSettings(for: kind)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                .contentShape(Rectangle())
                .notchControlSurface(
                    in: Capsule(),
                    reduceTransparency: reduceTransparency,
                    emphasized: true,
                    allowsLiquidGlass: false
                )
            }

            NotchIconButton(systemName: "xmark", label: "Dismiss", visualScale: 0.75) {
                coordinator.dismissError()
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Recording HUD

private struct RecordingContent: View {
    @Bindable var coordinator: AppCoordinator

    private var status: RecordingStatus { coordinator.recordingStatus }

    var body: some View {
        HStack(spacing: 14) {
            RecordingDot()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(status.elapsedDescription)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if status.fileSizeBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: status.fileSizeBytes, countStyle: .file))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                AudioLevelBar(
                    level: status.systemLevel,
                    samples: status.systemWaveform,
                    isEnabled: status.isSystemAudioEnabled,
                    isAvailable: status.isSystemMeterAvailable,
                    symbolName: "speaker.wave.2.fill",
                    label: "System audio level"
                )
                AudioLevelBar(
                    level: status.microphoneLevel,
                    samples: status.microphoneWaveform,
                    isEnabled: status.isMicrophoneEnabled,
                    isAvailable: status.isMicrophoneMeterAvailable,
                    symbolName: "mic.fill",
                    label: "Microphone level"
                )
            }
            .frame(width: 150)

            Spacer(minLength: 0)

            NotchIconButton(
                systemName: coordinator.isRecordingPaused ? "play.fill" : "pause.fill",
                label: coordinator.isRecordingPaused ? "Resume recording" : "Pause recording"
            ) {
                if coordinator.isRecordingPaused {
                    coordinator.resumeRecording()
                } else {
                    coordinator.pauseRecording()
                }
            }

            NotchIconButton(systemName: "stop.fill", label: "Stop recording", tint: .red, isProminent: true) {
                coordinator.stopRecording()
            }

            NotchIconButton(systemName: "trash", label: "Discard recording") {
                coordinator.cancelRecording()
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - System level HUD

/// Mirrors a volume or brightness change, in the shape of the system HUD but
/// living in the notch.
private struct SystemLevelContent: View {
    var level: SystemLevel
    var physicalNotchWidth: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let physicalNotchWidth {
                compactNotchContent(physicalNotchWidth: physicalNotchWidth)
            } else {
                pillContent
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.9),
            value: level.value
        )
        .animation(.easeOut(duration: 0.15), value: level.isMuted)
    }

    private var pillContent: some View {
        HStack(spacing: 12) {
            Image(systemName: level.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22)
                // The symbol swaps as the level crosses each threshold; a plain
                // swap would pop, so cross-fade it.
                .contentTransition(.symbolEffect(.replace))

            Text(level.kind.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                // Matches the compact variant. A fixed 96pt box with no scaling
                // truncates a longer localized title to an ellipsis, which in a
                // two-word HUD label leaves nothing readable.
                .minimumScaleFactor(0.75)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(3, geometry.size.width * fillFraction))
                }
            }
            .frame(height: 6)

            Text("\(Int((level.isMuted ? 0 : level.value) * 100))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
    }

    /// Uses the visible areas beside the camera so system feedback reads as
    /// part of the hardware notch and never creates a second bubble below it.
    private func compactNotchContent(physicalNotchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: level.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Text(level.kind.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: physicalNotchWidth)
                .accessibilityHidden(true)

            HStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(3, geometry.size.width * fillFraction))
                    }
                }
                .frame(height: 5)

                Text("\(Int((level.isMuted ? 0 : level.value) * 100))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity)
        }
    }

    private var fillFraction: Double {
        level.isMuted ? 0 : min(max(level.value, 0), 1)
    }
}

private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(isDimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                    isDimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}
