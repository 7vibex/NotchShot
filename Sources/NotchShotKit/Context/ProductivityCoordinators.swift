import AVFAudio
import EventKit
import Foundation
import Observation

public enum FocusTimerPolicy {
    public static let presets: [TimeInterval] = [5, 15, 25, 45].map { $0 * 60 }

    public static func formatted(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func context(from timer: FocusTimerSnapshot) -> ContextSnapshot {
        let title = timer.state == .completed ? "Timer Finished" : timer.label
        let subtitle: String = switch timer.state {
        case .running: "Focus timer"
        case .paused: "Paused"
        case .completed: "Time is up"
        }
        return ContextSnapshot(
            kind: .timer,
            title: title,
            subtitle: subtitle,
            metric: formatted(timer.remaining),
            accentHex: timer.state == .completed ? "#30D158" : "#FF9F0A",
            focusTimer: timer,
            createdAt: timer.startedAt,
            expiresAt: timer.state == .completed ? Date().addingTimeInterval(12) : nil,
            mayInterruptMedia: timer.state == .completed
        )
    }
}

@MainActor
@Observable
public final class FocusTimerCoordinator {
    public static let shared = FocusTimerCoordinator()

    public private(set) var current: FocusTimerSnapshot?
    public private(set) var recent: [FocusTimerSnapshot] = []
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private var tickTask: Task<Void, Never>?
    private var lastTick: Date?

    public init() {}

    public func start(duration: TimeInterval, label: String = "Focus") {
        guard duration >= 60, duration <= 24 * 60 * 60 else { return }
        tickTask?.cancel()
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        current = FocusTimerSnapshot(
            label: String((cleaned.isEmpty ? "Focus" : cleaned).prefix(80)),
            state: .running,
            duration: duration,
            elapsed: 0
        )
        lastTick = Date()
        publish()
        runTicker()
    }

    public func pause() {
        updateElapsed()
        guard current?.state == .running else { return }
        current?.state = .paused
        tickTask?.cancel()
        tickTask = nil
        lastTick = nil
        publish()
    }

    public func resume() {
        guard current?.state == .paused else { return }
        current?.state = .running
        lastTick = Date()
        publish()
        runTicker()
    }

    public func cancel() {
        tickTask?.cancel()
        tickTask = nil
        current = nil
        lastTick = nil
        onSnapshotChange?(nil)
    }

    private func runTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.updateElapsed()
                self.publish()
            }
        }
    }

    private func updateElapsed(now: Date = Date()) {
        guard current?.state == .running, let lastTick else { return }
        current?.elapsed = min(current?.duration ?? 0, (current?.elapsed ?? 0) + now.timeIntervalSince(lastTick))
        self.lastTick = now
        guard let current, current.remaining <= 0 else { return }
        var completed = current
        completed.state = .completed
        self.current = completed
        recent.insert(completed, at: 0)
        recent = Array(recent.prefix(12))
        tickTask?.cancel()
        tickTask = nil
        self.lastTick = nil
    }

    private func publish() {
        onSnapshotChange?(current.map(FocusTimerPolicy.context))
    }
}

public enum PlannerItemKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case event
    case reminder

    public var id: String { rawValue }
    public var title: String { self == .event ? "Calendar event" : "Reminder" }
}

public struct PlannerDraft: Sendable, Equatable {
    public var kind: PlannerItemKind
    public var title: String
    public var date: Date
    public var duration: TimeInterval

    public init(kind: PlannerItemKind, title: String, date: Date, duration: TimeInterval = 30 * 60) {
        self.kind = kind
        self.title = title
        self.date = date
        self.duration = duration
    }
}

