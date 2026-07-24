import AVFoundation
import AppKit
import CoreMedia
import Observation
import SwiftUI

/// A finished capture sitting in the notch shelf.
@MainActor
@Observable
public final class ShelfItem: Identifiable {
    public let id: UUID
    public var asset: CaptureAsset
    public var thumbnail: NSImage?
    /// Kept in memory so Annotate and OCR don't have to re-read from disk.
    public let image: CapturedImage?
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

    /// Most recent capture the user dismissed, for "restore last".
    private var lastDismissed: ShelfItem?
    private var shelfTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var scrollingSession: ScrollingCaptureSession?
    private var errorTask: Task<Void, Never>?

    public var windowController: NotchWindowController?
    public var onOpenEditor: ((AnnotationDocumentController) -> Void)?
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

        RecordingService.shared.onStatusChange = { [weak self] status in
            self?.recordingStatus = status
        }
        RecordingService.shared.onUnexpectedStop = { [weak self] error in
            Task { await self?.finishRecordingAfterFailure(error) }
        }

        // Media presence feeds the arbiter but can never outrank a capture.
        withObservationTracking {
            _ = media.snapshot.hasContent
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMedia() }
        }
        observeMedia()
        refreshActivity()
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

    private func refreshActivity() {
        let resolved = arbiter.resolve()
        if resolved != activity {
            activity = resolved
        }
        windowController?.update(
            activity: activity,
            isPeeking: isPeeking,
            resultCount: shelfItems.count
        )
    }

    public func setPeeking(_ peeking: Bool) {
        guard Preferences.shared.hoverPeekEnabled else { return }
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        refreshActivity()
    }

    /// Deliberate expansion: click, shortcut, or a drag entering the notch.
    public func toggleExpanded() {
        arbiter.userExpanded.toggle()
        refreshActivity()
    }

    public func collapse() {
        arbiter.userExpanded = false
        refreshActivity()
    }

    // MARK: Capture flow

    public func capture(_ intent: CaptureIntent, timer: CaptureTimer = .none) {
        Task { await performCapture(intent, timer: timer) }
    }

    private func performCapture(_ intent: CaptureIntent, timer: CaptureTimer) async {
        guard ensureScreenRecordingPermission() else { return }
        collapse()

        var request = CaptureRequest(
            intent: intent,
            timer: timer,
            includesCursor: Preferences.shared.includesCursorInScreenshots
        )

        if intent.needsSelection {
            guard let selection = await runSelection(for: intent) else { return }
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

        await executeCapture(request, intent: intent)
    }

    private func executeCapture(_ request: CaptureRequest, intent: CaptureIntent) async {
        arbiter.isProcessing = "Capturing"
        refreshActivity()
        defer {
            arbiter.isProcessing = nil
            refreshActivity()
        }

        // The exclusion set must be read *now*: panels come and go.
        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        let frontmost = NSWorkspace.shared.frontmostApplication

        do {
            let image = try await CaptureService.shared.capture(request, excludedWindows: excluded)

            if intent == .ocr {
                await handleTextCapture(image)
                return
            }

            playCaptureSound()
            await finishStillCapture(
                image,
                kind: .screenshot,
                sourceApplication: frontmost,
                warnings: [],
                seams: []
            )
        } catch {
            present(error: error)
        }
    }

    /// OCR captures never touch the shelf as an image: the point is the text.
    private func handleTextCapture(_ image: CapturedImage) async {
        arbiter.isProcessing = "Reading text"
        refreshActivity()
        do {
            let result = try await OCRService.shared.recognizeText(in: image)
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
            present(error: error)
        }
    }

    private func finishStillCapture(
        _ image: CapturedImage,
        kind: CaptureAssetKind,
        sourceApplication: NSRunningApplication?,
        warnings: [String],
        seams: [StitchSeam]
    ) async {
        do {
            let asset = try await persist(image, kind: kind, sourceApplication: sourceApplication)

            if Preferences.shared.copyToClipboardAfterCapture {
                ImageExport.copyToPasteboard(image.cgImage)
            }

            let thumbnail = ImageExport.makeThumbnail(from: image.cgImage).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            history.record(asset: asset, image: image.cgImage)

            let item = ShelfItem(
                asset: asset,
                thumbnail: thumbnail,
                image: image,
                stitchWarnings: warnings,
                seams: seams
            )
            push(item)
        } catch {
            present(error: error)
        }
    }

    /// Writes the capture to its destination (or the app's own store when
    /// "save to disk" is off, so the shelf always has a real file to drag).
    private func persist(
        _ image: CapturedImage,
        kind: CaptureAssetKind,
        sourceApplication: NSRunningApplication?
    ) async throws -> CaptureAsset {
        let preferences = Preferences.shared
        let appName = sourceApplication?.localizedName
        let name = preferences.expandFilename(appName: appName)
        let folder = preferences.saveToDiskAfterCapture ? preferences.outputFolder : AppPaths.captures

        let format = preferences.imageFormat
        let url = AppPaths.uniqueURL(in: folder, name: name, extension: format.fileExtension)
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
            finalURL = url.deletingPathExtension().appendingPathExtension(written.fileExtension)
            try? FileManager.default.moveItem(at: url, to: finalURL)
        }

        return CaptureAsset(
            url: finalURL,
            kind: kind,
            pixelSize: image.pixelSize,
            scale: image.scale,
            sourceApplication: sourceApplication?.bundleIdentifier,
            sourceApplicationName: appName
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
        countdownTask?.cancel()
        for remaining in stride(from: seconds, through: 1, by: -1) {
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
        return true
    }

    public func cancelCurrentOperation() {
        if SelectionOverlayController.shared.isPresenting {
            SelectionOverlayController.shared.cancel()
        }
        if arbiter.countdown != nil {
            countdownTask?.cancel()
            arbiter.countdown = nil
        }
        if let scrollingSession {
            scrollingSession.cancel()
            self.scrollingSession = nil
        }
        refreshActivity()
    }

    // MARK: Scrolling capture

    private func beginScrollingCapture(region: CGRect) async {
        let session = ScrollingCaptureSession(region: region) { [weak self] event in
            Task { @MainActor in self?.handleScrollingEvent(event) }
        }
        scrollingSession = session
        scrollingFrameCount = 0
        arbiter.isProcessing = "Scroll to capture · Return when done"
        refreshActivity()
        await session.start()
    }

    public func captureScrollingFrame() {
        Task { await scrollingSession?.captureFrameManually() }
    }

    public func finishScrollingCapture() {
        Task { await scrollingSession?.finish() }
    }

    private func handleScrollingEvent(_ event: ScrollingCaptureSession.Event) {
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
            arbiter.isProcessing = nil
            present(error: NotchShotError.stitchFailed(reason))
            NSWorkspace.shared.activateFileViewerSelecting([folder])

        case .cancelled:
            scrollingSession = nil
            arbiter.isProcessing = nil
            refreshActivity()
        }
    }

    // MARK: Recording

    public func startRecording(target: RecordingTarget? = nil) {
        Task { await beginRecording(target: target) }
    }

    private func beginRecording(target: RecordingTarget?) async {
        guard ensureScreenRecordingPermission() else { return }
        collapse()

        var resolvedTarget = target
        if resolvedTarget == nil {
            guard let selection = await runSelection(for: .area) else { return }
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

        let preferences = Preferences.shared
        let configuration = RecordingConfiguration(
            target: resolvedTarget,
            audioSources: preferences.recordingAudioSources,
            microphoneDeviceID: preferences.preferredMicrophoneID,
            quality: preferences.recordingQuality,
            resolution: preferences.recordingResolution,
            framesPerSecond: preferences.recordingFrameRate,
            showsCursor: preferences.recordingShowsCursor,
            highlightsClicks: preferences.recordingHighlightsClicks
        )

        do {
            try await RecordingService.shared.start(configuration)
            arbiter.isRecording = true
            refreshActivity()
        } catch {
            present(error: error)
        }
    }

    public func stopRecording() {
        Task {
            arbiter.isRecording = false
            arbiter.isProcessing = "Finishing recording"
            refreshActivity()
            defer {
                arbiter.isProcessing = nil
                refreshActivity()
            }
            do {
                let asset = try await RecordingService.shared.stop()
                let thumbnail = await VideoThumbnail.make(for: asset.url)
                history.record(
                    asset: asset,
                    image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                )
                push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            } catch {
                present(error: error)
            }
        }
    }

    public func cancelRecording() {
        Task {
            await RecordingService.shared.cancel()
            arbiter.isRecording = false
            refreshActivity()
        }
    }

    public func toggleRecordingMicrophone() {
        Task {
            await RecordingService.shared.setMicrophoneEnabled(!recordingStatus.isMicrophoneEnabled)
        }
    }

    private func finishRecordingAfterFailure(_ error: NotchShotError) async {
        arbiter.isRecording = false
        // The stream died, but the partial file is usually still playable.
        if let orphan = RecordingService.orphanedRecordings().first,
           let asset = try? await RecordingService.shared.recover(orphan) {
            let thumbnail = await VideoThumbnail.make(for: asset.url)
            push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            present(error: NotchShotError.recordingFailed("Recording stopped early — the partial file was kept"))
        } else {
            present(error: error)
        }
    }

    /// Offers to recover recordings a crash left behind.
    public func recoverOrphanedRecordings() {
        let orphans = RecordingService.orphanedRecordings()
        guard !orphans.isEmpty else { return }
        Task {
            for orphan in orphans.prefix(3) {
                guard let asset = try? await RecordingService.shared.recover(orphan) else { continue }
                let thumbnail = await VideoThumbnail.make(for: asset.url)
                history.record(asset: asset, image: nil)
                push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
            }
        }
    }

    // MARK: Shelf

    private func push(_ item: ShelfItem) {
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
        refreshActivity()
    }

    public func dismissShelfItem(_ item: ShelfItem) {
        lastDismissed = item
        shelfItems.removeAll { $0.id == item.id }
        selectedShelfIndex = 0
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
                ImageExport.copyToPasteboard(fileURL: item.asset.url)
            }

        case .save:
            saveAs(item)

        case .annotate:
            openEditor(for: item)

        case .ocr:
            Task { await copyText(from: item) }

        case .pin:
            pin(item)

        case .airDrop:
            shareViaAirDrop(item)

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([item.asset.url])

        case .delete:
            history.delete(id: item.asset.id, includingFile: true)
            dismissShelfItem(item)
        }
    }

    private func saveAs(_ item: ShelfItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.asset.url.lastPathComponent
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: item.asset.url, to: url)
        } catch {
            present(error: NotchShotError.destinationUnwritable(url.path))
        }
    }

    private func copyText(from item: ShelfItem) async {
        if let existing = item.ocrResult {
            ImageExport.copyToPasteboard(text: existing.fullText)
            return
        }
        guard let image = item.image else { return }
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
            image = NSImage(contentsOf: item.asset.url)
        }
        guard let image else { return }
        FloatingCaptureManager.shared.pin(asset: item.asset, image: image)
    }

    private func shareViaAirDrop(_ item: ShelfItem) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            present(error: NotchShotError.exportFailed("AirDrop isn't available"))
            return
        }
        guard service.canPerform(withItems: [item.asset.url]) else {
            present(error: NotchShotError.exportFailed("AirDrop can't send that file"))
            return
        }
        service.perform(withItems: [item.asset.url])
    }

    public func openEditor(for item: ShelfItem) {
        let controller: AnnotationDocumentController
        if let projectURL = item.asset.projectURL,
           let opened = try? AnnotationDocumentController.open(projectAt: projectURL) {
            controller = opened
        } else if let image = item.image {
            controller = AnnotationDocumentController(image: image, asset: item.asset)
        } else if let loaded = NSImage(contentsOf: item.asset.url),
                  let cgImage = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) {
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
        hideShelf()
        onOpenEditor?(controller)
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
        for url in urls.prefix(Self.maximumShelfItems) {
            let image = NSImage(contentsOf: url)
            let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let asset = CaptureAsset(
                url: url,
                kind: url.pathExtension.lowercased() == "mp4" ? .recording : .screenshot,
                pixelSize: cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                scale: 1
            )
            let thumbnail = cgImage
                .flatMap { ImageExport.makeThumbnail(from: $0) }
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            push(ShelfItem(asset: asset, thumbnail: thumbnail ?? image, image: nil))
        }
        arbiter.isDraggingFiles = false
        refreshActivity()
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
        if !granted {
            present(error: NotchShotError.screenRecordingPermissionDenied)
        }
        return granted
    }

    public func present(error: Error) {
        let message = (error as? NotchShotError)?.notchMessage
            ?? error.localizedDescription
        Log.app.error("\(message)")

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
