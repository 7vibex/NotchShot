import Foundation
import NotchShotAIReporterSupport

/// Maps NotchShot's existing source models onto island activities.
///
/// Adapters are pure. They never copy rich payloads (artwork, transcripts,
/// step lists, event lists); views read those from the source when drawing.
/// Every key below is a stable, source-owned identity.
public enum IslandActivityAdapters {
    /// How long a success stays in its island slot before leaving.
    public static let successLinger: TimeInterval = 2.6
    public static let failureLinger: TimeInterval = 5

    // MARK: Recording

    public static func recording(
        status: RecordingStatus,
        isPaused: Bool,
        startedAt: Date
    ) -> IslandActivity {
        IslandActivity(
            id: IslandActivityID(kind: .recording, key: "screen"),
            priority: .critical,
            relevance: 1,
            lifecycle: isPaused ? .paused : .active,
            progress: .none,
            measurement: status.fileSizeBytes > 0
                ? IslandMeasurement(completed: status.fileSizeBytes, unit: .bytes)
                : nil,
            startedAt: startedAt,
            actions: [isPaused ? .resume : .pause, .stop, .cancel],
            interruptionPolicy: .pinned,
            title: "Screen Recording",
            stateLabel: isPaused ? "Paused" : "Recording",
            metric: status.elapsedDescription,
            symbolName: "record.circle.fill",
            accentHex: "#FF453A"
        )
    }

    // MARK: Voice note

    /// `expiresAt` comes from the published context card, which stamps its
    /// 30-second linger once, at completion.
    public static func voiceNote(_ note: VoiceNoteSnapshot, expiresAt: Date?, now: Date) -> IslandActivity? {
        let lifecycle: IslandLifecycle
        let stateLabel: String
        switch note.state {
        case .recording:
            lifecycle = .active
            stateLabel = "Recording"
        case .transcribing:
            lifecycle = .active
            stateLabel = "Transcribing"
        case .completed:
            lifecycle = .succeeded
            stateLabel = "Saved"
        case .failed:
            lifecycle = .failed
            stateLabel = "Failed"
        }
        return IslandActivity(
            id: IslandActivityID(kind: .voiceNote, key: note.id.uuidString),
            // The microphone is live: keep it as visible as a recording, but a
            // recording that starts afterwards still wins the slot.
            priority: note.state == .recording ? .critical : .normal,
            relevance: note.state == .recording ? 1 : 0.6,
            lifecycle: lifecycle,
            progress: note.state == .transcribing ? .indeterminate : .none,
            startedAt: now.addingTimeInterval(-note.elapsed),
            actions: note.state == .recording ? [.stop] : [.dismiss],
            interruptionPolicy: note.state == .recording ? .pinned : .standard,
            expiresAt: expiresAt,
            title: "Voice Note",
            stateLabel: stateLabel,
            metric: FocusTimerPolicy.formatted(note.elapsed),
            symbolName: "waveform.and.mic",
            accentHex: "#FF453A"
        )
    }

    // MARK: Media

    public static func media(_ snapshot: MediaSnapshot, startedAt: Date) -> IslandActivity? {
        guard snapshot.hasContent else { return nil }
        var actions: [IslandActivityAction] = [.playPause]
        if snapshot.supportedCommands.contains(.nextTrack) { actions.append(.nextTrack) }
        if snapshot.supportedCommands.contains(.previousTrack) { actions.append(.previousTrack) }
        let progress: IslandProgress
        if let duration = snapshot.duration, duration > 0, let position = snapshot.position {
            progress = .reported(position / duration)
        } else {
            progress = .none
        }
        return IslandActivity(
            // One player at a time: the key is not the track, so a track change
            // morphs the same activity instead of replacing it.
            id: IslandActivityID(kind: .media, key: "now-playing"),
            priority: .normal,
            relevance: snapshot.isPlaying ? 0.5 : 0.3,
            lifecycle: snapshot.isPlaying ? .active : .paused,
            progress: progress,
            startedAt: startedAt,
            actions: actions,
            title: snapshot.title ?? "Not Playing",
            subtitle: snapshot.artist,
            stateLabel: snapshot.isPlaying ? "Playing" : "Paused",
            symbolName: snapshot.isPlaying ? "waveform" : "pause.fill",
            accentHex: "#FFFFFF"
        )
    }

    // MARK: Timer