public enum NaturalLanguagePlanner {
    public static func parse(
        _ input: String,
        preferredKind: PlannerItemKind? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> PlannerDraft? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let inferredKind: PlannerItemKind = lower.hasPrefix("remind ") || lower.hasPrefix("reminder ")
            ? .reminder : .event
        let kind = preferredKind ?? inferredKind

        var day = calendar.startOfDay(for: now)
        if lower.contains("tomorrow") {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        } else if let weekday = weekdayIndex(in: lower),
                  let next = calendar.nextDate(
                    after: day,
                    matching: DateComponents(weekday: weekday),
                    matchingPolicy: .nextTime,
                    direction: .forward
                  ) {
            day = next
        }

        let time = parsedTime(in: lower) ?? (kind == .event ? (9, 0) : (17, 0))
        guard let date = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day) else {
            return nil
        }
        let duration = parsedDuration(in: lower) ?? 30 * 60
        let title = cleanedTitle(trimmed)
        guard !title.isEmpty else { return nil }
        return PlannerDraft(kind: kind, title: title, date: date, duration: duration)
    }

    private static func parsedTime(in input: String) -> (Int, Int)? {
        let pattern = #"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let hourRange = Range(match.range(at: 1), in: input),
              var hour = Int(input[hourRange]) else { return nil }
        var minute = 0
        if match.range(at: 2).location != NSNotFound,
           let range = Range(match.range(at: 2), in: input) {
            minute = Int(input[range]) ?? 0
        }
        var marker: String?
        if match.range(at: 3).location != NSNotFound,
           let range = Range(match.range(at: 3), in: input) {
            marker = String(input[range])
        }
        if marker == "pm", hour < 12 { hour += 12 }
        if marker == "am", hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func parsedDuration(in input: String) -> TimeInterval? {
        let pattern = #"\bfor\s+(\d{1,3})\s*(m|min|mins|minutes|h|hr|hours)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let valueRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let value = Double(input[valueRange]) else { return nil }
        let unit = input[unitRange]
        return value * (unit.hasPrefix("h") ? 3_600 : 60)
    }

    private static func weekdayIndex(in input: String) -> Int? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return names.firstIndex(where: { input.contains($0) }).map { $0 + 1 }
    }

    private static func cleanedTitle(_ input: String) -> String {
        var result = input
        let patterns = [
            #"(?i)^remind(?:er)?\s+(?:me\s+)?(?:to\s+)?"#,
            #"(?i)\b(?:today|tomorrow|sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#,
            #"(?i)\bat\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b"#,
            #"(?i)\bfor\s+\d{1,3}\s*(?:m|min|mins|minutes|h|hr|hours)\b"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let collapsed = result.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(120))
    }
}

public enum PlannerServiceError: LocalizedError {
    case permissionDenied
    case noWritableCalendar

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Calendar or Reminders access was not granted."
        case .noWritableCalendar: "No writable Calendar or Reminders list is available."
        }
    }
}

@MainActor
@Observable
public final class PlannerEntryService {
    public static let shared = PlannerEntryService()
    public private(set) var statusMessage: String?
    private let store = EKEventStore()

    public init() {}

    public func save(_ draft: PlannerDraft) async throws {
        switch draft.kind {
        case .event:
            guard try await store.requestWriteOnlyAccessToEvents() else {
                throw PlannerServiceError.permissionDenied
            }
            guard let calendar = store.defaultCalendarForNewEvents else {
                throw PlannerServiceError.noWritableCalendar
            }
            let event = EKEvent(eventStore: store)
            event.title = draft.title
            event.startDate = draft.date
            event.endDate = draft.date.addingTimeInterval(max(60, draft.duration))
            event.calendar = calendar
            try store.save(event, span: .thisEvent, commit: true)
        case .reminder:
            guard try await store.requestFullAccessToReminders() else {
                throw PlannerServiceError.permissionDenied
            }
            guard let calendar = store.defaultCalendarForNewReminders() else {
                throw PlannerServiceError.noWritableCalendar
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = calendar
            reminder.dueDateComponents = Calendar.autoupdatingCurrent.dateComponents(
                [.year, .month, .day, .hour, .minute, .timeZone],
                from: draft.date
            )
            try store.save(reminder, commit: true)
        }
        statusMessage = draft.kind == .event ? "Added to Calendar" : "Added to Reminders"
    }
}

@MainActor
@Observable
public final class VoiceNoteCoordinator {
    public static let shared = VoiceNoteCoordinator()

    public private(set) var snapshot: VoiceNoteSnapshot?
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private var recorder: VoiceNoteAudioCapture?
    private var liveTranscriber: LiveVoiceNoteTranscriber?
    private var liveTranscriptionTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var startedAt: Date?

