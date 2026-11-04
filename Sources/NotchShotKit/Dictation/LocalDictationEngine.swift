import AVFAudio
import Foundation
import Speech

/// Abstraction so other engines can be evaluated later without changing callers.
/// Production default is SpeechAnalyzer/SpeechTranscriber.
public protocol LocalDictationEngine: Actor {
    func start(
        locale: Locale,
        onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws
    func consume(_ buffer: SendableAudioBuffer) throws
    func finish() async throws
    func cancel() async
    var analyzerFormat: AVAudioFormat? { get }
}

/// Default SpeechAnalyzer-based engine. Mirrors LiveVoiceNoteTranscriber but
/// adapted for dictation's transient use and generation-aware state.
public actor SpeechAnalyzerDictationEngine: LocalDictationEngine {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    public private(set) var analyzerFormat: AVAudioFormat?
    private let converter = SpeechBufferConverter(
        componentPrefix: "Dictation audio",
        conversionPrefix: "Dictation audio"
    )

    public init() {}

    public func start(
        locale requestedLocale: Locale,
        onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
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
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw OnDeviceTranscriptionError.unavailable
        }
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        self.transcriber = transcriber
        self.analyzer = analyzer
        analyzerFormat = format
        inputContinuation = continuation

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard self != nil else { return }
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await onTranscript(text, isFinal)
                }
            } catch {
                if !Task.isCancelled {
                    await onFailure(error.localizedDescription)
                }
            }
        }
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            await cancel()
            throw error
        }
    }

    public func consume(_ buffer: SendableAudioBuffer) throws {
        guard let inputContinuation, let analyzerFormat else {
            throw OnDeviceTranscriptionError.unavailable
        }
        let converted = try converter.convert(buffer.value, to: analyzerFormat)
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    public func finish() async throws {
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        // `finalizeAndFinishThroughEndOfInput()` closes the result sequence after
        // it has emitted the last stable phrase. Cancelling the consumer here
        // raced that final result and routinely dropped the last few words.
        await resultTask?.value
        clear()
    }

    public func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        await resultTask?.value
        clear()
    }

    private func clear() {
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }
}
