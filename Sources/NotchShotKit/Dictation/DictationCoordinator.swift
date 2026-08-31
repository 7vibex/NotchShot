import AppKit
import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
public final class DictationCoordinator {
    public static let shared = DictationCoordinator()

    public private(set) var snapshot = DictationSnapshot()
    public private(set) var state: DictationState = .idle {
        didSet { snapshot.state = state }
    }

    /// Live microphone trace. Separate from `snapshot` on purpose: the snapshot
    /// is what reaches `NotchActivity`, and pushing 25 Hz of waveform through
    /// there re-animated the whole notch and re-announced state to VoiceOver on
    /// every tick. Only the waveform view reads this.
    /// `internal(set)` so previews and tests can render a populated trace
    /// without a live microphone; clients outside the module still read-only.
    public internal(set) var meter = DictationMeter()
    /// Whole seconds of elapsed recording. Separate from the meter so the timer
    /// label redraws once a second instead of at the waveform tick rate.
    public internal(set) var elapsedSeconds: Int = 0

    private var sessionID: UInt64 = 0
    private var audioCapture: DictationAudioCapture?
    private var engine: SpeechAnalyzerDictationEngine?
    private var insertionTarget: DictationInsertionTarget?
    private var targetDisplayID: CGDirectDisplayID?
    private var waveformTimer: Timer?
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var maxDurationTimer: Timer?
    private var successCollapseTask: Task<Void, Never>?
    /// When the current push-to-talk key went down, so a tap can be told from
    /// a hold on release.
    private var pushToTalkPressedAt: Date?
    /// True while a tap is holding dictation open without the key being down.
    private var isLatched = false
    /// A press that arrived while the previous session was still finalising.
    private var pendingPushToTalkStart = false
    /// Anything shorter than this is a tap, not a hold.
    private static let latchDuration: TimeInterval = 0.6

    // Published transcript parts
    private var finalizedParts: [String] = []
    private var volatilePart = ""

    /// Model availability for the currently selected dictation language, plus
    /// any install in flight. Held here rather than in the Settings view so a
    /// download is not abandoned when the user closes the window.
    public private(set) var modelStatus: DictationModelStatus?
    public private(set) var isCheckingModel = false
    public private(set) var modelInstallProgress: Double?
    public private(set) var modelInstallError: String?
    private var modelInstallTask: Task<Void, Never>?

    public var onSnapshotChange: ((DictationSnapshot) -> Void)?
    public var onRequestDisplay: ((CGDirectDisplayID?) -> Void)?
    public var onAnnounce: ((String) -> Void)?

    private let insertionService = TextInsertionService.shared

    public init() {}

    // MARK: Permissions helpers

    public var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: Public API

    public func toggle() {
        switch state.toggleIntent {
        case .start:
            Task { await start() }
        case .cancel:
            // There is no audio to finalize yet. More importantly, cancelling
            // must invalidate the in-flight permission/download continuation so
            // it cannot start the microphone after the user toggles back off.
            cancel()
        case .stop:
            Task { await stop() }
        case .ignore:
            break // ignore during finalization
        }
    }

