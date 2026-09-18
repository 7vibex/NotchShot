import AppKit
import Foundation
import NotchShotAIReporterSupport
import Observation

/// The multi-activity island: collecting activities from every source, feeding
/// the presentation engine, user intent (select, expand, swipe), bursts, and
/// the services that only exist for the island (external activities, Focus).
@MainActor
extension AppCoordinator {

    // MARK: State

    var isIslandEnabled: Bool { Preferences.shared.multipleActivitiesEnabled }

    /// True while the notch is currently presenting the island.
    public var isIslandPresenting: Bool {
        if case .island = activity { return true }
        return false
    }

    /// A recording is what the notch is presenting — on its own or inside the
    /// island — so a stop shortcut stops it rather than cancelling a capture
    /// that is modally above it.
    public var isRecordingActive: Bool {
        switch activity {
        case .recording: true
        case .island(let descriptor): descriptor.containsRecording
        default: false
        }
    }

    // MARK: Lifecycle

    func startIsland() {
        transfers.onChange = { [weak self] in self?.scheduleIslandRefresh() }
        transfers.onFinish = { [weak self] transfer in self?.transferDidFinish(transfer) }
        externalActivities.onChange = { [weak self] in self?.scheduleIslandRefresh() }
        externalActivities.onOutcome = { [weak self] activity in self?.externalActivityDidFinish(activity) }
        focusStatus.onTransition = { [weak self] focused in self?.focusDidChange(focused) }
        if islandGestureCoordinator == nil {
            islandGestureCoordinator = IslandGestureCoordinator(coordinator: self)
        }
        refreshIslandServices()
        observeIslandSources()
    }

    /// Re-applies island preferences: services, gesture monitor, and layout.
    public func refreshIslandServices() {
        let preferences = Preferences.shared
        if preferences.multipleActivitiesEnabled, preferences.externalActivitiesEnabled {
            externalActivities.start()
        } else {
            externalActivities.stop()
        }
        if preferences.multipleActivitiesEnabled, preferences.showsFocusEvents {
            focusStatus.start()
        } else {
            focusStatus.stop()
        }
        if preferences.multipleActivitiesEnabled, preferences.swipesBetweenActivities {
            islandGestureCoordinator?.start()
        } else {
            islandGestureCoordinator?.stop()
        }
        if !preferences.multipleActivitiesEnabled {
            islandEngine = IslandPresentationEngine()
            islandEvents.removeAll()
            islandExpiryTask?.cancel()
            islandEventTask?.cancel()
            islandCollapseTask?.cancel()
        }
        refreshActivity()
    }

    func stopIslandServices() {
        externalActivities.stop()
        focusStatus.stop()
        islandGestureCoordinator?.stop()
    }

