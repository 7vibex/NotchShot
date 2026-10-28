import AVFAudio
import AppKit
import Foundation
import Observation
import OSLog
import ShazamKit

/// "What's this song?": listens to what the Mac itself is playing — a video
/// in a browser tab, a game, a stream with no track metadata — and asks
/// Shazam's catalogue what it is.
///
/// It taps the Mac's output, not the microphone, so it works with headphones
/// on and in a noisy room. Audio is matched as it arrives and is never kept;
/// listening stops at the first answer or after `timeout`. ShazamKit sends
/// an audio signature, not the audio, to Apple.
@MainActor
@Observable
public final class SongRecognizer {
    public static let shared = SongRecognizer()

    public struct Match: Equatable, Sendable {
        public var title: String
        public var artist: String?
        public var appleMusicURL: URL?
        public var webURL: URL?
    }

    public enum State: Equatable {
        case idle
        case listening
        case matched(Match)
        case noMatch
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Called with each state the island should announce.
    @ObservationIgnored var onEvent: ((IslandTransientEvent) -> Void)?

    static let timeout: Duration = .seconds(12)

    @ObservationIgnored private let tap = ProcessAudioTap()
    @ObservationIgnored private var session: SHSession?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    public var isListening: Bool { state == .listening }

    /// Starts listening, or stops if it already is.
    public func toggle() {
        isListening ? cancel() : start()
    }

    public func start() {
        cancel()
        let session = SHSession()
        self.session = session
        let feeder = SongBufferFeeder(session: session)
        do {
            try tap.start(.system) { samples, channels, rate in
                feeder.feed(samples, channels: channels, sampleRate: rate)
            }
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }
        state = .listening
        onEvent?(SongRecognitionPolicy.event(for: .listening))
        resultsTask = Task { [weak self] in
            for await result in session.results {
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .match(let match):
                    if let found = SongRecognitionPolicy.match(from: match) {
                        self.finish(.matched(found))
                        return
                    }
                case .noMatch:
                    // A miss on one stretch is normal; keep listening until
                    // the timeout says otherwise.
                    continue
                case .error(let error, _):
                    self.finish(.failed(SongRecognitionPolicy.message(for: error)))
                    return
                }
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.finish(.noMatch)
        }
    }

    public func cancel() {
        tearDown()
        if state == .listening { state = .idle }
    }

    /// Opens the match in Music, or on the web when Music can't.
    public func openLastMatch() {
        guard case .matched(let match) = state, let url = match.appleMusicURL ?? match.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func finish(_ outcome: State) {
        tearDown()
        state = outcome
        onEvent?(SongRecognitionPolicy.event(for: outcome))
        if case .failed(let message) = outcome {
            Log.media.notice("Song recognition failed: \(message, privacy: .public)")
        }
    }

    private func tearDown() {
        tap.stop()
        resultsTask?.cancel()
        resultsTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        session = nil
    }
}

/// Hands tapped audio to ShazamKit from the tap's queue. ShazamKit accepts
/// streaming buffers from any one thread; this is only ever called from the
/// tap's serial queue.
private final class SongBufferFeeder: @unchecked Sendable {
    private let session: SHSession
    private var format: AVAudioFormat?

    init(session: SHSession) { self.session = session }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        if format?.sampleRate != sampleRate {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        }
        guard let format else { return }
        let stride = max(channels, 1)
        let frames = samples.count / stride
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        // Mono from the first channel; matching needs the tune, not the stereo.
        for frame in 0..<frames { channel[frame] = samples[frame * stride] }
        buffer.frameLength = AVAudioFrameCount(frames)
        session.matchStreamingBuffer(buffer, at: nil)
    }
}

/// Words and symbols for each step, kept out of the recognizer so they can
/// be tested without ShazamKit.
enum SongRecognitionPolicy {
    static let symbol = "shazam.logo.fill"

    static func event(for state: SongRecognizer.State) -> IslandTransientEvent {
        switch state {
        case .idle, .listening:
            IslandTransientEvent(
                kind: .song,
                coalescingKey: "song",
                symbolName: "shazam.logo",
                title: "Listening…",
                detail: "What's this song?",
                holdDuration: 8
            )
        case .matched(let match):
            IslandTransientEvent(
                kind: .song,
                severity: .success,
                coalescingKey: "song",
                symbolName: symbol,
                title: match.title,
                detail: match.artist,
                holdDuration: 6
            )
        case .noMatch:
            IslandTransientEvent(
                kind: .song,
                severity: .warning,
                coalescingKey: "song",
                symbolName: "shazam.logo",
                title: "No Match",
                detail: "Try again while the song is louder",
                holdDuration: 2.6
            )
        case .failed(let message):
            IslandTransientEvent(
                kind: .song,
                severity: .error,
                coalescingKey: "song",
                symbolName: "exclamationmark.triangle.fill",
                title: "Couldn't Listen",
                detail: message,
                holdDuration: 4
            )
        }
    }

    static func match(from match: SHMatch) -> SongRecognizer.Match? {
        guard let item = match.mediaItems.first,
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return SongRecognizer.Match(
            title: title,
            artist: item.artist,
            appleMusicURL: item.appleMusicURL,
            webURL: item.webURL
        )
    }

    /// ShazamKit's own messages are written for developers.
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SHErrorDomain {
            switch SHError.Code(rawValue: nsError.code) {
            case .matchAttemptFailed?:
                return "Shazam couldn't be reached. Check the connection."
            case .internalError?:
                return "Song recognition isn't available in this build of NotchShot."
            default:
                break
            }
        }
        return nsError.localizedDescription
    }
}
