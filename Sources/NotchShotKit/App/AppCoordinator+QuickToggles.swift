import AppKit
import Foundation

/// The menu bar's Quick Toggles: Keep Awake, Clean Keyboard, Instant Replay
/// and the break nudges. Each runs on its own; this wires them to the notch.
extension AppCoordinator {
    func startQuickToggles() {
        // Coalesced: `refreshActivity` itself feeds these controllers, and a
        // direct refresh from their callbacks would run one inside another.
        let keepAwake = KeepAwakeController.shared
        keepAwake.onChange = { [weak self] in self?.scheduleIslandRefresh() }
        keepAwake.onExpire = { [weak self] in
            self?.presentIslandEvent(IslandTransientEvent(
                kind: .keepAwake,
                symbolName: "moon.zzz.fill",
                title: "Keep Awake ended",
                detail: "The Mac can sleep again"
            ))
        }

        let keyboard = KeyboardCleaningController.shared
        keyboard.onChange = { [weak self] in
            guard let self else { return }
            self.scheduleIslandRefresh()
            if !keyboard.isActive {
                self.presentIslandEvent(IslandTransientEvent(
                    kind: .keyboardLock,
                    severity: .success,
                    symbolName: "keyboard.fill",
                    title: "Keyboard unlocked"
                ))
            }
        }

        let replay = InstantReplayController.shared
        replay.onChange = { [weak self] in self?.scheduleIslandRefresh() }
        replay.onFailure = { [weak self] message in
            self?.present(error: NotchShotError.recordingFailed(message))
        }
        replay.start()

        let mixer = AppVolumeMixer.shared
        mixer.onFailure = { [weak self] message in
            self?.present(error: NotchShotError.exportFailed(message))
        }
        mixer.reconcileEnabled()

        wellbeing.onNudgeDue = { [weak self] kind in
            self?.presentIslandEvent(IslandTransientEvent(
                kind: .nudge,
                coalescingKey: "nudge",
                symbolName: kind.symbolName,
                title: kind.title,
                detail: kind.detail,
                holdDuration: 6
            ))
        }
        wellbeing.canNudge = { [weak self] in self?.canShowBreakNudge ?? false }
    }

    /// Fed from `refreshActivity`, which runs on every recording and agent
    /// change: the replay buffer steps aside for a recording, and the agent
    /// Keep Awake mode follows whether any agent is working.
    func syncQuickToggleInputs() {
        InstantReplayController.shared.setRecordingActive(isRecordingActive || RecordingService.shared.isRecording)
        KeepAwakeController.shared.setAgentsWorking(
            context.islandAIActivities.contains { $0.state == .working }
        )
    }

    /// A nudge never lands in the middle of a call or a recording.
    var canShowBreakNudge: Bool {
        guard !isRecordingActive, !RecordingService.shared.isRecording else { return false }
        let privacy = context.privacy
        if privacy.cameraInUse { return false }
        return !privacy.microphoneClients.contains { CallActivityPolicy.isCall(bundleIdentifier: $0.bundleIdentifier) }
    }

    // MARK: Keep Awake

    public func turnOnKeepAwake(_ choice: KeepAwakeChoice) {
        KeepAwakeController.shared.turnOn(choice)
        presentIslandEvent(IslandTransientEvent(
            kind: .keepAwake,
            symbolName: "cup.and.heat.waves.fill",
            title: "Keeping the Mac awake",
            detail: choice == .whileAgentsWork ? "While an agent is working" : choice.title
        ))
    }

    public func turnOffKeepAwake() {
        guard KeepAwakeController.shared.isOn else { return }
        KeepAwakeController.shared.turnOff()
        presentIslandEvent(IslandTransientEvent(
            kind: .keepAwake,
            symbolName: "moon.zzz.fill",
            title: "Keep Awake off"
        ))
    }

    // MARK: Clean Keyboard

    public func startKeyboardCleaning() {
        do {
            try KeyboardCleaningController.shared.start()
            presentIslandEvent(IslandTransientEvent(
                kind: .keyboardLock,
                symbolName: "keyboard.badge.ellipsis",
                title: "Keyboard locked for a minute",
                detail: "Wipe away. Click the menu bar icon to end early",
                holdDuration: 4
            ))
        } catch {
            present(error: error)
        }
    }

    public func stopKeyboardCleaning() {
        KeyboardCleaningController.shared.stop()
    }

    // MARK: Instant Replay

    public func setInstantReplayEnabled(_ enabled: Bool) {
        ExtrasPreferences.shared.instantReplayEnabled = enabled
        InstantReplayController.shared.refresh(userInitiated: enabled)
    }

    /// Saves what the replay buffer holds as a recording, the same way a
    /// finished recording is saved: same folder, history and shelf.
    public func saveInstantReplay() {
        let replay = InstantReplayController.shared
        guard !replay.isSaving else { return }
        guard replay.isBuffering else {
            present(error: InstantReplayController.SaveError.notBuffering)
            return
        }
        let label = beginProcessing("Saving Instant Replay…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(label) }
            let preferences = Preferences.shared
            let folder = preferences.saveToDiskAfterCapture ? preferences.outputFolder : AppPaths.recordings
            let destination = AppPaths.uniqueURL(
                in: folder,
                name: preferences.expandFilename(appName: "Instant Replay"),
                extension: "mp4"
            )
            do {
                let duration = try await replay.save(to: destination)
                let metadata = await VideoThumbnail.metadata(for: destination)
                let asset = CaptureAsset(
                    url: destination,
                    kind: .recording,
                    pixelSize: metadata?.pixelSize ?? .zero,
                    scale: 1,
                    duration: metadata?.duration ?? duration,
                    ownership: AppPaths.owns(destination) ? .managedTemporary : .userDocument
                )
                let thumbnail = await VideoThumbnail.make(for: destination)
                self.history.record(
                    asset: asset,
                    image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                )
                self.persistHistory()
                self.push(ShelfItem(asset: asset, thumbnail: thumbnail, image: nil))
                self.presentIslandEvent(IslandTransientEvent(
                    kind: .replay,
                    severity: .success,
                    symbolName: "record.circle",
                    title: "Saved the last \(Int(duration.rounded())) seconds"
                ))
            } catch {
                self.present(error: error)
            }
        }
    }
}

// MARK: App volume

extension AppCoordinator {
    public func setAppVolumesEnabled(_ enabled: Bool) {
        ExtrasPreferences.shared.appVolumesEnabled = enabled
        AppVolumeMixer.shared.reconcileEnabled()
    }
}

// MARK: Unlock

extension AppCoordinator {
    /// The padlock opening in the notch, the moment the Mac unlocks. Waits
    /// a beat for the desktop to come back, or it plays behind the fade.
    func presentUnlockAnimation() {
        guard ExtrasPreferences.shared.showsUnlockAnimation else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !self.media.isScreenLocked else { return }
            self.presentIslandEvent(IslandTransientEvent(
                kind: .unlock,
                symbolName: "lock.open.fill",
                title: "Unlocked",
                holdDuration: 1.4
            ))
        }
    }
}