    /// `expiresAt` comes from the published timer card, which stamps the
    /// completion linger once instead of on every refresh.
    public static func timer(_ timer: FocusTimerSnapshot, expiresAt: Date? = nil, now: Date) -> IslandActivity {
        let lifecycle: IslandLifecycle = switch timer.state {
        case .running: .active
        case .paused: .paused
        case .completed: .succeeded
        }
        let actions: [IslandActivityAction] = switch timer.state {
        case .running: [.pause, .cancel]
        case .paused: [.resume, .cancel]
        case .completed: [.dismiss]
        }
        let stateLabel: String = switch timer.state {
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Time is up"
        }
        return IslandActivity(
            id: IslandActivityID(kind: .timer, key: timer.id.uuidString),
            priority: .normal,
            relevance: timer.state == .completed ? 0.9 : 0.5,
            lifecycle: lifecycle,
            progress: .reported(timer.elapsed / max(1, timer.duration)),
            startedAt: timer.startedAt,
            actions: actions,
            // Completed timers stay 12 s, matching the existing context card.
            expiresAt: timer.state == .completed ? (expiresAt ?? timer.startedAt.addingTimeInterval(timer.duration + 12)) : nil,
            title: timer.label,
            stateLabel: stateLabel,
            metric: FocusTimerPolicy.formatted(timer.remaining),
            symbolName: timer.state == .completed ? "checkmark.circle.fill" : "timer",
            accentHex: timer.state == .completed ? "#30D158" : "#FF9F0A"
        )
    }

    // MARK: AI agents

    /// All live agents fold into one activity. The island has three slots;
    /// agents already have a purpose-built list inside the expanded card.
    public static func ai(_ agents: [AIActivitySnapshot], now: Date) -> IslandActivity? {
        guard let headline = headlineAgent(agents) else { return nil }
        let live = agents.filter { !$0.state.isTerminal }
        let anyWaiting = agents.contains { $0.state == .waiting }
        let allTerminal = live.isEmpty
        let lifecycle: IslandLifecycle
        var expiresAt: Date?
        if anyWaiting {
            lifecycle = .waiting
        } else if allTerminal {
            let failed = agents.contains { $0.state == .failed }
            lifecycle = failed ? .failed : .succeeded
            let latest = agents.map(\.updatedAt).max() ?? now
            expiresAt = latest.addingTimeInterval(failed ? failureLinger : successLinger)
        } else {
            lifecycle = .active
        }
        let progress: IslandProgress = switch headline.state {
        case .finished: .determinate(1)
        case .failed: .none
        case .working, .waiting: .reported(headline.progress)
        }
        let metric: String? = progress.fraction.map { "\(Int(($0 * 100).rounded()))%" }
        let earliest = agents.compactMap(\.startedAt).min() ?? headline.updatedAt
        return IslandActivity(
            id: IslandActivityID(kind: .ai, key: "agents"),
            priority: anyWaiting ? .elevated : .normal,
            relevance: anyWaiting ? 1 : 0.5,
            lifecycle: lifecycle,
            progress: progress,
            startedAt: earliest,
            updatedAt: headline.updatedAt,
            actions: anyWaiting ? [.approve, .deny] : [.dismiss],
            expiresAt: expiresAt,
            title: headline.title,
            subtitle: headline.source.title,
            stateLabel: headline.state.title,
            metric: metric,
            symbolName: headline.source.symbolName,
            accentHex: headline.source.accentHex
        )
    }

