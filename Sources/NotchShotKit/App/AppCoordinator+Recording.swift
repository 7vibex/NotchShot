import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
    // MARK: Recording

    public func startRecording(
        target: RecordingTarget? = nil,
        mode: RecordingTargetMode? = nil
    ) {
        if let dictation = arbiter.dictation, dictation.state != .idle {
            present(error: NotchShotError.recordingFailed("Finish dictation before starting a recording"))
            return
        }
        if let voiceState = context.voiceNotes.snapshot?.state, voiceState == .recording {
            present(error: NotchShotError.recordingFailed(
                "Finish the current voice note before starting a recording"
            ))
            return
        }
        guard recordingStartTask == nil,
              recordingCompletionTask == nil,
              !isRecordingPaused,
              !RecordingService.shared.hasActiveSession else { return }
        recordingSegments.removeAll()
        recordingInteractionSegments.removeAll()
        pendingRecordingInteractionTimeline = nil
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

    func beginRecording(
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
            autoZoomsOnClicks: preferences.recordingAutoZoomsOnClicks,
            smoothsCursor: preferences.recordingSmoothsCursor,
            showsKeystrokes: preferences.recordingShowsKeystrokes,
            showsPresenterCamera: preferences.recordingPresenterCamera,
            framesWithBackground: preferences.recordingFramesWithBackground
        )

        do {
            try await startRecordingPresentation(for: configuration)
            try await RecordingService.shared.start(configuration)
            guard isCurrentRecordingStart(operationID) else {
                await RecordingService.shared.cancel()
                RecordingPresentationOverlayController.shared.stop()
                return
            }
            arbiter.isRecording = true
            recordingUsesSmoothCursor = configuration.smoothsCursor && configuration.showsCursor
            recordingUsesClickZoom = configuration.autoZoomsOnClicks
            RecordingInteractionRecorder.shared.start(configuration: configuration)
            refreshActivity()
        } catch {
            RecordingPresentationOverlayController.shared.stop()
            guard isCurrentRecordingStart(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    func startRecordingPresentation(
        for configuration: RecordingConfiguration
    ) async throws {
        guard configuration.showsPresenterCamera || configuration.showsKeystrokes else { return }
        guard configuration.target.displayID != nil else {
            // A desktop-independent window recording contains exactly one
            // window; ScreenCaptureKit cannot add a second presenter window.
            throw NotchShotError.recordingFailed(
                "Presenter camera and shortcut overlays are available for area and display recordings, not a single-window recording."
            )
        }
        if configuration.showsKeystrokes, !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            guard CGPreflightListenEventAccess() else {
                throw NotchShotError.recordingFailed(
                    "Keyboard shortcut display needs Input Monitoring permission. Turn it on in Privacy & Security, then start the recording again."
                )
            }
        }
        let captureFrame: CGRect? = switch configuration.target {
        case .area(let rect, _):
            ScreenGeometry.cocoaRect(fromCG: rect, primaryFrame: ScreenLookup.primaryFrame)
        case .display, .window:
            nil
        }
        let didStart = await RecordingPresentationOverlayController.shared.start(
            options: RecordingPresentationOptions(
                showsCamera: configuration.showsPresenterCamera,
                showsKeystrokes: configuration.showsKeystrokes
            ),
            displayID: configuration.target.displayID,
            captureFrame: captureFrame
        )
        guard didStart else {
            throw NotchShotError.recordingFailed(
                "The selected recording area is too small to contain the presenter overlay. Choose a larger area or turn the overlay off."
            )
        }
    }

    func isCurrentRecordingStart(_ operationID: UUID) -> Bool {
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

    func finishRecording() async {
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
            // Register the intact base file before optional effects. If an
            // encoder fails, the user's finished recording remains findable.
            history.record(asset: asset, image: nil)
            persistHistory()
            if let timeline = pendingRecordingInteractionTimeline,
               recordingUsesSmoothCursor || recordingUsesClickZoom {
                arbiter.isProcessing = "Smoothing pointer and click zoom"
                refreshActivity()
                try await RecordingEffectsProcessor.process(
                    recordingURL: asset.url,
                    timeline: timeline,
                    smoothsCursor: recordingUsesSmoothCursor,
                    autoZoomsOnClicks: recordingUsesClickZoom
                )
                asset.refreshOwnedFileIdentities()
                history.record(asset: asset, image: nil)
                persistHistory()
            }
            pendingRecordingInteractionTimeline = nil
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
                let interaction = RecordingInteractionRecorder.shared.stop()
                let url = AppPaths.uniqueURL(
                    in: AppPaths.inProgress,
                    name: "Paused Segment",
                    extension: "mp4"
                )
                let segment = try await RecordingService.shared.stop(destination: url)
                RecordingPresentationOverlayController.shared.stop()
                appendInteractionSegment(interaction, duration: segment.duration)
                self.recordingSegments.append(segment)
                self.completedRecordingDuration += segment.duration ?? 0
                self.pausedRecordingConfiguration = configuration
                self.isRecordingPaused = true
                self.recordingStatus.elapsed = self.completedRecordingDuration
                self.recordingCompletionTask = nil
                self.refreshActivity()
            } catch {
                if RecordingService.shared.isRecording {
                    RecordingInteractionRecorder.shared.start(configuration: configuration)
                }
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
                try await self.startRecordingPresentation(for: configuration)
                try await RecordingService.shared.start(configuration)
                RecordingInteractionRecorder.shared.start(configuration: configuration)
                self.isRecordingPaused = false
                self.recordingStartTask = nil
                self.refreshActivity()
            } catch {
                RecordingPresentationOverlayController.shared.stop()
                self.recordingStartTask = nil
                self.present(error: error)
            }
        }
    }

    func finishRecordingSegments() async throws -> CaptureAsset {
        if RecordingService.shared.isRecording {
            let interaction = RecordingInteractionRecorder.shared.stop()
            if recordingSegments.isEmpty {
                let asset = try await RecordingService.shared.stop()
                RecordingPresentationOverlayController.shared.stop()
                appendInteractionSegment(interaction, duration: asset.duration)
                pendingRecordingInteractionTimeline = RecordingInteractionTimeline.joined(
                    recordingInteractionSegments
                )
                recordingInteractionSegments.removeAll()
                return asset
            }
            let url = AppPaths.uniqueURL(
                in: AppPaths.inProgress,
                name: "Paused Segment",
                extension: "mp4"
            )
            let segment = try await RecordingService.shared.stop(destination: url)
            RecordingPresentationOverlayController.shared.stop()
            appendInteractionSegment(interaction, duration: segment.duration)
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
            do {
                try RecordingService.retireCommittedPausedSegments(urls)
            } catch {
                // The joined file is the user's recording; it must not be lost
                // because scratch cleanup failed. Keep the sources out of crash
                // recovery so they are not offered back as a duplicate.
                for url in urls {
                    _ = RecordingService.ensureExcludedFromCrashRecovery(url)
                }
                Log.recording.error(
                    "Could not retire joined recording segments: \(error.localizedDescription)"
                )
            }
        }
        let metadata = await VideoThumbnail.metadata(for: destination)
        pendingRecordingInteractionTimeline = RecordingInteractionTimeline.joined(
            recordingInteractionSegments
        )
        recordingInteractionSegments.removeAll()
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

    func appendInteractionSegment(
        _ timeline: RecordingInteractionTimeline?,
        duration: TimeInterval?
    ) {
        guard var timeline else { return }
        if let duration, duration.isFinite, duration > 0 {
            timeline.duration = duration
        }
        recordingInteractionSegments.append(timeline)
    }

    public func finishRecordingForTermination() async throws -> CaptureAsset? {
        // A user-initiated stop or pause is already finalizing. Join that task
        // first, then fall through: a stop has recorded its asset, while a
        // pause has only parked the final segment into `recordingSegments`
        // and still needs the join below.
        if let completion = recordingCompletionTask {
            await completion.value
        }
        if RecordingService.shared.isRecording {
            return try await finishRecordingSegments()
        }
        // A stop or failure can still own the writer even though the
        // coordinator has no completion task; wait for it to finish first so
        // the join below never competes with it.
        if RecordingService.shared.hasActiveSession,
           let asset = try await RecordingService.shared.finishForTermination() {
            return asset
        }
        guard isRecordingPaused else { return nil }
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
            _ = RecordingInteractionRecorder.shared.stop()
            RecordingPresentationOverlayController.shared.stop()
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
            self.recordingInteractionSegments.removeAll()
            self.pendingRecordingInteractionTimeline = nil
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

    func presentRetainedDiscard(
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

    func finishRecordingAfterFailure(
        _ error: NotchShotError,
        recoveryURL: URL?
    ) async {
        arbiter.isRecording = false
        _ = RecordingInteractionRecorder.shared.stop()
        RecordingPresentationOverlayController.shared.stop()
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

    func presentRecoveryFiles(
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

}
