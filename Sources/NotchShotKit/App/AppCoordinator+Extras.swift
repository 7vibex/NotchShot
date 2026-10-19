import Foundation

/// Actions for the newer notch features that run from the island itself.
extension AppCoordinator {
    /// Runs a pinned shortcut and reports how it went on the island, with
    /// any text the shortcut returned as the detail line.
    public func runShortcut(named name: String) {
        let label = beginProcessing("Running \(name)…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.endProcessing(label) }
            do {
                let output = try await ShortcutsService.run(name)
                self.presentIslandEvent(IslandTransientEvent(
                    kind: .notice,
                    severity: .success,
                    coalescingKey: "shortcut",
                    symbolName: "square.stack.3d.up.fill",
                    title: name,
                    detail: output.map { String($0.prefix(120)) } ?? "Finished"
                ))
            } catch {
                self.present(error: error)
            }
        }
    }

    // MARK: Meeting controls

    /// Toggles the call's microphone: the app's own shortcut when it has one,
    /// otherwise the system input mute.
    public func toggleMeetingMute(_ id: IslandActivityID) {
        let bundleIdentifier = id.key
        Task { [weak self] in
            guard let self else { return }
            if let profile = MeetingControls.profile(for: bundleIdentifier) {
                if await MeetingControls.send(profile.mute, to: bundleIdentifier) {
                    self.meetingMutedApps.formSymmetricDifference([bundleIdentifier])
                } else {
                    self.present(error: NotchShotError.exportFailed("Couldn't reach \(profile.name). NotchShot needs Accessibility to press its mute shortcut."))
                }
                return
            }
            let muted = MeetingControls.isSystemInputMuted() ?? false
            if MeetingControls.setSystemInputMuted(!muted) {
                self.systemInputMuted = !muted
                self.presentIslandEvent(IslandTransientEvent(
                    kind: .notice,
                    coalescingKey: "meetingMute",
                    symbolName: muted ? "mic.fill" : "mic.slash.fill",
                    title: muted ? "Microphone on" : "Microphone muted",
                    detail: "For every app"
                ))
            } else {
                self.present(error: NotchShotError.exportFailed("This microphone has no mute control. Mute from the call app instead."))
            }
        }
    }

    public func toggleMeetingCamera(_ id: IslandActivityID) {
        let bundleIdentifier = id.key
        guard let profile = MeetingControls.profile(for: bundleIdentifier), let camera = profile.camera else { return }
        Task { [weak self] in
            guard let self else { return }
            if await MeetingControls.send(camera, to: bundleIdentifier) {
                self.meetingCameraOffApps.formSymmetricDifference([bundleIdentifier])
            } else {
                self.present(error: NotchShotError.exportFailed("Couldn't reach \(profile.name). NotchShot needs Accessibility to press its camera shortcut."))
            }
        }
    }

    /// Whether the island should draw the call's mic as muted. App state is
    /// tracked from the toggles NotchShot sent, since apps don't publish it.
    public func isMeetingMuted(_ id: IslandActivityID) -> Bool {
        MeetingControls.profile(for: id.key) == nil ? systemInputMuted : meetingMutedApps.contains(id.key)
    }
}
