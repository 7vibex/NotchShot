import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records the screen to an H.264 MP4 using ScreenCaptureKit's own recording
/// output, which handles muxing, A/V sync and rotation for us.
///
/// Audio is *also* tapped as raw sample buffers, purely to drive the meters in
/// the notch; the file itself is written by `SCRecordingOutput`.
@MainActor
public final class RecordingService {
    public static let shared = RecordingService()

    public private(set) var status = RecordingStatus()
    public private(set) var configuration: RecordingConfiguration?

    /// Recording owns resources across several suspension points. Keeping the
    /// full phase here prevents a second command, a delegate callback, or app
    /// termination from mistaking "starting" or "finalizing" for idle.
    private enum Lifecycle {
        case idle
        case starting(UUID)
        case recording(UUID)
        case stopping(UUID)
        case cancelling(UUID)
        case failing(UUID)

        var sessionID: UUID? {
            switch self {
            case .idle: nil
            case .starting(let id), .recording(let id), .stopping(let id),
                 .cancelling(let id), .failing(let id): id
            }
        }
    }

    private var lifecycle: Lifecycle = .idle
    private var lifecycleRevision = 0
    private var lifecycleWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public var isRecording: Bool {
        if case .recording = lifecycle { return true }
        return false
    }

    /// True until a start, stop, cancellation, or failure cleanup has fully
    /// released the session. App termination uses this broader signal instead
    /// of the narrower user-visible `isRecording` state.
    public var hasActiveSession: Bool {
        lifecycle.sessionID != nil || stopTask != nil
    }

    /// Fires roughly 10×/second while recording.
    public var onStatusChange: ((RecordingStatus) -> Void)?
    /// Fires if the stream dies on its own (display unplugged, window closed).
    public var onUnexpectedStop: ((NotchShotError, URL?) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    /// `SCStreamConfiguration.backgroundColor` is an assign property, so the
    /// stream does not retain a temporary CGColor for us.
    private var recordingBackgroundColor: CGColor?
    private var bridge: StreamBridge?
    private var temporaryURL: URL?
    private var startedAt: Date?
    private var tickTimer: Timer?
    private let audioMeterQueue = DispatchQueue(
        label: "com.notchshot.audio-meter",
        qos: .userInitiated
    )
    private var recordingActivity: NSObjectProtocol?
    /// Shared by manual stop and app termination so only one finalizer ever
    /// owns or moves the temporary recording.
    private var stopTask: Task<CaptureAsset, Error>?
    private var stopTaskSessionID: UUID?

    public init() {}

    // MARK: Start

    public func start(_ configuration: RecordingConfiguration) async throws {
        guard case .idle = lifecycle, stopTask == nil else {
            throw NotchShotError.recordingFailed("A recording operation is already in progress")
        }
        let sessionID = UUID()
        setLifecycle(.starting(sessionID))
        var scratchURL: URL?
        defer {
            // If this method throws before another terminal handler takes
            // ownership, leave no half-started service state behind.
            if lifecycleIsStarting(sessionID) {
                if let scratchURL {
                    try? FileManager.default.removeItem(at: scratchURL)
                }
                teardown()
                setLifecycle(.idle)
            }
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw NotchShotError.screenRecordingPermissionDenied
        }
        if configuration.audioSources.contains(.microphone) {
            let granted = await PermissionCenter.shared.requestMicrophoneAccess()
            guard granted else { throw NotchShotError.microphonePermissionDenied }
        }

        AppPaths.ensureDirectories()
        // Recording is written to a scratch file first: if export or the app
        // itself dies, the footage is still on disk and recoverable.
        let temporary = AppPaths.inProgress
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        scratchURL = temporary

        guard AppPaths.availableCapacity(at: AppPaths.inProgress) > 500_000_000 else {
            throw NotchShotError.diskSpaceUnavailable
        }

        let content = try await fetchRawShareableContent()
        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        let (filter, sourcePixelSize) = try makeFilter(
            for: configuration,
            content: content,
            excludedWindows: excluded
        )

        let streamConfiguration = makeStreamConfiguration(
            configuration,
            sourcePixelSize: sourcePixelSize,
            content: content
        )

        let bridge = StreamBridge()
        bridge.onStreamError = { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamFailure(error, sessionID: sessionID)
            }
        }
        bridge.onRecordingError = { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamFailure(error, sessionID: sessionID)
            }
        }
        bridge.onRecordingFinished = { [weak self] in
            Task { @MainActor in
                await self?.handleRecordingFinishedUnexpectedly(sessionID: sessionID)
            }
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: bridge)

