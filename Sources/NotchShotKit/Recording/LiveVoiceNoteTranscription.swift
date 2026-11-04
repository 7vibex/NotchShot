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

/// Shared by voice notes and dictation, which name themselves in its errors.
final class SpeechBufferConverter: @unchecked Sendable {
    struct ConversionError: LocalizedError {
        let errorDescription: String?
    }

    /// Begins "… converter could not start." and "… buffer could not be created."
    private let componentPrefix: String
    /// Begins "… conversion failed."
    private let conversionPrefix: String
    private var converter: AVAudioConverter?

    init(componentPrefix: String, conversionPrefix: String) {
        self.componentPrefix = componentPrefix
        self.conversionPrefix = conversionPrefix
    }

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw ConversionError(errorDescription: "\(componentPrefix) converter could not start.")
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(1, capacity)
        ) else {
            throw ConversionError(errorDescription: "\(componentPrefix) buffer could not be created.")
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
            throw ConversionError(
                errorDescription: conversionError?.localizedDescription ?? "\(conversionPrefix) conversion failed."
            )
        }
        return output
    }
}

/// A single progressive SpeechAnalyzer session. Audio never leaves the Mac.
public actor LiveVoiceNoteTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var accumulator = LiveTranscriptAccumulator()
    private let converter = SpeechBufferConverter(
        componentPrefix: "The live speech audio",
        conversionPrefix: "Live speech audio"
    )

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
        analyzerFormat = nil
    }
}

/// Captures one microphone stream, writes every buffer to disk, and exposes the
/// same buffers to live transcription. The lock prevents Stop from closing the
/// file while the audio render callback is writing its final buffer.
///
/// All engine calls run on `engineQueue`: opening the input device can take
/// hundreds of milliseconds, longer for a Bluetooth input that has to switch
/// profile, and the island animates through it.
final class VoiceNoteAudioCapture: @unchecked Sendable {
    /// About 45 seconds at a 4,096-frame tap on a 44.1 kHz input — far more
    /// slack than a healthy transcriber needs, and a hard ceiling if it stalls.
    static let maximumBufferedAudioBuffers = 512

    enum CaptureError: LocalizedError {
        case inputChanged

        var errorDescription: String? {
            "The microphone changed during the recording, so it stopped there."
        }
    }

    /// Long enough for a tap on any input rate to deliver a buffer if it is
    /// still alive, and short against the speech lost while the note looks live.
    private static let inputCheckDelay: TimeInterval = 1

    private let engine = AVAudioEngine()
    private let engineQueue = DispatchQueue(
        label: "com.notchshot.voice-note-capture",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var writeError: Error?
    private var buffersWritten: UInt64 = 0
    private var onInputLost: (@MainActor @Sendable () -> Void)?
    /// Confined to `engineQueue`.
    private var configurationObserver: NSObjectProtocol?

    /// Starts off the caller's thread. `onInputLost` runs on main if the input
    /// hardware changes and capture does not survive it; `finishCapture()`
    /// then reports `CaptureError.inputChanged`.
    func beginCapture(
        recordingURL: URL,
        streamsAudioForTranscription: Bool,
        onInputLost: @escaping @MainActor @Sendable () -> Void
    ) async throws -> AsyncStream<SendableAudioBuffer>? {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                do {
                    continuation.resume(returning: try self.startOnQueue(
                        recordingURL: recordingURL,
                        streamsAudioForTranscription: streamsAudioForTranscription,
                        onInputLost: onInputLost
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops off the caller's thread.
    func finishCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async {
                do {
                    try self.stopOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Waits for the file to close. For quitting, which has no animation to
    /// protect and must not exit before the WAV is complete.
    func stop() throws {
        try engineQueue.sync { try stopOnQueue() }
    }

    private func startOnQueue(
        recordingURL: URL,
        streamsAudioForTranscription: Bool,
        onInputLost: (@MainActor @Sendable () -> Void)?
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
            self.onInputLost = onInputLost
            writeError = nil
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            lock.withLock {
                do {
                    try file.write(from: buffer)
                    buffersWritten &+= 1
                    if let continuation, let copy = Self.copy(buffer) {
                        continuation.yield(SendableAudioBuffer(copy))
                    }
                } catch {
                    writeError = error
                }
            }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleInputCheck()
        }

        do {
            engine.prepare()
            try engine.start()
            return stream
        } catch {
            removeConfigurationObserver()
            input.removeTap(onBus: 0)
            lock.withLock {
                continuation?.finish()
                self.continuation = nil
                self.file = nil
                self.onInputLost = nil
            }
            throw error
        }
    }

    private func stopOnQueue() throws {
        removeConfigurationObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let error = lock.withLock { () -> Error? in
            continuation?.finish()
            continuation = nil
            file = nil
            onInputLost = nil
            return writeError
        }
        if let error { throw error }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    /// A hardware change usually stops and uninitializes the engine, so the tap
    /// falls silent while the note still looks live. The buffers are the proof
    /// either way: if they keep coming, the change lost nothing.
    private func scheduleInputCheck() {
        let written = lock.withLock { buffersWritten }
        engineQueue.asyncAfter(deadline: .now() + Self.inputCheckDelay) { [weak self] in
            self?.reportInputLost(ifNothingWrittenSince: written)
        }
    }

    private func reportInputLost(ifNothingWrittenSince written: UInt64) {
        let handler = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            guard file != nil, buffersWritten == written, writeError == nil else { return nil }
            writeError = CaptureError.inputChanged
            return onInputLost
        }
        guard let handler else { return }
        Task { @MainActor in handler() }
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
