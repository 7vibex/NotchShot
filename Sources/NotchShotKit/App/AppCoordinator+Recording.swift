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
        guard openDeferredModals == 0 else { return }
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
        recordingStoppedForLowDisk = false
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
                recordingPresentation.stop()
                return
            }
            arbiter.isRecording = true
            recordingUsesSmoothCursor = configuration.smoothsCursor && configuration.showsCursor
            recordingUsesClickZoom = configuration.autoZoomsOnClicks
            RecordingInteractionRecorder.shared.start(configuration: configuration)
            refreshActivity()
        } catch {
            recordingPresentation.stop()
            guard isCurrentRecordingStart(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    /// Stops the presenter overlay once the recording session has ended.
    ///
    /// The overlay belongs to the recording session, not to the success of
    /// file finalization, so a failed finalization still tears it down. A pause
    /// that failed while the writer is still recording is deliberately not
    /// terminal: the presenter is still part of that live recording and stays
    /// until the session really ends.
    ///
    /// - Parameter sessionStillRecording: the writer state when the transition
    ///   resolved. Defaults to the live service state; tests pass an explicit
    ///   value to pin both branches.
    func stopRecordingPresentationIfSessionEnded(sessionStillRecording: Bool? = nil) {
        let stillRecording = sessionStillRecording ?? RecordingService.shared.isRecording
        guard !stillRecording else { return }
        recordingPresentation.stop()
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
        let didStart = await recordingPresentation.start(
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
        var processingLabel = beginProcessing("Finishing recording")
        defer {
            recordingCompletionTask = nil
            endProcessing(processingLabel)
        }
        do {
            var asset = try await finishRecordingSegments()
            // Register the intact base file before optional effects. If an
            // encoder fails, the user's finished recording remains findable.
            history.record(asset: asset, image: nil)
            persistHistory()
            var effectsWarning: Error?
            if let timeline = pendingRecordingInteractionTimeline,
               recordingUsesSmoothCursor || recordingUsesClickZoom {
                processingLabel = beginProcessing("Smoothing pointer and click zoom")
                do {
                    try await RecordingEffectsProcessor.process(
                        recordingURL: asset.url,
                        timeline: timeline,
                        smoothsCursor: recordingUsesSmoothCursor,
                        autoZoomsOnClicks: recordingUsesClickZoom
                    )
                    asset.refreshOwnedFileIdentities()
                    history.record(asset: asset, image: nil)
                    persistHistory()
                } catch {
                    // Effects are optional like captions: the intact base file
                    // still gets its thumbnail and its place on the shelf.
                    effectsWarning = error
                }
            }
            pendingRecordingInteractionTimeline = nil
            var captionWarning: Error?

            if Preferences.shared.recordingGeneratesCaptions {
                processingLabel = beginProcessing("Creating captions on this Mac")
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
            if let effectsWarning {
                present(error: NotchShotError.recordingFailed(
                    "The recording was saved, but its effects could not be applied: \(effectsWarning.localizedDescription)"
                ))
            }
            if let captionWarning {
                present(error: NotchShotError.recordingFailed(
                    "The recording was saved, but captions could not be created: \(captionWarning.localizedDescription)"
                ))
            }
        } catch {
            recordingStoppedForLowDisk = false
            // Parked parts with no live writer: bring the paused island back so
            // Stop can retry the join and Discard stays reachable.
            if !RecordingService.shared.isRecording, !recordingSegments.isEmpty {
                isRecordingPaused = true
                arbiter.isRecording = true
                recordingStatus.elapsed = completedRecordingDuration
            }
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
                // A successful pause parks the session; a failure without a
                // live writer ends it. Both are terminal for the overlay. A
                // failure that leaves the writer recording is not, so the
                // presenter stays on camera.
                defer { self.stopRecordingPresentationIfSessionEnded() }
                let interaction = RecordingInteractionRecorder.shared.stop()
                let url = AppPaths.uniqueURL(
                    in: AppPaths.inProgress,
                    name: "Paused Segment",
                    extension: "mp4"
                )
                let segment = try await RecordingService.shared.stop(destination: url)
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
                } else if !self.recordingSegments.isEmpty {
                    // The writer is gone but earlier parts are parked, so this
                    // is a paused take that Stop can still finish.
                    self.pausedRecordingConfiguration = configuration
                    self.isRecordingPaused = true
                    self.recordingStatus.elapsed = self.completedRecordingDuration
                } else {
                    // No writer and nothing parked: nothing is recording, and
                    // the island must not keep saying so.
                    self.arbiter.isRecording = false
                }
                self.recordingCompletionTask = nil
                self.refreshActivity()
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
                // A cancelled start was already cleared by the canceller, and a
                // newer resume may own the task slot and the overlay by now.
                if !Task.isCancelled { self.recordingStartTask = nil }
                // The session never started, so the overlay must not outlive it.
                if self.recordingStartTask == nil { self.recordingPresentation.stop() }
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.present(error: error)
            }
        }
    }

    func finishRecordingSegments() async throws -> CaptureAsset {
        if RecordingService.shared.isRecording {
            // The writer is ending either way. Tying the presenter overlay to
            // this block means a failed finalization tears it down instead of
            // leaving the camera and keystroke monitors running.
            defer { recordingPresentation.stop() }
            let interaction = RecordingInteractionRecorder.shared.stop()
            if recordingSegments.isEmpty {
                let asset = try await RecordingService.shared.stop()
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
            appendInteractionSegment(interaction, duration: segment.duration)
            recordingSegments.append(segment)
            completedRecordingDuration += segment.duration ?? 0
        }
        guard !recordingSegments.isEmpty else {
            throw NotchShotError.recordingFailed("Nothing is recording")
        }

        let preferences = Preferences.shared
        let folder = preferences.saveToDiskAfterCapture ? preferences.outputFolder : AppPaths.recordings
        var destination = AppPaths.uniqueURL(
            in: folder,
            name: preferences.expandFilename(appName: "Recording"),
            extension: "mp4",
            alsoAvoiding: ["srt"]
        )
        let urls = recordingSegments.map(\.url)
        if urls.count == 1 {
            _ = try await RecordingService.shared.commitPausedSegment(
                from: urls[0],
                to: destination
            )
        } else {
            destination = try await RecordingSegmentJoiner.join(urls, to: destination)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try RecordingService.retireCommittedPausedSegments(urls)
                }.value
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
        // A failed take is joined or recovered there, and its parts can come
        // back parked if the join fails.
        await FileWorkTracker.shared.waitUntilIdle()
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
        // The main queue kept running under the alert, and the stream may have
        // died meanwhile: its parts are being joined, not waiting to be discarded.
        guard recordingCompletionTask == nil,
              RecordingService.shared.isRecording || isRecordingPaused else { return }

        arbiter.isRecording = false
        let processingLabel = beginProcessing("Discarding recording")
        recordingCompletionTask = Task { [weak self] in
            guard let self else { return }
            var retainedURLs: [URL] = []
            if RecordingService.shared.isRecording {
                if let retained = await RecordingService.shared.cancel() {
                    retainedURLs.append(retained)
                }
            }
            _ = RecordingInteractionRecorder.shared.stop()
            self.recordingPresentation.stop()
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
            self.recordingStoppedForLowDisk = false
            self.clearParkedSegments()
            self.recordingCompletionTask = nil
            self.endProcessing(processingLabel)
            if let retainedURL = retainedURLs.first {
                await self.presentRetainedDiscard(
                    at: retainedURL,
                    excludesCrashRecovery: excludesCrashRecovery
                )
            }
        }
    }

    /// Forgets the take's parts. Their files stay where they are, and any still
    /// in InProgress is offered by crash recovery on the next launch.
    func clearParkedSegments() {
        recordingSegments.removeAll()
        recordingInteractionSegments.removeAll()
        pendingRecordingInteractionTimeline = nil
        pausedRecordingConfiguration = nil
        completedRecordingDuration = 0
        isRecordingPaused = false
    }

    func presentRetainedDiscard(
        at url: URL,
        excludesCrashRecovery: Bool
    ) async {
        let alert = retainedDiscardAlert(at: url, excludesCrashRecovery: excludesCrashRecovery)
        let response = await runModalOutsideMainQueue(modes: Self.quitWaitableModalModes) { alert.runModal() }
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Recording flows that quit can join: a `.terminateLater` reply runs the
    /// run loop in the modal panel mode, so a default-mode dialog would never open.
    private static let quitWaitableModalModes: [RunLoop.Mode] = [.default, .modalPanel]

    private func retainedDiscardAlert(
        at url: URL,
        excludesCrashRecovery: Bool
    ) -> NSAlert {
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
        return alert
    }

    func finishRecordingAfterFailure(
        _ error: NotchShotError,
        recoveryURL: URL?
    ) async {
        arbiter.isRecording = false
        let interaction = RecordingInteractionRecorder.shared.stop()
        recordingPresentation.stop()
        recordingStoppedForLowDisk = false
        // A stop that lost the race with this failure may be joining the parts.
        if let completion = recordingCompletionTask {
            await completion.value
        }
        if !recordingSegments.isEmpty {
            // A completion task, so a new recording cannot clear the parts
            // mid-join and quit waits for the join to finish.
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.finishSegmentsAfterFailure(
                    recoveryURL: recoveryURL,
                    interaction: interaction
                )
            }
            recordingCompletionTask = task
            await task.value
            return
        }
        // Recover this exact session. Picking the newest global orphan could
        // move an unrelated file left by an older crash.
        guard let recoveryURL,
              RecordingService.isRecoverableRecording(recoveryURL) else {
            present(error: error)
            return
        }

        do {
            let asset = try await RecordingService.shared.recover(recoveryURL)
            await publishRecoveredRecording(asset)
            present(error: NotchShotError.recordingFailed("Recording stopped early — the partial file was kept"))
        } catch {
            Log.recording.error(
                "Could not recover interrupted recording \(recoveryURL.lastPathComponent): \(error.localizedDescription)"
            )
            await presentRecoveryFiles(
                title: "An interrupted recording needs attention",
                urls: [recoveryURL],
                explanation: "NotchShot could not safely validate or move this recording, so it remains in the recovery folder."
            )
        }
    }

    /// The stream died after a pause and resume. Joins everything recorded so
    /// far, because the last part alone would leave most of the take out. The last
    /// part was validated by the service and is already in InProgress, so it
    /// joins in place; one that failed validation stays there for recovery.
    private func finishSegmentsAfterFailure(
        recoveryURL: URL?,
        interaction: RecordingInteractionTimeline?
    ) async {
        arbiter.isRecording = false
        let processingLabel = beginProcessing("Finishing recording")
        defer {
            recordingCompletionTask = nil
            endProcessing(processingLabel)
        }
        var lastPartKept = false
        if let recoveryURL, RecordingService.isRecoverableRecording(recoveryURL) {
            let metadata = await VideoThumbnail.metadata(for: recoveryURL)
            appendInteractionSegment(interaction, duration: metadata?.duration)
            recordingSegments.append(CaptureAsset(
                url: recoveryURL,
                kind: .recording,
                pixelSize: metadata?.pixelSize ?? .zero,
                scale: 1,
                duration: metadata?.duration,
                ownership: .managedTemporary
            ))
            lastPartKept = true
        }
        do {
            let asset = try await finishRecordingSegments()
            pendingRecordingInteractionTimeline = nil
            await publishRecoveredRecording(asset)
            present(error: NotchShotError.recordingFailed(
                lastPartKept
                    ? "Recording stopped early — the partial file was kept"
                    : "Recording stopped early — the parts before it were kept"
            ))
        } catch {
            Log.recording.error("Could not join interrupted recording: \(error.localizedDescription)")
            let urls = recordingSegments.map(\.url)
            clearParkedSegments()
            await presentRecoveryFiles(
                title: "An interrupted recording needs attention",
                urls: urls,
                explanation: "NotchShot could not join its parts, so they remain in the recovery folder and will be offered again on the next launch."
            )
        }
    }

    private func publishRecoveredRecording(_ asset: CaptureAsset) async {
        history.record(asset: asset, image: nil)
        persistHistory()
        let thumbnail = await VideoThumbnail.make(for: asset.url)
        history.record(
            asset: asset,
            image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
    }

    /// Offers to recover recordings a crash left behind.
    public func recoverOrphanedRecordings() {
        let orphans = RecordingService.orphanedRecordings()
        guard !orphans.isEmpty else { return }
        guard Preferences.shared.historyEnabled
                || Preferences.shared.saveToDiskAfterCapture else {
            presentRecoveryFilesDuringLaunch(
                title: "Interrupted recordings need a save destination",
                urls: orphans,
                explanation: "History and automatic saving are both off, so NotchShot left these files in its recovery folder instead of recovering and later deleting them as untracked data."
            )
            return
        }
        FileWorkTracker.shared.run { [self] in
            var recoveredCount = 0
            var failed: [URL] = []
            var waiting: [URL] = []
            for orphan in orphans {
                guard recoveredCount < 3 else {
                    waiting.append(orphan)
                    continue
                }
                do {
                    let asset = try await RecordingService.shared.recover(orphan)
                    recoveredCount += 1
                    await publishRecoveredRecording(asset)
                } catch {
                    failed.append(orphan)
                    Log.recording.error(
                        "Could not recover \(orphan.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            if !failed.isEmpty || !waiting.isEmpty {
                var reasons: [String] = []
                if !failed.isEmpty {
                    reasons.append("Some remain in NotchShot’s recovery folder because validation or export did not complete.")
                }
                if !waiting.isEmpty {
                    reasons.append("NotchShot recovers three at each launch, so the rest wait in that folder for the next one.")
                }
                await presentRecoveryFiles(
                    title: "Some interrupted recordings need attention",
                    urls: failed + waiting,
                    explanation: reasons.joined(separator: " ")
                )
            }
        }
    }

    func presentRecoveryFiles(
        title: String,
        urls: [URL],
        explanation: String
    ) async {
        let alert = recoveryFilesAlert(title: title, urls: urls, explanation: explanation)
        let response = await runModalOutsideMainQueue(modes: Self.quitWaitableModalModes) { alert.runModal() }
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .alertThirdButtonReturn:
            if let kept = discardRecoveryFiles(urls) {
                await presentRetainedDiscard(at: kept.url, excludesCrashRecovery: kept.excludesCrashRecovery)
            }
        default:
            break
        }
    }

    /// The launch path has no Task and holds launch until this is answered, as
    /// it always has: onboarding and first-capture resume wait behind it.
    private func presentRecoveryFilesDuringLaunch(
        title: String,
        urls: [URL],
        explanation: String
    ) {
        switch recoveryFilesAlert(title: title, urls: urls, explanation: explanation).runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .alertThirdButtonReturn:
            if let kept = discardRecoveryFiles(urls) {
                let alert = retainedDiscardAlert(at: kept.url, excludesCrashRecovery: kept.excludesCrashRecovery)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([kept.url])
                }
            }
        default:
            break
        }
    }

    private func recoveryFilesAlert(
        title: String,
        urls: [URL],
        explanation: String
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "\(explanation) \(urls.count) file(s) are still present."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Move to Trash")
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }

    /// A file that never validates would otherwise bring this alert back on
    /// every launch. Uses the same disposition as discarding a live recording.
    /// Returns what could not be moved, for the caller to report.
    private func discardRecoveryFiles(_ urls: [URL]) -> (url: URL, excludesCrashRecovery: Bool)? {
        var retained: [URL] = []
        for url in urls {
            if let kept = RecordingService.shared.discardScratchRecording(
                url,
                discardedDirectory: AppPaths.discardedRecordings
            ) {
                retained.append(kept)
            }
        }
        guard let first = retained.first else { return nil }
        var excludesCrashRecovery = true
        for url in retained where !RecordingService.ensureExcludedFromCrashRecovery(url) {
            excludesCrashRecovery = false
        }
        return (first, excludesCrashRecovery)
    }

}