        // Audio taps for the meters. Failing to add one is not fatal — the
        // recording still works, but the HUD must say the meter is unavailable
        // rather than presenting a flat line as if it proved silence.
        var systemMeterAvailable = false
        var microphoneMeterAvailable = false
        if configuration.audioSources.contains(.system) {
            do {
                try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: audioMeterQueue)
                systemMeterAvailable = true
            } catch {
                Log.recording.error("System-audio meter unavailable: \(error.localizedDescription)")
            }
        }
        if configuration.audioSources.contains(.microphone) {
            do {
                try stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: audioMeterQueue)
                microphoneMeterAvailable = true
            } catch {
                Log.recording.error("Microphone meter unavailable: \(error.localizedDescription)")
            }
        }
        bridge.setMeterAvailability(
            system: systemMeterAvailable,
            microphone: microphoneMeterAvailable
        )

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = temporary
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: bridge)
        self.stream = stream
        self.recordingOutput = output
        self.temporaryURL = temporary
        self.configuration = configuration
        self.bridge = bridge

        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            // A delegate callback may already own failure cleanup. Wait for
            // that exact session instead of tearing its writer down twice.
            if lifecycleIsFailing(sessionID) {
                await waitUntilSessionEnds(sessionID)
            }
            if CaptureService.isPermissionError(error) {
                throw NotchShotError.screenRecordingPermissionDenied
            }
            throw NotchShotError.recordingFailed(error.localizedDescription)
        }

        // Delegate callbacks are installed before `startCapture()`. If one
        // arrived during that await, it is terminal even if start returned
        // successfully; never resurrect that dead stream as recording.
        if let terminalError = bridge.terminalError {
            await handleUnexpectedStop(
                .recordingFailed(terminalError.localizedDescription),
                logMessage: "Recording ended while it was starting: \(terminalError.localizedDescription)",
                sessionID: sessionID
            )
            throw NotchShotError.recordingFailed(terminalError.localizedDescription)
        }
        guard lifecycleIsStarting(sessionID) else {
            await waitUntilSessionEnds(sessionID)
            throw NotchShotError.recordingFailed("The recording ended while it was starting")
        }

        self.startedAt = Date()
        setLifecycle(.recording(sessionID))

        // Close the tiny race between the pre-transition terminal check and
        // publishing the recording state.
        if let terminalError = bridge.terminalError {
            await handleUnexpectedStop(
                .recordingFailed(terminalError.localizedDescription),
                logMessage: "Recording ended immediately after start: \(terminalError.localizedDescription)",
                sessionID: sessionID
            )
            throw NotchShotError.recordingFailed(terminalError.localizedDescription)
        }

        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "NotchShot is recording the screen"
        )

        status = RecordingStatus()
        status.isSystemAudioEnabled = configuration.audioSources.contains(.system)
        status.isMicrophoneEnabled = configuration.audioSources.contains(.microphone)
        status.isSystemMeterAvailable = systemMeterAvailable
        status.isMicrophoneMeterAvailable = microphoneMeterAvailable
        startTicking()

        Log.recording.notice("Recording started → \(temporary.lastPathComponent)")
    }

    // MARK: Stop / cancel

    /// Stops and moves the finished file to its destination.
    @discardableResult
    public func stop(destination: URL? = nil) async throws -> CaptureAsset {
        if let stopTask {
            return try await stopTask.value
        }
        guard case .recording(let sessionID) = lifecycle,
              let stream,
              let temporary = temporaryURL,
              let bridge,
              let recordingOutput else {
            throw NotchShotError.recordingFailed("Nothing is recording")
        }

        stopTicking()
        setLifecycle(.stopping(sessionID))
        let task = Task { @MainActor [weak self] () throws -> CaptureAsset in
            guard let self else {
                throw NotchShotError.recordingFailed("The recording service was released")
            }
            return try await self.performStop(
                sessionID: sessionID,
                stream: stream,
                bridge: bridge,
                recordingOutput: recordingOutput,
                temporary: temporary,
                destination: destination
            )
        }
        stopTask = task
        stopTaskSessionID = sessionID

        do {
            let asset = try await task.value
            clearStopTask(for: sessionID)
            return asset
        } catch {
            clearStopTask(for: sessionID)
            throw error
        }
    }

    /// Stops and throws the footage away.
    public func cancel() async {
        guard case .recording(let sessionID) = lifecycle else { return }
        setLifecycle(.cancelling(sessionID))
        stopTicking()
        if let stream {
            try? await stream.stopCapture()
        }
        if let bridge {
            try? await bridge.waitForRecordingToFinish(timeout: 4)
        }
        let temporary = temporaryURL
        teardown()
        setLifecycle(.idle)
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
        Log.recording.notice("Recording cancelled")
    }

    // MARK: Recovery

    /// Recordings left behind by a crash or a forced quit.
    public static func orphanedRecordings() -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: AppPaths.inProgress,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "mp4" }
            .filter(Self.isRecoverableRecording)
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    public static func isRecoverableRecording(_ url: URL) -> Bool {
        // This is only a cheap candidate filter. `recover` performs the actual
        // AVAsset validation before the file is moved or shown as successful.
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0) > 0
    }

    public func recover(_ url: URL) async throws -> CaptureAsset {
        let metadata = try await validatedVideoMetadata(of: url)
        let destination = defaultRecordingURL()
        let moved = try moveOrCopy(from: url, to: destination)
        return CaptureAsset(
            url: moved,
            kind: .recording,
            pixelSize: metadata.pixelSize,
            scale: 1,
            duration: metadata.duration
        )
    }

    /// Joins an existing finalizer or safely stops a session that is still
    /// starting/recording. Used by `applicationShouldTerminate` so quit never
    /// races the writer or starts a second stop operation.
    public func finishForTermination() async throws -> CaptureAsset? {
        while true {
            if let stopTask {
                return try await stopTask.value
            }

            switch lifecycle {
            case .idle:
                return nil
            case .recording:
                return try await stop()
            case .starting, .stopping, .cancelling, .failing:
                let revision = lifecycleRevision
                await waitForLifecycleChange(after: revision)
            }
        }
    }

    // MARK: Internals

    private struct ValidatedVideoMetadata {
        let pixelSize: CGSize
        let duration: TimeInterval
    }

    private func performStop(
        sessionID: UUID,
        stream: SCStream,
        bridge: StreamBridge,
        recordingOutput: SCRecordingOutput,
        temporary: URL,
        destination: URL?
    ) async throws -> CaptureAsset {
        defer {
            if lifecycle.sessionID == sessionID {
                teardown()
                setLifecycle(.idle)
            }
        }

        do {
            try await stream.stopCapture()
        } catch {
            // The delegate is authoritative about whether the MP4 finalized.
            // Keep waiting, but never accept the file if finalization fails.
            Log.recording.error("stopCapture failed: \(error.localizedDescription)")
        }

        // `stopCapture()` stops the stream, but the MP4 is not ready until the
        // recording-output delegate confirms finalization.
        do {
            try await bridge.waitForRecordingToFinish()
        } catch {
            Log.recording.error("Recording finalization failed: \(error.localizedDescription)")
            throw NotchShotError.recordingFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw NotchShotError.recordingFailed("The recording file is missing")
        }

        // Validate while the file is still in InProgress. A failed or timed-out
        // writer must never move a corrupt artifact into user history.
        let metadata = try await validatedVideoMetadata(of: temporary)
        let finalURL = destination ?? defaultRecordingURL()
        let moved = try moveOrCopy(from: temporary, to: finalURL)

        let reportedDuration = recordingOutput.recordedDuration.seconds
        if reportedDuration.isFinite,
           abs(reportedDuration - metadata.duration) > 1 {
            Log.recording.warning(
                "Recording duration metadata differed from ScreenCaptureKit by more than one second"
            )
        }

        Log.recording.notice("Recording finished: \(moved.lastPathComponent)")
        return CaptureAsset(
            url: moved,
            kind: .recording,
            pixelSize: metadata.pixelSize,
            scale: 1,
            duration: metadata.duration
        )
    }

    private func setLifecycle(_ newValue: Lifecycle) {
        lifecycle = newValue
        lifecycleRevision &+= 1
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll(keepingCapacity: true)
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    private func waitForLifecycleChange(after revision: Int) async {
        if lifecycleRevision != revision { return }
        await withCheckedContinuation { continuation in
            if lifecycleRevision != revision {
                continuation.resume()
            } else {
                lifecycleWaiters.append((revision, continuation))
            }
        }
    }

    private func waitUntilSessionEnds(_ sessionID: UUID) async {
        while lifecycle.sessionID == sessionID {
            let revision = lifecycleRevision
            await waitForLifecycleChange(after: revision)
        }
    }

    private func lifecycleIsStarting(_ sessionID: UUID) -> Bool {
        if case .starting(let currentSessionID) = lifecycle {
            return currentSessionID == sessionID
        }
        return false
    }

    private func lifecycleIsFailing(_ sessionID: UUID) -> Bool {
        if case .failing(let currentSessionID) = lifecycle {
            return currentSessionID == sessionID
        }
        return false
    }

    private func clearStopTask(for sessionID: UUID) {
        guard stopTaskSessionID == sessionID else { return }
        stopTask = nil
        stopTaskSessionID = nil
    }

    private func teardown() {
        if let bridge, let stream {
            try? stream.removeStreamOutput(bridge, type: .audio)
            try? stream.removeStreamOutput(bridge, type: .microphone)
        }
        if let recordingOutput, let stream {
            try? stream.removeRecordingOutput(recordingOutput)
        }
        stream = nil
        recordingOutput = nil
        recordingBackgroundColor = nil
        bridge = nil
        temporaryURL = nil
        startedAt = nil
        configuration = nil
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
    }

    private func makeFilter(
        for configuration: RecordingConfiguration,
        content: SCShareableContent,
        excludedWindows: Set<CGWindowID>
    ) throws -> (SCContentFilter, CGSize?) {
        let excluded = content.windows.filter { excludedWindows.contains($0.windowID) }

        switch configuration.target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NotchShotError.displayNotFound
            }
            let scale = ScreenLookup.screen(for: displayID)?.backingScaleFactor ?? 2
            let size = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
            return (SCContentFilter(display: display, excludingWindows: excluded), size)

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw NotchShotError.windowNotFound
            }
            let scale = ScreenLookup.screen(bestMatchingCGRect: window.frame)?.backingScaleFactor ?? 2
            let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            return (SCContentFilter(desktopIndependentWindow: window), size)

        case .area(let rect, let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NotchShotError.displayNotFound
            }
            let scale = ScreenLookup.screen(for: displayID)?.backingScaleFactor ?? 2
            let size = ScreenGeometry.pixelSize(forPointRect: rect, scale: scale)
            return (SCContentFilter(display: display, excludingWindows: excluded), size)
        }
    }

    private func makeStreamConfiguration(
        _ configuration: RecordingConfiguration,
        sourcePixelSize: CGSize?,
        content: SCShareableContent
    ) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()

        if case .area(let rect, let displayID) = configuration.target,
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            streamConfiguration.sourceRect = ScreenGeometry.displayLocalRect(
                globalCGRect: rect,
                displayCGBounds: display.frame
            )
        }

        if let sourcePixelSize {
            let output = configuration.outputPixelSize(for: sourcePixelSize)
            streamConfiguration.width = Int(output.width)
            streamConfiguration.height = Int(output.height)
            if configuration.framesWithBackground {
                streamConfiguration.destinationRect = configuration.destinationRect(
                    for: sourcePixelSize,
                    outputPixelSize: output
                )
                recordingBackgroundColor = NSColor(
                    calibratedRed: 0.055,
                    green: 0.058,
                    blue: 0.068,
                    alpha: 1
                ).cgColor
                if let recordingBackgroundColor {
                    streamConfiguration.backgroundColor = recordingBackgroundColor
                }
            }
        }

        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, configuration.framesPerSecond))
        )
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.showMouseClicks = configuration.highlightsClicks
        streamConfiguration.scalesToFit = configuration.framesWithBackground
        streamConfiguration.captureResolution = .best
        streamConfiguration.queueDepth = 6
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB

        streamConfiguration.capturesAudio = configuration.audioSources.contains(.system)
        // Our own UI sounds would otherwise end up in the user's recording.
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.captureMicrophone = configuration.audioSources.contains(.microphone)
        if let deviceID = configuration.microphoneDeviceID {
            streamConfiguration.microphoneCaptureDeviceID = deviceID
        }

        return streamConfiguration
    }

    private func handleStreamFailure(_ error: Error, sessionID: UUID) async {
        await handleUnexpectedStop(
            .recordingFailed(error.localizedDescription),
            logMessage: "Stream stopped unexpectedly: \(error.localizedDescription)",
            sessionID: sessionID
        )
    }

    private func handleRecordingFinishedUnexpectedly(sessionID: UUID) async {
        await handleUnexpectedStop(
            .recordingFailed("ScreenCaptureKit finished the recording unexpectedly"),
            logMessage: "Recording output finished before the user stopped it",
            sessionID: sessionID
        )
    }

    private func handleUnexpectedStop(
        _ error: NotchShotError,
        logMessage: String,
        sessionID: UUID
    ) async {
        let ownsTerminalCleanup: Bool
        switch lifecycle {
        case .starting(let current), .recording(let current):
            ownsTerminalCleanup = current == sessionID
        case .idle, .stopping, .cancelling, .failing:
            ownsTerminalCleanup = false
        }
        guard ownsTerminalCleanup else { return }

        Log.recording.error("\(logMessage)")
        stopTicking()
        setLifecycle(.failing(sessionID))
        let candidateURL = temporaryURL
        if let stream {
            try? await stream.stopCapture()
        }

        var recoveryURL: URL?
        do {
            guard let bridge else {
                throw NotchShotError.recordingFailed("The recording finalizer is unavailable")
            }
            try await bridge.waitForRecordingToFinish(timeout: 4)
            if let candidateURL {
                _ = try await validatedVideoMetadata(of: candidateURL)
                recoveryURL = candidateURL
            }
        } catch {
            // Keep the exact scratch file in InProgress. A later launch may be
            // able to validate it, but it must not be moved while finalization
            // is failed or unresolved.
            Log.recording.error("Unexpected recording could not be validated: \(error.localizedDescription)")
        }

        teardown()
        setLifecycle(.idle)
        onUnexpectedStop?(error, recoveryURL)
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isRecording else { return }
        if let startedAt {
            status.elapsed = Date().timeIntervalSince(startedAt)
        }
        let levels = bridge?.meterSnapshot() ?? (
            system: 0,
            microphone: 0,
            systemAvailable: false,
            microphoneAvailable: false
        )
        status.isSystemMeterAvailable = levels.systemAvailable
        status.isMicrophoneMeterAvailable = levels.microphoneAvailable
        status.appendMeterSnapshot(system: levels.system, microphone: levels.microphone)
        status.fileSizeBytes = Int64(recordingOutput?.recordedFileSize ?? 0)
        publishStatus()
    }

    private func publishStatus() {
        onStatusChange?(status)
    }

    private func defaultRecordingURL() -> URL {
        let preferences = Preferences.shared
        let folder = preferences.saveToDiskAfterCapture ? preferences.outputFolder : AppPaths.recordings
        let name = preferences.expandFilename(appName: "Recording")
        return AppPaths.uniqueURL(in: folder, name: name, extension: "mp4")
    }

    /// Moves when possible, copies across volumes, and falls back to leaving the
    /// source untouched if neither operation can complete.
    private func moveOrCopy(from source: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: destination)
            return destination
        } catch let moveError {
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
                return destination
            } catch let copyError {
                Log.recording.error("Could not move recording to \(destination.path); keeping \(source.path)")
                throw NotchShotError.exportFailed(
                    "Could not save the recording (move: \(moveError.localizedDescription); copy: \(copyError.localizedDescription))"
                )
            }
        }
    }

    private func validatedVideoMetadata(of url: URL) async throws -> ValidatedVideoMetadata {
        let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard byteCount > 0 else {
            throw NotchShotError.recordingFailed("The recording file is empty")
        }

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw NotchShotError.recordingFailed("The recording is not playable")
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NotchShotError.recordingFailed("The recording contains no video track")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // A rotated track reports its pre-transform size, so apply the
        // transform and take the absolute extents.
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let pixelSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            throw NotchShotError.recordingFailed("The recording has invalid video dimensions")
        }

        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NotchShotError.recordingFailed("The recording has no playable duration")
        }
        return ValidatedVideoMetadata(pixelSize: pixelSize, duration: duration)
    }
}

