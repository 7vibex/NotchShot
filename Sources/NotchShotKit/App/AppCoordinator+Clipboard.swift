import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
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

    public func setCaptureSpotlightIndexEnabled(_ enabled: Bool) {
        Preferences.shared.indexesCapturesInSpotlight = enabled
        history.refreshSpotlightIndex()
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
    public func openProductivity(
        tool: ProductivityTool = .notes,
        localSendFiles: [URL] = []
    ) {
        ProductivityCenterRouter.shared.route(to: tool, localSendFiles: localSendFiles)
        onOpenProductivity?()
    }

    public func setContextExpanded(_ expanded: Bool) {
        // Inside the multi-activity island, context cards are island
        // activities: their expand and dismiss controls drive the island.
        if isIslandPresenting {
            if expanded { expandIslandPrimary() } else { collapseIsland() }
            return
        }
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
        // One microphone consumer at a time: a recording or dictation must
        // finish first, mirroring the refusal in the other direction.
        if RecordingService.shared.hasActiveSession || arbiter.isRecording || isRecordingPaused {
            present(error: NotchShotError.captureFailed(
                "Finish the current recording before starting a voice note"
            ))
            return
        }
        if let dictation = arbiter.dictation, dictation.state != .idle {
            present(error: NotchShotError.captureFailed(
                "Finish dictation before starting a voice note"
            ))
            return
        }
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

    public func approveClaudePermission(sessionID: String) {
        context.claude.approve(sessionID: sessionID)
    }

    public func denyClaudePermission(sessionID: String, reason: String? = nil) {
        context.claude.deny(sessionID: sessionID, reason: reason)
    }

    struct ValidatedDropMetadata: Sendable {
        var url: URL
        var kind: CaptureAssetKind
        var identity: ExternalFileIdentity
    }

    func validatedExternalAssets(for urls: [URL]) -> [CaptureAsset]? {
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

    nonisolated static func validatedDropMetadata(at url: URL) -> ValidatedDropMetadata? {
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

    func loadExternalImagePreview(for item: ShelfItem) {
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

}
