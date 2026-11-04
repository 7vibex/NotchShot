import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
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
            imageFormat: baseRecipe.imageFormat,
            targetMaximumBytes: baseRecipe.targetMaximumBytes,
            libraryTags: baseRecipe.libraryTags,
            collectionName: baseRecipe.collectionName,
            runsOCR: baseRecipe.runsOCR
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
        Task { [weak self] in
            // Reading the data can block on the app that owns the pasteboard.
            let image = await ClipboardMonitor.onReadQueue {
                SafeImageFile.cgImage(fromPasteboard: NSPasteboard.general)
            }
            guard let self else { return }
            guard let cgImage = image else {
                self.present(error: NotchShotError.captureFailed(
                    "The clipboard does not contain a safely readable image"
                ))
                return
            }
            let processingLabel = self.beginProcessing("Reading clipboard")
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
        guard !showShelfItem(id: entry.asset.id) else { return }
        let asset = entry.asset
        Task { [weak self] in
            // Reading and downsampling the whole file does not belong on main.
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CapturedImage, CGImage?)? in
                guard let image = SafeImageFile.capturedImage(for: asset) else { return nil }
                return (image, ImageExport.makeThumbnail(from: image.cgImage))
            }.value
            guard let self else { return }
            // A second request can have put it on the shelf during the load.
            guard !self.showShelfItem(id: asset.id) else { return }
            let thumbnail = loaded?.1.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: loaded?.0))
            self.arbiter.userExpanded = true
            self.refreshActivity()
        }
    }

    /// Shows an item already on the shelf. Items are identified by their asset,
    /// so pushing the same one twice would give two rows one identity.
    private func showShelfItem(id: UUID) -> Bool {
        guard let index = shelfItems.firstIndex(where: { $0.id == id }) else { return false }
        selectShelfItem(at: index)
        arbiter.hasResult = Preferences.shared.showsShelfAfterCapture
        arbiter.userExpanded = true
        refreshActivity()
        return true
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
            // Choosing Shelf is an explicit park operation: it must not turn a
            // PDF into a summary.
            stageExternalFiles(urls)
            return
        }

        // Apps are folders and archives may be large, so these skip the
        // regular-file checks that guard sharing.
        switch action {
        case .extract:
            refreshActivity()
            extractArchives(urls)
            return
        case .uninstall, .resetApp:
            refreshActivity()
            beginAppRemoval(urls, mode: action == .uninstall ? .uninstall : .reset)
            return
        default:
            break
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
        case .localSend:
            // Pinned now, at the drop, not when Send is pressed later.
            openProductivity(
                tool: .localSend,
                localSendFiles: assets.compactMap(LocalSendSelection.init(asset:))
            )
        case .compress:
            compress(assets)
        case .extract, .uninstall, .resetApp:
            break
        }
    }

    /// Finder Services are an explicit request to park the selected files, so
    /// documents stay as shelf references instead of opening the separate
    /// document-summary workflow.
    public func acceptFilesFromFinderService(_ urls: [URL]) {
        stageExternalFiles(urls)
    }

    /// Parks files on the shelf. These are explicit operations (the AirDrop-style
    /// Shelf target, Finder Service, and Floating Basket), and transactional:
    /// validate the whole batch before the first visible shelf mutation.
    func stageExternalFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

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
    }

    public func summarizeDocument(at url: URL) {
        guard DocumentSummaryService.supports(url) else {
            present(error: NotchShotError.exportFailed(
                "Choose a PDF, text, RTF, Word, HTML, or OpenDocument file"
            ))
            return
        }
        let session = DocumentSummarySession(sourceURL: url)
        // The label this session holds now: only that one is its to release, so
        // it cannot blank a compress or OCR running alongside it.
        var processingLabel: String?
        session.onStageChange = { [weak self, weak session] stage in
            guard let self else { return }
            switch stage {
            case .validating, .extracting, .recognizingScans, .summarizing:
                processingLabel = self.beginProcessing(stage.title)
            case .complete:
                if let label = processingLabel { self.endProcessing(label) }
                processingLabel = nil
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
                if let label = processingLabel { self.endProcessing(label) }
                processingLabel = nil
                self.refreshActivity()
            }
        }
        onOpenDocumentSummary?(session)
    }

    public func showContext(_ snapshot: ContextSnapshot) {
        context.present(snapshot)
    }

    public func openBatterySettings() {
        guard BatterySettingsService.open() else {
            present(error: NotchShotError.exportFailed("Battery Settings could not be opened"))
            return
        }
    }

    public func openNetworkSettings() {
        guard NetworkSettingsService.open() else {
            present(error: NotchShotError.exportFailed("Network Settings could not be opened"))
            return
        }
        context.dismissTransient()
    }

    /// Closes a context card that carries its own dismiss control.
    public func dismissContextAlert() { context.dismissTransient() }

    public func refreshContextPreferences() { context.refreshPreferences() }

}
