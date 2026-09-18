import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppCoordinator {
    // MARK: Dictation

    public func toggleDictation() {
        // Arbitrate: don't start dictation during modal selection/countdown/recording or voice note
        if arbiter.selection != nil || arbiter.countdown != nil || arbiter.isRecording {
            present(error: NotchShotError.recordingFailed("Finish the current capture or recording before starting dictation"))
            return
        }
        if let voiceState = context.voiceNotes.snapshot?.state, voiceState == .recording {
            present(error: NotchShotError.recordingFailed("Finish the current voice note before starting dictation"))
            return
        }
        // Use trigger mode: toggle vs holdToTalk
        // Toggle mode uses Carbon hotkey; hold mode uses event tap. But both can be invoked via toggle.
        if Preferences.shared.dictationTriggerMode == .toggle {
            dictation.toggle()
        } else {
            // Hold-to-talk triggered via toggle shortcut should still toggle (fallback)
            dictation.toggle()
        }
    }

    public func stopDictation() {
        // During permission/model setup there is no audio to finalize; Stop is
        // a cancel, not a failure that reads "No speech detected".
        guard dictation.state.isStoppable else {
            dictation.cancel()
            return
        }
        Task { await dictation.stop() }
    }

    /// Push-to-talk entry point. The coordinator owns cross-feature
    /// exclusivity, so the hotkey must come through here rather than calling
    /// `dictation.handlePushToTalk` directly: otherwise a hold could open the
    /// microphone while a recording is already using it.
    public func handleDictationPushToTalk(pressed: Bool) {
        if pressed {
            if arbiter.selection != nil || arbiter.countdown != nil || arbiter.isRecording
                || RecordingService.shared.hasActiveSession || isRecordingPaused {
                present(error: NotchShotError.recordingFailed(
                    "Finish the current capture or recording before starting dictation"
                ))
                return
            }
            if let voiceState = context.voiceNotes.snapshot?.state, voiceState == .recording {
                present(error: NotchShotError.recordingFailed(
                    "Finish the current voice note before starting dictation"
                ))
                return
            }
        }
        dictation.handlePushToTalk(pressed: pressed)
    }

    public func cancelDictation() {
        dictation.cancel()
    }

    public func handleDictationReturn() {
        Task { await dictation.stop() }
    }

    public func handleDictationEscape() {
        dictation.cancel()
    }

    // MARK: System level HUD

    func showSystemLevel(_ level: SystemLevel) {
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
        reconcileSystemLevelIntegration(requestInputAccess: suppressed)
    }

    public func setNotchEnabled(_ enabled: Bool) {
        Preferences.shared.notchEnabled = enabled
        windowController?.rebuildPanels()
        reconcileSystemLevelIntegration()
    }

    public func setNotchDisplayPlacement(_ placement: NotchDisplayPlacement) {
        Preferences.shared.notchDisplayPlacement = placement
        windowController?.rebuildPanels()
        reconcileSystemLevelIntegration()
    }

    /// Applies the fail-open invariant: native feedback is suppressed only
    /// while a real panel exists and the custom HUD is enabled. VoiceOver keeps
    /// Apple's native feedback because the custom HUD is not yet a complete
    /// accessibility replacement for every system OSD.
    public func reconcileSystemLevelIntegration(requestInputAccess: Bool = false) {
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
        osd.setEnabled(shouldSuppress, requestInputAccess: requestInputAccess)
    }

    func installVoiceOverObservationIfNeeded() {
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

    func refreshActivity() {
        refreshIsland()
        let resolved = arbiter.resolve()
        if resolved != activity {
            activity = resolved
        }
        reconcileSystemNotificationTimer(for: resolved)
        windowController?.update(
            activity: activity,
            isPeeking: isPeeking,
            resultCount: shelfItems.count,
            hasStack: stack.isCollecting || !stack.isEmpty,
            hasMediaContent: media.snapshot.hasContent,
            hasLockedActivityContent: notifications.lockScreenItem() != nil
                || context.timer.current != nil,
            mediaPanelRowCount: mediaPanelRowCount
        )
    }

    // MARK: System notification banners

    public func setSystemNotificationMirroringEnabled(_ enabled: Bool) {
        Preferences.shared.mirrorsSystemNotificationBanners = enabled
        systemNotifications.setEnabled(enabled, requestAccessibility: enabled)
        if !enabled { clearSystemNotifications() }
        refreshActivity()
    }

    public func refreshSystemNotificationMirroringPermission() {
        systemNotifications.refreshPermission()
    }

    public func dismissSystemNotification() {
        systemNotificationTask?.cancel()
        systemNotificationTask = nil
        systemNotificationTaskID = nil
        promoteNextSystemNotification()
        refreshActivity()
    }

    /// Hands the user to the application that posted the visible banner. The
    /// public notification API does not expose another app's reply callback,
    /// so this intentionally opens the real app instead of pretending a reply
    /// was sent from NotchShot.
    public func openSystemNotificationSource(_ snapshot: SystemNotificationSnapshot) {
        let source = SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
        guard SystemNotificationSourceCatalog.activate(source) else { return }
        dismissSystemNotification()
    }

    func receiveSystemNotification(_ snapshot: SystemNotificationSnapshot) {
        guard Preferences.shared.mirrorsSystemNotificationBanners,
              media.isSessionActive else { return }
        guard systemNotificationQueue.enqueue(snapshot) else { return }
        arbiter.systemNotification = systemNotificationQueue.current
        refreshActivity()
    }

    func reconcileSystemNotificationTimer(for resolved: NotchActivity) {
        guard case .systemNotification(let snapshot) = resolved else {
            systemNotificationTask?.cancel()
            systemNotificationTask = nil
            systemNotificationTaskID = nil
            return
        }
        guard systemNotificationTaskID != snapshot.id else { return }

        systemNotificationTask?.cancel()
        systemNotificationTaskID = snapshot.id
        systemNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.arbiter.systemNotification?.id == snapshot.id else { return }
                self.systemNotificationTask = nil
                self.systemNotificationTaskID = nil
                self.promoteNextSystemNotification()
                self.refreshActivity()
            }
        }
    }

    func promoteNextSystemNotification() {
        systemNotificationQueue.advance()
        arbiter.systemNotification = systemNotificationQueue.current
    }

    func clearSystemNotifications() {
        systemNotificationTask?.cancel()
        systemNotificationTask = nil
        systemNotificationTaskID = nil
        systemNotificationQueue.removeAll()
        arbiter.systemNotification = nil
    }

    /// Hover reported by the window controller.
    ///
    /// The delay lives here rather than in the view: it is what stops the notch
    /// flaring open every time the pointer crosses the top of the screen on its
    /// way to the menu bar. Leaving is immediate — a lingering open notch after
    /// the pointer has gone is exactly the "it opened by itself" complaint.
    public func setHovering(_ hovering: Bool) {
        handleIslandHover(hovering)
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

    /// Opens or closes one of the expanded player's lists. Routed through the
    /// coordinator rather than held in the view because the island's height and
    /// its click-through region are both derived from the activity.
    public func setMediaPanel(_ panel: MediaPanelKind, rowCount: Int = 0) {
        let kind = rowCount > 0 ? panel : .none
        let clamped = kind == .none ? 0 : max(1, rowCount)
        guard kind != mediaPanel || clamped != mediaPanelRowCount else { return }
        mediaPanel = kind
        mediaPanelRowCount = clamped
        refreshActivity()
    }

    public func setPeeking(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        // A list left open would otherwise reserve height in a collapsed
        // island, which reads as a stuck, empty gap under the player.
        if !peeking {
            mediaPanel = .none
            mediaPanelRowCount = 0
        }
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

}
