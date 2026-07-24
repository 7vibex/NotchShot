import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Turns raw audio sample buffers into a 0…1 level suitable for a meter.
///
/// Uses RMS in dBFS mapped onto a perceptual curve, with an asymmetric
/// smoothing envelope — fast attack so speech registers immediately, slow
/// release so the meter doesn't strobe between syllables.
public struct AudioLevelMeter: Sendable {
    /// Floor of the displayed range, in dBFS.
    private let floorDB: Float = -60
    private let attack: Float = 0.55
    private let release: Float = 0.12

    private var smoothed: Float = 0

    public init() {}

    public var level: Float { smoothed }

    public mutating func decay() {
        smoothed *= (1 - release)
        if smoothed < 0.001 { smoothed = 0 }
    }

    public mutating func process(sampleBuffer: CMSampleBuffer) {
        guard let rms = Self.rootMeanSquare(of: sampleBuffer) else {
            decay()
            return
        }
        push(rms: rms)
    }

    public mutating func push(rms: Float) {
        let db = rms > 0 ? 20 * log10(rms) : floorDB
        let clamped = max(floorDB, min(0, db))
        // Normalise, then bias upward so quiet-but-present audio is visible.
        let linear = (clamped - floorDB) / -floorDB
        let target = powf(linear, 0.6)

        let coefficient = target > smoothed ? attack : release
        smoothed += (target - smoothed) * coefficient
        smoothed = max(0, min(1, smoothed))
    }

    /// RMS across every channel of an interleaved or planar float buffer.
    public static func rootMeanSquare(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        // ScreenCaptureKit delivers 32-bit float PCM; anything else is treated
        // as unmeterable rather than misread as garbage.
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            return nil
        }

        var blockBufferOut: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var sumOfSquares: Float = 0
        var totalFrames = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: frameCount)
            var channelSum: Float = 0
            vDSP_measqv(samples, 1, &channelSum, vDSP_Length(frameCount))
            sumOfSquares += channelSum * Float(frameCount)
            totalFrames += frameCount
        }

        guard totalFrames > 0 else { return nil }
        return sqrtf(sumOfSquares / Float(totalFrames))
    }
}
