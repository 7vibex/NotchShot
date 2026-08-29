import Foundation
import Observation

@MainActor
@Observable
public final class ContextCoordinator {
    public static let shared = ContextCoordinator()

    public private(set) var snapshot: ContextSnapshot?
    public let calendar = CalendarGlanceService.shared
    public let ai = AIActivityMonitor.shared
    public let timer = FocusTimerCoordinator.shared
    public let voiceNotes = VoiceNoteCoordinator.shared
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let power = PowerSourceMonitor()
    private let audio = AudioRouteMonitor()
    private var calendarSnapshot: ContextSnapshot?
    private var aiSnapshot: ContextSnapshot?
    private var timerSnapshot: ContextSnapshot?
    private var voiceNoteSnapshot: ContextSnapshot?
    private var expiryTask: Task<Void, Never>?

    public init() {}

    public func start() {
        power.onTransition = { [weak self] snapshot in self?.present(snapshot) }
        audio.onTransition = { [weak self] snapshot in self?.present(snapshot) }
        calendar.onSnapshotChange = { [weak self] snapshot in self?.updateCalendar(snapshot) }
        ai.onSnapshotChange = { [weak self] snapshot in self?.updateAI(snapshot) }
        timer.onSnapshotChange = { [weak self] snapshot in self?.updateTimer(snapshot) }
        voiceNotes.onSnapshotChange = { [weak self] snapshot in self?.updateVoiceNote(snapshot) }
        refreshPreferences()
    }

    public func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        power.stop()
        audio.stop()
        calendar.stop()
        ai.stop()
        voiceNotes.finalizeForTermination()
        calendarSnapshot = nil
        aiSnapshot = nil
        timerSnapshot = nil
        voiceNoteSnapshot = nil
        snapshot = nil
        onSnapshotChange?(nil)
    }

    public func refreshPreferences() {
        if Preferences.shared.powerStatusEnabled { power.start() } else { power.stop() }
        if Preferences.shared.audioRouteStatusEnabled { audio.start() } else { audio.stop() }
        if Preferences.shared.calendarGlanceEnabled { calendar.start() } else { calendar.stop() }
        if Preferences.shared.aiActivityEnabled {
            ai.setEnabledSources(Preferences.shared.enabledAISources)
            ai.start(mayInterruptMedia: Preferences.shared.showsAIActivityOverMedia)
        } else {
            ai.stop()
        }
    }

    public func present(_ newSnapshot: ContextSnapshot) {
        guard !newSnapshot.isExpired else { return }
        expiryTask?.cancel()
        snapshot = newSnapshot
        onSnapshotChange?(newSnapshot)
        guard let expiresAt = newSnapshot.expiresAt else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.restorePersistentSnapshot()
        }
    }

    public func updateCalendar(_ calendar: ContextSnapshot?) {
        var updated = calendar
        if snapshot?.kind == .calendar, snapshot?.presentation == .expanded {
            updated?.presentation = .expanded
        }
        calendarSnapshot = updated
        guard snapshot == nil || snapshot?.kind == .calendar || snapshot?.isExpired == true else { return }
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
                || snapshot?.isExpired == true
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
                || snapshot?.isExpired == true
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

    public func setExpanded(_ expanded: Bool) {
        guard var current = snapshot else { return }
        current.presentation = expanded ? .expanded : .compact
        snapshot = current
        onSnapshotChange?(current)
    }

    private func restorePersistentSnapshot() {
        expiryTask = nil
        let restored: ContextSnapshot?
        if let voiceNoteSnapshot, !voiceNoteSnapshot.isExpired {
            restored = voiceNoteSnapshot
        } else if let timerSnapshot, !timerSnapshot.isExpired {
            restored = timerSnapshot
        } else if let aiSnapshot, !aiSnapshot.isExpired {
            restored = aiSnapshot
        } else if let calendarSnapshot, !calendarSnapshot.isExpired {
            restored = calendarSnapshot
        } else {
            restored = nil
        }
        snapshot = restored
        onSnapshotChange?(restored)
    }
}
