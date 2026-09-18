import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
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

    func performCapture(
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

        // The timer applies to every intent, including scrolling. It runs
        // after the region is chosen and before the scrolling mode chooser.
        if timer != .none {
            guard await runCountdown(seconds: timer.rawValue, intent: intent) else { return }
        }

        // Scrolling takes over after the region is chosen.
        if intent == .scrolling {
            guard let rect = request.rect else { return }
            guard let mode = chooseScrollingCaptureMode() else { return }
            if mode.isAutomatic, !permissions.accessibilityGranted {
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                guard AXIsProcessTrustedWithOptions(options) else {
                    present(error: NotchShotError.captureFailed(
                        "Automatic scrolling needs Accessibility permission to send scroll events. Manual scrolling still works without it."
                    ))
                    return
                }
            }
            await beginScrollingCapture(region: rect, mode: mode)
            return
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

    func executeCapture(
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
            if request.intent == .area || request.intent == .ocr || request.intent == .scrolling {
                // The service recorded the rect; the menu can now offer Repeat.
                hasPreviousArea = true
            }

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
    func handleTextCapture(_ image: CapturedImage, operationID: UUID) async {
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

    func finishStillCapture(
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
            var prepared = try CaptureRecipeRenderer.render(image, recipe: recipe)
            if let maximumBytes = recipe.targetMaximumBytes, maximumBytes > 0 {
                let format = recipe.imageFormat ?? Preferences.shared.imageFormat
                let fitted = try SmartExportService.renderToFit(
                    prepared.cgImage,
                    maximumBytes: maximumBytes,
                    format: format,
                    quality: Preferences.shared.jpegQuality,
                    dpiScale: prepared.scale
                )
                prepared = CapturedImage(
                    cgImage: fitted,
                    scale: prepared.scale,
                    sourceRect: prepared.sourceRect
                )
            }
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
            let ocrResult = recipe.runsOCR == true
                ? try? await OCRService.shared.recognizeText(in: prepared)
                : nil
            history.record(
                asset: asset,
                image: prepared.cgImage,
                recognizedText: ocrResult?.fullText,
                thumbnail: thumbnailImage
            )
            if !(recipe.libraryTags ?? []).isEmpty
                || recipe.collectionName != nil {
                history.updateLibraryMetadata(
                    id: asset.id,
                    tags: recipe.libraryTags ?? [],
                    collectionName: recipe.collectionName,
                    isFavorite: false
                )
            }

            let item = ShelfItem(
                asset: asset,
                thumbnail: thumbnail,
                image: prepared,
                stitchWarnings: warnings,
                seams: seams
            )
            item.ocrResult = ocrResult
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

    func isCurrentCapture(_ operationID: UUID) -> Bool {
        !Task.isCancelled && captureOperationID == operationID
    }

    func removeCancelledArtifactIfOwned(_ asset: CaptureAsset) {
        guard asset.canBeAutomaticallyRemoved else { return }
        try? FileManager.default.removeItem(at: asset.url)
    }

    /// Writes the capture to its destination (or the app's own store when
    /// "save to disk" is off, so the shelf always has a real file to drag).
    func persist(
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

    func runSelection(for intent: CaptureIntent) async -> SelectionResult? {
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
    func runCountdown(seconds: Int, intent: CaptureIntent) async -> Bool {
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

    func cancelCaptureWorkflow() {
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

    func cancelPendingRecordingStart() {
        guard recordingStartTask != nil else { return }
        recordingStartOperationID = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        if SelectionOverlayController.shared.isPresenting {
            SelectionOverlayController.shared.cancel()
        }
        Task {
            await RecordingService.shared.cancel()
            _ = RecordingInteractionRecorder.shared.stop()
            self.recordingPresentation.stop()
        }
    }

    // MARK: Scrolling capture

    func chooseScrollingCaptureMode() -> ScrollingCaptureMode? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        for mode in ScrollingCaptureMode.allCases {
            popup.addItem(withTitle: mode.title)
        }
        popup.selectItem(at: 1)
        popup.setAccessibilityLabel("Scrolling capture mode")

        let alert = NSAlert()
        alert.messageText = "Choose Scrolling Direction"
        alert.informativeText = "Automatic modes scroll until the content stops changing. Manual modes capture whenever scrolling settles."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Start Capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return ScrollingCaptureMode.allCases[popup.indexOfSelectedItem]
    }

    func beginScrollingCapture(
        region: CGRect,
        mode: ScrollingCaptureMode
    ) async {
        scrollingSession?.cancel()

        let sessionID = UUID()
        scrollingRegion = region
        let session = ScrollingCaptureSession(region: region, mode: mode) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollingEvent(event, sessionID: sessionID)
            }
        }
        scrollingSession = session
        scrollingSessionID = sessionID
        scrollingFrameCount = 0
        arbiter.isProcessing = mode.isAutomatic
            ? "Auto-scrolling \(mode.axis.title.lowercased()) · Return to finish"
            : "Scroll \(mode.axis.title.lowercased()) to capture · Return when done"
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

    func handleScrollingEvent(
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

}
