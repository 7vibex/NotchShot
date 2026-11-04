import AVFAudio
import Accelerate
import Foundation

/// In-memory microphone capture for dictation. No WAV file, no transcript file.
/// Bounded buffering, single update loop for waveform, no heavy work on real-time callback.
final class DictationAudioCapture: @unchecked Sendable {
    static let maximumBufferedBuffers = 256

    /// Every engine call is a synchronous trip into CoreAudio, up to a second or
    /// two when a Bluetooth route has to switch profile. They all run here, in
    /// order, never on the main thread.
    private let engineQueue = DispatchQueue(
        label: "com.notchshot.dictation.audio",
        qos: .userInitiated
    )
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var isRunning = false
    /// `engine.isRunning` as last seen on `engineQueue`, for `available`, which
    /// is read from the main thread at the waveform tick rate.
    private var engineIsRunning = false
    private var configurationObserver: (any NSObjectProtocol)?
    private var level = AudioLevelMeter.dictation()

    // Waveform state published via callback outside real-time thread.
    private var pendingSamples: [Float] = []
    private let pendingLock = NSLock()

    /// Starts capture. Returns a bounded stream of buffers for the transcriber.
    /// The caller may have been cancelled by the time this returns, and owns
    /// calling `stop()` then.
    func start() async throws -> AsyncStream<SendableAudioBuffer> {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                continuation.resume(with: Result { try self.startEngine() })
            }
        }
    }

    private func startEngine() throws -> AsyncStream<SendableAudioBuffer> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OnDeviceTranscriptionError.noAudio
        }

        let (stream, cont) = AsyncStream<SendableAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maximumBufferedBuffers)
        )

        lock.withLock {
            continuation = cont
            isRunning = true
            pendingSamples = []
            level = AudioLevelMeter.dictation()
        }

        input.removeTap(onBus: 0)
        // Do not capture self strongly in render callback.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Never allocate heavily, log, or update SwiftUI on real-time thread.
            // Compute RMS quickly and yield copy.
            let rms = Self.rms(of: buffer)
            // Apply smoothing off-thread? Do minimal here: enqueue copy and rms.
            // Buffer copy is lightweight but still allocation; keep it bounded.
            let shouldYield: Bool = self.lock.withLock { self.isRunning }
            guard shouldYield else { return }

            // Lightweight level push on this thread is okay (small math) but we
            // keep the smoothed value for polling instead of per-buffer hop.
            // Instead push rms into pending for the UI poll to smooth.
            self.pendingLock.withLock {
                self.pendingSamples.append(rms)
                if self.pendingSamples.count > 1024 {
                    self.pendingSamples.removeFirst(self.pendingSamples.count - 1024)
                }
            }

            if let copy = Self.copy(buffer) {
                _ = self.lock.withLock {
                    self.continuation?.yield(SendableAudioBuffer(copy))
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            lock.withLock { engineIsRunning = true }
            // The engine stops itself when the input route changes. This keeps
            // that visible to the waveform, which must not show a live trace.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.engineQueue.async {
                    let running = self.engine.isRunning
                    self.lock.withLock { self.engineIsRunning = running }
                }
            }
            return stream
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                continuation?.finish()
                continuation = nil
                isRunning = false
            }
            throw error
        }
    }

    /// Ends the stream now, so whatever was already captured drains and nothing
    /// new is added. The engine itself winds down on its queue.
    func stop() {
        lock.withLock {
            isRunning = false
            engineIsRunning = false
            continuation?.finish()
            continuation = nil
        }
        engineQueue.async {
            if let observer = self.configurationObserver {
                NotificationCenter.default.removeObserver(observer)
                self.configurationObserver = nil
            }
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Folds every RMS value captured since the last call into the smoothed
    /// meter and returns the single current level. Called on the main thread at
    /// the waveform tick rate.
    ///
    /// It deliberately returns one value rather than a batch. The caller draws
    /// exactly one column per tick, so scroll speed stays constant regardless of
    /// how many audio buffers happened to land in the last frame; returning raw
    /// per-buffer samples made the old trace lurch between 0 and 7 new bars.
    @discardableResult
    func drainLevel() -> Float {
        let rmsValues: [Float] = pendingLock.withLock {
            let v = pendingSamples
            pendingSamples = []
            return v
        }
        var meter = lock.withLock { level }
        for rms in rmsValues {
            meter.push(rms: rms)
        }
        if rmsValues.isEmpty {
            meter.decay()
        }
        lock.withLock { level = meter }
        return meter.level
    }

    /// Current engine state for UI: ensures we don't show fake waveform.
    var available: Bool {
        lock.withLock { isRunning && engineIsRunning }
    }

    // MARK: Helpers

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else { return 0 }
        var sumSquares: Float = 0
        var total: Int = 0
        for ch in 0..<channelCount {
            let data = channelData[ch]
            var ms: Float = 0
            vDSP_measqv(data, 1, &ms, vDSP_Length(frameLength))
            sumSquares += ms * Float(frameLength)
            total += frameLength
        }
        guard total > 0 else { return 0 }
        return sqrt(sumSquares / Float(total))
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dest = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        dest.frameLength = source.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(dest.mutableAudioBufferList)
        guard srcList.count == dstList.count else { return nil }
        for i in srcList.indices {
            guard let s = srcList[i].mData, let d = dstList[i].mData else { return nil }
            memcpy(d, s, Int(srcList[i].mDataByteSize))
            dstList[i].mDataByteSize = srcList[i].mDataByteSize
        }
        return dest
    }
}

extension AudioLevelMeter {
    /// The dictation waveform's tuning of the meter.
    static func dictation() -> AudioLevelMeter {
        AudioLevelMeter(floorDB: -50, attack: 0.6, release: 0.18, curve: 0.55)
    }
}