    /// Sources that change without passing through `refreshActivity` on their
    /// own. Event-driven; nothing here polls.
    ///
    /// Transfers are deliberately absent: the store publishes through
    /// `onChange`, so tracking its observable `transfers` array directly would
    /// let raw progress mutations schedule refreshes the store intentionally
    /// throttled.
    func observeIslandSources() {
        withObservationTracking {
            _ = context.ai.snapshot
            _ = context.claude.sessions
            _ = context.timer.current
            _ = context.voiceNotes.snapshot
            _ = isRecordingPaused
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleIslandRefresh()
                self?.observeIslandSources()
            }
        }
    }

    /// Coalesces bursts of source changes into one refresh per run-loop turn.
    func scheduleIslandRefresh() {
        guard !islandRefreshScheduled else { return }
        islandRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.islandRefreshScheduled = false
            self.refreshActivity()
        }
    }

    // MARK: Resolution

    /// Rebuilds the activity set, resolves the presentation, and hands the
    /// arbiter the island's structural descriptor. Called from
    /// `refreshActivity`, before the arbiter resolves.
    func refreshIsland(now: Date = Date()) {
        let preferences = Preferences.shared
        arbiter.islandOwnsAmbientActivities = preferences.multipleActivitiesEnabled
        arbiter.allowsContextOverlay = preferences.allowsAlertsOverActivities
        guard preferences.multipleActivitiesEnabled else {
            if arbiter.island != nil { arbiter.island = nil }
            if islandPresentation != .empty { islandPresentation = .empty }
            return
        }

        islandEngine.sync(collectIslandActivities(now: now), now: now)
        islandEvents.expire(now: now)

        var presentation = islandEngine.present(
            configuration: IslandEngineConfiguration(
                maximumVisibleActivities: preferences.maximumVisibleActivities,
                expandsOnHover: preferences.hoverPeekEnabled
            ),
            isHoverPreviewing: isPeeking && media.isSessionActive,
            now: now
        )
        presentation.transientOverlay = resolveIslandOverlay(
            hasPrimary: presentation.primary != nil,
            isExpanded: presentation.level == .expanded
        )

        if presentation != islandPresentation {
            islandPresentation = presentation
        }

        let descriptor = presentation.descriptor(
            overlayDisplayID: {
                if case .systemLevel(let level) = presentation.transientOverlay { return level.displayID }
                return nil
            }()
        )
        let island: IslandLayoutDescriptor? = descriptor.hasPrimary || descriptor.overlay != nil
            ? descriptor
            : nil
        if arbiter.island != island { arbiter.island = island }
        scheduleIslandExpiry()
    }

    /// Same precedence the arbiter applies: a level HUD, then an interrupting
    /// transient card, then a burst. Without a primary, level and context
    /// cards keep their legacy presentation and only bursts use the island.
    func resolveIslandOverlay(hasPrimary: Bool, isExpanded: Bool) -> IslandOverlay? {
        if hasPrimary {
            if let level = arbiter.systemLevel { return .systemLevel(level) }
            if let context = arbiter.context,
               arbiter.allowsContextOverlay,
               ActivityArbiter.isTransientContext(context),
               context.mayInterruptMedia,
               !isExpanded {
                return .context(context)
            }
        }
        return islandEvents.current.map { .event($0) }
    }

    func collectIslandActivities(now: Date) -> [IslandActivity] {
        let preferences = Preferences.shared
        var activities: [IslandActivity] = []

        if arbiter.isRecording {
            let startedAt = recordingActivityStartedAt ?? now
            recordingActivityStartedAt = startedAt
            activities.append(IslandActivityAdapters.recording(
                status: recordingStatus,
                isPaused: isRecordingPaused,
                startedAt: startedAt
            ))
        } else {
            recordingActivityStartedAt = nil
        }

        if let note = context.voiceNotes.snapshot,
           let activity = IslandActivityAdapters.voiceNote(
               note,
               expiresAt: context.voiceNoteContextSnapshot?.expiresAt,
               now: now
           ) {
            activities.append(activity)
        }

        if preferences.showsMediaActivity, media.snapshot.hasContent {
            let startedAt = mediaActivityStartedAt ?? now
            mediaActivityStartedAt = startedAt
            if let activity = IslandActivityAdapters.media(media.snapshot, startedAt: startedAt) {
                activities.append(activity)
            }
        } else {
            mediaActivityStartedAt = nil
        }

        if preferences.showsTimerActivity, let timer = context.timer.current {
            activities.append(IslandActivityAdapters.timer(
                timer,
                expiresAt: context.timerContextSnapshot?.expiresAt,
                now: now
            ))
        }

        if preferences.aiActivityEnabled, preferences.showsAIIslandActivity,
           let agents = IslandActivityAdapters.ai(context.islandAIActivities, now: now) {
            activities.append(agents)
        }

        if preferences.showsTransferActivity {
            activities.append(contentsOf: transfers.transfers.map(IslandActivityAdapters.transfer))
        }

        if preferences.externalActivitiesEnabled {
            activities.append(contentsOf: externalActivities.live.map(IslandActivityAdapters.external))
        }

        if preferences.showsPassiveActivities,
           preferences.calendarGlanceEnabled,
           let calendar = context.calendarGlanceSnapshot,
           let activity = IslandActivityAdapters.calendar(calendar) {
            activities.append(activity)
        }
        return activities
    }

    /// One wake-up for the earliest expiry. Refreshes run every second while
    /// a timer ticks, so the task is only replaced when the deadline moves.
    private func scheduleIslandExpiry() {
        let deadlines = [islandEngine.nextExpiry, islandEvents.current?.expiresAt].compactMap { $0 }
        let next = deadlines.min()
        guard next != islandExpiryDeadline else { return }
        islandExpiryDeadline = next
        islandExpiryTask?.cancel()
        islandExpiryTask = nil
        guard let next else { return }
        islandExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.islandExpiryDeadline = nil
            self.refreshActivity()
        }
    }

    // MARK: User intent

    /// Promotes an activity. Clicking a satellite also expands it.
    @discardableResult
    public func selectIslandActivity(_ id: IslandActivityID, expand: Bool = false) -> Bool {
        guard islandEngine.select(id, expand: expand) else { return false }
        islandCollapseTask?.cancel()
        refreshActivity()
        if expand { windowController?.focusActivePanel() }
        let summary = islandEngine.activities[id]?.accessibilitySummary ?? id.kind.title
        announceForAccessibility(summary, priority: .low)
        return true
    }

    /// Swipe or keyboard navigation to the satellite on one side.
    @discardableResult
    public func selectIslandNeighbor(_ direction: IslandNavigationDirection) -> Bool {
        guard islandEngine.selectNeighbor(direction, in: islandPresentation) != nil else { return false }
        refreshActivity()
        if let primary = islandPresentation.primary {
            announceForAccessibility(primary.accessibilitySummary, priority: .low)
        }
        return true
    }

    public func expandIslandPrimary() {
        guard let primary = islandPresentation.primary else { return }
        islandEngine.expand(primary.id)
        islandCollapseTask?.cancel()
        setPeeking(false)
        refreshActivity()
        windowController?.focusActivePanel()
    }

    public func collapseIsland() {
        islandCollapseTask?.cancel()
        islandEngine.collapse()
        if mediaPanel != .none {
            mediaPanel = .none
            mediaPanelRowCount = 0
        }
        if isPeeking {
            setPeeking(false)
        } else {
            refreshActivity()
        }
        windowController?.resignFocus()
    }

    /// A deliberately expanded island closes a moment after the pointer leaves,
    /// unless its activity is waiting on the user.
    func handleIslandHover(_ hovering: Bool) {
        islandCollapseTask?.cancel()
        guard !hovering, islandEngine.expandedID != nil else { return }
        islandCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            guard self.windowController?.hoveredDisplayID == nil,
                  self.islandPresentation.primary?.requiresPersistentInteraction != true else { return }
            self.collapseIsland()
        }
    }

    /// Routes an activity command to the source that owns the real work.
    public func performIslandAction(_ action: IslandActivityAction, on id: IslandActivityID) {
        switch (id.kind, action) {
        case (.media, .playPause): media.send(.togglePlayPause)
        case (.media, .nextTrack): media.send(.nextTrack)
        case (.media, .previousTrack): media.send(.previousTrack)
        case (.recording, .pause): pauseRecording()
        case (.recording, .resume): resumeRecording()
        case (.recording, .stop): stopRecording()
        case (.recording, .cancel): cancelRecording()
        case (.timer, .pause): pauseFocusTimer()
        case (.timer, .resume): resumeFocusTimer()
        case (.timer, .cancel), (.timer, .dismiss): cancelFocusTimer()
        case (.voiceNote, .stop): stopVoiceNote()
        case (.voiceNote, .dismiss): dismissVoiceNote()
        case (.transfer, .cancel):
            if let uuid = UUID(uuidString: id.key) { transfers.requestCancel(uuid) }
        case (.transfer, .dismiss):
            if let uuid = UUID(uuidString: id.key) { transfers.dismiss(uuid) }
        case (.external, .dismiss): externalActivities.dismiss(id: id.key)
        default: return
        }
        scheduleIslandRefresh()
    }

    // MARK: Bursts

    public func presentIslandEvent(_ event: IslandTransientEvent) {
        guard isIslandEnabled else { return }
        islandEvents.enqueue(event)
        announceForAccessibility(
            [event.title, event.detail].compactMap { $0 }.joined(separator: ", "),
            priority: event.severity == .error ? .high : .medium
        )
        refreshActivity()
    }

    public func dismissIslandEvent() {
        islandEvents.dismissCurrent()
        refreshActivity()
    }

    private func isVisibleInIsland(_ kind: IslandActivityKind, key: String) -> Bool {
        islandPresentation.visibleActivities.contains { $0.id == IslandActivityID(kind: kind, key: key) }
    }

    private func transferDidFinish(_ transfer: TransferActivitySnapshot) {
        guard Preferences.shared.showsTransferCompletionAlerts,
              !isVisibleInIsland(.transfer, key: transfer.id.uuidString) else { return }
        switch transfer.state {
        case .completed:
            presentIslandEvent(IslandTransientEvent(
                kind: .transferCompleted,
                severity: .success,
                coalescingKey: "transfer",
                symbolName: "checkmark.circle.fill",
                title: transfer.title,
                detail: transfer.peerName
            ))
        case .failed:
            presentIslandEvent(IslandTransientEvent(
                kind: .transferFailed,
                severity: .error,
                coalescingKey: "transfer",
                symbolName: "exclamationmark.triangle.fill",
                title: "Transfer failed",
                detail: transfer.errorMessage ?? transfer.peerName
            ))
        default:
            break
        }
    }

    private func externalActivityDidFinish(_ activity: ExternalLiveActivity) {
        guard !isVisibleInIsland(.external, key: activity.id) else { return }
        presentIslandEvent(IslandTransientEvent(
            kind: activity.lifecycle == .failed ? .activityFailed : .activityCompleted,
            severity: activity.lifecycle == .failed ? .error : .success,
            coalescingKey: "external-" + activity.id,
            symbolName: activity.lifecycle == .failed
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill",
            title: activity.title,
            detail: activity.source
        ))
    }

    private func focusDidChange(_ focused: Bool) {
        guard Preferences.shared.showsFocusEvents else { return }
        // Public API exposes only on/off, never the Focus's name.
        presentIslandEvent(IslandTransientEvent(
            kind: .focus,
            severity: .informational,
            coalescingKey: "focus",
            symbolName: focused ? "moon.fill" : "moon",
            title: focused ? "Focus On" : "Focus Off",
            holdDuration: 1.8
        ))
    }
}
