import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
    // MARK: Shelf

    func push(_ item: ShelfItem) {
        // While the stack is collecting, every capture also joins it, so a
        // multi-step flow can be grabbed without touching the UI between shots.
        if stack.isCollecting, item.asset.kind.isImage, !stack.add(item.asset) {
            presentStackFullError()
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

    /// Brings the shelf back for captures that are still parked on it.
    ///
    /// Until this existed the shelf could only be reached in the seconds after
    /// a capture: dismiss it, or let it time out, and the files were still
    /// there with no way left to see them.
    public func showShelf() {
        guard !shelfItems.isEmpty else { return }
        selectedShelfIndex = min(selectedShelfIndex, max(0, shelfItems.count - 1))
        arbiter.hasResult = true
        // Deliberately *not* on the dismissal timer: a shelf the user opened on
        // purpose should stay until they close it, unlike one that appeared by
        // itself after a capture.
        shelfTimer?.invalidate()
        refreshActivity()
        windowController?.focusActivePanel()
    }

    public var canShowShelf: Bool { !shelfItems.isEmpty }

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

    func removeShelfItemPermanently(_ item: ShelfItem) {
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

    func scheduleShelfDismissal() {
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

        case .localSend:
            guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
                present(error: NotchShotError.exportFailed(
                    "That file changed or is no longer safely readable"
                ))
                return
            }
            openProductivity(tool: .localSend, localSendFiles: [item.asset.url])

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
    /// update is expressed once, here, rather than at each call site. The
    /// relocation carries the exact verified caption that moved with the
    /// recording, or none — never a same-stem subtitle discovered afterwards.
    func relocate(_ item: ShelfItem, to relocation: ShelfFileOperations.RelocatedFile) throws {
        do {
            try history.updateLocation(
                for: item.asset.id,
                to: relocation.url,
                relocatedCaptionURL: relocation.captionURL,
                relocatedCaptionIdentity: relocation.captionIdentity
            )
        } catch {
            // History refused the new state, so put the files back rather than
            // leave the shelf pointing at a path metadata rejects.
            ShelfFileOperations.rollback(relocation, to: item.asset)
            throw error
        }
        item.asset.url = relocation.url
        item.asset.captionURL = relocation.captionURL
        item.asset.ownership = AppPaths.owns(relocation.url) ? .managedTemporary : .userDocument
        item.asset.refreshOwnedFileIdentities()
        persistHistory()
        if lastDismissed?.asset.id == item.asset.id {
            lastDismissed?.asset.url = relocation.url
            lastDismissed?.asset.captionURL = relocation.captionURL
            lastDismissed?.asset.ownership = item.asset.ownership
            lastDismissed?.asset.refreshOwnedFileIdentities()
        }
        stack.replace(id: item.asset.id, with: item.asset)
        refreshActivity()
    }

    func renameShelfItem(_ item: ShelfItem) {
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
            try relocate(item, to: renamed)
        } catch {
            present(error: error)
        }
    }

    func moveShelfItem(_ item: ShelfItem) {
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
            try relocate(item, to: moved)
        } catch {
            present(error: error)
        }
    }

    func compressShelfItem(_ item: ShelfItem) {
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

    func compress(_ assets: [CaptureAsset]) {
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

    func sendViaAirDrop(_ assets: [CaptureAsset]) {
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
    func removeBackground(from item: ShelfItem) {
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

    func saveAs(_ item: ShelfItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.asset.url.lastPathComponent
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fileManager = FileManager.default
        let stagingURL = url.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        guard SafeAssetFile.isCurrentAndSafe(item.asset) else {
            present(error: NotchShotError.exportFailed("The capture file changed or is no longer safely readable"))
            return
        }
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
    func convertShelfItem(_ item: ShelfItem) {
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

    func pin(_ item: ShelfItem) {
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

    func share(_ assets: [CaptureAsset]) {
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

    public func openRecordingExport(for asset: CaptureAsset) {
        guard asset.kind == .recording, SafeAssetFile.isCurrentAndSafe(asset) else {
            present(error: NotchShotError.exportFailed(
                "That recording changed or is no longer safely readable"
            ))
            return
        }
        let session = RecordingExportSession(asset: asset)
        session.onExported = { [weak self] exported in
            self?.history.record(asset: exported, image: nil)
            self?.persistHistory()
        }
        onOpenRecordingExport?(session)
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
           selected.asset.kind.isImage, !stack.add(selected.asset) {
            presentStackFullError()
        }
        refreshActivity()
    }

    public func addSelectedToStack() {
        guard let selected = selectedShelfItem, selected.asset.kind.isImage else { return }
        if !stack.add(selected.asset) { presentStackFullError() }
        refreshActivity()
    }

    /// The menu command is worded "Add Latest Capture to Stack"; use the newest
    /// shelf item rather than whatever happens to be paged into view.
    public func addLatestToStack() {
        guard let latest = shelfItems.first, latest.asset.kind.isImage else { return }
        if !stack.add(latest.asset) { presentStackFullError() }
        refreshActivity()
    }

    public func presentStackFullError() {
        present(error: NotchShotError.captureFailed(
            "The capture stack is full (\(CaptureStack.maximumItems)). Remove a shot before adding another."
        ))
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

}
