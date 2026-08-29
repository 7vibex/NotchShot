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
                || coordinator.context.timer.current != nil
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
            hasStack: coordinator.stack.isCollecting || !coordinator.stack.isEmpty
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
                showsPlaceholders: false
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

    /// Apple keeps the Dynamic Island background opaque black and uses colour
    /// in content plus a restrained keyline. The artwork accent therefore
    /// traces the shell instead of tinting its entire surface.
    @ViewBuilder
    private var mediaShellKeyline: some View {
        if NotchMediaGlowPolicy.shouldShow(
            isMedia: isShowingMedia,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        ) {
            shape
                .stroke(
                    Color(nsColor: coordinator.media.artworkAccentColor)
                        .opacity(NotchMediaGlowPolicy.keylineOpacity),
                    lineWidth: 1
                )
                .shadow(
                    color: Color(nsColor: coordinator.media.artworkAccentColor)
                        .opacity(NotchMediaGlowPolicy.haloOpacity),
                    radius: 10
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
                isPeeking: !isLockedSession && coordinator.isPeeking && isActiveDisplay
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
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: itemCount == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .foregroundStyle(.cyan)

                Text(itemCountDescription)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Text("Release over an option")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            }

            HStack(spacing: 8) {
                ForEach(FileDropAction.allCases) { action in
                    actionTarget(action)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .focusable()
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

    private func actionTarget(_ action: FileDropAction) -> some View {
        let isSelected = action == selectedAction
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(
                        isSelected
                            ? accent(for: action)
                            : Color.white.opacity(reduceTransparency ? 0.13 : 0.09)
                    )
                    .overlay {
                        Circle().strokeBorder(
                            isSelected ? Color.white.opacity(0.72) : Color.white.opacity(0.16),
                            lineWidth: isSelected ? 2 : 1
                        )
                    }

                Image(systemName: action.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? .black : .white.opacity(0.78))
            }
            .frame(width: 54, height: 54)
            .shadow(color: isSelected ? accent(for: action).opacity(0.42) : .clear, radius: 10)

            Text(action.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Text(action.subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 102)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : .clear)
        }
        .scaleEffect(isSelected && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title + ", " + action.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { onManualSelection(action) }
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
        if snapshot.presentation == .expanded {
            expanded
        } else if isPreviewing {
            if let agent = headlineAgent {
                AgentPeekHeader(activity: agent) { coordinator.setContextExpanded(true) }
            } else {
                preview
            }
        } else {
            if let agent = headlineAgent {
                AgentCompactStrip(
                    activity: agent,
                    otherAgentCount: max(0, snapshot.aiActivities.count - 1),
                    physicalNotchWidth: physicalNotchWidth
                ) {
                    coordinator.setContextExpanded(true)
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
        return snapshot.aiActivities.first
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
            previewHeader
                .accessibilityElement(children: .combine)
                .accessibilityLabel(snapshot.title)
                .accessibilityValue(snapshot.subtitle ?? snapshot.metric ?? "")
            Divider().overlay(.white.opacity(0.14))
            if snapshot.kind == .calendar {
                HStack(alignment: .top, spacing: 14) {
                    eventList
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider().overlay(.white.opacity(0.14))
                    monthOverview
                        .frame(width: 160)
                }
            } else if snapshot.kind == .ai {
                AgentActivityList(
                    activities: snapshot.aiActivities,
                    recent: snapshot.aiRecentActivities,
                    subtitle: snapshot.subtitle,
                    onDismiss: { coordinator.dismissAIActivity($0) },
                    onClearHistory: { coordinator.clearAIActivityHistory() }
                )
            } else if snapshot.kind == .timer {
                focusTimerControls
            } else if snapshot.kind == .voiceNote {
                voiceNoteControls
            } else {
                eventList
            }
            Spacer(minLength: 0)
            HStack {
                if snapshot.kind == .power, snapshot.title == "Low Battery" {
                    Button("Battery Settings") {
                        guard let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.battery"
                        ) else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                    .contentShape(Rectangle())
                }
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()
    @State private var audioOutputs: [AudioRouteReading] = []
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

    private var compact: some View {
        Button {
            coordinator.setPeeking(true)
            coordinator.windowController?.focusActivePanel()
        } label: {
            HStack(spacing: 0) {
                artwork(size: 20)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                PlaybackIndicator(
                    isPlaying: snapshot.isPlaying,
                    accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                    animates: coordinator.media.areScreensAwake
                )
                .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show now playing controls")
    }

    private var expanded: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                artwork(size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    // Scrolls itself when the title is longer than the space, so a
                    // long track name is fully readable rather than truncated.
                    MarqueeText(
                        snapshot.title ?? "Not Playing",
                        font: .system(size: 13, weight: .semibold),
                        color: .white
                    )
                    .frame(height: 16)

                    MarqueeText(
                        snapshot.artist ?? snapshot.applicationName ?? "",
                        font: .system(size: 11, weight: .medium),
                        color: .white.opacity(0.65),
                        speed: 22
                    )
                    .frame(height: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    MediaTransportControls(
                        isPlaying: snapshot.isPlaying,
                        tint: Color(nsColor: coordinator.media.artworkAccentColor),
                        canGoPrevious: coordinator.media.supports(.previousTrack),
                        canTogglePlayback: coordinator.media.supports(.togglePlayPause),
                        canGoNext: coordinator.media.supports(.nextTrack),
                        onPrevious: { coordinator.media.send(.previousTrack) },
                        onTogglePlayback: { coordinator.media.send(.togglePlayPause) },
                        onNext: { coordinator.media.send(.nextTrack) }
                    )

                    Divider()
                        .frame(height: 18)
                        .overlay(.white.opacity(0.2))

                    NotchIconButton(
                        systemName: "camera.viewfinder",
                        label: "Open capture tools"
                    ) {
                        coordinator.toggleExpanded()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            MediaScrubber(snapshot: snapshot, now: now) { position in
                coordinator.media.send(.seek(position))
            }

            audioOutputPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // `now` is read so the progress bar re-evaluates on each tick. It must
        // not become a view identity — keying the view on it rebuilt the whole
        // subtree every second and restarted the marquee mid-scroll.
        .opacity(now == .distantPast ? 0 : 1)
    }

    private var audioOutputPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text(currentAudioOutputName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Menu {
                if audioOutputs.isEmpty {
                    Text("No audio outputs found")
                } else {
                    ForEach(audioOutputs) { output in
                        Button {
                            selectAudioOutput(output)
                        } label: {
                            if output.deviceID == currentAudioOutputID {
                                Label(output.name, systemImage: "checkmark")
                            } else {
                                Text(output.name)
                            }
                        }
                    }
                }
            } label: {
                Label("Choose Output", systemImage: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 28)
                    .notchControlSurface(in: Capsule(), reduceTransparency: reduceTransparency)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the macOS audio output")
            .accessibilityLabel("Audio output, \(currentAudioOutputName)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(.white.opacity(0.06))
        }
    }

    private var currentAudioOutputName: String {
        audioOutputs.first(where: { $0.deviceID == currentAudioOutputID })?.name
            ?? "Audio Output"
    }

    private func refreshAudioOutputs() {
        audioOutputs = AudioOutputDeviceService.availableOutputs()
        currentAudioOutputID = AudioOutputDeviceService.currentOutput()?.deviceID
    }

    private func selectAudioOutput(_ output: AudioRouteReading) {
        do {
            try AudioOutputDeviceService.select(output.deviceID)
            refreshAudioOutputs()
        } catch {
            coordinator.present(error: error)
        }
    }

    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 5)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size / 2.4))
                            .foregroundStyle(.white.opacity(0.6))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
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
        HStack(spacing: 6) {
            timeLabel(elapsed, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 3)
                    Capsule()
                        .fill(.white.opacity(canSeek ? 0.95 : 0.6))
                        .frame(width: max(3, geometry.size.width * displayedFraction), height: 3)
                    if canSeek {
                        Circle()
                            .fill(.white)
                            .frame(width: 7, height: 7)
                            .offset(x: max(0, geometry.size.width * displayedFraction - 3.5))
                    }
                }
                // The bar is 3pt tall but the whole row is grabbable, or seeking
                // would demand pixel-accurate aim at a hairline.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geometry.size.width))
            }
            .frame(height: 24)

            timeLabel(duration, alignment: .trailing)
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
    private func timeLabel(_ time: TimeInterval?, alignment: Alignment) -> some View {
        Text(Self.formatted(time))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
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

    private var accessibilityValue: String {
        guard let duration else { return Self.formatted(elapsed) }
        return "\(Self.formatted(elapsed)) of \(Self.formatted(duration))"
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
private struct PlaybackIndicator: View {
    var isPlaying: Bool
    var accentColor: Color = .white
    var animates = true
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
                    .frame(width: 2, height: isBouncing ? bar.high : bar.low)
                    .animation(animation(bar.duration), value: isBouncing)
            }
        }
        .frame(height: 12, alignment: .center)
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

/// A single transport surface reads more clearly than three unrelated
/// circles. The play/pause action remains prominent while previous and next
/// gain stable, full-size pointer targets and familiar track-skip symbols.
private struct MediaTransportControls: View {
    var isPlaying: Bool
    var tint: Color
    var canGoPrevious: Bool
    var canTogglePlayback: Bool
    var canGoNext: Bool
    var onPrevious: () -> Void
    var onTogglePlayback: () -> Void
    var onNext: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            MediaTransportButton(
                systemName: "backward.end.fill",
                label: "Previous track",
                action: onPrevious
            )
            .disabled(!canGoPrevious)

            MediaTransportButton(
                systemName: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                tint: tint,
                isProminent: true,
                action: onTogglePlayback
            )
            .disabled(!canTogglePlayback)

            MediaTransportButton(
                systemName: "forward.end.fill",
                label: "Next track",
                action: onNext
            )
            .disabled(!canGoNext)
        }
        .padding(3)
        .notchControlSurface(in: Capsule(), reduceTransparency: reduceTransparency)
        .accessibilityElement(children: .contain)
    }
}

private struct MediaTransportButton: View {
    var systemName: String
    var label: String
    var tint: Color = .white
    var isProminent = false
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isProminent ? 13 : 11, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : Color.white.opacity(0.9))
                .contentTransition(.symbolEffect(.replace))
                .animation(NotchShotMotion.selection(reduceMotion: reduceMotion), value: systemName)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(
                        isProminent
                            ? tint
                            : Color.white.opacity(isHovered && isEnabled ? 0.14 : 0.001)
                    )
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .opacity(isEnabled ? 1 : NotchIconButton.disabledOpacity)
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered && isEnabled,
            reduceMotion: reduceMotion,
            activeScale: 1.06
        ))
        .offset(y: NotchShotMotion.activeOffset(
            isActive: isHovered && isEnabled,
            reduceMotion: reduceMotion,
            activeOffset: -1
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(isEnabled ? label : "\(label) unavailable")
        .accessibilityLabel(label)
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

                NotchIconButton(
                    systemName: "xmark",
                    label: "Close",
                    visualScale: 0.8
                ) {
                    coordinator.collapse()
                }
            }

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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func commandLabel(
        _ title: String,
        systemImage: String,
        iconTint: Color = .white.opacity(0.88)
    ) -> some View {
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
            reduceTransparency: reduceTransparency
        )
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
