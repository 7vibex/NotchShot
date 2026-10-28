import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit

/// Instant Replay: while it's on, the last 15 seconds to two minutes of one
/// display are kept in memory, and the replay shortcut saves them as a
/// recording.
///
/// Off by default and never silent: the notch shows a glyph while the buffer
/// runs, and macOS shows its own screen-recording indicator. It pauses while
/// the screen is locked or asleep and while a normal recording runs, and
/// what it held is dropped when it pauses.
@MainActor
@Observable
public final class InstantReplayController {
    public static let shared = InstantReplayController()

    public enum State: Equatable, Sendable {
        case off
        case starting
        case buffering
        /// On in Settings, but waiting: the screen is locked or asleep, or a
        /// recording is running.
        case paused
        case failed(String)
    }

    public private(set) var state: State = .off
    public private(set) var isSaving = false
    public var isBuffering: Bool { state == .buffering }

    @ObservationIgnored var onChange: (() -> Void)?
    /// A start or a running buffer failed; the message is for the notch.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    @ObservationIgnored private var recorder: InstantReplayRecorder?
    @ObservationIgnored private var runningSettings: InstantReplayRecorder.Settings?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sessionLocked = false
    @ObservationIgnored private var recordingActive = false
    @ObservationIgnored private var recentFailures: [Date] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {}

    /// Listens for sleep and lock. Called once at launch.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.screensDidSleepNotification: self.screensAsleep = true
                    case NSWorkspace.screensDidWakeNotification: self.screensAsleep = false
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionLocked = true
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionLocked = false
                    default: return
                    }
                    self.refresh()
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in [ScreenLockSignal.lockedNotification, ScreenLockSignal.unlockedNotification] {
            observers.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated {
                    guard let self, let active = ScreenLockSignal.sessionIsActive(for: name) else { return }
                    self.sessionLocked = !active
                    self.refresh()
                }
            })
        }
        refresh()
    }

    /// A normal recording is running; the replay buffer steps aside.
    func setRecordingActive(_ active: Bool) {
        guard active != recordingActive else { return }
        recordingActive = active
        refresh()
    }

    /// Brings the buffer in line with Settings and the Mac's state.
    /// `userInitiated` may show the Screen Recording prompt.
    public func refresh(userInitiated: Bool = false) {
        let extras = ExtrasPreferences.shared
        guard extras.instantReplayEnabled else {
            recentFailures.removeAll()
            stopRecorder(becoming: .off)
            return
        }
        if screensAsleep || sessionLocked || recordingActive {
            stopRecorder(becoming: .paused)
            return
        }
        if userInitiated { recentFailures.removeAll() }
        if case .failed = state, !userInitiated { return }
        let wanted = (window: TimeInterval(extras.replaySeconds), audio: extras.replayIncludesSystemAudio)
        if let runningSettings, recorder != nil {
            guard runningSettings.window != wanted.window || runningSettings.includesSystemAudio != wanted.audio else { return }
            // A different length or audio choice needs a new writer.
            stopRecorder(becoming: .starting)
        } else if state == .starting {
            return
        }
        startRecorder(window: wanted.window, includesAudio: wanted.audio, userInitiated: userInitiated)
    }

    private func startRecorder(window: TimeInterval, includesAudio: Bool, userInitiated: Bool) {
        if !CGPreflightScreenCaptureAccess() {
            if userInitiated { _ = CGRequestScreenCaptureAccess() }
            fail("Instant Replay needs Screen Recording. Turn NotchShot on in Privacy & Security.")
            return
        }
        generation &+= 1
        let current = generation
        setState(.starting)
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, self.generation == current else { return }
                let displayID = Self.displayUnderPointer() ?? CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                    throw NotchShotError.displayNotFound
                }
                let excludedIDs = WindowExclusionRegistry.shared.excludedWindowNumbers
                // Handed to the recorder and never touched here again.
                nonisolated(unsafe) let filter = SCContentFilter(
                    display: display,
                    excludingWindows: content.windows.filter { excludedIDs.contains($0.windowID) }
                )
                let scale = ScreenLookup.screen(for: display.displayID)?.backingScaleFactor ?? 2
                let settings = InstantReplayRecorder.Settings(
                    window: window,
                    includesSystemAudio: includesAudio,
                    pixelSize: InstantReplayRecorder.Settings.encodedSize(forDisplayPixels: CGSize(
                        width: CGFloat(display.width) * scale,
                        height: CGFloat(display.height) * scale
                    ))
                )
                let recorder = InstantReplayRecorder(settings: settings)
                recorder.onUnexpectedStop = { [weak self] error in
                    Task { @MainActor in self?.recorderStopped(current, error: error) }
                }
                try await recorder.start(filter: filter)
                guard self.generation == current else {
                    await recorder.stop()
                    return
                }
                self.recorder = recorder
                self.runningSettings = settings
                self.setState(.buffering)
            } catch {
                guard let self, self.generation == current else { return }
                self.recorderStopped(current, error: error)
            }
        }
    }

    private func stopRecorder(becoming next: State) {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        if let recorder {
            self.recorder = nil
            Task { await recorder.stop() }
        }
        runningSettings = nil
        setState(next)
    }

    /// The display went away or slept before the notification arrived, or the
    /// encoder failed. Tries again a few seconds later; three failures in a
    /// minute turn the buffer off with a message instead of looping.
    private func recorderStopped(_ stoppedGeneration: Int, error: Error) {
        guard stoppedGeneration == generation else { return }
        Log.recording.error("Instant Replay stopped: \(error.localizedDescription)")
        if let recorder {
            self.recorder = nil
            Task { await recorder.stop() }
        }
        runningSettings = nil
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentFailures.count < 3 else {
            fail("Instant Replay stopped: \(error.localizedDescription)")
            return
        }
        setState(.paused)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func fail(_ message: String) {
        generation &+= 1
        runningSettings = nil
        setState(.failed(message))
        onFailure?(message)
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        onChange?()
    }

    // MARK: Saving

    public enum SaveError: LocalizedError {
        case notBuffering
        case nothingYet

        public var errorDescription: String? {
            switch self {
            case .notBuffering: "Instant Replay is off. Turn it on from the menu bar first."
            case .nothingYet: "Instant Replay has nothing to save yet. Give it a second."
            }
        }
    }

    /// Writes the buffered stretch to `destination` as an ordinary MP4 and
    /// returns its length. Buffering carries on while it saves.
    func save(to destination: URL) async throws -> TimeInterval {
        guard let recorder, state == .buffering else { throw SaveError.notBuffering }
        isSaving = true
        defer { isSaving = false }
        guard let data = await recorder.movieData(includingNewest: true) else { throw SaveError.nothingYet }

        // The segments are a fragmented MP4. Rewriting them as a plain one
        // (no re-encode) is what every editor and upload form expects.
        let fragmented = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-replay-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try data.write(to: fragmented, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fragmented) }

        let asset = AVURLAsset(url: fragmented)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SaveError.nothingYet
        }
        // The video's range: the audio of the last segment can run a few
        // milliseconds past the last frame.
        let range = try await video.load(.timeRange)
        export.timeRange = range
        try await export.export(to: destination, as: .mp4)
        return range.duration.seconds
    }

    private static func displayUnderPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }.flatMap(ScreenLookup.displayID(for:))
    }
}
