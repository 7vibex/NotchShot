import AVFAudio
import CoreMedia
import Foundation
import Speech

public struct CaptionCue: Sendable, Equatable {
    public var start: TimeInterval
    public var duration: TimeInterval
    public var text: String

    public init(start: TimeInterval, duration: TimeInterval, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }
}

public struct RecordingTranscript: Sendable, Equatable {
    public var text: String
    public var cues: [CaptionCue]

    public init(text: String, cues: [CaptionCue]) {
        self.text = text
        self.cues = cues
    }

    public var srt: String {
        cues.enumerated().map { index, cue in
            let end = cue.start + max(cue.duration, 0.25)
            return """
            \(index + 1)
            \(Self.srtTimestamp(cue.start)) --> \(Self.srtTimestamp(end))
            \(cue.text)
            """
        }
        .joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    static func srtTimestamp(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }
}

public enum OnDeviceTranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLocale
    case languageModelNotInstalled
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device transcription is not available on this Mac."
        case .unsupportedLocale:
            "There is no on-device model for this language. Choose another in NotchShot Settings → Dictation."
        case .languageModelNotInstalled:
            // macOS has no pane for this: the model is downloaded by the app
            // itself, so the old "install it in macOS settings" sent people
            // looking for a control that does not exist.
            "The language model for this language isn't installed yet. Install it in NotchShot Settings → Dictation."
        case .noAudio:
            "The recording contains no audio to transcribe."
        }
    }
}

/// Converts the audio track in a finished recording into a local transcript
/// and time-indexed caption cues. It never uploads media or transcript text.
public actor OnDeviceTranscriptionService {
    public static let shared = OnDeviceTranscriptionService()

    public func transcribe(
        recordingURL: URL,
        locale requestedLocale: Locale = .current
    ) async throws -> RecordingTranscript {
        guard SpeechTranscriber.isAvailable else {
            throw OnDeviceTranscriptionError.unavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw OnDeviceTranscriptionError.unsupportedLocale
        }
        let installedLocales = await SpeechTranscriber.installedLocales
        guard installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw OnDeviceTranscriptionError.languageModelNotInstalled
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: recordingURL)
        } catch {
            throw OnDeviceTranscriptionError.noAudio
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collected = Self.collectResults(from: transcriber)
        if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> RecordingTranscript {
        var cues: [CaptionCue] = []
        var parts: [String] = []

        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, result.isFinal else { continue }

            let start = max(0, CMTimeGetSeconds(result.range.start))
            let duration = max(0, CMTimeGetSeconds(result.range.duration))
            cues.append(CaptionCue(start: start, duration: duration, text: text))
            parts.append(text)
        }

        return RecordingTranscript(text: parts.joined(separator: " "), cues: cues)
    }
}