    /// Identifies one recording attempt. `start()` suspends several times
    /// before it owns `recorder`, and `stop()` hands finalization to a task
    /// that outlives it, so neither can be gated on `recorder` alone: a second
    /// press during the microphone prompt would open the same file twice, and
    /// a late finalization would publish its stale snapshot over a newer note.
    /// Every mutation below carries the generation it was started for and is
    /// dropped once that generation is no longer current.
    private var generation: UInt64 = 0
    /// Held from the moment `start()` is entered until it either owns a
    /// recorder or fails. `recorder` is still nil across that window.
    private var isStarting = false

    public init() {}

    public func start() async {
        guard recorder == nil, !isStarting else { return }
        isStarting = true
        generation &+= 1
        let generation = self.generation
        // Unconditional: only one `start()` runs at a time, so nothing else can
        // have set this flag, and a conditional clear risks wedging the button
        // permanently if the generation ever moves under us.
        defer { isStarting = false }
        guard await PermissionCenter.shared.requestMicrophoneAccess() else {
            publish(
                VoiceNoteSnapshot(state: .failed, errorMessage: "Microphone access was denied."),
                ifGenerationIs: generation
            )
            return
        }
        guard AppPaths.ensureDirectories() else {
            publish(
                VoiceNoteSnapshot(state: .failed, errorMessage: "Voice Notes folder is unavailable."),
                ifGenerationIs: generation
            )
            return
        }
        let url = AppPaths.voiceNotes.appendingPathComponent(Self.recordingFilename())
        let liveTranscriber = LiveVoiceNoteTranscriber()
        var liveErrorMessage: String?
        do {
            try await liveTranscriber.start(
                onTranscript: { [weak self] text in
                    self?.updateLiveTranscript(text)
                },
                onFailure: { [weak self] message in
                    self?.markLiveTranscriptionUnavailable(message)
                }
            )
            guard self.generation == generation else {
                await liveTranscriber.cancel()
                return
            }
            self.liveTranscriber = liveTranscriber
        } catch {
            guard self.generation == generation else { return }
            liveErrorMessage = "Live transcript unavailable. Audio is still recording. \(error.localizedDescription)"
        }

        do {
            let recorder = VoiceNoteAudioCapture()
            let audioStream = try recorder.start(
                recordingURL: url,
                streamsAudioForTranscription: self.liveTranscriber != nil
            )
            self.recorder = recorder
            startedAt = Date()
            publish(VoiceNoteSnapshot(
                state: .recording,
                fileURL: url,
                errorMessage: liveErrorMessage
            ))
            if self.liveTranscriber != nil, let audioStream {
                liveTranscriptionTask = Task { [weak self, liveTranscriber] in
                    do {
                        for await buffer in audioStream {
                            try await liveTranscriber.consume(buffer)
                        }
                        try await liveTranscriber.finish()
                    } catch {
                        await liveTranscriber.cancel()
                        self?.markLiveTranscriptionUnavailable(error.localizedDescription)
                    }
                }
            }
            runTicker()
        } catch {
            await liveTranscriber.cancel()
            guard self.generation == generation else { return }
            self.liveTranscriber = nil
            publish(VoiceNoteSnapshot(state: .failed, errorMessage: error.localizedDescription))
        }
    }

