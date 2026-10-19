import AVFoundation
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Audio meter temporary storage")
struct AudioMeterPerformanceTests {
    @Test("Temporary buffer lists preserve every channel and supported PCM representation")
    func supportedFormats() throws {
        for channels in [1, 2, 6] {
            for planar in [false, true] {
                for frames in [1, 17, 1024] {
                    let amplitudes = (0..<channels).flatMap { channel in
                        [Double](repeating: channel.isMultiple(of: 2) ? 0.25 : -0.75, count: frames)
                    }
                    // Interleaving does not change an all-channel RMS.
                    let expected = Float(sqrt(amplitudes.reduce(0) { $0 + $1 * $1 } / Double(amplitudes.count)))
                    let inputs: [(Data, UInt32, UInt32)] = [
                        (amplitudes.map(Float.init).withUnsafeBytes { Data($0) }, 32, kAudioFormatFlagIsFloat),
                        (amplitudes.withUnsafeBytes { Data($0) }, 64, kAudioFormatFlagIsFloat),
                        (amplitudes.map { Int16($0 * 32_768) }.withUnsafeBytes { Data($0) }, 16, kAudioFormatFlagIsSignedInteger),
                        (amplitudes.map { Int32($0 * 2_147_483_648) }.withUnsafeBytes { Data($0) }, 32, kAudioFormatFlagIsSignedInteger),
                    ]
                    for (data, bits, flags) in inputs {
                        let sample = try makeSample(data, bits: bits, flags: flags,
                            channels: channels, planar: planar, frames: frames)
                        let actual = try #require(AudioLevelMeter.rootMeanSquare(of: sample))
                        #expect(abs(actual - expected) < 0.000001)
                        var meter = AudioLevelMeter()
                        let processed = meter.process(sampleBuffer: sample)
                        #expect(processed)
                        #expect(meter.level > 0 && meter.level <= 1)
                    }
                }
            }
        }
    }

    @Test("Unsupported PCM and endian inputs still decay rather than showing invented levels")
    func unsupportedFormats() throws {
        for (data, bits, flags) in [
            (Data([1, 2, 3, 4]), UInt32(8), kAudioFormatFlagIsSignedInteger),
            ([Float](repeating: 0.5, count: 4).withUnsafeBytes { Data($0) }, UInt32(32), kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian),
        ] {
            let sample = try makeSample(data, bits: bits, flags: flags, channels: 1, planar: false, frames: 4)
            #expect(AudioLevelMeter.rootMeanSquare(of: sample) == nil)
            var meter = AudioLevelMeter()
            meter.push(rms: 0.5)
            let before = meter.level
            let processed = meter.process(sampleBuffer: sample)
            #expect(!processed)
            #expect(meter.level < before)
        }
    }

    private func makeSample(_ data: Data, bits: UInt32, flags: UInt32,
        channels: Int, planar: Bool, frames: Int) throws -> CMSampleBuffer {
        let bytesPerFrame = bits / 8 * UInt32(planar ? 1 : channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: bits, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: 0, blockBufferOut: &block) == noErr)
        let readyBlock = try #require(block)
        #expect(data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: readyBlock,
                offsetIntoDestination: 0, dataLength: data.count)
        } == noErr)
        var sample: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: readyBlock, formatDescription: try #require(format), sampleCount: frames,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
