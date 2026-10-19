import Foundation
import Observation

@MainActor
@Observable
public final class ContextCoordinator {
    public static let shared = ContextCoordinator()

    public private(set) var snapshot: ContextSnapshot?
    public let calendar = CalendarGlanceService.shared
    public let ai = AIActivityMonitor.shared
    public let claude = ClaudeCodeSessionMonitor.shared
    public let crewline = CrewlineMonitor.shared
    public let claudeUsage = ClaudeUsageMonitor.shared
    public let timer = FocusTimerCoordinator.shared
    public let voiceNotes = VoiceNoteCoordinator.shared
    public let privacy = PrivacyIndicatorMonitor.shared
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let power = PowerSourceMonitor()
    private let audio = AudioRouteMonitor()
    private let network = NetworkReachabilityMonitor()
    private var calendarSnapshot: ContextSnapshot?
    private var aiSnapshot: ContextSnapshot?
    private var claudeSnapshot: ContextSnapshot?
    private var crewlineActivities: [AIActivitySnapshot] = []
    private var timerSnapshot: ContextSnapshot?
    private var voiceNoteSnapshot: ContextSnapshot?
    private var cancelExpiry: (() -> Void)?
    private var expiryGeneration = 0

    private let timing: ContextTiming

    public convenience init() { self.init(timing: ContextTiming()) }

    init(timing: ContextTiming) { self.timing = timing }

    private func isExpired(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.expiresAt.map { $0 <= timing.now() } ?? false
    }

    public func start() {
        power.onTransition = { [weak self] snapshot in self?.present(snapshot) }
        audio.onTransition = { [weak self] snapshot in self?.present(snapshot) }
        network.onTransition = { [weak self] snapshot in self?.present(snapshot) }
        calendar.onSnapshotChange = { [weak self] snapshot in self?.updateCalendar(snapshot) }
        ai.onSnapshotChange = { [weak self] snapshot in self?.updateAI(snapshot) }
        claude.onSnapshotChange = { [weak self] snapshot in self?.updateClaude(snapshot) }
        crewline.onChange = { [weak self] in self?.updateCrewline() }
        timer.onSnapshotChange = { [weak self] snapshot in self?.updateTimer(snapshot) }
        voiceNotes.onSnapshotChange = { [weak self] snapshot in self?.updateVoiceNote(snapshot) }
        refreshPreferences()
    }

    public func stop() {
        cancelScheduledExpiry()
        power.stop()
        audio.stop()
        network.stop()
        privacy.stop()
        calendar.stop()
        ai.stop()
        claude.stop()
        claudeUsage.stop()
        crewline.stop()
        voiceNotes.finalizeForTermination()
        calendarSnapshot = nil
        aiSnapshot = nil
        claudeSnapshot = nil
        crewlineActivities = []
        timerSnapshot = nil
        voiceNoteSnapshot = nil
        // Stopping producers can publish nil and restore another source.
        cancelScheduledExpiry()
        snapshot = nil
        onSnapshotChange?(nil)
    }

    public func refreshPreferences() {
        if Preferences.shared.powerStatusEnabled { power.start() } else { power.stop() }
        if Preferences.shared.audioRouteStatusEnabled { audio.start() } else { audio.stop() }
        if Preferences.shared.networkStatusEnabled { network.start() } else { network.stop() }
        // The same listener feeds the indicator dots and the call activity.
        let preferences = Preferences.shared
        if preferences.showsPrivacyIndicators || preferences.showsCallActivity {
            privacy.start()
        } else {
            privacy.stop()
        }
        if Preferences.shared.calendarGlanceEnabled { calendar.start() } else { calendar.stop() }
        if Preferences.shared.aiActivityEnabled {
            ai.setEnabledSources(Preferences.shared.enabledAISources)
            ai.start(mayInterruptMedia: Preferences.shared.showsAIActivityOverMedia)
            if Preferences.shared.enabledAISources.contains(.claude) {
                claude.start(mayInterruptMedia: Preferences.shared.showsAIActivityOverMedia)
                claudeUsage.start()
            } else {
                claude.stop()
                claudeUsage.stop()
            }
            if Preferences.shared.crewlineEnabled {
                crewline.start()
            } else {
                crewline.stop()
            }
        } else {
            ai.stop()
            claude.stop()
            claudeUsage.stop()
            crewline.stop()
        }
    }

    public func present(_ newSnapshot: ContextSnapshot) {
        guard !isExpired(newSnapshot) else { return }
        cancelScheduledExpiry()
        let generation = expiryGeneration
        snapshot = newSnapshot
        onSnapshotChange?(newSnapshot)
        armExpiry(for: newSnapshot, generation: generation)
    }

    public func updateCalendar(_ calendar: ContextSnapshot?) {
        var updated = calendar
        if snapshot?.kind == .calendar, snapshot?.presentation == .expanded {
            updated?.presentation = .expanded
        }
        calendarSnapshot = updated
        guard snapshot == nil || snapshot?.kind == .calendar || snapshot.map({ isExpired($0) }) == true else { return }
        restorePersistentSnapshot()
    }

    public func updateAI(_ ai: ContextSnapshot?) {
        var updated = ai
        if snapshot?.kind == .ai, snapshot?.presentation == .expanded {
            updated?.presentation = .expanded
        }
        aiSnapshot = updated
        guard snapshot == nil
                || snapshot?.kind == .ai
                || snapshot?.kind == .calendar
                || snapshot.map({ isExpired($0) }) == true
        else { return }
        restorePersistentSnapshot()
    }

