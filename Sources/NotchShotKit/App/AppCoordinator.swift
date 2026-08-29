import AVFoundation
import AppKit
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A finished capture sitting in the notch shelf.
@MainActor
@Observable
public final class ShelfItem: Identifiable {
    public let id: UUID
    public var asset: CaptureAsset
    public var thumbnail: NSImage?
    /// Kept in memory so Annotate and OCR don't have to re-read from disk.
    public var image: CapturedImage?
    public var ocrResult: OCRResult?
    public var stitchWarnings: [String]
    public var seams: [StitchSeam]

    public init(
        asset: CaptureAsset,
        thumbnail: NSImage?,
        image: CapturedImage?,
        stitchWarnings: [String] = [],
        seams: [StitchSeam] = []
    ) {
        self.id = asset.id
        self.asset = asset
        self.thumbnail = thumbnail
        self.image = image
        self.stitchWarnings = stitchWarnings
        self.seams = seams
    }
}

/// The application's single source of truth.
///
/// Owns the activity arbiter, drives every capture and recording flow, and
/// manages the shelf. Services stay dumb and testable; the ordering rules and
/// user-visible behaviour live here.
@MainActor
@Observable
public final class AppCoordinator {

    // MARK: State

    public private(set) var arbiter = ActivityArbiter()
    public private(set) var activity: NotchActivity = .idle
    public private(set) var shelfItems: [ShelfItem] = []
    public private(set) var selectedShelfIndex = 0
    public private(set) var recordingStatus = RecordingStatus()
    public private(set) var isRecordingPaused = false
    public private(set) var scrollingFrameCount = 0

    /// True while the pointer is over the island. Peeking never expands the
    /// full interface on its own — that needs a click or a shortcut.
    public var isPeeking = false

    public let media = MediaCoordinator.shared
    public let context = ContextCoordinator.shared
    public let history = HistoryRepository.shared
    public let clipboard = ClipboardStore.shared
    public let clipboardMonitor = ClipboardMonitor.shared
    public let permissions = PermissionCenter.shared
    public let systemLevels = SystemLevelMonitor.shared
    public let osd = SystemOSDSuppressor.shared
    public let stack = CaptureStack.shared
    public let dictation = DictationCoordinator.shared

    /// Most recent capture the user dismissed, for "restore last".
    private var lastDismissed: ShelfItem?
    private var shelfTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var captureOperationID: UUID?
    /// The screen rectangle the active scrolling capture is reading from. The
    /// stitched result inherits its display's scale rather than the main
    /// display's, which are different numbers on a mixed-DPI desk.
    private var scrollingRegion: CGRect?
    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingSessionID: UUID?
    private var errorTask: Task<Void, Never>?
    private var systemLevelTask: Task<Void, Never>?
    private var accessibilityLevelTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartOperationID: UUID?
    private var recordingCompletionTask: Task<Void, Never>?
    private var recordingSegments: [CaptureAsset] = []
    private var pausedRecordingConfiguration: RecordingConfiguration?
    private var completedRecordingDuration: TimeInterval = 0
    private var isPresentingRecordingCancellation = false
    private var recordingStoppedForLowDisk = false
    private var editorExportActions: [ObjectIdentifier: (CaptureAsset) -> Void] = [:]
    private var voiceOverObservation: NSKeyValueObservation?

    public var windowController: NotchWindowController?
    public var onOpenEditor: ((AnnotationDocumentController) -> Void)?
    public var onOpenPrivacyReview: ((PrivacyReviewSession) -> Void)?
    public var onOpenBugReport: ((BugReportSession) -> Void)?
    public var onOpenComparison: ((VisualComparisonSession) -> Void)?
    public var onOpenSmartExport: ((SmartExportSession) -> Void)?
    public var onOpenVideoTrim: ((VideoTrimSession) -> Void)?
    public var onOpenInspector: ((ImageInspectionSession) -> Void)?
    public var onOpenCapturePreview: ((ShelfItem) -> Void)?
    public var onOpenDocumentSummary: ((DocumentSummarySession) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onOpenClipboard: (() -> Void)?

    /// Up to five results stay in the notch; older ones live in History.
    public static let maximumShelfItems = 5

    public init() {}

    // MARK: Wiring

    public func start() {
        guard AppPaths.ensureDirectories() else {
            present(error: NotchShotError.destinationUnwritable(AppPaths.support.path))
            return
        }
        Preferences.shared.refreshOutputFolderBookmarkIfStale()
        media.start()
        context.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            self.arbiter.context = snapshot
            self.refreshActivity()
            if let snapshot, snapshot.mayInterruptMedia {
                self.announceForAccessibility(
                    snapshot.title + " " + (snapshot.metric ?? ""),
                    priority: .medium
                )
            }
        }
        context.start()
        if history.loadOutcome.permitsManagedCleanup {
            history.applyRetention()
            history.removeUntrackedManagedFiles()
        } else if let message = history.loadRecoveryMessage {
            present(error: NotchShotError.exportFailed(message))
        }
        clipboard.applyRetention()
        clipboard.removeOrphanedImages()
        clipboardMonitor.reconcile()

        RecordingService.shared.onStatusChange = { [weak self] status in
            guard let self else { return }
            var adjusted = status
            adjusted.elapsed += self.completedRecordingDuration
            self.recordingStatus = adjusted
        }
        RecordingService.shared.onUnexpectedStop = { [weak self] error, recoveryURL in
            Task { await self?.finishRecordingAfterFailure(error, recoveryURL: recoveryURL) }
        }
        RecordingService.shared.onLowDiskThresholdReached = { [weak self] in
            self?.recordingStoppedForLowDisk = true
            self?.stopRecording()
        }

        systemLevels.onChange = { [weak self] level in
            self?.showSystemLevel(level)
        }
        osd.onSystemMediaKey = { [weak self] action in
            self?.systemLevels.applyInterceptedKey(action) ?? false
        }
        FloatingBasketManager.shared.start(coordinator: self)
        // One-time migration: older builds could leave the native helper
        // suspended without a watchdog. Later launches resume only PIDs owned
        // by this process, so one app can never cancel another app's lease.
        if Preferences.shared.hasCompletedFirstRun,
           !Preferences.shared.hasRecoveredLegacySystemOSD,
           osd.hasStoppedSystemOSD {
            presentLegacyOSDRecoveryPrompt()
        }
        // A new install has no legacy suspension to heal. Marking it complete
        // without signalling prevents us from resuming an OSD another utility
        // deliberately paused.
        Preferences.shared.hasRecoveredLegacySystemOSD = true
        osd.stop()
        installVoiceOverObservationIfNeeded()
        // A persisted replacement preference is already explicit opt-in. On
        // macOS 26.5 the replacement also needs Input Monitoring to consume
        // only the media keys before Control Center draws its duplicate OSD.
        reconcileSystemLevelIntegration(
            requestInputAccess: Preferences.shared.suppressesSystemOSD
        )

        // Media presence feeds the arbiter but can never outrank a capture.
        // `observeMedia` re-arms its own tracker, so it must be started exactly
        // once — arming it here as well doubled the trackers on every change.
        observeMedia()
        observeDictation()
        refreshActivity()
    }

    private func presentLegacyOSDRecoveryPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apple’s system overlay is already paused"
        alert.informativeText = "An older NotchShot build or another utility may own that paused state. Restore it only if brightness and volume overlays stayed missing after the owning app quit."
        alert.addButton(withTitle: "Leave It Alone")
        alert.addButton(withTitle: "Restore Apple Overlay")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            osd.recoverLegacySuspension()
        }
    }

    private func observeMedia() {
        arbiter.hasMedia = media.snapshot.hasContent
        refreshActivity()
        withObservationTracking {
            _ = media.snapshot.hasContent
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMedia() }
        }
    }

    /// Last dictation state announced to VoiceOver, so republished snapshots
    /// (transcript updates) do not re-announce a state the user already heard.
    private var lastAnnouncedDictationState: DictationState = .idle

    private func observeDictation() {
        dictation.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            if snapshot.state == .idle {
                self.arbiter.dictation = nil
            } else {
                self.arbiter.dictation = snapshot
            }
            self.refreshActivity()
            // Announce transitions only. The snapshot is republished on every
            // transcript update, so announcing unconditionally made VoiceOver
            // repeat "Dictation listening" for the whole session.
            guard snapshot.state != self.lastAnnouncedDictationState else { return }
            self.lastAnnouncedDictationState = snapshot.state
            switch snapshot.state {
            case .listening: self.announceForAccessibility("Dictation listening", priority: .medium)
            case .finalizing: self.announceForAccessibility("Finalizing", priority: .medium)
            case .completed: self.announceForAccessibility("Inserted", priority: .medium)
            case .copied: self.announceForAccessibility("Copied", priority: .medium)
            case .cancelled: self.announceForAccessibility("Cancelled", priority: .medium)
            case .failed(let msg): self.announceForAccessibility("Dictation failed: \(msg)", priority: .high)
            default: break
            }
        }
        dictation.onRequestDisplay = { [weak self] displayID in
            guard let self, let displayID else { return }
            // Ensure dictation display is active – windowController's activeDisplayID will be coerced by hover logic,
            // but we can hint by moving pointer focus? For now just ensure arbiter dictation has display.
            self.arbiter.dictation?.displayID = displayID
            self.refreshActivity()
            // Force windowController to use this display as active for dictation duration
            // The windowController already picks hoveredDisplay or mouse location; dictation snapshot's displayID drives panel routing.
        }
        dictation.onAnnounce = { [weak self] msg in
            self?.announceForAccessibility(msg, priority: .medium)
        }
        withObservationTracking {
            _ = dictation.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDictation() }
        }
    }

    // MARK: Dictation

    public func toggleDictation() {
        // Arbitrate: don't start dictation during modal selection/countdown/recording or voice note
        if arbiter.selection != nil || arbiter.countdown != nil || arbiter.isRecording {
            present(error: NotchShotError.recordingFailed("Finish the current capture or recording before starting dictation"))
            return
        }
        if let voiceState = context.voiceNotes.snapshot?.state, voiceState == .recording {
            present(error: NotchShotError.recordingFailed("Finish the current voice note before starting dictation"))
            return
        }
        // Use trigger mode: toggle vs holdToTalk
        // Toggle mode uses Carbon hotkey; hold mode uses event tap. But both can be invoked via toggle.
        if Preferences.shared.dictationTriggerMode == .toggle {
            dictation.toggle()
        } else {
            // Hold-to-talk triggered via toggle shortcut should still toggle (fallback)
            dictation.toggle()
        }
    }

    public func stopDictation() {
        Task { await dictation.stop() }
    }

    public func cancelDictation() {
        dictation.cancel()
    }

    public func handleDictationReturn() {
        Task { await dictation.stop() }
    }

    public func handleDictationEscape() {
        dictation.cancel()
    }

    // MARK: System level HUD

    private func showSystemLevel(_ level: SystemLevel) {
        var routed = level
        if routed.displayID == nil {
            routed.displayID = windowController?.activeDisplayID
        }
        arbiter.systemLevel = routed
        refreshActivity()

        // Announce the settled value once after a key-repeat burst rather than
        // speaking every intermediate percentage.
        accessibilityLevelTask?.cancel()
        accessibilityLevelTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let level = self?.arbiter.systemLevel else { return }
            let message = level.kind == .volume && level.isMuted
                ? "Muted"
                : "\(level.kind.title) \(Int(level.value * 100)) percent"
            self?.announceForAccessibility(message, priority: .medium)
        }

        systemLevelTask?.cancel()
        systemLevelTask = Task { [weak self] in
            // Each further change restarts the timer, so holding a volume key
            // keeps the HUD up rather than flickering.
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.arbiter.systemLevel = nil
                self?.refreshActivity()
            }
        }
    }

    public func setSystemLevelHUDEnabled(_ enabled: Bool) {
        Preferences.shared.systemLevelHUDEnabled = enabled
        reconcileSystemLevelIntegration()
    }

    public func setBrightnessMirroringEnabled(_ enabled: Bool) {
        Preferences.shared.mirrorsBrightnessChanges = enabled
        systemLevels.setBrightnessMirroringEnabled(enabled)
        if !enabled, arbiter.systemLevel?.kind == .brightness {
            arbiter.systemLevel = nil
            refreshActivity()
        }
    }

    public func setSystemOSDSuppressed(_ suppressed: Bool) {
        Preferences.shared.suppressesSystemOSD = suppressed
        reconcileSystemLevelIntegration(requestInputAccess: suppressed)
    }

    public func setNotchEnabled(_ enabled: Bool) {
        Preferences.shared.notchEnabled = enabled
        windowController?.rebuildPanels()
        reconcileSystemLevelIntegration()
    }

    public func setNotchDisplayPlacement(_ placement: NotchDisplayPlacement) {
        Preferences.shared.notchDisplayPlacement = placement
        windowController?.rebuildPanels()
        reconcileSystemLevelIntegration()
    }

    /// Applies the fail-open invariant: native feedback is suppressed only
    /// while a real panel exists and the custom HUD is enabled. VoiceOver keeps
    /// Apple's native feedback because the custom HUD is not yet a complete
    /// accessibility replacement for every system OSD.
    public func reconcileSystemLevelIntegration(requestInputAccess: Bool = false) {
        let preferences = Preferences.shared
        let canRender = preferences.notchEnabled
            && preferences.systemLevelHUDEnabled
            && windowController?.hasRenderablePanel == true
        guard canRender else {
            systemLevels.stop()
            osd.stop()
            arbiter.systemLevel = nil
            refreshActivity()
            return
        }

        systemLevels.start()
        let shouldSuppress = preferences.suppressesSystemOSD
            && !NSWorkspace.shared.isVoiceOverEnabled
        osd.setEnabled(shouldSuppress, requestInputAccess: requestInputAccess)
    }

    private func installVoiceOverObservationIfNeeded() {
        guard voiceOverObservation == nil else { return }
        voiceOverObservation = NSWorkspace.shared.observe(
            \.isVoiceOverEnabled,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.reconcileSystemLevelIntegration()
            }
        }
    }

    private func refreshActivity() {
        let resolved = arbiter.resolve()
        if resolved != activity {
            activity = resolved
        }
        windowController?.update(
            activity: activity,
            isPeeking: isPeeking,
            resultCount: shelfItems.count,
            hasStack: stack.isCollecting || !stack.isEmpty,
            hasMediaContent: media.snapshot.hasContent
        )
    }

    /// Hover reported by the window controller.
    ///
    /// The delay lives here rather than in the view: it is what stops the notch
    /// flaring open every time the pointer crosses the top of the screen on its
    /// way to the menu bar. Leaving is immediate — a lingering open notch after
    /// the pointer has gone is exactly the "it opened by itself" complaint.
    public func setHovering(_ hovering: Bool) {
        peekTask?.cancel()
        guard Preferences.shared.hoverPeekEnabled else {
            if isPeeking { setPeeking(false) }
            return
        }

        guard hovering else {
            setPeeking(false)
            return
        }
        guard !isPeeking else { return }

        peekTask = Task { [weak self] in
            let delay = Preferences.shared.hoverPeekDelay
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.setPeeking(true) }
        }
    }

    public func setPeeking(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        refreshActivity()
    }

    /// Deliberate expansion: click, shortcut, or a drag entering the notch.
    public func toggleExpanded() {
        arbiter.userExpanded.toggle()
        refreshActivity()
        if arbiter.userExpanded {
            windowController?.focusActivePanel()
        } else {
            windowController?.resignFocus()
        }
    }

    public func collapse() {
        arbiter.userExpanded = false
        refreshActivity()
        windowController?.resignFocus()
    }

    // MARK: Capture flow

    public func beginFirstCapture() {
        Preferences.shared.pendingFirstCaptureIntent = .area
        capture(.area)
    }

    public func resumePendingFirstCaptureIfPossible() {
        guard permissions.screenRecording.isUsable,
              let intent = Preferences.shared.pendingFirstCaptureIntent else { return }
        capture(intent)
    }

    /// - Parameter clipboardOnly: Copies the result and keeps the file in the
    ///   app's own store rather than the user's output folder. This is what the
    ///   ⌃⇧⌘3 and ⌃⇧⌘4 shortcuts mean, and it overrides the save-to-disk
    ///   preference for this one capture without touching the active recipe.
    public func capture(
        _ intent: CaptureIntent,
        timer: CaptureTimer = .none,
        clipboardOnly: Bool = false,
        recipe: CaptureRecipe? = nil,
        automationAction: URLCaptureAction = .defaultBehavior,
        displayID: CGDirectDisplayID? = nil
    ) {
        if recordingStartTask != nil {
            cancelPendingRecordingStart()
            refreshActivity()
            present(error: NotchShotError.recordingFailed(
                "The pending recording was cancelled. Trigger the capture again when its cleanup finishes."
            ))
            return
        }
        guard !RecordingService.shared.hasActiveSession,
              recordingCompletionTask == nil,
              !isPresentingRecordingCancellation else {
            // New overlay windows cannot be added to a recording filter after
            // ScreenCaptureKit has started. Refuse the conflicting workflow so
            // NotchShot never appears in its own video.
            present(error: NotchShotError.recordingFailed(
                "Finish or discard the recording before starting a screenshot."
            ))
            return
        }
        // A newly requested workflow owns the shared selection overlay. Retire
        // any older capture or not-yet-started recording before presenting it.
        cancelPendingRecordingStart()
        cancelCaptureWorkflow()
        let operationID = UUID()
        captureOperationID = operationID
        countdownTask = Task { [weak self] in
            await self?.performCapture(
                intent,
                timer: timer,
                clipboardOnly: clipboardOnly,
                recipe: recipe,
                automationAction: automationAction,
                displayID: displayID,
                operationID: operationID
            )
            guard let self, self.captureOperationID == operationID else { return }
            self.countdownTask = nil
            self.captureOperationID = nil
        }
    }

    private func performCapture(
        _ intent: CaptureIntent,
        timer: CaptureTimer,
        clipboardOnly: Bool = false,
        recipe: CaptureRecipe? = nil,
        automationAction: URLCaptureAction = .defaultBehavior,
        displayID: CGDirectDisplayID? = nil,
        operationID: UUID
    ) async {
        guard isCurrentCapture(operationID), ensureScreenRecordingPermission() else { return }
        if Preferences.shared.pendingFirstCaptureIntent == intent {
            Preferences.shared.pendingFirstCaptureIntent = nil
        }
        collapse()

        var request = CaptureRequest(
            intent: intent,
            timer: timer,
            includesCursor: Preferences.shared.includesCursorInScreenshots
        )

        if intent.needsSelection {
            guard let selection = await runSelection(for: intent) else { return }
            guard isCurrentCapture(operationID) else { return }
            switch selection {
            case .area(let rect, let displayID):
                request.rect = rect
                request.displayID = displayID
            case .window(let window):
                request.windowID = window.id
                request.intent = .window
            case .cancelled:
                return
            }
        } else if intent == .display {
            request.displayID = displayID
                ?? windowController?.activeDisplayID
                ?? NSScreen.main.flatMap { ScreenLookup.displayID(for: $0) }
        }

        // Scrolling takes over after the region is chosen.
        if intent == .scrolling {
            guard let rect = request.rect else { return }
            await beginScrollingCapture(region: rect)
            return
        }

        if timer != .none {
            guard await runCountdown(seconds: timer.rawValue, intent: intent) else { return }
        }

        guard isCurrentCapture(operationID) else { return }
        await executeCapture(
            request,
            intent: intent,
            clipboardOnly: clipboardOnly,
            recipe: recipe,
            automationAction: automationAction,
            operationID: operationID
        )
    }

    private func executeCapture(
        _ request: CaptureRequest,
        intent: CaptureIntent,
        clipboardOnly: Bool = false,
        recipe: CaptureRecipe? = nil,
        automationAction: URLCaptureAction = .defaultBehavior,
        operationID: UUID
    ) async {
        arbiter.isProcessing = "Capturing"
        refreshActivity()
        defer {
            if captureOperationID == operationID {
                arbiter.isProcessing = nil
                refreshActivity()
            }
        }

        // The exclusion set must be read *now*: panels come and go.
        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        let frontmost = NSWorkspace.shared.frontmostApplication

        do {
            let image = try await CaptureService.shared.capture(request, excludedWindows: excluded)
            guard isCurrentCapture(operationID) else { return }

            if intent == .ocr {
                await handleTextCapture(image, operationID: operationID)
                return
            }

            playCaptureSound()
            await finishStillCapture(
                image,
                kind: .screenshot,
                sourceApplication: frontmost,
                warnings: [],
                seams: [],
                clipboardOnly: clipboardOnly,
                recipe: recipe,
                automationAction: automationAction,
                operationID: operationID
            )
        } catch {
            guard isCurrentCapture(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    /// OCR captures never touch the shelf as an image: the point is the text.
    private func handleTextCapture(_ image: CapturedImage, operationID: UUID) async {
        arbiter.isProcessing = "Reading text"
        refreshActivity()
        do {
            let result = try await OCRService.shared.recognizeText(in: image)
            guard isCurrentCapture(operationID) else { return }
            guard !result.isEmpty else {
                present(error: NotchShotError.captureFailed("No text found in that area"))
                return
            }
            ImageExport.copyToPasteboard(text: result.clipboardText(format: .text))
            playCaptureSound()

            // Still record it so the text is recoverable from history, subject
            // to the indexing opt-in.
            let asset = try await persist(
                image,
                kind: .text,
                sourceApplication: NSWorkspace.shared.frontmostApplication
            )
            guard isCurrentCapture(operationID) else {
                removeCancelledArtifactIfOwned(asset)
                return
            }
            let thumbnailImage = await ImageExport.makeThumbnail(from: image)
            // Resampling suspends, so a newer capture can have superseded this
            // one in the meantime; re-check before it reaches the shelf.
            guard isCurrentCapture(operationID) else {
                removeCancelledArtifactIfOwned(asset)
                return
            }
            let item = ShelfItem(
                asset: asset,
                thumbnail: thumbnailImage.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                },
                image: image
            )
            item.ocrResult = result
            history.record(
                asset: asset,
                image: image.cgImage,
                recognizedText: result.fullText,
                thumbnail: thumbnailImage
            )
            push(item)
        } catch {
            guard isCurrentCapture(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    private func finishStillCapture(
        _ image: CapturedImage,
        kind: CaptureAssetKind,
        sourceApplication: NSRunningApplication?,
        warnings: [String],
        seams: [StitchSeam],
        clipboardOnly: Bool = false,
        recipe recipeOverride: CaptureRecipe? = nil,
        automationAction: URLCaptureAction = .defaultBehavior,
        operationID: UUID? = nil
    ) async {
        do {
            guard operationID.map(isCurrentCapture) ?? true else { return }
            let recipe = recipeOverride ?? CaptureRecipeStore.shared.activeRecipe
            let prepared = try CaptureRecipeRenderer.render(image, recipe: recipe)
            let asset = try await persist(
                prepared,
                kind: kind,
                sourceApplication: sourceApplication,
                recipe: recipe,
                clipboardOnly: clipboardOnly
            )
            guard operationID.map(isCurrentCapture) ?? true else {
                removeCancelledArtifactIfOwned(asset)
                return
            }

            if clipboardOnly
                || Preferences.shared.copyToClipboardAfterCapture
                || recipe.destination == .clipboardOnly {
                ImageExport.copyToPasteboard(prepared.cgImage)
            }

            // Downsampled once, off the main actor, and shared with history —
            // the shelf and the history row want the same pixels, and a
            // full-screen capture costs tens of milliseconds to resample.
            let thumbnailImage = await ImageExport.makeThumbnail(from: prepared)
            // Resampling suspends, so a newer capture can have superseded this
            // one in the meantime; re-check before it reaches the shelf.
            guard operationID.map(isCurrentCapture) ?? true else {
                removeCancelledArtifactIfOwned(asset)
                return
            }
            let thumbnail = thumbnailImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            history.record(asset: asset, image: prepared.cgImage, thumbnail: thumbnailImage)

            let item = ShelfItem(
                asset: asset,
                thumbnail: thumbnail,
                image: prepared,
                stitchWarnings: warnings,
                seams: seams
            )
            push(item)

            let annotationMode: RecipeAnnotationMode = automationAction == .annotate
                ? .openEditor
                : recipe.annotationMode
            switch annotationMode {
            case .none:
                break
            case .openEditor:
                openEditor(for: item)
            case .privacyReview:
                openPrivacyReview(for: item)
            }
        } catch {
            if let operationID {
                guard isCurrentCapture(operationID), !(error is CancellationError) else { return }
            }
            present(error: error)
        }
    }

    private func isCurrentCapture(_ operationID: UUID) -> Bool {
        !Task.isCancelled && captureOperationID == operationID
    }

    private func removeCancelledArtifactIfOwned(_ asset: CaptureAsset) {
        guard asset.canBeAutomaticallyRemoved else { return }
        try? FileManager.default.removeItem(at: asset.url)
    }

    /// Writes the capture to its destination (or the app's own store when
    /// "save to disk" is off, so the shelf always has a real file to drag).
    private func persist(
        _ image: CapturedImage,
        kind: CaptureAssetKind,
        sourceApplication: NSRunningApplication?,
        recipe: CaptureRecipe? = nil,
        clipboardOnly: Bool = false
    ) async throws -> CaptureAsset {
        let preferences = Preferences.shared
        let recipe = recipe ?? CaptureRecipe.all[0]
        let appName = sourceApplication?.localizedName
        let template = recipe.id == "standard" ? nil : recipe.filenameTemplate
        let name = preferences.expandFilename(template: template, appName: appName)

        let format = recipe.imageFormat ?? preferences.imageFormat
        let url: URL
        let ownership: CaptureAssetOwnership
        // A clipboard-only capture keeps its file in the app's store so it stays
        // recoverable from History, without dropping a file the user did not ask
        // for into their output folder.
        switch clipboardOnly ? .clipboardOnly : recipe.destination {
        case .configuredFolder:
            let folder = recipe.id == "standard" && !preferences.saveToDiskAfterCapture
                ? AppPaths.captures : preferences.outputFolder
            url = AppPaths.uniqueURL(in: folder, name: name, extension: format.fileExtension)
            ownership = AppPaths.owns(url) ? .managedTemporary : .userDocument
        case .clipboardOnly:
            url = AppPaths.uniqueURL(
                in: AppPaths.captures,
                name: name,
                extension: format.fileExtension
            )
            ownership = .managedTemporary
        case .askEveryTime:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [ImageExport.utType(for: format)]
            panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
            panel.directoryURL = preferences.outputFolder
            if panel.runModal() == .OK, let chosen = panel.url {
                url = chosen
                ownership = .userDocument
            } else {
                // Cancelling the destination dialog must not destroy the pixels
                // the user just captured; retain them in the app's local store.
                url = AppPaths.uniqueURL(
                    in: AppPaths.captures,
                    name: name,
                    extension: format.fileExtension
                )
                ownership = .managedTemporary
            }
        }
        let written = try await ImageExport.write(
            image,
            to: url,
            format: format,
            quality: preferences.jpegQuality
        )

        // If HEIC fell back to PNG the extension must follow, or Finder and
        // Preview will disagree about the file.
        var finalURL = url
        if written != format {
            let preferred = url.deletingPathExtension().appendingPathExtension(written.fileExtension)
            if FileManager.default.fileExists(atPath: preferred.path) {
                finalURL = AppPaths.uniqueURL(
                    in: preferred.deletingLastPathComponent(),
                    name: preferred.deletingPathExtension().lastPathComponent,
                    extension: written.fileExtension
                )
            } else {
                finalURL = preferred
            }
            try FileManager.default.moveItem(at: url, to: finalURL)
        }

        return CaptureAsset(
            url: finalURL,
            kind: kind,
            pixelSize: image.pixelSize,
            scale: image.scale,
            sourceApplication: sourceApplication?.bundleIdentifier,
            sourceApplicationName: appName,
            ownership: ownership
        )
    }

    // MARK: Selection & countdown

    private func runSelection(for intent: CaptureIntent) async -> SelectionResult? {
        let mode: SelectionMode = switch intent {
        case .window: .window
        case .scrolling: .scrollingRegion
        case .ocr: .textRegion
        default: .area
        }

        arbiter.selection = intent
        refreshActivity()
        defer {
            arbiter.selection = nil
            refreshActivity()
        }

        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        var freezeFrames: [CGDirectDisplayID: CapturedImage] = [:]
        // Freeze frames double as the magnifier's pixel source, so they're
        // taken even when the freeze itself is switched off.
        for screen in NSScreen.screens {
            guard let displayID = ScreenLookup.displayID(for: screen) else { continue }
            if let frame = try? await CaptureService.shared.captureFreezeFrame(
                displayID: displayID,
                excludedWindows: excluded
            ) {
                freezeFrames[displayID] = frame
            }
        }

        let windows = (try? await ShareableContentProvider.shared.snapshot(forceRefresh: true))?
            .selectableWindows(excluding: excluded) ?? []

        let previous = intent == .area ? await CaptureService.shared.previousAreaRect : nil

        // Everything above suspends — freeze frames and a forced
        // SCShareableContent refresh take long enough for the user to cancel
        // before the overlay exists. The cancel paths can only retire an
        // overlay that is already presenting, so without this check a cancelled
        // workflow still throws a full-screen overlay up afterwards and the
        // user has to dismiss it a second time.
        guard !Task.isCancelled else { return nil }

        // Activating for the overlay can push our panels behind the menu bar,
        // so they are re-asserted the moment the overlay goes away.
        SelectionOverlayController.shared.onDismiss = { [weak self] in
            self?.windowController?.reassertPanels()
        }
        let result = await SelectionOverlayController.shared.beginSelection(
            mode: mode,
            freezeFrames: freezeFrames,
            windows: windows,
            initialRect: previous
        )
        return result == .cancelled ? nil : result
    }

    /// Returns false if the user cancelled during the countdown.
    private func runCountdown(seconds: Int, intent: CaptureIntent) async -> Bool {
        for remaining in stride(from: seconds, through: 1, by: -1) {
            guard !Task.isCancelled else { return false }
            arbiter.countdown = (remaining, intent)
            refreshActivity()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                arbiter.countdown = nil
                refreshActivity()
                return false
            }
        }
        arbiter.countdown = nil
        refreshActivity()
        return !Task.isCancelled
    }

    public func cancelCurrentOperation() {
        cancelPendingRecordingStart()
        cancelCaptureWorkflow()
        refreshActivity()
    }

    private func cancelCaptureWorkflow() {
        let hadCaptureWorkflow = captureOperationID != nil
            || arbiter.countdown != nil
            || scrollingSession != nil
        if SelectionOverlayController.shared.isPresenting {
            SelectionOverlayController.shared.cancel()
        }
        countdownTask?.cancel()
        countdownTask = nil
        captureOperationID = nil
        arbiter.countdown = nil
        if let scrollingSession {
            scrollingSession.cancel()
            self.scrollingSession = nil
            scrollingSessionID = nil
            scrollingFrameCount = 0
        }
        if hadCaptureWorkflow {
            arbiter.isProcessing = nil
        }
    }

    private func cancelPendingRecordingStart() {
        guard recordingStartTask != nil else { return }
        recordingStartOperationID = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        if SelectionOverlayController.shared.isPresenting {
            SelectionOverlayController.shared.cancel()
        }
        Task {
            await RecordingService.shared.cancel()
        }
    }

    // MARK: Scrolling capture

    private func beginScrollingCapture(region: CGRect) async {
        scrollingSession?.cancel()

        let sessionID = UUID()
        scrollingRegion = region
        let session = ScrollingCaptureSession(region: region) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollingEvent(event, sessionID: sessionID)
            }
        }
        scrollingSession = session
        scrollingSessionID = sessionID
        scrollingFrameCount = 0
        arbiter.isProcessing = "Scroll to capture · Return when done"
        refreshActivity()
        await session.start()
        guard scrollingSessionID == sessionID else {
            session.cancel()
            return
        }
    }

    public func captureScrollingFrame() {
        Task { await scrollingSession?.captureFrameManually() }
    }

    public func saveCurrentCaptureSession() {
        guard !stack.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Save Capture Session"
        alert.informativeText = "The session keeps the order of these captures and can be resumed later while the files remain in History."
        let field = NSTextField(string: "Capture Session \(Date().formatted(date: .abbreviated, time: .shortened))")
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Capture session name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try stack.saveSession(named: field.stringValue)
        } catch {
            present(error: error)
        }
    }

    public func resumeCaptureSession(_ session: CaptureSessionRecord) {
        let restored = stack.resume(session, history: history)
        if restored == 0 {
            present(error: NotchShotError.exportFailed(
                "None of that session's capture files are still available in History"
            ))
        } else {
            refreshActivity()
        }
    }

    public func finishScrollingCapture() {
        Task { await scrollingSession?.finish() }
    }

    private func handleScrollingEvent(
        _ event: ScrollingCaptureSession.Event,
        sessionID: UUID
    ) {
        guard scrollingSessionID == sessionID else { return }

        switch event {
        case .frameCaptured(let count):
            scrollingFrameCount = count
            arbiter.isProcessing = "\(count) frame\(count == 1 ? "" : "s") · Return when done"
            refreshActivity()

        case .stitching(let progress):
            arbiter.isProcessing = "Stitching \(Int(progress * 100))%"
            refreshActivity()

        case .finished(let output):
            scrollingSession = nil
            scrollingSessionID = nil
            arbiter.isProcessing = nil
            let region = scrollingRegion
            scrollingRegion = nil
            // The scroll may have happened on a 1x external display while the
            // main display is 2x. Taking the scale from the wrong screen gives
            // the export the wrong DPI and the editor the wrong point size —
            // the same reason window captures resolve scale from their own
            // display rather than the main one.
            let scale = region
                .flatMap { ScreenLookup.screen(bestMatchingCGRect: $0)?.backingScaleFactor }
                ?? NSScreen.main?.backingScaleFactor ?? 2
            let image = CapturedImage(
                cgImage: output.image,
                scale: scale,
                sourceRect: region ?? .zero
            )
            playCaptureSound()
            // Registered like any other capture so a newer one can supersede
            // it. Without an ID the guards in `finishStillCapture` pass
            // unconditionally and a stale stitch reaches the shelf last.
            let operationID = UUID()
            captureOperationID = operationID
            Task { [weak self] in
                await self?.finishStillCapture(
                    image,
                    kind: .scrollingScreenshot,
                    sourceApplication: NSWorkspace.shared.frontmostApplication,
                    warnings: output.warnings,
                    seams: output.seams,
                    operationID: operationID
                )
                guard let self, self.captureOperationID == operationID else { return }
                self.captureOperationID = nil
            }

        case .failedButFramesKept(let reason, let folder):
            scrollingSession = nil
            scrollingSessionID = nil
            scrollingRegion = nil
            arbiter.isProcessing = nil
            present(error: NotchShotError.stitchFailed(reason))
            NSWorkspace.shared.activateFileViewerSelecting([folder])

        case .failed(let reason):
            scrollingSession = nil
            scrollingSessionID = nil
            scrollingRegion = nil
            arbiter.isProcessing = nil
            present(error: NotchShotError.stitchFailed(reason))

        case .cancelled:
            scrollingSession = nil
            scrollingSessionID = nil
            scrollingRegion = nil
            scrollingFrameCount = 0
            arbiter.isProcessing = nil
            refreshActivity()
        }
    }

    // MARK: Recording

    public func startRecording(
        target: RecordingTarget? = nil,
        mode: RecordingTargetMode? = nil
    ) {
        guard recordingStartTask == nil,
              recordingCompletionTask == nil,
              !isRecordingPaused,
              !RecordingService.shared.hasActiveSession else { return }
        recordingSegments.removeAll()
        completedRecordingDuration = 0
        pausedRecordingConfiguration = nil
        isRecordingPaused = false
        cancelCaptureWorkflow()
        refreshActivity()

        let operationID = UUID()
        recordingStartOperationID = operationID
        recordingStartTask = Task { [weak self] in
            await self?.beginRecording(target: target, mode: mode, operationID: operationID)
            guard let self, self.recordingStartOperationID == operationID else { return }
            self.recordingStartTask = nil
            self.recordingStartOperationID = nil
        }
    }

    private func beginRecording(
        target: RecordingTarget?,
        mode: RecordingTargetMode?,
        operationID: UUID
    ) async {
        guard isCurrentRecordingStart(operationID) else { return }
        guard ensureScreenRecordingPermission() else { return }
        collapse()

        var resolvedTarget = target
        if resolvedTarget == nil {
            let targetMode = mode ?? Preferences.shared.recordingTargetMode
            Preferences.shared.recordingTargetMode = targetMode
            switch targetMode {
            case .display:
                guard let displayID = windowController?.activeDisplayID
                        ?? NSScreen.main.flatMap({ ScreenLookup.displayID(for: $0) }) else {
                    present(error: NotchShotError.displayNotFound)
                    return
                }
                resolvedTarget = .display(displayID)
            case .area, .window:
                let selectionIntent: CaptureIntent = targetMode == .window ? .window : .area
                guard let selection = await runSelection(for: selectionIntent) else { return }
                guard isCurrentRecordingStart(operationID) else { return }
                switch selection {
                case .area(let rect, let displayID):
                    resolvedTarget = .area(rect, displayID)
                case .window(let window):
                    resolvedTarget = .window(window.id)
                case .cancelled:
                    return
                }
            }
        }
        guard let resolvedTarget else { return }
        guard isCurrentRecordingStart(operationID) else { return }

        let preferences = Preferences.shared
        let configuration = RecordingConfiguration(
            target: resolvedTarget,
            audioSources: preferences.recordingAudioSources,
            microphoneDeviceID: preferences.preferredMicrophoneID,
            resolution: preferences.recordingResolution,
            framesPerSecond: preferences.recordingFrameRate,
            showsCursor: preferences.recordingShowsCursor,
            highlightsClicks: preferences.recordingHighlightsClicks,
            // SCRecordingOutput finalizes the file if its stream
            // configuration changes. Smooth click zoom therefore belongs in
            // a post-processing pipeline, not the live recording stream.
            autoZoomsOnClicks: false,
            framesWithBackground: preferences.recordingFramesWithBackground
        )

        do {
            try await RecordingService.shared.start(configuration)
            guard isCurrentRecordingStart(operationID) else {
                await RecordingService.shared.cancel()
                return
            }
            arbiter.isRecording = true
            refreshActivity()
        } catch {
            guard isCurrentRecordingStart(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    private func isCurrentRecordingStart(_ operationID: UUID) -> Bool {
        !Task.isCancelled && recordingStartOperationID == operationID
    }

    public func stopRecording() {
        if recordingStartTask != nil {
            cancelPendingRecordingStart()
            refreshActivity()
            return
        }
        guard (RecordingService.shared.isRecording || isRecordingPaused),
              recordingCompletionTask == nil,
              !isPresentingRecordingCancellation else { return }
        recordingCompletionTask = Task { [weak self] in
            await self?.finishRecording()
        }
    }

    private func finishRecording() async {
        arbiter.isRecording = false
        arbiter.isProcessing = "Finishing recording"
        refreshActivity()
        defer {
            recordingCompletionTask = nil
            arbiter.isProcessing = nil
            refreshActivity()
        }
        do {
            var asset = try await finishRecordingSegments()
            // Persist the base MP4 before any optional caption or thumbnail
            // await. If the user quits during post-processing, the finished
            // recording is still discoverable on the next launch.
            history.record(asset: asset, image: nil)
            persistHistory()
            var captionWarning: Error?

            if Preferences.shared.recordingGeneratesCaptions {
                arbiter.isProcessing = "Creating captions on this Mac"
                refreshActivity()
                do {
                    let transcript = try await OnDeviceTranscriptionService.shared.transcribe(
                        recordingURL: asset.url
                    )
                    let preferredCaptionURL = asset.url.deletingPathExtension().appendingPathExtension("srt")
                    let captionURL: URL
                    if FileManager.default.fileExists(atPath: preferredCaptionURL.path) {
                        captionURL = AppPaths.uniqueURL(
                            in: preferredCaptionURL.deletingLastPathComponent(),
                            name: preferredCaptionURL.deletingPathExtension().lastPathComponent,
                            extension: "srt"
                        )
                    } else {
                        captionURL = preferredCaptionURL
                    }
                    try Data(transcript.srt.utf8).write(
                        to: captionURL,
                        options: [.atomic, .withoutOverwriting]
                    )
                    asset.recognizedText = transcript.text
                    asset.captionURL = captionURL
                    asset.refreshOwnedFileIdentities()
                } catch {
                    // Captioning is optional: the finished MP4 must never be
                    // discarded because a language model or audio track is absent.
                    captionWarning = error
                }
            }
            let thumbnail = await VideoThumbnail.make(for: asset.url)
            history.record(
                asset: asset,
                image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                recognizedText: asset.recognizedText
            )
            persistHistory()
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            if recordingStoppedForLowDisk {
                recordingStoppedForLowDisk = false
                present(error: NotchShotError.diskSpaceUnavailable)
            }
            if let captionWarning {
                present(error: NotchShotError.recordingFailed(
                    "The recording was saved, but captions could not be created: \(captionWarning.localizedDescription)"
                ))
            }
        } catch {
            recordingStoppedForLowDisk = false
            present(error: error)
        }
    }

    public func pauseRecording() {
        guard RecordingService.shared.isRecording,
              recordingCompletionTask == nil,
              !isRecordingPaused,
              let configuration = RecordingService.shared.configuration else { return }
        recordingCompletionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = AppPaths.uniqueURL(
                    in: AppPaths.inProgress,
                    name: "Paused Segment",
                    extension: "mp4"
                )
                let segment = try await RecordingService.shared.stop(destination: url)
                self.recordingSegments.append(segment)
                self.completedRecordingDuration += segment.duration ?? 0
                self.pausedRecordingConfiguration = configuration
                self.isRecordingPaused = true
                self.recordingStatus.elapsed = self.completedRecordingDuration
                self.recordingCompletionTask = nil
                self.refreshActivity()
            } catch {
                self.recordingCompletionTask = nil
                self.present(error: error)
            }
        }
    }

    public func resumeRecording() {
        guard isRecordingPaused,
              recordingStartTask == nil,
              recordingCompletionTask == nil,
              let configuration = pausedRecordingConfiguration else { return }
        recordingStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await RecordingService.shared.start(configuration)
                self.isRecordingPaused = false
                self.recordingStartTask = nil
                self.refreshActivity()
            } catch {
                self.recordingStartTask = nil
                self.present(error: error)
            }
        }
    }

    private func finishRecordingSegments() async throws -> CaptureAsset {
        if RecordingService.shared.isRecording {
            if recordingSegments.isEmpty {
                return try await RecordingService.shared.stop()
            }
            let url = AppPaths.uniqueURL(
                in: AppPaths.inProgress,
                name: "Paused Segment",
                extension: "mp4"
            )
            let segment = try await RecordingService.shared.stop(destination: url)
            recordingSegments.append(segment)
        }
        guard !recordingSegments.isEmpty else {
            throw NotchShotError.recordingFailed("Nothing is recording")
        }

        let preferences = Preferences.shared
        let folder = preferences.saveToDiskAfterCapture ? preferences.outputFolder : AppPaths.recordings
        let destination = AppPaths.uniqueURL(
            in: folder,
            name: preferences.expandFilename(appName: "Recording"),
            extension: "mp4",
            alsoAvoiding: ["srt"]
        )
        let urls = recordingSegments.map(\.url)
        if urls.count == 1 {
            _ = try RecordingService.shared.commitPausedSegment(
                from: urls[0],
                to: destination
            )
        } else {
            try await RecordingSegmentJoiner.join(urls, to: destination)
            try RecordingService.retireCommittedPausedSegments(urls)
        }
        let metadata = await VideoThumbnail.metadata(for: destination)
        recordingSegments.removeAll()
        pausedRecordingConfiguration = nil
        isRecordingPaused = false
        completedRecordingDuration = 0
        return CaptureAsset(
            url: destination,
            kind: .recording,
            pixelSize: metadata?.pixelSize ?? .zero,
            scale: 1,
            duration: metadata?.duration,
            ownership: AppPaths.owns(destination) ? .managedTemporary : .userDocument
        )
    }

    public func finishRecordingForTermination() async throws -> CaptureAsset? {
        guard RecordingService.shared.hasActiveSession || isRecordingPaused else { return nil }
        return try await finishRecordingSegments()
    }

    public func cancelRecording() {
        guard (RecordingService.shared.isRecording || isRecordingPaused),
              recordingCompletionTask == nil,
              !isPresentingRecordingCancellation else { return }
        isPresentingRecordingCancellation = true
        defer { isPresentingRecordingCancellation = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The partial recording will be moved to the Trash, where it can still be recovered."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Move to Trash")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        arbiter.isRecording = false
        arbiter.isProcessing = "Discarding recording"
        refreshActivity()
        recordingCompletionTask = Task { [weak self] in
            guard let self else { return }
            var retainedURLs: [URL] = []
            if RecordingService.shared.isRecording {
                if let retained = await RecordingService.shared.cancel() {
                    retainedURLs.append(retained)
                }
            }
            for segment in self.recordingSegments where AppPaths.owns(segment.url) {
                do {
                    try FileManager.default.trashItem(at: segment.url, resultingItemURL: nil)
                } catch {
                    let fallback = AppPaths.uniqueURL(
                        in: AppPaths.discardedRecordings,
                        name: "Discarded Recording",
                        extension: "mp4"
                    )
                    do {
                        try FileManager.default.createDirectory(
                            at: AppPaths.discardedRecordings,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.moveItem(at: segment.url, to: fallback)
                        retainedURLs.append(fallback)
                    } catch {
                        retainedURLs.append(segment.url)
                    }
                }
            }
            var excludesCrashRecovery = true
            for retained in retainedURLs {
                if !RecordingService.ensureExcludedFromCrashRecovery(retained) {
                    excludesCrashRecovery = false
                }
            }
            self.recordingSegments.removeAll()
            self.pausedRecordingConfiguration = nil
            self.completedRecordingDuration = 0
            self.isRecordingPaused = false
            self.recordingCompletionTask = nil
            self.arbiter.isProcessing = nil
            self.refreshActivity()
            if let retainedURL = retainedURLs.first {
                self.presentRetainedDiscard(
                    at: retainedURL,
                    excludesCrashRecovery: excludesCrashRecovery
                )
            }
        }
    }

    private func presentRetainedDiscard(
        at url: URL,
        excludesCrashRecovery: Bool
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The recording could not be moved to Trash"
        if excludesCrashRecovery {
            alert.informativeText = "NotchShot kept the partial recording at \(url.path) so it would not be silently lost. It will not be offered as crash recovery."
        } else {
            alert.informativeText = "NotchShot kept the partial recording at \(url.path), but could not mark it as discarded. Move or delete it before restarting NotchShot, or it may be offered as crash recovery."
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func finishRecordingAfterFailure(
        _ error: NotchShotError,
        recoveryURL: URL?
    ) async {
        arbiter.isRecording = false
        // Recover this exact session. Picking the newest global orphan could
        // move an unrelated file left by an older crash.
        guard let recoveryURL,
              RecordingService.isRecoverableRecording(recoveryURL) else {
            present(error: error)
            return
        }

        do {
            let asset = try await RecordingService.shared.recover(recoveryURL)
            history.record(asset: asset, image: nil)
            persistHistory()
            let thumbnail = await VideoThumbnail.make(for: asset.url)
            history.record(
                asset: asset,
                image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            )
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            present(error: NotchShotError.recordingFailed("Recording stopped early — the partial file was kept"))
        } catch {
            Log.recording.error(
                "Could not recover interrupted recording \(recoveryURL.lastPathComponent): \(error.localizedDescription)"
            )
            presentRecoveryFiles(
                title: "An interrupted recording needs attention",
                urls: [recoveryURL],
                explanation: "NotchShot could not safely validate or move this recording, so it remains in the recovery folder."
            )
        }
    }

    /// Offers to recover recordings a crash left behind.
    public func recoverOrphanedRecordings() {
        let orphans = RecordingService.orphanedRecordings()
        guard !orphans.isEmpty else { return }
        guard Preferences.shared.historyEnabled
                || Preferences.shared.saveToDiskAfterCapture else {
            presentRecoveryFiles(
                title: "Interrupted recordings need a save destination",
                urls: orphans,
                explanation: "History and automatic saving are both off, so NotchShot left these files in its recovery folder instead of recovering and later deleting them as untracked data."
            )
            return
        }
        Task {
            var recoveredCount = 0
            var failed: [URL] = []
            for orphan in orphans {
                guard recoveredCount < 3 else {
                    failed.append(orphan)
                    continue
                }
                do {
                    let asset = try await RecordingService.shared.recover(orphan)
                    recoveredCount += 1
                    history.record(asset: asset, image: nil)
                    persistHistory()
                    let thumbnail = await VideoThumbnail.make(for: asset.url)
                    history.record(
                        asset: asset,
                        image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    )
                    push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
                } catch {
                    failed.append(orphan)
                    Log.recording.error(
                        "Could not recover \(orphan.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            if !failed.isEmpty {
                presentRecoveryFiles(
                    title: "Some interrupted recordings need attention",
                    urls: failed,
                    explanation: "They remain in NotchShot’s recovery folder because validation or export did not complete."
                )
            }
        }
    }

    private func presentRecoveryFiles(
        title: String,
        urls: [URL],
        explanation: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "\(explanation) \(urls.count) file(s) are still present."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: Shelf

    private func push(_ item: ShelfItem) {
        // While the stack is collecting, every capture also joins it, so a
        // multi-step flow can be grabbed without touching the UI between shots.
        if stack.isCollecting, item.asset.kind.isImage {
            stack.add(item.asset)
        }
        // Keep a full-resolution bitmap only for the newest item. Older shelf
        // entries can be reloaded from their file when edited or OCR'd.
        for existing in shelfItems {
            existing.image = nil
        }
        shelfItems.insert(item, at: 0)
        if shelfItems.count > Self.maximumShelfItems {
            shelfItems.removeLast(shelfItems.count - Self.maximumShelfItems)
        }
        selectedShelfIndex = 0
        arbiter.hasResult = Preferences.shared.showsShelfAfterCapture
        refreshActivity()
        scheduleShelfDismissal()
    }

    public func selectShelfItem(at index: Int) {
        guard shelfItems.indices.contains(index) else { return }
        selectedShelfIndex = index
        scheduleShelfDismissal()
    }

    public func advanceShelfSelection(by delta: Int) {
        guard !shelfItems.isEmpty else { return }
        let next = (selectedShelfIndex + delta + shelfItems.count) % shelfItems.count
        selectShelfItem(at: next)
    }

    public var selectedShelfItem: ShelfItem? {
        shelfItems.indices.contains(selectedShelfIndex) ? shelfItems[selectedShelfIndex] : nil
    }

    /// Opens the shelf image at a readable size without changing or exporting
    /// it. The app delegate owns the window; the coordinator owns the route.
    public func openPreview(for item: ShelfItem) {
        guard item.asset.kind.isImage else { return }
        onOpenCapturePreview?(item)
        scheduleShelfDismissal()
    }

    /// Hides the shelf without discarding the capture.
    public func hideShelf() {
        lastDismissed = shelfItems.first
        arbiter.hasResult = false
        shelfTimer?.invalidate()
        for item in shelfItems {
            item.image = nil
        }
        refreshActivity()
    }

    public func dismissShelfItem(_ item: ShelfItem) {
        lastDismissed = item
        shelfItems.removeAll { $0.id == item.id }
        selectedShelfIndex = 0
        arbiter.hasResult = !shelfItems.isEmpty
        refreshActivity()
    }

    private func removeShelfItemPermanently(_ item: ShelfItem) {
        if lastDismissed?.id == item.id {
            lastDismissed = nil
        }
        shelfItems.removeAll { $0.id == item.id }
        selectedShelfIndex = min(selectedShelfIndex, max(0, shelfItems.count - 1))
        arbiter.hasResult = !shelfItems.isEmpty
        refreshActivity()
    }

    public func restoreLastDismissed() {
        guard let lastDismissed else { return }
        if !shelfItems.contains(where: { $0.id == lastDismissed.id }) {
            shelfItems.insert(lastDismissed, at: 0)
        }
        selectedShelfIndex = 0
        arbiter.hasResult = true
        refreshActivity()
        scheduleShelfDismissal()
    }

    public var canRestoreDismissed: Bool { lastDismissed != nil }

    private func scheduleShelfDismissal() {
        shelfTimer?.invalidate()
        guard let interval = Preferences.shared.shelfDuration.interval else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Never yank the shelf out from under a pointer that's on it.
                if self.isPeeking {
                    self.scheduleShelfDismissal()
                } else {
                    self.hideShelf()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shelfTimer = timer
    }

    // MARK: Shelf actions

    public func perform(_ action: ShareAction, on item: ShelfItem) {
        switch action {
        case .copy:
            if let image = item.image {
                ImageExport.copyToPasteboard(image.cgImage)
            } else {
                guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
                    present(error: NotchShotError.exportFailed(
                        "That file changed or is no longer safely readable"
                    ))
                    return
                }
                ImageExport.copyToPasteboard(fileURL: item.asset.url)
            }

        case .open:
            guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
                present(error: NotchShotError.exportFailed(
                    "That file changed or is no longer safely readable"
                ))
                return
            }
            NSWorkspace.shared.open(item.asset.url)

        case .save:
            saveAs(item)

        case .annotate:
            openEditor(for: item)

        case .trim:
            guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
                present(error: NotchShotError.exportFailed(
                    "That recording changed after it was added. Add the current file again before trimming."
                ))
                return
            }
            let session = VideoTrimSession(asset: item.asset)
            session.onExport = { [weak self] asset in
                guard let self else { return }
                self.history.record(asset: asset, image: nil)
                self.persistHistory()
                Task {
                    let thumbnail = await VideoThumbnail.make(for: asset.url)
                    self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
                }
            }
            onOpenVideoTrim?(session)

        case .privacyReview:
            openPrivacyReview(for: item)

        case .removeBackground:
            removeBackground(from: item)

        case .bugReport:
            onOpenBugReport?(BugReportSession(asset: item.asset))

        case .ocr:
            Task { await copyRecognizedContent(from: item) }

        case .pin:
            pin(item)

        case .inspect:
            openInspector(for: item.asset)

        case .optimize:
            openSmartExport(for: item.asset)

        case .convert:
            convertShelfItem(item)

        case .share:
            share(item.asset)

        case .quickLook:
            do {
                guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
                    throw NotchShotError.exportFailed(
                        "That file changed or is no longer safely readable"
                    )
                }
                try QuickLookPresenter.shared.present([item.asset.url])
            } catch {
                present(error: error)
            }

        case .rename:
            renameShelfItem(item)

        case .moveTo:
            moveShelfItem(item)

        case .compress:
            compressShelfItem(item)

        case .airDrop:
            sendViaAirDrop(item.asset)

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([item.asset.url])

        case .delete:
            if item.asset.ownership == .externalReference {
                removeShelfItemPermanently(item)
                return
            }
            do {
                if history.entry(id: item.asset.id) != nil {
                    try history.delete(id: item.asset.id, includingFile: true)
                } else {
                    try HistoryRepository.trashCaptureAndCaption(
                        at: item.asset.url,
                        primaryIdentity: item.asset.externalFileIdentity,
                        captionURL: item.asset.captionURL,
                        captionIdentity: item.asset.captionFileIdentity,
                        projectURL: item.asset.projectURL,
                        projectIdentity: item.asset.projectFileIdentity,
                        toleratingMissingPrimary: true
                    )
                }
                removeShelfItemPermanently(item)
            } catch {
                present(error: error)
            }
        }
    }

    public func applicationsThatCanOpen(_ asset: CaptureAsset) -> [URL] {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: asset.url)
            .filter(\.isFileURL)
            .sorted {
                $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                    $1.deletingPathExtension().lastPathComponent
                ) == .orderedAscending
            }
    }

    public func open(_ asset: CaptureAsset, with applicationURL: URL) {
        guard SafeAssetFile.isCurrentAndSafe(asset), applicationURL.isFileURL else {
            present(error: NotchShotError.exportFailed(
                "That file or application is no longer safely available"
            ))
            return
        }
        NSWorkspace.shared.open(
            [asset.url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.present(error: error) }
        }
    }

    // MARK: Shelf file operations

    /// Points the shelf, History, the stack, and "restore last" at a file that
    /// moved.
    ///
    /// A rename is one file-system call and four places that were holding the
    /// old path. Missing any of them leaves a row that opens nothing, so the
    /// update is expressed once, here, rather than at each call site.
    private func relocate(_ item: ShelfItem, to url: URL) {
        item.asset.url = url
        item.asset.ownership = AppPaths.owns(url) ? .managedTemporary : .userDocument
        item.asset.refreshOwnedFileIdentities()
        history.updateLocation(for: item.asset.id, to: url)
        persistHistory()
        if lastDismissed?.asset.id == item.asset.id {
            lastDismissed?.asset.url = url
            lastDismissed?.asset.ownership = item.asset.ownership
            lastDismissed?.asset.refreshOwnedFileIdentities()
        }
        stack.replace(id: item.asset.id, with: item.asset)
        refreshActivity()
    }

    private func renameShelfItem(_ item: ShelfItem) {
        let alert = NSAlert()
        alert.messageText = "Rename Capture"
        alert.informativeText = "The file keeps its extension unless you type a different one."
        let field = NSTextField(string: item.asset.url.deletingPathExtension().lastPathComponent)
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Capture filename")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let renamed = try ShelfFileOperations.rename(item.asset, to: field.stringValue)
            relocate(item, to: renamed)
        } catch {
            present(error: error)
        }
    }

    private func moveShelfItem(_ item: ShelfItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose where to move \(item.asset.url.lastPathComponent)."
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let moved = try ShelfFileOperations.move(item.asset, toFolder: folder)
            relocate(item, to: moved)
        } catch {
            present(error: error)
        }
    }

    private func compressShelfItem(_ item: ShelfItem) {
        compress([item.asset])
    }

    /// Zips the capture stack in one archive when it is collecting, so a
    /// multi-shot flow can be handed over as a single file.
    public func compressStack() {
        guard !stack.isEmpty else {
            present(error: NotchShotError.exportFailed("The stack is empty"))
            return
        }
        compress(stack.items.map(\.asset))
    }

    private func compress(_ assets: [CaptureAsset]) {
        guard !assets.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(ShelfFileOperations.suggestedArchiveName(for: assets)).zip"
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let processingLabel = beginProcessing("Compressing")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(processingLabel) }
            do {
                // Off the main actor: zipping a few full-screen recordings is
                // seconds of work, and the notch has to keep animating through
                // it or the app looks wedged.
                try await Task.detached(priority: .userInitiated) {
                    _ = try ShelfFileOperations.compress(assets, to: url)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.present(error: error)
            }
        }
    }

    /// Hands the file straight to AirDrop rather than to the whole share sheet.
    ///
    /// Falls back to the sheet when AirDrop is unavailable — Wi-Fi off, or a Mac
    /// that has it disabled — because a button that silently does nothing is
    /// worse than one that offers the next best thing.
    public func sendViaAirDrop(_ asset: CaptureAsset) {
        sendViaAirDrop([asset])
    }

    private func sendViaAirDrop(_ assets: [CaptureAsset]) {
        guard !assets.isEmpty, assets.allSatisfy(SafeAssetFile.isCurrentAndSafe) else {
            present(error: NotchShotError.exportFailed(
                "One or more files changed or are no longer safely readable"
            ))
            return
        }
        let items = assets.map(\.url)
        if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: items) {
            airDrop.perform(withItems: items)
            return
        }
        share(assets)
    }

    /// Uses Vision's foreground-instance mask to write a full-size transparent
    /// PNG. The save panel comes first so an expensive on-device analysis never
    /// runs for an operation the user then cancels.
    private func removeBackground(from item: ShelfItem) {
        let source = item.image?.cgImage ?? SafeImageFile.cgImage(for: item.asset)
        guard SafeAssetFile.isCurrentAndSafe(item.asset), let source else {
            present(error: NotchShotError.exportFailed(
                "That image changed or is no longer safely readable"
            ))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ForegroundRemovalService.suggestedFilename(
            for: item.asset.url
        )
        panel.directoryURL = Preferences.shared.outputFolder
        panel.message = "The subject stays in place and the removed background becomes transparent."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let processingLabel = beginProcessing("Removing background on this Mac")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(processingLabel) }
            do {
                let result = try await ForegroundRemovalService.shared.removeBackground(from: source)
                try Task.checkCancellation()
                let captured = CapturedImage(
                    cgImage: result,
                    scale: item.asset.scale,
                    sourceRect: .zero
                )
                _ = try await ImageExport.write(
                    captured,
                    to: url,
                    format: .png,
                    quality: 1
                )
                try Task.checkCancellation()

                let thumbnailImage = await ImageExport.makeThumbnail(from: captured)
                let thumbnail = thumbnailImage.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                let asset = CaptureAsset(
                    url: url,
                    kind: .screenshot,
                    pixelSize: CGSize(width: result.width, height: result.height),
                    scale: item.asset.scale,
                    sourceApplication: item.asset.sourceApplication,
                    sourceApplicationName: item.asset.sourceApplicationName,
                    ownership: AppPaths.owns(url) ? .managedTemporary : .userDocument
                )
                self.history.record(asset: asset, image: result, thumbnail: thumbnailImage)
                self.persistHistory()
                self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: captured))
            } catch is CancellationError {
                // The atomic writer either completed the file or left no
                // partial output. Cancellation needs no user-facing error.
            } catch {
                self.present(error: error)
            }
        }
    }

    private func saveAs(_ item: ShelfItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.asset.url.lastPathComponent
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fileManager = FileManager.default
        let stagingURL = url.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            // A file the user deliberately saved should carry the permissions
            // every other app's Save As produces. The staging copy's default is
            // owner-only, which is right for an app-managed working file and
            // wrong for a screenshot being dropped into a shared folder.
            try SafeAssetFile.copy(
                item.asset,
                to: stagingURL,
                mode: SafeAssetFile.userVisibleMode
            )
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: url)
            }
        } catch {
            present(error: NotchShotError.destinationUnwritable(url.path))
        }
    }

    /// Converts an image to PNG, JPEG, or HEIC without re-capturing.
    ///
    /// Droppy's Convert Droplet is the closest analogue. NotchShot already
    /// optimizes via SmartExport presets; this is the direct format switch the
    /// shelf otherwise lacked — a JPEG for email, an HEIC for size, a PNG for
    /// fidelity — using the same hardened write path as every other export.
    private func convertShelfItem(_ item: ShelfItem) {
        guard item.asset.kind.isImage else {
            present(error: NotchShotError.exportFailed("Only images can be converted"))
            return
        }
        let source = item.image?.cgImage ?? SafeImageFile.cgImage(for: item.asset)
        guard SafeAssetFile.isCurrentAndSafe(item.asset), let source else {
            present(error: NotchShotError.exportFailed("That image changed or is no longer safely readable"))
            return
        }
        let currentFormat: ImageFormat = {
            switch item.asset.url.pathExtension.lowercased() {
            case "jpg", "jpeg": .jpeg
            case "heic", "heif": .heic
            default: .png
            }
        }()

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        for format in ImageFormat.allCases {
            popup.addItem(withTitle: format.title)
            popup.lastItem?.tag = format == .png ? 0 : format == .jpeg ? 1 : 2
        }
        popup.setAccessibilityLabel("Output image format")
        let initialIndex: Int = switch currentFormat {
        case .png: 0
        case .jpeg: 1
        case .heic: 2
        }
        popup.selectItem(at: initialIndex)

        let qualityLabel = NSTextField(labelWithString: "Quality:")
        qualityLabel.font = .systemFont(ofSize: 11)
        let slider = NSSlider(value: 0.92, minValue: 0.5, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.setAccessibilityLabel("Image quality")
        let qualityHint = NSTextField(labelWithString: "for JPEG / HEIC")
        qualityHint.font = .systemFont(ofSize: 10)
        qualityHint.textColor = .secondaryLabelColor

        let qualityStack = NSStackView(views: [qualityLabel, slider, qualityHint])
        qualityStack.orientation = .horizontal
        qualityStack.spacing = 6
        qualityStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        qualityLabel.setContentHuggingPriority(.required, for: .horizontal)
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let formatLabel = NSTextField(labelWithString: "Convert to:")
        formatLabel.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [formatLabel, popup])
        row.orientation = .horizontal
        row.spacing = 8

        let container = NSStackView(views: [row, qualityStack])
        container.orientation = .vertical
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 4, right: 0)

        let alert = NSAlert()
        alert.messageText = "Convert Image"
        alert.informativeText = "Choose the output format. PNG is lossless. JPEG and HEIC use the quality slider. The converted file is added to the shelf alongside the original."
        alert.alertStyle = .informational
        alert.accessoryView = container
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedFormat: ImageFormat = popup.indexOfSelectedItem == 0 ? .png : popup.indexOfSelectedItem == 1 ? .jpeg : .heic
        let quality = slider.doubleValue

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: selectedFormat)]
        let baseName = item.asset.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)-converted.\(selectedFormat.fileExtension)"
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, var url = panel.url else { return }

        // Enforce chosen extension if user typed a different one
        if url.pathExtension.lowercased() != selectedFormat.fileExtension {
            url.deletePathExtension()
            url.appendPathExtension(selectedFormat.fileExtension)
        }

        let processingLabel = beginProcessing("Converting to \(selectedFormat.title)")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(processingLabel) }
            do {
                let usedFormat = try await ImageExport.write(
                    CapturedImage(cgImage: source, scale: item.asset.scale, sourceRect: .zero),
                    to: url,
                    format: selectedFormat,
                    quality: selectedFormat == .png ? 1 : quality
                )
                var finalURL = url
                if usedFormat != selectedFormat {
                    let corrected = url.deletingPathExtension().appendingPathExtension(usedFormat.fileExtension)
                    if FileManager.default.fileExists(atPath: corrected.path) {
                        finalURL = AppPaths.uniqueURL(
                            in: corrected.deletingLastPathComponent(),
                            name: corrected.deletingPathExtension().lastPathComponent,
                            extension: usedFormat.fileExtension
                        )
                        try FileManager.default.moveItem(at: url, to: finalURL)
                    } else {
                        do { try FileManager.default.moveItem(at: url, to: corrected) } catch {}
                        finalURL = corrected
                    }
                }
                guard let cgImage = SafeImageFile.cgImage(at: finalURL, limits: .generated) else {
                    throw NotchShotError.exportFailed("Converted file could not be read back")
                }
                let captured = CapturedImage(cgImage: cgImage, scale: item.asset.scale, sourceRect: .zero)
                let thumbnailImage = await ImageExport.makeThumbnail(from: captured)
                let thumbnail = thumbnailImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                let asset = CaptureAsset(
                    url: finalURL,
                    kind: .screenshot,
                    pixelSize: captured.pixelSize,
                    scale: captured.scale,
                    sourceApplication: item.asset.sourceApplication,
                    sourceApplicationName: item.asset.sourceApplicationName,
                    ownership: AppPaths.owns(finalURL) ? .managedTemporary : .userDocument
                )
                self.history.record(asset: asset, image: cgImage, thumbnail: thumbnailImage)
                self.persistHistory()
                self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: captured))
            } catch is CancellationError {
            } catch {
                self.present(error: error)
            }
        }
    }

    public func copyRecognizedContent(
        from item: ShelfItem,
        format: OCRClipboardFormat = .text
    ) async {
        if let existing = item.ocrResult {
            ImageExport.copyToPasteboard(text: existing.clipboardText(format: format))
            return
        }
        let image = item.image ?? SafeImageFile.capturedImage(for: item.asset)
        guard let image else {
            present(error: NotchShotError.captureFailed("That image could not be read safely"))
            return
        }
        let processingLabel = beginProcessing("Reading text")
        defer { endProcessing(processingLabel) }
        do {
            let result = try await OCRService.shared.recognizeText(in: image)
            item.ocrResult = result
            if result.isEmpty {
                present(error: NotchShotError.captureFailed("No text found"))
            } else {
                ImageExport.copyToPasteboard(text: result.clipboardText(format: format))
            }
        } catch {
            present(error: error)
        }
    }

    public func openDetectedItem(_ item: DetectedItem) {
        guard let url = item.actionURL else {
            ImageExport.copyToPasteboard(text: item.value)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open detected \(item.kind == .qrCode ? "QR link" : "item")?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            ImageExport.copyToPasteboard(text: item.value)
        default:
            break
        }
    }

    private func pin(_ item: ShelfItem) {
        let image: NSImage?
        if let captured = item.image {
            image = captured.makeNSImage()
        } else {
            image = SafeImageFile.nsImage(for: item.asset)
        }
        guard let image else { return }
        FloatingCaptureManager.shared.pin(asset: item.asset, image: image)
    }

    public func share(_ asset: CaptureAsset) {
        share([asset])
    }

    private func share(_ assets: [CaptureAsset]) {
        guard !assets.isEmpty, assets.allSatisfy(SafeAssetFile.isCurrentAndSafe) else {
            present(error: NotchShotError.exportFailed(
                "One or more files changed or are no longer safely readable"
            ))
            return
        }
        do {
            try MacSharePresenter.shared.present(items: assets.map(\.url))
        } catch {
            present(error: error)
        }
    }

    public func openSmartExport(for asset: CaptureAsset) {
        do {
            let session = try SmartExportSession(asset: asset)
            session.onExported = { [weak self] exported in
                self?.history.record(asset: exported, image: nil)
            }
            onOpenSmartExport?(session)
        } catch {
            present(error: error)
        }
    }

    public func openInspector(for asset: CaptureAsset) {
        do {
            onOpenInspector?(try ImageInspectionSession(asset: asset))
        } catch {
            present(error: error)
        }
    }

    public func openEditor(
        for item: ShelfItem,
        afterExport: ((CaptureAsset) -> Void)? = nil
    ) {
        let controller: AnnotationDocumentController
        if let projectURL = item.asset.projectURL,
           let opened = try? AnnotationDocumentController.open(projectAt: projectURL) {
            controller = opened
        } else if let image = item.image {
            controller = AnnotationDocumentController(image: image, asset: item.asset)
        } else if let cgImage = SafeImageFile.cgImage(for: item.asset) {
            let document = AnnotationDocument(
                sourcePixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                sourceScale: item.asset.scale
            )
            controller = AnnotationDocumentController(
                source: cgImage,
                document: document,
                asset: item.asset
            )
        } else {
            present(error: NotchShotError.exportFailed("Can't open that capture for editing"))
            return
        }
        controller.seams = item.seams
        if let afterExport {
            editorExportActions[ObjectIdentifier(controller)] = afterExport
        }
        hideShelf()
        onOpenEditor?(controller)
    }

    public func openEditor(for stackItem: StackItem) {
        openEditor(
            for: ShelfItem(asset: stackItem.asset, thumbnail: nil, image: nil)
        ) { [weak self] exported in
            self?.stack.replace(id: stackItem.id, with: exported)
        }
    }

    public func handleEditorExport(
        from controller: AnnotationDocumentController,
        asset: CaptureAsset
    ) {
        let key = ObjectIdentifier(controller)
        editorExportActions.removeValue(forKey: key)?(asset)
    }

    public func handleEditorProjectSaved(
        from controller: AnnotationDocumentController,
        projectURL: URL
    ) {
        guard let assetID = controller.asset?.id else { return }
        history.updateProject(for: assetID, projectURL: projectURL)
        if let item = shelfItems.first(where: { $0.asset.id == assetID }) {
            item.asset.projectURL = projectURL
            item.asset.refreshOwnedFileIdentities()
        }
        if lastDismissed?.asset.id == assetID {
            lastDismissed?.asset.projectURL = projectURL
            lastDismissed?.asset.refreshOwnedFileIdentities()
        }
    }

    public func discardEditorExportAction(for controller: AnnotationDocumentController) {
        editorExportActions.removeValue(forKey: ObjectIdentifier(controller))
    }

    public func openPrivacyReview(for item: ShelfItem) {
        let source: CGImage?
        if let image = item.image {
            source = image.cgImage
        } else {
            source = SafeImageFile.cgImage(for: item.asset)
        }
        guard let source else {
            present(error: NotchShotError.exportFailed("Can't review that capture"))
            return
        }
        hideShelf()
        onOpenPrivacyReview?(PrivacyReviewSession(asset: item.asset, source: source))
    }

    /// Called only after the user selected privacy findings. The suggested
    /// pixelation remains editable, and no redaction is burned in until export.
    public func applyPrivacySuggestions(
        from session: PrivacyReviewSession,
        findings: [PrivacyFinding]
    ) {
        let document = AnnotationDocument(
            sourcePixelSize: CGSize(width: session.source.width, height: session.source.height),
            sourceScale: session.asset.scale
        )
        let controller = AnnotationDocumentController(
            source: session.source,
            document: document,
            asset: session.asset
        )
        for finding in findings {
            var style = AnnotationStyle.default(
                for: .pixelate,
                baseColorHex: "#000000",
                lineWidth: 0
            )
            style.pixelBlockSize = finding.kind == .face ? 22 : 14
            controller.add(AnnotationElement(
                kind: .pixelate,
                points: [
                    CGPoint(x: finding.rect.minX, y: finding.rect.minY),
                    CGPoint(x: finding.rect.maxX, y: finding.rect.maxY),
                ],
                style: style
            ))
        }
        onOpenEditor?(controller)
    }

    // MARK: Capture stack

    public func toggleStackCollecting() {
        stack.isCollecting.toggle()
        // Starting a stack from an existing result should include that result,
        // otherwise the first shot of the flow is silently missing.
        if stack.isCollecting, stack.isEmpty, let selected = selectedShelfItem,
           selected.asset.kind.isImage {
            stack.add(selected.asset)
        }
        refreshActivity()
    }

    public func addSelectedToStack() {
        guard let selected = selectedShelfItem, selected.asset.kind.isImage else { return }
        stack.add(selected.asset)
        refreshActivity()
    }

    public func exportStack(style: StackExportStyle, numbersSteps: Bool) {
        guard !stack.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [style == .pdf ? .pdf : .png]
        panel.nameFieldStringValue = "\(Preferences.shared.expandFilename(appName: "Stack"))"
            + ".\(style.fileExtension)"
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        arbiter.isProcessing = "Building \(style.title.lowercased())"
        refreshActivity()

        do {
            let options = StackExportOptions(style: style, numbersSteps: numbersSteps)
            _ = try stack.export(to: url, options: options)

            let cgImage = SafeImageFile.cgImage(at: url, limits: .generated)
            let asset = CaptureAsset(
                url: url,
                kind: style == .pdf ? .document : .screenshot,
                pixelSize: cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                scale: style == .pdf ? 1 : 2
            )
            let thumbnailImage = cgImage.flatMap { ImageExport.makeThumbnail(from: $0) }
            history.record(asset: asset, image: cgImage, thumbnail: thumbnailImage)
            // Matches `shareStack` below: the debounced save covers the normal
            // case, but the user has just written a file to a location they
            // chose, and losing its row to a quit inside the debounce window is
            // the one outcome worth paying a synchronous write to avoid.
            persistHistory()

            let thumbnail = thumbnailImage
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }

            arbiter.isProcessing = nil
            stack.clear()
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
        } catch {
            arbiter.isProcessing = nil
            present(error: error)
        }
    }

    public func shareStack(style: StackExportStyle, numbersSteps: Bool = false) {
        guard !stack.isEmpty else { return }
        let url = AppPaths.uniqueURL(
            in: AppPaths.captures,
            name: Preferences.shared.expandFilename(appName: "Capture Session"),
            extension: style.fileExtension
        )
        arbiter.isProcessing = "Building \(style.title.lowercased())"
        refreshActivity()
        do {
            try stack.export(
                to: url,
                options: StackExportOptions(style: style, numbersSteps: numbersSteps)
            )
            let image = SafeImageFile.cgImage(at: url, limits: .generated)
            let asset = CaptureAsset(
                url: url,
                kind: style == .pdf ? .document : .screenshot,
                pixelSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                scale: style == .pdf ? 1 : 2,
                ownership: .managedTemporary
            )
            history.record(asset: asset, image: image)
            persistHistory()
            arbiter.isProcessing = nil
            try MacSharePresenter.shared.present(items: [url])
            refreshActivity()
        } catch {
            arbiter.isProcessing = nil
            present(error: error)
        }
    }

    public func compareFirstTwoStackItems() {
        guard stack.items.count >= 2 else {
            present(error: NotchShotError.exportFailed("Add two captures to the stack first"))
            return
        }
        do {
            let session = try VisualComparisonSession(
                beforeAsset: stack.items[0].asset,
                afterAsset: stack.items[1].asset
            )
            onOpenComparison?(session)
        } catch {
            present(error: error)
        }
    }

    public func openEditor(for entry: HistoryEntry) {
        let item = ShelfItem(asset: entry.asset, thumbnail: nil, image: nil)
        openEditor(for: item)
    }

    // MARK: Documented URL automation

    public func performAutomationCapture(_ command: URLCaptureCommand) {
        guard let baseRecipe = command.presetID.flatMap({ id in
            CaptureRecipeStore.shared.recipes.first(where: { $0.id == id })
        }) ?? Optional(CaptureRecipeStore.shared.activeRecipe) else { return }

        let destination: RecipeDestination = switch command.action {
        case .copy: .clipboardOnly
        case .save: .configuredFolder
        case .annotate, .defaultBehavior: baseRecipe.destination
        }
        let recipe = CaptureRecipe(
            id: baseRecipe.id,
            name: baseRecipe.name,
            detail: baseRecipe.detail,
            outputPixelSize: baseRecipe.outputPixelSize,
            background: baseRecipe.background,
            annotationMode: baseRecipe.annotationMode,
            filenameTemplate: baseRecipe.filenameTemplate,
            destination: destination,
            imageFormat: baseRecipe.imageFormat
        )

        var selectedDisplayID: CGDirectDisplayID?
        if let displayNumber = command.displayNumber {
            let screens = NSScreen.screens.sorted { lhs, rhs in
                if lhs == NSScreen.main { return true }
                if rhs == NSScreen.main { return false }
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                return lhs.frame.minY > rhs.frame.minY
            }
            guard screens.indices.contains(displayNumber - 1) else {
                present(error: NotchShotError.captureFailed(
                    "Display \(displayNumber) is not currently available"
                ))
                return
            }
            selectedDisplayID = ScreenLookup.displayID(for: screens[displayNumber - 1])
        }

        capture(
            command.intent,
            clipboardOnly: command.action == .copy,
            recipe: recipe,
            automationAction: command.action,
            displayID: selectedDisplayID
        )
    }

    public func recognizeClipboard(format: OCRClipboardFormat) {
        // Bounded before the decode, not after it. The dimension guards used to
        // sit below an `NSImage(pasteboard:)` that had already rasterised the
        // whole bitmap, so a single very large copy could cost hundreds of
        // megabytes on the main actor before anything rejected it.
        guard let cgImage = SafeImageFile.cgImage(fromPasteboard: .general) else {
            present(error: NotchShotError.captureFailed(
                "The clipboard does not contain a safely readable image"
            ))
            return
        }
        let processingLabel = beginProcessing("Reading clipboard")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(processingLabel) }
            do {
                let result = try await OCRService.shared.recognizeText(in: CapturedImage(
                    cgImage: cgImage,
                    scale: 1,
                    sourceRect: .zero
                ))
                guard !result.isEmpty else {
                    self.present(error: NotchShotError.captureFailed("No text or code found"))
                    return
                }
                ImageExport.copyToPasteboard(text: result.clipboardText(format: format))
            } catch {
                self.present(error: error)
            }
        }
    }

    public func openLatestCapture() {
        guard let entry = history.recent.first, SafeAssetFile.isCurrentAndSafe(entry.asset) else {
            present(error: NotchShotError.exportFailed("No safely readable recent capture was found"))
            return
        }
        let image = SafeImageFile.capturedImage(for: entry.asset)
        let thumbnail: NSImage?
        if let cgImage = image?.cgImage,
           let rendered = ImageExport.makeThumbnail(from: cgImage) {
            thumbnail = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        } else {
            thumbnail = nil
        }
        push(ShelfItem(asset: entry.asset, thumbnail: thumbnail, image: image))
        arbiter.userExpanded = true
        refreshActivity()
    }

    public func pinExternalFile(_ url: URL) {
        guard let dropped = Self.validatedDropMetadata(at: url), dropped.kind.isImage else {
            present(error: NotchShotError.exportFailed(
                "Only a regular image under 500 MB can be pinned"
            ))
            return
        }
        let asset = CaptureAsset(
            url: dropped.url,
            kind: dropped.kind,
            pixelSize: .zero,
            scale: 1,
            ownership: .externalReference,
            externalFileIdentity: dropped.identity
        )
        let item = ShelfItem(asset: asset, thumbnail: nil, image: nil)
        pin(item)
        loadExternalImagePreview(for: item)
    }

    // MARK: File drop

    /// Files dragged onto the notch land in the shelf, so the notch works as a
    /// staging area for AirDrop and drag-out as well as for captures.
    public func acceptDroppedFiles(_ urls: [URL]) {
        stageExternalFiles(urls, summarizesDocuments: true, forceShowShelf: false)
    }

    /// Performs the destination selected while the Finder drag is still held.
    /// Non-shelf actions validate the whole batch before doing anything so a
    /// partially loaded drag can never AirDrop, share, or archive fewer files
    /// than the user selected without saying so.
    public func performFileDropAction(
        _ action: FileDropAction,
        urls: [URL],
        expectedItemCount: Int
    ) {
        arbiter.isDraggingFiles = false

        guard expectedItemCount > 0, urls.count == expectedItemCount else {
            refreshActivity()
            present(error: NotchShotError.exportFailed(
                "NotchShot could not read every file in that drag. Nothing was changed."
            ))
            return
        }

        if action == .shelf {
            // Choosing Shelf is an explicit park operation. Unlike the legacy
            // generic document drop, it must not turn a PDF into a summary.
            stageExternalFiles(urls, summarizesDocuments: false, forceShowShelf: true)
            return
        }

        guard let assets = validatedExternalAssets(for: urls) else {
            refreshActivity()
            present(error: NotchShotError.exportFailed(
                "Choose regular files under 500 MB. Nothing was changed."
            ))
            return
        }

        refreshActivity()
        switch action {
        case .shelf:
            break
        case .airDrop:
            sendViaAirDrop(assets)
        case .share:
            share(assets)
        case .compress:
            compress(assets)
        }
    }

    /// Finder Services are an explicit request to park the selected files, so
    /// documents stay as shelf references instead of opening the separate
    /// document-summary workflow.
    public func acceptFilesFromFinderService(_ urls: [URL]) {
        stageExternalFiles(urls, summarizesDocuments: false, forceShowShelf: true)
    }

    private func stageExternalFiles(
        _ urls: [URL],
        summarizesDocuments: Bool,
        forceShowShelf: Bool
    ) {
        guard !urls.isEmpty else { return }

        // Explicit park operations (the AirDrop-style Shelf target, Finder
        // Service, and Floating Basket) are transactional: validate the whole
        // batch before the first visible shelf mutation.
        if forceShowShelf {
            guard urls.count <= Self.maximumShelfItems,
                  let assets = validatedExternalAssets(for: urls),
                  assets.count == urls.count else {
                arbiter.isDraggingFiles = false
                refreshActivity()
                present(error: NotchShotError.exportFailed(
                    "Every selected item must be a distinct regular file under 500 MB. Nothing was added."
                ))
                return
            }
            var newItems: [ShelfItem] = []
            newItems.reserveCapacity(assets.count)
            for asset in assets {
                let item = ShelfItem(asset: asset, thumbnail: nil, image: nil)
                newItems.append(item)
                push(item)
            }
            for item in newItems where item.asset.kind.isImage {
                loadExternalImagePreview(for: item)
            }
            arbiter.hasResult = true
            arbiter.isDraggingFiles = false
            refreshActivity()
            return
        }

        var rejected = 0
        // Dropping the extras silently made a batch park look complete when it
        // was not: eight files selected in Finder produced five on the shelf and
        // no indication the other three had gone anywhere.
        let dropped = max(0, urls.count - Self.maximumShelfItems)
        for url in urls.prefix(Self.maximumShelfItems) {
            if summarizesDocuments, DocumentSummaryService.supports(url) {
                summarizeDocument(at: url)
                continue
            }
            guard let dropped = Self.validatedDropMetadata(at: url) else {
                rejected += 1
                continue
            }
            let asset = CaptureAsset(
                url: dropped.url,
                kind: dropped.kind,
                pixelSize: .zero,
                scale: 1,
                ownership: .externalReference,
                externalFileIdentity: dropped.identity
            )
            let item = ShelfItem(asset: asset, thumbnail: nil, image: nil)
            push(item)
            if dropped.kind.isImage {
                loadExternalImagePreview(for: item)
            }
        }
        if rejected > 0 {
            present(error: NotchShotError.exportFailed(
                "Add a regular file under 500 MB"
            ))
        } else if dropped > 0 {
            present(error: NotchShotError.exportFailed(
                "Parked \(Self.maximumShelfItems) of \(urls.count) files — the shelf holds \(Self.maximumShelfItems)"
            ))
        }
        if forceShowShelf, !shelfItems.isEmpty {
            arbiter.hasResult = true
        }
        arbiter.isDraggingFiles = false
        refreshActivity()
    }

    public func summarizeDocument(at url: URL) {
        guard DocumentSummaryService.supports(url) else {
            present(error: NotchShotError.exportFailed(
                "Choose a PDF, text, RTF, Word, HTML, or OpenDocument file"
            ))
            return
        }
        let session = DocumentSummarySession(sourceURL: url)
        session.onStageChange = { [weak self, weak session] stage in
            guard let self else { return }
            switch stage {
            case .validating, .extracting, .recognizingScans, .summarizing:
                self.arbiter.isProcessing = stage.title
                self.refreshActivity()
            case .complete:
                self.arbiter.isProcessing = nil
                let sourceName = session?.result?.sourceName ?? url.lastPathComponent
                self.showContext(ContextSnapshot(
                    kind: .document,
                    title: "Summary ready",
                    subtitle: sourceName,
                    metric: "Done",
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(6),
                    mayInterruptMedia: true
                ))
            case .awaitingConfirmation, .failed:
                self.arbiter.isProcessing = nil
                self.refreshActivity()
            }
        }
        onOpenDocumentSummary?(session)
    }

    public func showContext(_ snapshot: ContextSnapshot) {
        context.present(snapshot)
    }

    public func refreshContextPreferences() { context.refreshPreferences() }

    // MARK: Clipboard

    public func setClipboardEnabled(_ enabled: Bool) {
        Preferences.shared.clipboardEnabled = enabled
        clipboardMonitor.reconcile()
        // Switching it off has to be retroactive, the way turning off capture
        // text search is. A history the user just asked to stop keeping is not
        // something to keep.
        if !enabled {
            clipboard.clear()
            clipboard.removeOrphanedImages()
        }
    }

    /// Puts a stored clipping back on the pasteboard.
    public func useClipboardEntry(_ entry: ClipboardEntry) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clipboardMonitor.copyToPasteboard(entry)
                self.showContext(ContextSnapshot(
                    kind: .document,
                    title: "Copied",
                    subtitle: entry.preview,
                    metric: entry.kind.displayName,
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(2),
                    mayInterruptMedia: false
                ))
            } catch {
                self.present(error: error)
            }
        }
    }

    /// Runs local OCR for one stored clipboard image only after the user asks
    /// for it, then makes that text searchable in the clipboard window.
    public func indexClipboardImageText(_ entry: ClipboardEntry) {
        guard entry.kind == .image, let url = entry.imageURL else {
            present(error: NotchShotError.captureFailed("That clipboard image is no longer readable"))
            return
        }

        let processingLabel = beginProcessing("Recognizing clipboard image on this Mac")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(processingLabel) }
            do {
                guard let image = await Task.detached(priority: .userInitiated, operation: {
                    SafeImageFile.cgImage(at: url, limits: .generated)
                }).value else {
                    throw NotchShotError.captureFailed("That clipboard image is no longer readable")
                }
                let result = try await OCRService.shared.recognizeText(in: CapturedImage(
                    cgImage: image,
                    scale: 1,
                    sourceRect: .zero
                ))
                guard !result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NotchShotError.captureFailed("No readable text was found in that image")
                }
                guard self.clipboard.setRecognizedText(result.fullText, id: entry.id) else {
                    throw NotchShotError.captureFailed("That clipboard entry is no longer available")
                }
                self.showContext(ContextSnapshot(
                    kind: .document,
                    title: "Image text indexed",
                    subtitle: "Search can now find this clipping",
                    metric: "On-device OCR",
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(3),
                    mayInterruptMedia: false
                ))
            } catch {
                self.present(error: error)
            }
        }
    }

    public func copyRecognizedClipboardText(_ entry: ClipboardEntry) {
        guard entry.kind == .image, let text = entry.text, !text.isEmpty else { return }
        clipboardMonitor.copyDerivedTextToPasteboard(text)
        showContext(ContextSnapshot(
            kind: .document,
            title: "Copied image text",
            subtitle: entry.displayTitle,
            metric: "OCR",
            accentHex: "#64D2FF",
            expiresAt: Date().addingTimeInterval(2),
            mayInterruptMedia: false
        ))
    }

    public func revealClipboardFiles(_ entry: ClipboardEntry) {
        do {
            let urls = try ClipboardMonitor.validatedFileURLs(for: entry)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            present(error: error)
        }
    }

    /// Pushes a clipboard entry to the notch shelf — Droppy's most-requested
    /// shelf integration. An image becomes a shelf image, files park as
    /// external references, and text becomes a temporary .txt so the notch can
    /// drag it into Finder, Mail, or an upload field the same way a capture can.
    public func pushClipboardEntryToShelf(_ entry: ClipboardEntry) {
        switch entry.kind {
        case .image:
            guard let url = entry.imageURL else {
                present(error: NotchShotError.exportFailed("That clipboard image is no longer readable"))
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let stamp = formatter.string(from: entry.createdAt)
            let destination = AppPaths.uniqueURL(
                in: AppPaths.captures,
                name: "Clipboard Image \(stamp)",
                extension: "png"
            )
            Task { [weak self] in
                guard let self else { return }
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        guard let cgImage = SafeImageFile.cgImage(at: url, limits: .generated) else {
                            throw NotchShotError.exportFailed(
                                "That clipboard image is no longer readable"
                            )
                        }
                        _ = try ImageExport.write(
                            cgImage,
                            to: destination,
                            format: .png,
                            quality: 1,
                            dpiScale: 2
                        )
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: destination.path
                        )
                        return (cgImage, ImageExport.makeThumbnail(from: cgImage))
                    }.value
                    let cgImage = prepared.0
                    let preparedThumbnail = prepared.1
                let asset = CaptureAsset(
                    url: destination,
                    kind: .screenshot,
                    pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                    scale: 2,
                    sourceApplication: entry.sourceApplicationBundleID,
                    sourceApplicationName: entry.sourceApplicationName,
                    ownership: .managedTemporary
                )
                let thumbnail = preparedThumbnail.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                let captured = CapturedImage(cgImage: cgImage, scale: 2, sourceRect: .zero)
                    self.history.record(asset: asset, image: nil, thumbnail: preparedThumbnail)
                    self.persistHistory()
                    self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: captured))
                    self.arbiter.userExpanded = true
                    self.refreshActivity()
                    self.showContext(ContextSnapshot(
                    kind: .document,
                    title: "Added to Shelf",
                    subtitle: "Clipboard image",
                    metric: "\(cgImage.width) × \(cgImage.height)",
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(2),
                    mayInterruptMedia: false
                    ))
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    self.present(error: error)
                }
            }

        case .files:
            do {
                let urls = try ClipboardMonitor.validatedFileURLs(for: entry)
                performFileDropAction(.shelf, urls: urls, expectedItemCount: urls.count)
                showContext(ContextSnapshot(
                    kind: .document,
                    title: "Added to Shelf",
                    subtitle: entry.preview,
                    metric: "\(urls.count) file\(urls.count == 1 ? "" : "s")",
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(2),
                    mayInterruptMedia: false
                ))
            } catch {
                present(error: error)
            }

        case .text, .link, .color:
            guard let text = entry.text, !text.isEmpty else {
                present(error: NotchShotError.exportFailed("That clipping has no text to place on the shelf"))
                return
            }
            let sanitizedBase = entry.label ?? entry.sourceApplicationName ?? "Clipboard Text"
            let safeBase = ShelfFileOperations.sanitizedName(sanitizedBase) ?? "Clipboard Text"
            let destination = AppPaths.uniqueURL(in: AppPaths.captures, name: safeBase, extension: "txt")
            do {
                try FileManager.default.createDirectory(at: AppPaths.captures, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let asset = CaptureAsset(
                    url: destination,
                    kind: .text,
                    pixelSize: .zero,
                    scale: 1,
                    sourceApplication: entry.sourceApplicationBundleID,
                    sourceApplicationName: entry.sourceApplicationName,
                    ownership: .managedTemporary
                )
                let thumbnail: NSImage? = nil
                history.record(asset: asset, image: nil)
                persistHistory()
                push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
                arbiter.userExpanded = true
                refreshActivity()
                showContext(ContextSnapshot(
                    kind: .document,
                    title: "Added to Shelf",
                    subtitle: entry.displayTitle,
                    metric: entry.kind.displayName,
                    accentHex: "#64D2FF",
                    expiresAt: Date().addingTimeInterval(2),
                    mayInterruptMedia: false
                ))
            } catch {
                present(error: error)
            }
        }
    }

    /// Distinct source apps that have contributed to the current clipboard history, sorted for UI.
    public var clipboardSourceApps: [String] {
        let names = Set(clipboard.entries.compactMap(\.sourceApplicationName))
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func openClipboard() { onOpenClipboard?() }

    public func setContextExpanded(_ expanded: Bool) {
        context.setExpanded(expanded)
        if expanded {
            setPeeking(false)
            windowController?.focusActivePanel()
        }
    }

    public func openCalendarEvent(_ event: CalendarEventSnapshot) {
        context.calendar.open(event)
    }

    public func startFocusTimer(minutes: Int, label: String = "Focus") {
        context.timer.start(duration: TimeInterval(minutes * 60), label: label)
        context.setExpanded(true)
        setPeeking(false)
    }

    public func pauseFocusTimer() { context.timer.pause() }

    public func resumeFocusTimer() { context.timer.resume() }

    public func cancelFocusTimer() { context.timer.cancel() }

    public func startVoiceNote() {
        Task { await context.voiceNotes.start() }
        context.setExpanded(true)
        setPeeking(false)
    }

    public func stopVoiceNote() { context.voiceNotes.stop() }

    public func dismissVoiceNote() { context.voiceNotes.dismiss() }

    public func dismissAIActivity(_ activity: AIActivitySnapshot) {
        context.ai.dismiss(activity)
    }

    public func clearAIActivityHistory() { context.ai.clearHistory() }

    private struct ValidatedDropMetadata: Sendable {
        var url: URL
        var kind: CaptureAssetKind
        var identity: ExternalFileIdentity
    }

    private func validatedExternalAssets(for urls: [URL]) -> [CaptureAsset]? {
        var seen = Set<URL>()
        var assets: [CaptureAsset] = []
        assets.reserveCapacity(urls.count)

        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { continue }
            guard let dropped = Self.validatedDropMetadata(at: standardized) else {
                return nil
            }
            assets.append(CaptureAsset(
                url: dropped.url,
                kind: dropped.kind,
                pixelSize: .zero,
                scale: 1,
                ownership: .externalReference,
                externalFileIdentity: dropped.identity
            ))
        }
        return assets.isEmpty ? nil : assets
    }

    private nonisolated static func validatedDropMetadata(at url: URL) -> ValidatedDropMetadata? {
        guard url.isFileURL else { return nil }
        let resolved = url.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey,
        ]
        guard let values = try? resolved.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount >= 0,
              byteCount <= 500_000_000,
              let type = values.contentType
        else { return nil }
        guard let identity = SafeAssetFile.identity(
            at: resolved,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ) else { return nil }

        let kind: CaptureAssetKind
        if type.conforms(to: .image) {
            kind = .screenshot
        } else if type.conforms(to: .movie) {
            kind = .recording
        } else {
            kind = .document
        }
        return ValidatedDropMetadata(url: resolved, kind: kind, identity: identity)
    }

    private func loadExternalImagePreview(for item: ShelfItem) {
        let asset = item.asset
        guard asset.kind.isImage else { return }
        Task { [weak self, weak item] in
            let result: (CGSize, CGImage)? = await Task.detached(priority: .utility) {
                () -> (CGSize, CGImage)? in
                guard SafeAssetFile.isCurrentAndSafe(asset),
                      let image = SafeImageFile.cgImage(for: asset),
                      let thumbnail = ImageExport.makeThumbnail(from: image) else { return nil }
                return (CGSize(width: image.width, height: image.height), thumbnail)
            }.value
            guard let self, let item, let (pixelSize, thumbnail) = result,
                  item.asset.url == asset.url,
                  item.asset.externalFileIdentity == asset.externalFileIdentity,
                  SafeAssetFile.isCurrentAndSafe(item.asset) else { return }
            item.asset.pixelSize = pixelSize
            item.thumbnail = NSImage(
                cgImage: thumbnail,
                size: NSSize(width: thumbnail.width, height: thumbnail.height)
            )
            self.refreshActivity()
        }
    }

    public func setDraggingFiles(_ dragging: Bool) {
        guard arbiter.isDraggingFiles != dragging else { return }
        arbiter.isDraggingFiles = dragging
        refreshActivity()
    }

    // MARK: Errors

    /// History is an index over already-created capture files. A persistence
    /// failure must be visible, but it must not turn a successful capture or
    /// export into a misleading claim that the underlying file was lost.
    @discardableResult
    private func persistHistory() -> Bool {
        do {
            try history.save()
            return true
        } catch {
            present(error: NotchShotError.exportFailed(
                "The capture was saved, but NotchShot could not update History: \(error.localizedDescription)"
            ))
            return false
        }
    }

    private func ensureScreenRecordingPermission() -> Bool {
        // The value can change while NotchShot is in the background with System
        // Settings open. Re-read the current-process preflight before deciding
        // whether to request or remediate access.
        permissions.refresh()
        if permissions.screenRecording.isUsable { return true }
        let granted = permissions.requestScreenRecordingAccess()
        guard !granted else { return true }

        // Three different situations, three different remedies. "Approved but
        // macOS still says no" is the one that used to be indistinguishable from
        // a plain refusal, which left no way forward.
        if permissions.hasUnstableSigningIdentity {
            // Reported ahead of the two TCC states because it outranks them: an
            // ad-hoc build cannot hold a grant at all, so telling the user to
            // approve or reset one sends them round a loop that cannot end.
            present(error: NotchShotError.unstableSigningIdentity)
        } else if permissions.isScreenRecordingGrantStale {
            present(error: NotchShotError.screenRecordingGrantStale)
        } else {
            present(error: permissions.requiresScreenRecordingRelaunch
                ? NotchShotError.screenRecordingPermissionPending
                : NotchShotError.screenRecordingPermissionDenied)
        }
        return false
    }

    // MARK: Processing label

    /// Claims the single processing slot and hands back the label, so the
    /// matching release can prove it is still the one being shown.
    private func beginProcessing(_ label: String) -> String {
        arbiter.isProcessing = label
        refreshActivity()
        return label
    }

    /// Releases the processing slot only if this operation still owns it.
    ///
    /// There is one slot and several flows that can run at once — compress,
    /// convert, background removal, clipboard OCR. Each of them used to clear
    /// the slot unconditionally on finishing, so the first flow to end wiped
    /// the label belonging to a flow that was still working, and the notch went
    /// blank while the Mac was visibly busy.
    private func endProcessing(_ label: String) {
        guard arbiter.isProcessing == label else { return }
        arbiter.isProcessing = nil
        refreshActivity()
    }

    public func present(error: Error) {
        let message = (error as? NotchShotError)?.notchMessage
            ?? error.localizedDescription
        Log.app.error("\(message)")
        announceForAccessibility(message, priority: .high)

        errorTask?.cancel()
        arbiter.error = message
        refreshActivity()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.arbiter.error = nil
                self?.refreshActivity()
            }
        }
    }

    public func dismissError() {
        errorTask?.cancel()
        arbiter.error = nil
        refreshActivity()
    }

    private func announceForAccessibility(
        _ message: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    private func playCaptureSound() {
        guard Preferences.shared.playsCaptureSound else { return }
        NSSound(named: "Grab")?.play()
    }
}

/// Pulls a poster frame out of a finished recording for the shelf.
enum VideoThumbnail {
    struct Metadata {
        var pixelSize: CGSize
        var duration: TimeInterval
    }

    static func metadata(for url: URL) async -> Metadata? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0 else { return nil }
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return Metadata(
            pixelSize: CGSize(width: abs(transformed.width), height: abs(transformed.height)),
            duration: duration
        )
    }

    static func make(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        // A frame from a little way in avoids the black first frame most
        // screen recordings start with.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(max(duration * 0.1, 0.2), 3), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