/// Bridges ScreenCaptureKit's delegate callbacks — which arrive on arbitrary
/// queues — into `Sendable` closures the `@MainActor` service can consume.
private final class StreamBridge: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    var onStreamError: ((Error) -> Void)?
    var onRecordingError: ((Error) -> Void)?
    var onRecordingFinished: (() -> Void)?
    private let finalization = RecordingFinalization()
    private let terminalLock = NSLock()
    private var storedTerminalError: Error?
    private let meterLock = NSLock()
    private var systemMeter = AudioLevelMeter()
    private var microphoneMeter = AudioLevelMeter()
    /// Whether a buffer arrived for each source since the last UI tick.
    private var hasFreshSystemSample = false
    private var hasFreshMicrophoneSample = false
    private var isSystemMeterAvailable = false
    private var isMicrophoneMeterAvailable = false

    var terminalError: Error? {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        return storedTerminalError
    }

    func setMeterAvailability(system: Bool, microphone: Bool) {
        meterLock.lock()
        isSystemMeterAvailable = system
        isMicrophoneMeterAvailable = microphone
        meterLock.unlock()
    }

    func waitForRecordingToFinish(timeout: TimeInterval = 12) async throws {
        try await finalization.wait(timeout: timeout)
    }

    /// Called by the 10 Hz UI tick. Sample callbacks do all signal processing
    /// on ScreenCaptureKit's serial queue; the main actor only reads this small
    /// coalesced snapshot.
    func meterSnapshot() -> (
        system: Float,
        microphone: Float,
        systemAvailable: Bool,
        microphoneAvailable: Bool
    ) {
        meterLock.lock()
        defer { meterLock.unlock() }
        // Decay stands in for "no audio arrived", so it must only apply to a
        // source that produced nothing since the last tick. Decaying on every
        // tick pulled the level down by the release coefficient even while
        // sound was playing, so the meter always read low.
        if !hasFreshSystemSample { systemMeter.decay() }
        if !hasFreshMicrophoneSample { microphoneMeter.decay() }
        hasFreshSystemSample = false
        hasFreshMicrophoneSample = false
        return (
            systemMeter.level,
            microphoneMeter.level,
            isSystemMeterAvailable,
            isMicrophoneMeterAvailable
        )
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        meterLock.lock()
        switch type {
        case .audio:
            isSystemMeterAvailable = systemMeter.process(sampleBuffer: sampleBuffer)
            hasFreshSystemSample = true
        case .microphone:
            isMicrophoneMeterAvailable = microphoneMeter.process(sampleBuffer: sampleBuffer)
            hasFreshMicrophoneSample = true
        default:
            break
        }
        meterLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        recordTerminal(error)
        onStreamError?(error)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.recording.debug("Recording output started")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        recordTerminal(error)
        finalization.complete(.failure(error))
        onRecordingError?(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        recordTerminal(NotchShotError.recordingFailed(
            "ScreenCaptureKit finished the recording unexpectedly"
        ))
        finalization.complete(.success(()))
        Log.recording.debug("Recording output finished")
        onRecordingFinished?()
    }

    private func recordTerminal(_ error: Error) {
        terminalLock.lock()
        if storedTerminalError == nil {
            storedTerminalError = error
        }
        terminalLock.unlock()
    }
}

/// Bridges the delegate's eventual finalization callback into async code. It
/// also handles the callback arriving before `stop()` begins awaiting it.
private final class RecordingFinalization: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(.failure(NotchShotError.recordingFailed(
                    "Timed out while finalizing the recording"
                )))
            }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