    /// Crewline publishes whole-workspace changes; the island only needs to
    /// hear about them when the visible run list actually moved.
    public func updateCrewline() {
        let activities = crewline.activities
        guard activities != crewlineActivities else { return }
        crewlineActivities = activities
        guard snapshot == nil
                || snapshot?.kind == .ai
                || snapshot?.kind == .calendar
                || snapshot.map({ isExpired($0) }) == true
        else { return }
        restorePersistentSnapshot()
    }

    public func updateClaude(_ claude: ContextSnapshot?) {
        claudeSnapshot = claude
        guard snapshot == nil
                || snapshot?.kind == .ai
                || snapshot?.kind == .calendar
                || snapshot.map({ isExpired($0) }) == true
        else { return }
        restorePersistentSnapshot()
    }

    public func updateTimer(_ timer: ContextSnapshot?) {
        var updated = timer
        if snapshot?.kind == .timer, snapshot?.presentation == .expanded {
            updated?.presentation = .expanded
        }
        timerSnapshot = updated
        guard snapshot == nil
                || snapshot?.kind == .timer
                || snapshot?.kind == .ai
                || snapshot?.kind == .calendar
                || snapshot.map({ isExpired($0) }) == true
        else { return }
        restorePersistentSnapshot()
    }

    public func updateVoiceNote(_ voiceNote: ContextSnapshot?) {
        var updated = voiceNote
        if snapshot?.kind == .voiceNote, snapshot?.presentation == .expanded {
            updated?.presentation = .expanded
        }
        voiceNoteSnapshot = updated
        restorePersistentSnapshot()
    }

    /// The published timer card, carrying its completion linger.
    public var timerContextSnapshot: ContextSnapshot? { timerSnapshot }

    /// The published voice-note card, carrying its completion linger.
    public var voiceNoteContextSnapshot: ContextSnapshot? { voiceNoteSnapshot }

    /// The upcoming-event glance, independent of which card currently leads.
    public var calendarGlanceSnapshot: ContextSnapshot? { calendarSnapshot }

    /// Every agent record the island should know about: generic reporter
    /// records plus the live Claude sessions, without duplicates.
    public var islandAIActivities: [AIActivitySnapshot] {
        guard claude.isRunning else { return (aiSnapshot?.aiActivities ?? []) + crewlineActivities }
        let generic = aiSnapshot?.aiActivities.filter { $0.source != .claude } ?? []
        let direct = claude.sessions.map(\.aiActivity)
        return generic + direct + crewlineActivities
    }

    /// Finished agent records for the expanded card's Recent list.
    public var islandAIRecentActivities: [AIActivitySnapshot] {
        let recent = aiSnapshot?.aiRecentActivities ?? []
        guard claude.isRunning else { return recent }
        return recent.filter { $0.source != .claude }
    }

    public func setExpanded(_ expanded: Bool) {
        guard var current = snapshot else { return }
        current.presentation = expanded ? .expanded : .compact
        snapshot = current
        onSnapshotChange?(current)
    }

    /// Closes a transient card early instead of waiting out its expiry, for
    /// the cards that carry their own dismiss control.
    public func dismissTransient() {
        restorePersistentSnapshot()
    }

    private func restorePersistentSnapshot() {
        cancelScheduledExpiry()
        let generation = expiryGeneration
        let restored: ContextSnapshot?
        if let voiceNoteSnapshot, !isExpired(voiceNoteSnapshot) {
            restored = voiceNoteSnapshot
        } else if let timerSnapshot, !isExpired(timerSnapshot) {
            restored = timerSnapshot
        } else if let aiSnapshot = effectiveAISnapshot(), !isExpired(aiSnapshot) {
            restored = aiSnapshot
        } else if let calendarSnapshot, !isExpired(calendarSnapshot) {
            restored = calendarSnapshot
        } else {
            restored = nil
        }
        snapshot = restored
        onSnapshotChange?(restored)
        armExpiry(for: restored, generation: generation)
    }

    private func cancelScheduledExpiry() {
        cancelExpiry?()
        cancelExpiry = nil
        expiryGeneration += 1
    }

    private func armExpiry(for snapshot: ContextSnapshot?, generation: Int) {
        guard generation == expiryGeneration, let deadline = snapshot?.expiresAt else { return }
        cancelExpiry = timing.schedule(deadline) { [weak self] in
            guard let self, self.expiryGeneration == generation else { return }
            self.restorePersistentSnapshot()
        }
    }

    /// The generic reporter still supplies Codex, Cursor, Terminal, and older
    /// Claude records. Once the live Claude socket is running, its session list
    /// is authoritative for Claude so a hook event cannot appear twice.
    private func effectiveAISnapshot() -> ContextSnapshot? {
        guard claude.isRunning || !crewlineActivities.isEmpty else { return aiSnapshot }

        let generic = claude.isRunning
            ? aiSnapshot?.aiActivities.filter { $0.source != .claude } ?? []
            : aiSnapshot?.aiActivities ?? []
        let direct = claudeSnapshot?.aiActivities ?? []
        var merged = AIActivityPolicy.contextSnapshot(
            from: generic + direct + crewlineActivities,
            mayInterruptMedia: claudeSnapshot?.mayInterruptMedia
                ?? aiSnapshot?.mayInterruptMedia
                ?? false
        )
        merged?.aiRecentActivities = Array(
            (aiSnapshot?.aiRecentActivities ?? [])
                .filter { !claude.isRunning || $0.source != .claude }
                .prefix(5)
        )
        if snapshot?.kind == .ai, snapshot?.presentation == .expanded {
            merged?.presentation = .expanded
        }
        return merged
    }
}
