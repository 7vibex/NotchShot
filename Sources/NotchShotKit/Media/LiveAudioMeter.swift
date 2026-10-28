import Accelerate
import AppKit
import Foundation
import OSLog

/// Drives the now-playing meters from the music itself.
///
/// While the setting is on, something is playing, the screens are awake and
/// at least one meter is on screen, a process tap listens to the player app
/// and four frequency bands are pushed straight into the meters' layers
/// about thirty times a second. SwiftUI never sees the levels, so nothing is
/// re-rendered for them. With the setting off, the permission denied, or the
/// player not found, the meters keep their keyframed bounce.
@MainActor
final class LiveAudioMeter {
    static let shared = LiveAudioMeter()
    static let bandCount = 4

    private let tap = ProcessAudioTap()
    private let meters = NSHashTable<PlaybackMeterView>.weakObjects()
    private var bundleID: String?
    private var isPlaying = false
    private var screensAwake = true
    /// A player that refused once is not retried until it changes, so a
    /// denied permission doesn't prompt or log on every track.
    private var refusedBundleID: String?
    private(set) var isDelivering = false
    private var stopTask: Task<Void, Never>?
    private var tapStartedAt: Date?
    private var lastSignalAt: Date?
    /// A tap without the System Audio Recording permission still starts, but
    /// delivers silence. Playing music this quiet for this long means that,
    /// so the meters go back to their bounce instead of lying flat.
    static let silentTapTimeout: TimeInterval = 4

    func updateSource(bundleID: String?, isPlaying: Bool, screensAwake: Bool) {
        if bundleID != self.bundleID { refusedBundleID = nil }
        let sourceChanged = bundleID != self.bundleID && tap.isRunning
        self.bundleID = bundleID
        self.isPlaying = isPlaying
        self.screensAwake = screensAwake
        if sourceChanged { stopTap() }
        reconcile()
    }

    func attach(_ meter: PlaybackMeterView) {
        meters.add(meter)
        reconcile()
    }

    func detach(_ meter: PlaybackMeterView) {
        meters.remove(meter)
        reconcile()
    }

    func preferenceChanged() {
        if !ExtrasPreferences.shared.usesLiveAudioMeter { refusedBundleID = nil }
        reconcile()
    }

    private var shouldRun: Bool {
        ExtrasPreferences.shared.usesLiveAudioMeter
            && isPlaying && screensAwake
            && meters.count > 0
            && bundleID != nil && bundleID != refusedBundleID
    }

    private func reconcile() {
        if shouldRun {
            stopTask?.cancel()
            stopTask = nil
            if !tap.isRunning { startTap() }
        } else if tap.isRunning, stopTask == nil {
            // A short grace, so a track change or a meter remounting during
            // an island transition doesn't tear the tap down and rebuild it.
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.stopTask = nil
                if !self.shouldRun { self.stopTap() }
            }
        }
    }

    private func startTap() {
        guard let bundleID else { return }
        let analyzer = LevelAnalyzer(bandCount: Self.bandCount)
        do {
            try tap.start(.applications([bundleID])) { samples, channels, rate in
                guard let levels = analyzer.process(samples, channels: channels, sampleRate: rate) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { LiveAudioMeter.shared.deliver(levels) }
                }
            }
            tapStartedAt = Date()
            lastSignalAt = nil
        } catch {
            refusedBundleID = bundleID
            Log.media.notice("Live meter unavailable for \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopTap() {
        tap.stop()
        isDelivering = false
        for meter in meters.allObjects { meter.liveLevelsEnded() }
    }

    private func deliver(_ levels: [Float]) {
        guard tap.isRunning else { return }
        let now = Date()
        if levels.contains(where: { $0 > 0.05 }) {
            lastSignalAt = now
        } else if now.timeIntervalSince(lastSignalAt ?? tapStartedAt ?? now) > Self.silentTapTimeout {
            if lastSignalAt == nil {
                refusedBundleID = bundleID
                Log.media.notice("Live meter heard only silence; falling back to the animated meter")
            }
            stopTap()
            return
        }
        isDelivering = true
        for meter in meters.allObjects { meter.applyLiveLevels(levels) }
    }
}

/// Turns tapped samples into a few smoothed 0...1 band levels. Confined to
/// the tap's queue: one instance per tap, never shared.
final class LevelAnalyzer: @unchecked Sendable {
    static let fftSize = 1024
    /// Analyse roughly every 33 ms of audio, whatever the buffer size.
    static let hopSeconds = 0.033

    private let bandCount: Int
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private var ring: [Float]
    private var ringIndex = 0
    private var filled = 0
    private var sinceLast = 0
    private var smoothed: [Float]
    private var ceilings: [Float]

    init(bandCount: Int) {
        self.bandCount = bandCount
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(Self.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        ring = [Float](repeating: 0, count: Self.fftSize)
        smoothed = [Float](repeating: 0, count: bandCount)
        ceilings = [Float](repeating: -30, count: bandCount)
    }

    static let minimumCeiling: Float = -60

    /// Band edges in hertz: lows, low mids, high mids, highs.
    static let bandEdges: [Double] = [40, 220, 900, 3_200, 12_000]

    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) -> [Float]? {
        let stride = max(channels, 1)
        var index = 0
        while index < samples.count {
            ring[ringIndex] = samples[index]
            ringIndex = (ringIndex + 1) % Self.fftSize
            index += stride
            filled = min(filled + 1, Self.fftSize)
            sinceLast += 1
        }
        let hop = Int(sampleRate * Self.hopSeconds)
        guard filled == Self.fftSize, sinceLast >= hop, let fft else { return nil }
        sinceLast = 0

        // Oldest sample first, windowed.
        var frame = [Float](repeating: 0, count: Self.fftSize)
        for i in 0..<Self.fftSize { frame[i] = ring[(ringIndex + i) % Self.fftSize] }
        vDSP.multiply(frame, window, result: &frame)

        let half = Self.fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                frame.withUnsafeBufferPointer { framePointer in
                    framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &magnitudes)
            }
        }

        let binWidth = sampleRate / Double(Self.fftSize)
        var levels = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let low = max(1, Int(Self.bandEdges[band] / binWidth))
            let high = min(half - 1, max(low + 1, Int(Self.bandEdges[band + 1] / binWidth)))
            let energy = vDSP.mean(magnitudes[low..<high])
            let decibels = 10 * log10(max(energy, 1e-12))
            // Each band keeps its own slowly falling ceiling, so quiet
            // passages and loud masters both use the meter's full height.
            // It never falls below -60 dB: digital silence must stay flat
            // rather than be amplified into a full-height meter.
            ceilings[band] = max(decibels, ceilings[band] - 0.08, Self.minimumCeiling)
            let floor = ceilings[band] - 36
            let target = min(max((decibels - floor) / 36, 0), 1)
            let rate: Float = target > smoothed[band] ? 0.55 : 0.18
            smoothed[band] += (target - smoothed[band]) * rate
            levels[band] = smoothed[band]
        }
        return levels
    }
}
