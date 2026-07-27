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
    public private(set) var scrollingFrameCount = 0

    /// True while the pointer is over the island. Peeking never expands the
    /// full interface on its own — that needs a click or a shortcut.
    public var isPeeking = false

    public let media = MediaCoordinator.shared
    public let history = HistoryRepository.shared
    public let permissions = PermissionCenter.shared
    public let systemLevels = SystemLevelMonitor.shared
    public let osd = SystemOSDSuppressor.shared
    public let stack = CaptureStack.shared

    /// Most recent capture the user dismissed, for "restore last".
    private var lastDismissed: ShelfItem?
    private var shelfTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var captureOperationID: UUID?
    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingSessionID: UUID?
    private var errorTask: Task<Void, Never>?
    private var systemLevelTask: Task<Void, Never>?
    private var accessibilityLevelTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartOperationID: UUID?
    private var recordingCompletionTask: Task<Void, Never>?
    private var isPresentingRecordingCancellation = false
    private var editorExportActions: [ObjectIdentifier: (CaptureAsset) -> Void] = [:]
    private var voiceOverObservation: NSKeyValueObservation?

    public var windowController: NotchWindowController?
    public var onOpenEditor: ((AnnotationDocumentController) -> Void)?
    public var onOpenPrivacyReview: ((PrivacyReviewSession) -> Void)?
    public var onOpenBugReport: ((BugReportSession) -> Void)?
    public var onOpenComparison: ((VisualComparisonSession) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?

    /// Up to five results stay in the notch; older ones live in History.
    public static let maximumShelfItems = 5

    public init() {}

    // MARK: Wiring

    public func start() {
        AppPaths.ensureDirectories()
        media.start()
        history.applyRetention()
        history.removeUntrackedManagedFiles()

        RecordingService.shared.onStatusChange = { [weak self] status in
            self?.recordingStatus = status
        }
        RecordingService.shared.onUnexpectedStop = { [weak self] error, recoveryURL in
            Task { await self?.finishRecordingAfterFailure(error, recoveryURL: recoveryURL) }
        }

        systemLevels.onChange = { [weak self] level in
            self?.showSystemLevel(level)
        }
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
        reconcileSystemLevelIntegration()

        // Media presence feeds the arbiter but can never outrank a capture.
        // `observeMedia` re-arms its own tracker, so it must be started exactly
        // once — arming it here as well doubled the trackers on every change.
        observeMedia()
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
        reconcileSystemLevelIntegration()
    }

    public func setNotchEnabled(_ enabled: Bool) {
        Preferences.shared.notchEnabled = enabled
        windowController?.rebuildPanels()
        reconcileSystemLevelIntegration()
    }

    /// Applies the fail-open invariant: native feedback is suppressed only
    /// while a real panel exists and the custom HUD is enabled. VoiceOver keeps
    /// Apple's native feedback because the custom HUD is not yet a complete
    /// accessibility replacement for every system OSD.
    public func reconcileSystemLevelIntegration() {
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
        osd.setEnabled(shouldSuppress)
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
            hasStack: stack.isCollecting || !stack.isEmpty
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

    /// - Parameter clipboardOnly: Copies the result and keeps the file in the
    ///   app's own store rather than the user's output folder. This is what the
    ///   ⌃⇧⌘3 and ⌃⇧⌘4 shortcuts mean, and it overrides the save-to-disk
    ///   preference for this one capture without touching the active recipe.
    public func capture(
        _ intent: CaptureIntent,
        timer: CaptureTimer = .none,
        clipboardOnly: Bool = false
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
        operationID: UUID
    ) async {
        guard isCurrentCapture(operationID), ensureScreenRecordingPermission() else { return }
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
            request.displayID = windowController?.activeDisplayID
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
            operationID: operationID
        )
    }

    private func executeCapture(
        _ request: CaptureRequest,
        intent: CaptureIntent,
        clipboardOnly: Bool = false,
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
            ImageExport.copyToPasteboard(text: result.fullText)
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
            let item = ShelfItem(
                asset: asset,
                thumbnail: ImageExport.makeThumbnail(from: image.cgImage).map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                },
                image: image
            )
            item.ocrResult = result
            history.record(asset: asset, image: image.cgImage, recognizedText: result.fullText)
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
        operationID: UUID? = nil
    ) async {
        do {
            guard operationID.map(isCurrentCapture) ?? true else { return }
            let recipe = CaptureRecipeStore.shared.activeRecipe
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

            let thumbnail = ImageExport.makeThumbnail(from: prepared.cgImage).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            history.record(asset: asset, image: prepared.cgImage)

            let item = ShelfItem(
                asset: asset,
                thumbnail: thumbnail,
                image: prepared,
                stitchWarnings: warnings,
                seams: seams
            )
            push(item)

            switch recipe.annotationMode {
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
        let written = try ImageExport.write(
            image.cgImage,
            to: url,
            format: format,
            quality: preferences.jpegQuality,
            dpiScale: image.scale
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
            let image = CapturedImage(
                cgImage: output.image,
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                sourceRect: .zero
            )
            playCaptureSound()
            Task {
                await finishStillCapture(
                    image,
                    kind: .scrollingScreenshot,
                    sourceApplication: NSWorkspace.shared.frontmostApplication,
                    warnings: output.warnings,
                    seams: output.seams
                )
            }

        case .failedButFramesKept(let reason, let folder):
            scrollingSession = nil
            scrollingSessionID = nil
            arbiter.isProcessing = nil
            present(error: NotchShotError.stitchFailed(reason))
            NSWorkspace.shared.activateFileViewerSelecting([folder])

        case .cancelled:
            scrollingSession = nil
            scrollingSessionID = nil
            scrollingFrameCount = 0
            arbiter.isProcessing = nil
            refreshActivity()
        }
    }

    // MARK: Recording

    public func startRecording(target: RecordingTarget? = nil) {
        guard recordingStartTask == nil,
              recordingCompletionTask == nil,
              !RecordingService.shared.hasActiveSession else { return }
        cancelCaptureWorkflow()
        refreshActivity()

        let operationID = UUID()
        recordingStartOperationID = operationID
        recordingStartTask = Task { [weak self] in
            await self?.beginRecording(target: target, operationID: operationID)
            guard let self, self.recordingStartOperationID == operationID else { return }
            self.recordingStartTask = nil
            self.recordingStartOperationID = nil
        }
    }

    private func beginRecording(target: RecordingTarget?, operationID: UUID) async {
        guard isCurrentRecordingStart(operationID) else { return }
        guard ensureScreenRecordingPermission() else { return }
        collapse()

        var resolvedTarget = target
        if resolvedTarget == nil {
            guard let selection = await runSelection(for: .area) else { return }
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
        guard let resolvedTarget else { return }
        guard isCurrentRecordingStart(operationID) else { return }

        let preferences = Preferences.shared
        let configuration = RecordingConfiguration(
            target: resolvedTarget,
            audioSources: preferences.recordingAudioSources,
            microphoneDeviceID: preferences.preferredMicrophoneID,
            quality: preferences.recordingQuality,
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
        guard RecordingService.shared.isRecording,
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
            var asset = try await RecordingService.shared.stop()
            // Persist the base MP4 before any optional caption or thumbnail
            // await. If the user quits during post-processing, the finished
            // recording is still discoverable on the next launch.
            history.record(asset: asset, image: nil)
            history.save()
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
            history.save()
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            if let captionWarning {
                present(error: NotchShotError.recordingFailed(
                    "The recording was saved, but captions could not be created: \(captionWarning.localizedDescription)"
                ))
            }
        } catch {
            present(error: error)
        }
    }

    public func cancelRecording() {
        guard RecordingService.shared.isRecording,
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
            let retainedURL = await RecordingService.shared.cancel()
            guard let self else { return }
            self.recordingCompletionTask = nil
            self.arbiter.isProcessing = nil
            self.refreshActivity()
            if let retainedURL {
                self.presentRetainedDiscard(at: retainedURL)
            }
        }
    }

    private func presentRetainedDiscard(at url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The recording could not be moved to Trash"
        alert.informativeText = "NotchShot kept the partial recording at \(url.path) so it would not be silently lost. It will not be offered as crash recovery."
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
            history.save()
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
                    history.save()
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
        if stack.isCollecting, item.asset.kind != .recording {
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

        case .save:
            saveAs(item)

        case .annotate:
            openEditor(for: item)

        case .privacyReview:
            openPrivacyReview(for: item)

        case .bugReport:
            onOpenBugReport?(BugReportSession(asset: item.asset))

        case .ocr:
            Task { await copyText(from: item) }

        case .pin:
            pin(item)

        case .airDrop:
            shareViaAirDrop(item)

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
                        captionURL: item.asset.captionURL,
                        projectURL: item.asset.projectURL
                    )
                }
                removeShelfItemPermanently(item)
            } catch {
                present(error: NotchShotError.destinationUnwritable(item.asset.url.path))
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
            try SafeAssetFile.copy(item.asset, to: stagingURL)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: url)
            }
        } catch {
            present(error: NotchShotError.destinationUnwritable(url.path))
        }
    }

    private func copyText(from item: ShelfItem) async {
        if let existing = item.ocrResult {
            ImageExport.copyToPasteboard(text: existing.fullText)
            return
        }
        let image = item.image ?? SafeImageFile.capturedImage(for: item.asset)
        guard let image else {
            present(error: NotchShotError.captureFailed("That image could not be read safely"))
            return
        }
        arbiter.isProcessing = "Reading text"
        refreshActivity()
        defer {
            arbiter.isProcessing = nil
            refreshActivity()
        }
        do {
            let result = try await OCRService.shared.recognizeText(in: image)
            item.ocrResult = result
            if result.isEmpty {
                present(error: NotchShotError.captureFailed("No text found"))
            } else {
                ImageExport.copyToPasteboard(text: result.fullText)
            }
        } catch {
            present(error: error)
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

    private func shareViaAirDrop(_ item: ShelfItem) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            present(error: NotchShotError.exportFailed("AirDrop isn't available"))
            return
        }
        guard SafeAssetFile.isCurrentAndSafe(item.asset),
              service.canPerform(withItems: [item.asset.url]) else {
            present(error: NotchShotError.exportFailed("AirDrop can't send that file"))
            return
        }
        service.perform(withItems: [item.asset.url])
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
        }
        if lastDismissed?.asset.id == assetID {
            lastDismissed?.asset.projectURL = projectURL
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
           selected.asset.kind != .recording {
            stack.add(selected.asset)
        }
        refreshActivity()
    }

    public func addSelectedToStack() {
        guard let selected = selectedShelfItem, selected.asset.kind != .recording else { return }
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
                kind: .screenshot,
                pixelSize: cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                scale: 2
            )
            history.record(asset: asset, image: cgImage)

            let thumbnail = cgImage
                .flatMap { ImageExport.makeThumbnail(from: $0) }
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }

            arbiter.isProcessing = nil
            stack.clear()
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
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

    // MARK: File drop

    /// Files dragged onto the notch land in the shelf, so the notch works as a
    /// staging area for AirDrop and drag-out as well as for captures.
    public func acceptDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var rejected = 0
        for url in urls.prefix(Self.maximumShelfItems) {
            guard let dropped = Self.validatedDroppedFile(at: url) else {
                rejected += 1
                continue
            }
            let asset = CaptureAsset(
                url: dropped.url,
                kind: dropped.kind,
                pixelSize: dropped.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                scale: 1,
                ownership: .externalReference,
                externalFileIdentity: dropped.identity
            )
            let thumbnail = dropped.image
                .flatMap { ImageExport.makeThumbnail(from: $0) }
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
        }
        if rejected > 0 {
            present(error: NotchShotError.exportFailed(
                "Only regular image and movie files under 500 MB can be added to the shelf"
            ))
        }
        arbiter.isDraggingFiles = false
        refreshActivity()
    }

    private struct ValidatedDrop {
        var url: URL
        var kind: CaptureAssetKind
        var image: CGImage?
        var identity: ExternalFileIdentity
    }

    private static func validatedDroppedFile(at url: URL) -> ValidatedDrop? {
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

        if type.conforms(to: .image),
           let image = SafeImageFile.cgImage(at: resolved, limits: .external) {
            return ValidatedDrop(
                url: resolved,
                kind: .screenshot,
                image: image,
                identity: identity
            )
        }
        if type.conforms(to: .movie) {
            return ValidatedDrop(
                url: resolved,
                kind: .recording,
                image: nil,
                identity: identity
            )
        }
        return nil
    }

    public func setDraggingFiles(_ dragging: Bool) {
        guard arbiter.isDraggingFiles != dragging else { return }
        arbiter.isDraggingFiles = dragging
        refreshActivity()
    }

    // MARK: Errors

    private func ensureScreenRecordingPermission() -> Bool {
        if permissions.screenRecording.isUsable { return true }
        let granted = permissions.requestScreenRecordingAccess()
        guard !granted else { return true }

        // Three different situations, three different remedies. "Approved but
        // macOS still says no" is the one that used to be indistinguishable from
        // a plain refusal, which left no way forward.
        if permissions.isScreenRecordingGrantStale {
            present(error: NotchShotError.screenRecordingGrantStale)
        } else {
            present(error: permissions.requiresScreenRecordingRelaunch
                ? NotchShotError.screenRecordingPermissionPending
                : NotchShotError.screenRecordingPermissionDenied)
        }
        return false
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
