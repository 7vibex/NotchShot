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

    @discardableResult
    public mutating func process(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let rms = Self.rootMeanSquare(of: sampleBuffer) else {
            decay()
            return false
        }
        push(rms: rms)
        return true
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

    /// RMS across every channel of an interleaved or planar PCM buffer.
    public static func rootMeanSquare(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        // An AudioBufferList has a trailing array. A stack value contains room
        // for one buffer only, so planar/multi-channel input must query and
        // allocate the complete list before CoreMedia fills it.
        var requiredSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            return nil
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: 16
        )
        defer { storage.deallocate() }
        let audioBufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        var blockBufferOut: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else { return nil }
        // The returned AudioBuffer pointers may refer to storage owned by this
        // retained block buffer. Keep it alive until every sample has been
        // consumed, including when CoreMedia had to make an aligned copy.
        defer { withExtendedLifetime(blockBufferOut) {} }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var sumOfSquares: Double = 0
        var totalSamples = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            guard let measurement = measurement(
                data: data,
                byteCount: Int(buffer.mDataByteSize),
                format: asbd
            ) else { continue }
            sumOfSquares += measurement.sumOfSquares
            totalSamples += measurement.sampleCount
        }

        guard totalSamples > 0 else { return nil }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    private static func measurement(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        format: AudioStreamBasicDescription
    ) -> (sumOfSquares: Double, sampleCount: Int)? {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        guard !isBigEndian else { return nil }

        if isFloat, format.mBitsPerChannel == 32 {
            let count = byteCount / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            let samples = data.assumingMemoryBound(to: Float.self)
            var meanSquare: Float = 0
            vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
            return (Double(meanSquare) * Double(count), count)
        }

        if isFloat, format.mBitsPerChannel == 64 {
            let count = byteCount / MemoryLayout<Double>.size
            guard count > 0 else { return nil }
            let samples = data.assumingMemoryBound(to: Double.self)
            var meanSquare = 0.0
            vDSP_measqvD(samples, 1, &meanSquare, vDSP_Length(count))
            return (meanSquare * Double(count), count)
        }

        if isSignedInteger, format.mBitsPerChannel == 16 {
            let count = byteCount / MemoryLayout<Int16>.size
            guard count > 0 else { return nil }
            let samples = data.assumingMemoryBound(to: Int16.self)
            var sum = 0.0
            for index in 0 ..< count {
                let normalized = Double(samples[index]) / 32_768.0
                sum += normalized * normalized
            }
            return (sum, count)
        }

        if isSignedInteger, format.mBitsPerChannel == 32 {
            let count = byteCount / MemoryLayout<Int32>.size
            guard count > 0 else { return nil }
            let samples = data.assumingMemoryBound(to: Int32.self)
            var sum = 0.0
            for index in 0 ..< count {
                let normalized = Double(samples[index]) / 2_147_483_648.0
                sum += normalized * normalized
            }
            return (sum, count)
        }

        return nil
    }
}