    public func start() async {
        // Duplicate start protection via generation – only allow idle/terminal
        // states. Shares `canStartNewSession` with the push-to-talk gate so the
        // two can never disagree about when a hold is allowed to begin.
        guard state.canStartNewSession else { return }
        // Cross-feature exclusivity is enforced by AppCoordinator before this
        // dedicated transient session is started.

        successCollapseTask?.cancel()
        successCollapseTask = nil
        sessionID &+= 1
        let currentSession = sessionID
        snapshot = DictationSnapshot(
            state: .requestingMicrophone,
            sessionID: currentSession,
            elapsed: 0,
            finalizedText: "",
            volatileText: "",
            isHoverExpanded: false,
            languageCode: Preferences.shared.dictationLanguage
        )
        meter = DictationMeter()
        elapsedSeconds = 0

        insertionTarget = insertionService.captureTarget()
        targetDisplayID = insertionTarget?.displayID ?? activeDisplayID()
        onRequestDisplay?(targetDisplayID)

        state = .requestingMicrophone
        publish()
        announce("Dictation started")

        Log.dictation.notice(
            "Starting dictation session \(currentSession, privacy: .public) in \(Preferences.shared.dictationLanguage, privacy: .public)"
        )

        // Check Notch Dictation enabled
        guard Preferences.shared.dictationEnabled else {
            fail("Dictation is disabled in Settings", session: currentSession)
            return
        }

        // Microphone permission
        let micGranted = await PermissionCenter.shared.requestMicrophoneAccess()
        guard checkSession(currentSession) else { return }
        guard micGranted else {
            fail("Microphone access denied. Enable it in System Settings.", session: currentSession)
            return
        }

        // Model preparation
        state = .preparingModel(progress: 0)
        publish()

        Log.dictation.notice("Microphone granted; preparing the language model")

        let locale = Locale(identifier: Preferences.shared.dictationLanguage)
        // Check installed locales; if missing, show download progress
        do {
            try await ensureModel(for: locale, session: currentSession)
        } catch {
            if !checkSession(currentSession) { return }
            fail(error.localizedDescription, session: currentSession)
            return
        }
        guard checkSession(currentSession) else { return }

        // Prepare the analyzer before opening the microphone. This removes the
        // race where Stop could finalize an analyzer that was still starting and
        // avoids buffering speech before there is a consumer.
        let eng = SpeechAnalyzerDictationEngine()
        engine = eng
        finalizedParts = []
        volatilePart = ""

        let onTranscript: @MainActor @Sendable (String, Bool) -> Void = { [weak self] text, isFinal in
            guard let self else { return }
            Task { @MainActor in self.receiveTranscript(text, isFinal: isFinal, session: currentSession) }
        }
        let onFailure: @MainActor @Sendable (String) -> Void = { [weak self] msg in
            guard let self else { return }
            Task { @MainActor in
                guard self.checkSession(currentSession) else { return }
                self.fail(msg, session: currentSession)
            }
        }

        do {
            try await eng.start(locale: locale, onTranscript: onTranscript, onFailure: onFailure)
        } catch {
            guard checkSession(currentSession) else { return }
            fail(error.localizedDescription, session: currentSession)
            return
        }
        guard checkSession(currentSession) else {
            await eng.cancel()
            return
        }

        let capture = DictationAudioCapture()
        let stream: AsyncStream<SendableAudioBuffer>
        do {
            stream = try capture.start()
        } catch {
            await eng.cancel()
            engine = nil
            fail("Microphone unavailable: \(error.localizedDescription)", session: currentSession)
            return
        }
        audioCapture = capture
        startedAt = Date()
        state = .listening
        publish()

        startTimers()

        let maxDuration = Preferences.shared.dictationMaximumDuration
        if maxDuration > 0 {
            maxDurationTimer?.invalidate()
            maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in await self?.stop() }
            }
            if let timer = maxDurationTimer { RunLoop.main.add(timer, forMode: .common) }
        }

        // Feed audio buffers
        Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                guard await MainActor.run(body: { self.checkSession(currentSession) }) else { break }
                do {
                    try await eng.consume(buffer)
                } catch {
                    await MainActor.run {
                        guard self.checkSession(currentSession) else { return }
                        self.fail(error.localizedDescription, session: currentSession)
                    }
                    break
                }
            }
        }
    }

    public func stop() async {
        guard checkSession(sessionID) else { return }
        switch state {
        case .idle, .completed, .cancelled, .failed, .copied, .inserting, .finalizing:
            return
        default: break
        }
        let currentSession = sessionID
        state = .finalizing
        publish()

        stopTimers()
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        audioCapture?.stop()
        // Keep capture alive until engine finishes
        let eng = engine

        // Finalize engine
        do {
            try await eng?.finish()
        } catch {
            // Continue to insertion attempt even if finalize throws?
        }
        engine = nil
        audioCapture = nil

        guard checkSession(currentSession) else { return }

        let combined = combinedTranscript()
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty speech -> show error but not insert
            fail("No speech detected", session: currentSession)
            return
        }

        // Apply post-processing
        let processed = DictationTextProcessor.process(
            combined,
            mode: Preferences.shared.dictationPostProcessing,
            removeFillerWords: Preferences.shared.dictationRemovesFillerWords,
            deterministicReplacements: Preferences.shared.dictationDeterministicReplacements,
            customDictionary: Dictionary(uniqueKeysWithValues: Preferences.shared.dictationCustomWords.map { ($0, $0) }),
            appendMode: Preferences.shared.dictationAppendMode,
            enableSpokenFormatting: Preferences.shared.dictationSpokenFormattingEnabled
        )

        state = .inserting
        publish()

        let result: TextInsertionResult
        if let target = insertionTarget {
            result = await insertionService.insert(processed, into: target, mode: Preferences.shared.dictationInsertMode)
        } else {
            result = await insertionService.insert(processed, into: DictationInsertionTarget(), mode: Preferences.shared.dictationInsertMode)
        }

        guard checkSession(currentSession) else { return }

        switch result {
        case .inserted:
            state = .completed
            snapshot.finalizedText = processed
            snapshot.volatileText = ""
            publish()
            Log.dictation.notice("Inserted \(processed.count, privacy: .public) characters")
            isLatched = false
            scheduleCollapseAfterSuccess(session: currentSession)
            startQueuedPushToTalkIfNeeded()
        case .copied:
            state = .copied
            snapshot.finalizedText = processed
            snapshot.volatileText = ""
            publish()
            Log.dictation.notice("Copied \(processed.count, privacy: .public) characters to the clipboard")
            isLatched = false
            scheduleCollapseAfterSuccess(session: currentSession)
            startQueuedPushToTalkIfNeeded()
        case .failed(let msg):
            fail(msg, session: currentSession)
        }
    }

    public func cancel() {
        // Invalidate every async continuation from the previous generation.
        // Without this increment, a microphone prompt or model download that
        // completed after Cancel could silently begin a new recording.
        sessionID &+= 1
        let cancellationSession = sessionID
        // Immediately discard transient audio and text, insert nothing, collapse.
        audioCapture?.stop()
        audioCapture = nil
        let activeEngine = engine
        engine = nil
        Task { await activeEngine?.cancel() }
        stopTimers()
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        finalizedParts = []
        volatilePart = ""
        startedAt = nil
        insertionTarget = nil

        // Faster collapse: set cancelled and schedule immediate collapse
        state = .cancelled
        snapshot.finalizedText = ""
        snapshot.volatileText = ""
        publish()
        isLatched = false
        successCollapseTask?.cancel()
        // Collapse quickly (150ms) vs normal 500-800ms
        successCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.checkSession(cancellationSession) else { return }
            await MainActor.run {
                guard self.checkSession(cancellationSession) else { return }
                self.state = .idle
                self.targetDisplayID = nil
                self.snapshot = DictationSnapshot()
                self.meter = DictationMeter()
                self.elapsedSeconds = 0
                self.publish()
            }
        }
    }

    /// Press and release of the push-to-talk key.
    ///
    /// Two behaviours share one key, because holding is only half of how people
    /// actually use it. A real hold records for as long as the key is down. A
    /// *tap* — anything shorter than `latchDuration`, which in practice is
    /// someone pressing and letting go before the microphone has even opened —
    /// latches dictation on instead, and the next tap ends it. Without the
    /// latch a tap captured a few hundred milliseconds of silence and reported
    /// "No speech detected", which reads as the feature being broken.
    public func handlePushToTalk(pressed: Bool) {
        if pressed {
            // A tap has latched dictation on; this press is the one that ends
            // it, not the start of a new session.
            if isLatched, state == .listening {
                isLatched = false
                Log.dictation.notice("Latched dictation ended by a second press")
                Task { await stop() }
                return
            }

            // Finalising the previous session can take a second or more, and a
            // press during that window used to be dropped on the floor. Queue
            // it instead, so a quick second attempt still records.
            if state == .finalizing || state == .inserting {
                pendingPushToTalkStart = true
                Log.dictation.notice("Push-to-talk queued behind the session still finishing")
                return
            }

            guard state.canStartNewSession else {
                Log.dictation.notice(
                    "Push-to-talk press ignored in state \(String(describing: self.state), privacy: .public)"
                )
                return
            }
            pushToTalkPressedAt = Date()
            isLatched = false
            Log.dictation.notice("Push-to-talk pressed")
            Task { await start() }
        } else {
            guard !isLatched else { return }

            let held = pushToTalkPressedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if held < Self.latchDuration, state != .idle {
                isLatched = true
                Log.dictation.notice(
                    "Push-to-talk tapped (\(Int(held * 1000), privacy: .public) ms); latching until the next press"
                )
                return
            }

            let shouldStop: Bool = {
                switch state {
                case .listening, .requestingMicrophone, .preparingModel: return true
                default: return false
                }
            }()
            if shouldStop {
                if state == .listening {
                    Log.dictation.notice("Push-to-talk released while listening; finalising")
                    Task { await stop() }
                } else {
                    // Released before the microphone was open. Nothing was
                    // heard, so there is nothing to finalise.
                    Log.dictation.notice(
                        "Push-to-talk released during \(String(describing: self.state), privacy: .public); nothing captured yet"
                    )
                    cancel()
                }
            }
        }
    }

    /// Starts the session a press asked for while the previous one was still
    /// finishing. Called from every terminal transition.
    private func startQueuedPushToTalkIfNeeded() {
        guard pendingPushToTalkStart else { return }
        pendingPushToTalkStart = false
        // Treated as a fresh hold: the key is still down, so it latches or
        // stops on the same rules as any other.
        pushToTalkPressedAt = Date()
        isLatched = false
        Log.dictation.notice("Starting the queued push-to-talk session")
        Task { await start() }
    }

    public func handleEscape() {
        cancel()
    }

    // MARK: Language model

    /// Re-reads availability for `identifier`. Cheap enough to call whenever the
    /// language picker changes or the Settings pane appears.
    public func refreshModelStatus(for identifier: String? = nil) async {
        let language = identifier ?? Preferences.shared.dictationLanguage
        isCheckingModel = true
        let status = await DictationModelCatalog.status(forLanguage: language)
        isCheckingModel = false
        // A slower check for a language the user has since switched away from
        // must not overwrite the newer one.
        guard language == (identifier ?? Preferences.shared.dictationLanguage) else { return }
        modelStatus = status
        if status.isInstalled { modelInstallError = nil }
    }

    /// Downloads the model for `identifier`, keeping progress visible in
    /// Settings. Re-entrant calls are ignored while one is running.
    public func installModel(for identifier: String? = nil) {
        guard modelInstallTask == nil else { return }
        let language = identifier ?? Preferences.shared.dictationLanguage
        modelInstallError = nil
        modelInstallProgress = 0
        modelInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await DictationModelCatalog.install(languageIdentifier: language) { fraction in
                    self.modelInstallProgress = fraction
                }
                await self.refreshModelStatus(for: language)
            } catch is CancellationError {
                // Cancelled by the user; leave the last known status alone.
            } catch {
                self.modelInstallError = error.localizedDescription
                await self.refreshModelStatus(for: language)
            }
            self.modelInstallProgress = nil
            self.modelInstallTask = nil
        }
    }

    public func cancelModelInstall() {
        modelInstallTask?.cancel()
        modelInstallTask = nil
        modelInstallProgress = nil
    }

    public var isInstallingModel: Bool { modelInstallTask != nil }

    public func setHoverExpanded(_ expanded: Bool) {
        snapshot.isHoverExpanded = expanded
        publish()
    }

    public func handleDisplayChange(to displayID: CGDirectDisplayID) {
        // If originating display disconnects, move safely without losing transcript
        if targetDisplayID != nil, snapshot.displayID != displayID {
            snapshot.displayID = displayID
            targetDisplayID = displayID
            publish()
        }
    }

    // MARK: - Private

    /// Shares `DictationModelCatalog` with Settings so the two can never
    /// disagree about whether a language is ready.
    private func ensureModel(for locale: Locale, session: UInt64) async throws {
        try await DictationModelCatalog.install(languageIdentifier: locale.identifier) { [weak self] fraction in
            guard let self, self.checkSession(session) else { return }
            self.state = .preparingModel(progress: fraction)
            self.publish()
        }
        guard checkSession(session) else { throw CancellationError() }
    }

    private func receiveTranscript(_ text: String, isFinal: Bool, session: UInt64) {
        guard checkSession(session) else { return }
        guard state == .listening || state == .finalizing else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !cleaned.isEmpty { finalizedParts.append(cleaned) }
            volatilePart = ""
        } else {
            volatilePart = cleaned
        }
        snapshot.finalizedText = finalizedParts.joined(separator: " ")
        snapshot.volatileText = volatilePart
        publish()
    }

    private func combinedTranscript() -> String {
        let final = finalizedParts.joined(separator: " ")
        let volatile = volatilePart.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty { return volatile }
        if volatile.isEmpty { return final }
        return final + " " + volatile
    }

    private func fail(_ message: String, session: UInt64) {
        guard checkSession(session) else { return }
        // Public on purpose: this is the line that says why dictation stopped,
        // and a redacted one is useless in a bug report.
        Log.dictation.error("Dictation failed: \(message, privacy: .public)")
        stopTimers()
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        audioCapture?.stop()
        audioCapture = nil
        let activeEngine = engine
        engine = nil
        Task { await activeEngine?.cancel() }
        state = .failed(message)
        snapshot.errorMessage = message
        publish()
        isLatched = false
        startQueuedPushToTalkIfNeeded()
        // Keep island expanded enough to show problem and recovery action; do not auto-collapse immediately
        // Caller UI will show retry/open settings actions.
    }

    private func checkSession(_ s: UInt64) -> Bool { s == sessionID }

    private func publish() {
        snapshot.state = state
        snapshot.sessionID = sessionID
        if snapshot.displayID == nil { snapshot.displayID = targetDisplayID }
        if let at = startedAt { snapshot.elapsed = Date().timeIntervalSince(at) }
        onSnapshotChange?(snapshot)
    }

    private func announce(_ msg: String) {
        onAnnounce?(msg)
    }

    private func startTimers() {
        stopTimers()
        // Waveform at 25 Hz
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWaveform() }
        }
        if let t = waveformTimer { RunLoop.main.add(t, forMode: .common) }

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        if let t = elapsedTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopTimers() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// One column per tick, never a batch — that is what makes the trace scroll
    /// at a constant speed. Writes only `meter`, so the notch shell, its glass,
    /// and its content animations are untouched by microphone activity.
    private func tickWaveform() {
        guard let capture = audioCapture, state == .listening, capture.available else {
            // Let an interrupted trace fall away and scroll out rather than
            // freezing mid-word, and stop once it has flattened.
            if meter.isCapturing || !meter.isSilent {
                var next = meter
                next.isCapturing = false
                next.settle()
                meter = next
            }
            return
        }
        var next = meter
        next.isCapturing = true
        next.advance(level: capture.drainLevel())
        meter = next
    }

    /// Publishing here would push a new `NotchActivity` value five times a
    /// second for a label that only changes once, so the seconds counter is its
    /// own observable value and the snapshot picks up `elapsed` at publish time.
    private func tickElapsed() {
        guard let at = startedAt, state == .listening else { return }
        let seconds = Int(Date().timeIntervalSince(at))
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
    }

    private func scheduleCollapseAfterSuccess(session: UInt64) {
        successCollapseTask?.cancel()
        successCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, self.checkSession(session) else { return }
            await MainActor.run {
                guard self.checkSession(session) else { return }
                // Fade content first, then collapse shape. We do this by clearing snapshot before setting idle.
                self.state = .idle
                self.snapshot = DictationSnapshot()
                self.meter = DictationMeter()
                self.elapsedSeconds = 0
                self.startedAt = nil
                self.insertionTarget = nil
                self.targetDisplayID = nil
                self.finalizedParts = []
                self.volatilePart = ""
                self.publish()
            }
        }
    }

    private func activeDisplayID() -> CGDirectDisplayID? {
        if let main = NSScreen.main, let id = ScreenLookup.displayID(for: main) { return id }
        return nil
    }
}

extension DictationCoordinator {
    func setAppCoordinator(_ coordinator: AppCoordinator) {
        // retained weakly via closure capture in AppCoordinator; no strong cycle needed here
    }
}