    /// Waiting beats working beats finished; newest first within a state.
    public static func headlineAgent(_ agents: [AIActivitySnapshot]) -> AIActivitySnapshot? {
        func rank(_ state: AIActivityState) -> Int {
            switch state {
            case .waiting: 0
            case .working: 1
            case .failed: 2
            case .finished: 3
            }
        }
        return agents.min { lhs, rhs in
            if rank(lhs.state) != rank(rhs.state) { return rank(lhs.state) < rank(rhs.state) }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    // MARK: Transfers

    public static func transfer(_ transfer: TransferActivitySnapshot) -> IslandActivity {
        let lifecycle: IslandLifecycle = switch transfer.state {
        case .preparing, .transferring: .active
        case .completed: .succeeded
        case .failed, .cancelled: .failed
        }
        let progress: IslandProgress = transfer.fraction.map { .determinate($0) } ?? .indeterminate
        var measurement: IslandMeasurement?
        if let bytes = transfer.bytesTransferred {
            measurement = IslandMeasurement(
                completed: bytes,
                total: transfer.totalBytes,
                unit: .bytes,
                ratePerSecond: transfer.bytesPerSecond,
                estimatedCompletion: transfer.estimatedCompletion
            )
        } else if transfer.service == .localSend {
            measurement = IslandMeasurement(
                completed: Int64(transfer.completedFiles),
                total: Int64(transfer.effectiveFileCount),
                unit: .items
            )
        }
        let linger = transfer.state == .completed
            ? TransferActivityStore.completedLinger
            : TransferActivityStore.failedLinger
        let stateLabel: String = switch transfer.state {
        case .preparing: "Preparing"
        case .transferring: transfer.service == .airDrop ? "Sharing" : "Sending"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
        return IslandActivity(
            id: IslandActivityID(kind: .transfer, key: transfer.id.uuidString),
            priority: .normal,
            relevance: 0.55,
            lifecycle: lifecycle,
            progress: lifecycle == .active ? progress : (lifecycle == .succeeded ? .determinate(1) : .none),
            measurement: measurement,
            startedAt: transfer.startedAt,
            updatedAt: transfer.updatedAt,
            actions: transfer.canCancel ? [.cancel] : [],
            expiresAt: transfer.finishedAt?.addingTimeInterval(linger),
            title: transfer.title,
            subtitle: transfer.peerName,
            stateLabel: stateLabel,
            metric: progress.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" },
            symbolName: transfer.service == .airDrop ? "airplayaudio" : "arrow.up.circle.fill",
            accentHex: "#0A84FF"
        )
    }

    // MARK: External

    public static func external(_ activity: ExternalLiveActivity) -> IslandActivity {
        let lifecycle: IslandLifecycle = switch activity.lifecycle {
        case .active: .active
        case .succeeded: .succeeded
        case .failed: .failed
        }
        let progress: IslandProgress
        switch activity.lifecycle {
        case .succeeded: progress = .determinate(1)
        case .failed: progress = .none
        case .active: progress = activity.effectiveProgress.map { .determinate($0) } ?? .indeterminate
        }
        let registryLimits = ExternalActivityRegistry.Limits()
        let linger = activity.lifecycle == .failed ? registryLimits.failureLinger : registryLimits.successLinger
        let priority: IslandPriority
        let policy: IslandInterruptionPolicy
        switch activity.urgency {
        case .passive:
            priority = .passive
            policy = .passive
        case .normal:
            priority = .normal
            policy = .standard
        case .important:
            priority = .elevated
            policy = .standard
        }
        let fallbackState: String = switch activity.lifecycle {
        case .active: "Working"
        case .succeeded: "Finished"
        case .failed: "Failed"
        }
        return IslandActivity(
            id: IslandActivityID(kind: .external, key: activity.id),
            priority: priority,
            relevance: 0.45,
            lifecycle: lifecycle,
            progress: progress,
            measurement: activity.current.map { current in
                IslandMeasurement(
                    completed: current,
                    total: activity.total,
                    unit: externalUnit(activity.unit),
                    estimatedCompletion: activity.estimatedCompletion
                )
            },
            startedAt: activity.startedAt,
            updatedAt: activity.updatedAt,
            actions: [.dismiss],
            interruptionPolicy: policy,
            expiresAt: activity.completedAt?.addingTimeInterval(linger) ?? activity.expiresAt,
            title: activity.title,
            subtitle: activity.subtitle ?? activity.source,
            stateLabel: activity.stateLabel ?? fallbackState,
            metric: progress.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" },
            symbolName: activity.icon.symbolName,
            accentHex: activity.accent.hex
        )
    }

    private static func externalUnit(_ unit: LiveActivityUnit?) -> IslandMeasurement.Unit {
        switch unit {
        case .bytes: .bytes
        case .items: .items
        case .count, nil: .count
        }
    }

    // MARK: Calendar

    public static func calendar(_ snapshot: ContextSnapshot) -> IslandActivity? {
        guard snapshot.kind == .calendar, !snapshot.events.isEmpty else { return nil }
        let urgent = snapshot.mayInterruptMedia
        return IslandActivity(
            id: IslandActivityID(kind: .calendar, key: "upcoming"),
            priority: urgent ? .normal : .passive,
            relevance: urgent ? 0.7 : 0.2,
            lifecycle: .active,
            startedAt: snapshot.createdAt,
            interruptionPolicy: urgent ? .standard : .passive,
            expiresAt: snapshot.expiresAt,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            metric: snapshot.metric,
            symbolName: ContextKind.calendar.symbolName,
            accentHex: snapshot.accentHex
        )
    }
}
