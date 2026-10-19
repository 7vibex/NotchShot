import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import NotchShotKit

/// Isolated, deterministic workloads for the behavior-preserving performance sweep.
/// No general pasteboard, user preferences, permission requests or network traffic.
@MainActor
enum PerformanceSweepBenchmarks {
    static func run(enabled: (String) -> Bool) {
        guard enabled("performance-sweep") else { return }

        let hashData = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let expectedHash = SHA256.hash(data: hashData).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        precondition(ClipboardEntry.hash(for: hashData) == expectedHash)
        Benchmark.measure("sweep.clipboard.hash 4096 bytes (1000x)") {
            for _ in 0..<1000 { Benchmark.blackHole(ClipboardEntry.hash(for: hashData)) }
        }

        let transcript = Data((0..<1500).map { index in
            "{\"type\":\"assistant\",\"uuid\":\"message-\(index)\",\"timestamp\":\"2026-10-13T09:15:00Z\",\"message\":{\"content\":\"Visible message \(index)\"}}"
        }.joined(separator: "\n").utf8)
        let expectedDate = Date(timeIntervalSince1970: 1_791_882_900)
        let parsed = ClaudeConversationReader.messages(from: transcript)
        precondition(parsed.count == 80 && parsed.first?.id == "message-1420"
            && parsed.last?.text == "Visible message 1499"
            && parsed.allSatisfy { $0.timestamp == expectedDate })
        Benchmark.measure("sweep.transcript 1500 timestamped messages", iterations: 9) {
            Benchmark.blackHole(ClaudeConversationReader.messages(from: transcript))
        }

        for count in [120, 1200] {
            let document = EditorBenchmarks.document(
                elementCount: count, size: CGSize(width: 2880, height: 1800), includeRedactions: false
            )
            let points = (0..<100).map { CGPoint(x: ($0 * 173) % 2880, y: ($0 * 97) % 1800) }
            for point in points {
                precondition(document.element(at: point)?.id
                    == document.sortedElements.reversed().first(where: { $0.contains(point) })?.id)
            }
            Benchmark.measure("sweep.annotation hitTest \(count) (1000x)") {
                for index in 0..<1000 {
                    Benchmark.blackHole(document.element(at: points[index % points.count]))
                }
            }
        }

        let storeURL = Fixtures.runDirectory.appendingPathComponent("sweep-clipboard.json")
        let rows: [ClipboardEntry] = (0..<500).map { index -> ClipboardEntry in
            let id = UUID()
            let text: String? = index == 0 ? nil : String(repeating: "Clipping \(index) ", count: 100)
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            return ClipboardEntry(
                id: id,
                kind: index == 0 ? .image : .text,
                text: text,
                imageFilename: index == 0 ? "\(id.uuidString).png" : nil,
                createdAt: createdAt,
                contentHash: "fixture-\(index)"
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode(rows).write(to: storeURL, options: .atomic)
        var store = ClipboardStore(storeURL: storeURL, imageDirectory: Fixtures.runDirectory)
        precondition(store.entries.count == rows.count && store.entry(id: rows[0].id)?.kind == .image,
            "Clipboard fixture must retain the OCR image row")
        Benchmark.measure("sweep.clipboard OCR budget 500 rows", setUp: {
            store = ClipboardStore(storeURL: storeURL, imageDirectory: Fixtures.runDirectory)
        }) {
            precondition(store.setRecognizedText("Recognized local text", id: rows[0].id))
            Benchmark.blackHole(store.entries)
        }
        precondition(store.entries.count == 500 && store.entry(id: rows[0].id)?.text == "Recognized local text")
        Benchmark.measure("sweep.clipboard load 500 rows", iterations: 9) {
            let loaded = ClipboardStore(storeURL: storeURL, imageDirectory: Fixtures.runDirectory)
            precondition(loaded.entries.count == 500)
            Benchmark.blackHole(loaded.entries)
        }

        for (channels, planar) in [(1, false), (2, false), (2, true), (6, true)] {
            let sample = audioSample(channels: channels, planar: planar)
            let rms = AudioLevelMeter.rootMeanSquare(of: sample)
            precondition(rms.map { abs($0 - 0.5) < 0.000001 } == true)
            Benchmark.measure("sweep.audio RMS \(channels)ch \(planar ? "planar" : "interleaved") (1000x)") {
                for _ in 0..<1000 {
                    Benchmark.blackHole(AudioLevelMeter.rootMeanSquare(of: sample))
                }
            }
        }
    }

    private static func audioSample(channels: Int, planar: Bool) -> CMSampleBuffer {
        let frames = 1024
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: UInt32(4 * (planar ? 1 : channels)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * (planar ? 1 : channels)),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        ) == noErr)
        let values = [Float](repeating: 0.5, count: frames * channels)
        let byteCount = values.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr)
        precondition(values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: byteCount)
        } == noErr)
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!,
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr)
        return sample!
    }
}
