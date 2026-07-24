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
    public private(set) var isRecording = false
    public private(set) var configuration: RecordingConfiguration?

    /// Fires roughly 10×/second while recording.
    public var onStatusChange: ((RecordingStatus) -> Void)?
    /// Fires if the stream dies on its own (display unplugged, window closed).
    public var onUnexpectedStop: ((NotchShotError) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var bridge: StreamBridge?
    /// The live stream configuration, kept so mid-recording updates can change
    /// one property instead of rebuilding (and zeroing) the rest.
    private var activeStreamConfiguration: SCStreamConfiguration?
    private var temporaryURL: URL?
    private var startedAt: Date?
    private var tickTimer: Timer?
    private var systemMeter = AudioLevelMeter()
    private var microphoneMeter = AudioLevelMeter()

    public init() {}

    // MARK: Start

    public func start(_ configuration: RecordingConfiguration) async throws {
        guard !isRecording else { return }
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
        bridge.onAudio = { [weak self] buffer, type in
            Task { @MainActor in self?.handleAudio(buffer, type: type) }
        }
        bridge.onStreamError = { [weak self] error in
            Task { @MainActor in self?.handleStreamFailure(error) }
        }
        bridge.onRecordingError = { [weak self] error in
            Task { @MainActor in self?.handleStreamFailure(error) }
        }
        self.bridge = bridge

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: bridge)

        // Audio taps for the meters. Failing to add one is not fatal — the
        // recording still works, the meter just stays flat.
        let queue = DispatchQueue(label: "com.notchshot.audio-meter", qos: .userInitiated)
        if configuration.audioSources.contains(.system) {
            try? stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.audioSources.contains(.microphone) {
            try? stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: queue)
        }

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = temporary
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: bridge)
        do {
            try stream.addRecordingOutput(output)
        } catch {
            throw NotchShotError.recordingFailed(error.localizedDescription)
        }

        do {
            try await stream.startCapture()
        } catch {
            if CaptureService.isPermissionError(error) {
                throw NotchShotError.screenRecordingPermissionDenied
            }
            throw NotchShotError.recordingFailed(error.localizedDescription)
        }

        self.stream = stream
        self.recordingOutput = output
        self.activeStreamConfiguration = streamConfiguration
        self.temporaryURL = temporary
        self.configuration = configuration
        self.startedAt = Date()
        self.isRecording = true

        systemMeter = AudioLevelMeter()
        microphoneMeter = AudioLevelMeter()
        status = RecordingStatus()
        status.isSystemAudioEnabled = configuration.audioSources.contains(.system)
        status.isMicrophoneEnabled = configuration.audioSources.contains(.microphone)
        startTicking()

        Log.recording.notice("Recording started → \(temporary.lastPathComponent)")
    }

    // MARK: Stop / cancel

    /// Stops and moves the finished file to its destination.
    @discardableResult
    public func stop(destination: URL? = nil) async throws -> CaptureAsset {
        guard isRecording, let stream, let temporary = temporaryURL else {
            throw NotchShotError.recordingFailed("Nothing is recording")
        }

        stopTicking()
        isRecording = false

        do {
            try await stream.stopCapture()
        } catch {
            // A stop failure usually still leaves a playable file; keep going
            // and let the move/validate step decide.
            Log.recording.error("stopCapture failed: \(error.localizedDescription)")
        }

        let duration = recordingOutput?.recordedDuration.seconds ?? status.elapsed
        teardown()

        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw NotchShotError.recordingFailed("The recording file is missing")
        }

        let finalURL = destination ?? defaultRecordingURL()
        let moved = moveOrCopy(from: temporary, to: finalURL)
        let size = try await videoPixelSize(of: moved)

        Log.recording.notice("Recording finished: \(moved.lastPathComponent)")
        return CaptureAsset(
            url: moved,
            kind: .recording,
            pixelSize: size,
            scale: 1,
            duration: duration.isFinite && duration > 0 ? duration : status.elapsed
        )
    }

    /// Stops and throws the footage away.
    public func cancel() async {
        guard isRecording else { return }
        stopTicking()
        isRecording = false
        if let stream {
            try? await stream.stopCapture()
        }
        let temporary = temporaryURL
        teardown()
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
        Log.recording.notice("Recording cancelled")
    }

    /// Toggles the microphone without interrupting the recording.
    public func setMicrophoneEnabled(_ enabled: Bool) async {
        guard isRecording, let stream, var configuration else { return }
        if enabled {
            let granted = await PermissionCenter.shared.requestMicrophoneAccess()
            guard granted else { return }
        }

        if enabled {
            configuration.audioSources.insert(.microphone)
        } else {
            configuration.audioSources.remove(.microphone)
        }
        self.configuration = configuration

        // Mutate the live configuration rather than building a fresh one:
        // rebuilding without the source dimensions would push width/height 0
        // into a running stream and kill the recording mid-take.
        guard let updated = activeStreamConfiguration else { return }
        updated.captureMicrophone = enabled
        if let deviceID = configuration.microphoneDeviceID {
            updated.microphoneCaptureDeviceID = deviceID
        }

        do {
            try await stream.updateConfiguration(updated)
            status.isMicrophoneEnabled = enabled
            if !enabled { microphoneMeter = AudioLevelMeter() }
            publishStatus()
        } catch {
            Log.recording.error("Microphone toggle failed: \(error.localizedDescription)")
        }
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
            // Anything under 64 KB has no recoverable frames in it.
            .filter { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 65_536 }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    public func recover(_ url: URL) async throws -> CaptureAsset {
        let destination = defaultRecordingURL()
        let moved = moveOrCopy(from: url, to: destination)
        let size = try await videoPixelSize(of: moved)
        let duration = try? await AVURLAsset(url: moved).load(.duration).seconds
        return CaptureAsset(
            url: moved,
            kind: .recording,
            pixelSize: size,
            scale: 1,
            duration: duration
        )
    }

    // MARK: Internals

    private func teardown() {
        if let bridge, let stream {
            try? stream.removeStreamOutput(bridge, type: .audio)
            try? stream.removeStreamOutput(bridge, type: .microphone)
        }
        stream = nil
        recordingOutput = nil
        bridge = nil
        activeStreamConfiguration = nil
        temporaryURL = nil
        startedAt = nil
        configuration = nil
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
        }

        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, configuration.framesPerSecond))
        )
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.showMouseClicks = configuration.highlightsClicks
        streamConfiguration.scalesToFit = false
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

    private func handleAudio(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        switch type {
        case .audio: systemMeter.process(sampleBuffer: buffer)
        case .microphone: microphoneMeter.process(sampleBuffer: buffer)
        default: break
        }
    }

    private func handleStreamFailure(_ error: Error) {
        guard isRecording else { return }
        Log.recording.error("Stream stopped unexpectedly: \(error.localizedDescription)")
        stopTicking()
        isRecording = false
        onUnexpectedStop?(.recordingFailed(error.localizedDescription))
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
        // Meters decay on their own so a silent passage falls to zero instead
        // of freezing at the last sample's level.
        systemMeter.decay()
        microphoneMeter.decay()
        status.systemLevel = systemMeter.level
        status.microphoneLevel = microphoneMeter.level
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
    /// file where it is rather than losing it.
    private func moveOrCopy(from source: URL, to destination: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: destination)
            return destination
        } catch {
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
                return destination
            } catch {
                Log.recording.error("Could not move recording to \(destination.path); keeping \(source.path)")
                return source
            }
        }
    }

    private func videoPixelSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .zero
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // A rotated track reports its pre-transform size, so apply the
        // transform and take the absolute extents.
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}

/// Bridges ScreenCaptureKit's delegate callbacks — which arrive on arbitrary
/// queues — into `Sendable` closures the `@MainActor` service can consume.
private final class StreamBridge: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    var onAudio: ((CMSampleBuffer, SCStreamOutputType) -> Void)?
    var onStreamError: ((Error) -> Void)?
    var onRecordingError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onAudio?(sampleBuffer, type)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamError?(error)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.recording.debug("Recording output started")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        onRecordingError?(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Log.recording.debug("Recording output finished")
    }
}
