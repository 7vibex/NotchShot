@preconcurrency import AVFAudio
import Foundation
import Speech

public struct LiveTranscriptAccumulator: Sendable, Equatable {
    public private(set) var finalizedParts: [String] = []
    public private(set) var volatilePart = ""

    public init() {}

    public mutating func consume(_ text: String, isFinal: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !cleaned.isEmpty {
                finalizedParts.append(cleaned)
            }
            volatilePart = ""
        } else {
            volatilePart = cleaned
        }
    }

    public var text: String {
        (finalizedParts + (volatilePart.isEmpty ? [] : [volatilePart]))
            .joined(separator: " ")
    }
}

public final class SendableAudioBuffer: @unchecked Sendable {
    public let value: AVAudioPCMBuffer

    public init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class SpeechBufferConverter: @unchecked Sendable {
    enum ConversionError: LocalizedError {
        case couldNotCreateConverter
        case couldNotCreateBuffer
        case conversionFailed(NSError?)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateConverter:
                "The live speech audio converter could not start."
            case .couldNotCreateBuffer:
                "The live speech audio buffer could not be created."
            case let .conversionFailed(error):
                error?.localizedDescription ?? "Live speech audio conversion failed."
            }
        }
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.couldNotCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(1, capacity)
        ) else {
            throw ConversionError.couldNotCreateBuffer
        }

        var conversionError: NSError?
        let input = ConverterInput(buffer: buffer)
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if input.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.wasSupplied = true
            inputStatus.pointee = .haveData
            return input.buffer
        }
        guard status != .error else {
            throw ConversionError.conversionFailed(conversionError)
        }
        return output
    }
}

/// A single progressive SpeechAnalyzer session. Audio never leaves the Mac.
public actor LiveVoiceNoteTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var accumulator = LiveTranscriptAccumulator()
    private let converter = SpeechBufferConverter()

    public init() {}

    public func start(
        locale requestedLocale: Locale = .current,
        onTranscript: @escaping @MainActor @Sendable (String) -> Void,
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
        accumulator = LiveTranscriptAccumulator()
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    await self.receive(
                        String(result.text.characters),
                        isFinal: result.isFinal,
                        onTranscript: onTranscript
                    )
                }
            } catch {
                // The recording path remains independent. The finished file is
                // transcribed again after Stop, so a live-only failure is safe.
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

    func consume(_ buffer: SendableAudioBuffer) throws {
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
        resultTask?.cancel()
        await resultTask?.value
        clear()
    }

    public func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        clear()
    }

    private func receive(
        _ text: String,
        isFinal: Bool,
        onTranscript: @MainActor @Sendable (String) -> Void
    ) async {
        accumulator.consume(text, isFinal: isFinal)
        await onTranscript(accumulator.text)
    }

    private func clear() {
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }
}

/// Captures one microphone stream, writes every buffer to disk, and exposes the
/// same buffers to live transcription. The lock prevents Stop from closing the
/// file while the audio render callback is writing its final buffer.
final class VoiceNoteAudioCapture: @unchecked Sendable {
    /// About 45 seconds at a 4,096-frame tap on a 44.1 kHz input — far more
    /// slack than a healthy transcriber needs, and a hard ceiling if it stalls.
    static let maximumBufferedAudioBuffers = 512

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var writeError: Error?

    func start(
        recordingURL: URL,
        streamsAudioForTranscription: Bool
    ) throws -> AsyncStream<SendableAudioBuffer>? {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OnDeviceTranscriptionError.noAudio
        }

        let file = try AVAudioFile(forWriting: recordingURL, settings: format.settings)
        let streamAndContinuation = streamsAudioForTranscription
            // The render callback yields in real time; the transcriber consumes
            // asynchronously and can fall behind. `.unbounded` would let that
            // gap grow without limit and the backlog is worthless anyway — old
            // audio transcribed late is worse than dropped. The recording on
            // disk is written from the same callback and is never affected.
            ? AsyncStream<SendableAudioBuffer>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.maximumBufferedAudioBuffers)
              )
            : nil
        let stream = streamAndContinuation?.stream
        let continuation = streamAndContinuation?.continuation
        lock.withLock {
            self.file = file
            self.continuation = continuation
            writeError = nil
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            lock.withLock {
                do {
                    try file.write(from: buffer)
                    if let continuation, let copy = Self.copy(buffer) {
                        continuation.yield(SendableAudioBuffer(copy))
                    }
                } catch {
                    writeError = error
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            return stream
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                continuation?.finish()
                self.continuation = nil
                self.file = nil
            }
            throw error
        }
    }

    func stop() throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let error = lock.withLock { () -> Error? in
            continuation?.finish()
            continuation = nil
            file = nil
            return writeError
        }
        if let error { throw error }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return destination
    }
}