    /// Closes the audio file so the note on disk is a complete, playable WAV.
    ///
    /// Quit deliberately stops here rather than awaiting transcription. The
    /// recording is the artifact that cannot be recreated; a transcript can
    /// always be regenerated from the saved audio, and `terminateLater` is
    /// meant for the short save that closing this file is — not for speech
    /// recognition that scales with the length of the note.
    public func finalizeForTermination() {
        guard let recorder else { return }
        generation &+= 1
        isStarting = false
        try? recorder.stop()
        if let fileURL = snapshot?.fileURL {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        self.recorder = nil
        tickTask?.cancel()
        tickTask = nil
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        liveTranscriber = nil
    }

    public func stop() {
        guard let recorder, let current = snapshot else { return }
        // Retire this recording before the finalization task below is handed
        // its snapshot. A new note started while transcription is still running
        // bumps the generation again, and every `publish` below is dropped.
        generation &+= 1
        let generation = self.generation
        let recordingError: Error?
        do {
            try recorder.stop()
            recordingError = nil
        } catch {
            recordingError = error
        }
        if let fileURL = current.fileURL {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        self.recorder = nil
        tickTask?.cancel()
        tickTask = nil
        var transcribing = current
        transcribing.state = .transcribing
        transcribing.elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? current.elapsed
        publish(transcribing)
        guard let url = transcribing.fileURL else { return }
        let liveTask = liveTranscriptionTask
        liveTranscriptionTask = nil
        let liveTranscriber = liveTranscriber
        self.liveTranscriber = nil
        Task { [weak self] in
            await liveTask?.value
            if let recordingError {
                var finished = transcribing
                finished.state = .failed
                finished.errorMessage = "The voice note could not be saved completely. \(recordingError.localizedDescription)"
                self?.publish(finished, ifGenerationIs: generation)
                return
            }
            do {
                let result = try await OnDeviceTranscriptionService.shared.transcribe(recordingURL: url)
                let transcriptURL = url.deletingPathExtension().appendingPathExtension("txt")
                try Data(result.text.utf8).write(to: transcriptURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
                var finished = transcribing
                finished.state = .completed
                finished.transcript = result.text
                finished.errorMessage = nil
                self?.publish(finished, ifGenerationIs: generation)
            } catch {
                var finished = transcribing
                finished.state = .completed
                finished.errorMessage = "Saved audio. \(error.localizedDescription)"
                self?.publish(finished, ifGenerationIs: generation)
            }
            if let liveTranscriber {
                await liveTranscriber.cancel()
            }
        }
    }

    public func dismiss() {
        guard recorder == nil else { return }
        snapshot = nil
        onSnapshotChange?(nil)
    }

    private func runTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, var snapshot = self.snapshot else { return }
                snapshot.elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? snapshot.elapsed
                self.publish(snapshot)
            }
        }
    }

    private func updateLiveTranscript(_ text: String) {
        guard var snapshot, snapshot.state == .recording || snapshot.state == .transcribing else { return }
        snapshot.transcript = text.isEmpty ? nil : text
        publish(snapshot)
    }

    private func markLiveTranscriptionUnavailable(_ message: String) {
        guard var snapshot, snapshot.state == .recording else { return }
        snapshot.errorMessage = "Live transcript unavailable. Audio is still recording. \(message)"
        publish(snapshot)
    }

    /// Publishes only while `generation` is still the live recording. A
    /// finalization task that outlived its recording drops its result here
    /// rather than overwriting a newer note's state.
    private func publish(_ note: VoiceNoteSnapshot, ifGenerationIs generation: UInt64) {
        guard self.generation == generation else { return }
        publish(note)
    }

    /// Second resolution is not enough on its own: two notes started inside the
    /// same second would resolve to one path, and `AVAudioFile` opened for
    /// writing truncates whatever is already there. Keep the complete UUID;
    /// the former four-hex prefix had only 65,536 possibilities and collided in
    /// the parallel stress suite.
    static func recordingFilename(
        now: Date = Date(),
        identifier: UUID = UUID()
    ) -> String {
        let stamp = filenameFormatter.string(from: now)
        return "Voice Note \(stamp) \(identifier.uuidString).wav"
    }

    /// Sortable and human-readable to the second; `recordingFilename` appends
    /// the UUID that covers the sub-second case.
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private func publish(_ note: VoiceNoteSnapshot) {
        snapshot = note
        let title: String = switch note.state {
        case .recording: "Voice Note"
        case .transcribing: "Transcribing Locally"
        case .completed: "Voice Note Saved"
        case .failed: "Voice Note Failed"
        }
        let subtitle = note.transcript ?? note.errorMessage ?? (note.state == .recording ? "Recording microphone" : "On-device speech recognition")
        onSnapshotChange?(ContextSnapshot(
            kind: .voiceNote,
            title: title,
            subtitle: subtitle,
            metric: FocusTimerPolicy.formatted(note.elapsed),
            accentHex: note.state == .failed ? "#FF453A" : "#FF375F",
            voiceNote: note,
            expiresAt: note.state == .completed || note.state == .failed ? Date().addingTimeInterval(30) : nil,
            mayInterruptMedia: note.state == .completed || note.state == .failed
        ))
    }
}
