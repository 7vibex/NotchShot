import AVFoundation
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NotchShotKit

@Suite("Bounded command execution", .serialized)
struct BoundedProcessRegressionTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("Both pipes are drained while retained output stays bounded")
    func outputCaps() async throws {
        let result = try await BoundedProcess.run(shell, ["-c", "head -c 1100000 /dev/zero & head -c 90000 /dev/zero >&2 & wait"], timeout: 5)
        #expect(result.status == 0 && !result.timedOut)
        #expect(result.output.utf8.count == BoundedProcess.maximumOutputBytes)
        #expect(result.errorOutput.utf8.count == 64_000)
    }

    @Test("A process ignoring termination is killed within the deadline")
    func ignoredTermination() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await BoundedProcess.run(shell, ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 1)
        #expect(result.timedOut && result.status != 0)
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)
    }

    @Test("An exited parent cannot leave an inherited output pipe hanging")
    func inheritedPipe() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await BoundedProcess.run(shell, ["-c", "sleep 30 & printf '%s' $!"], timeout: 5)
        #expect(result.status == 0 && !result.timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)
        let child = try #require(pid_t(result.output))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while kill(child, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(child, 0) != 0 && errno == ESRCH)
    }

    @Test("Cancellation releases an active command")
    func cancellation() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let request = Task { try await BoundedProcess.run(shell, ["-c", "sleep 30"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(150))
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)
    }
}

@Suite("GIF conversion progress", .serialized)
struct GIFConversionRegressionTests {
    @Test("A stalled or failed encoder exits without silently skipping frames")
    func readinessFailure() throws {
        var clock: TimeInterval = 0
        #expect(throws: NotchShotError.self) {
            try GIFToMovieWriter.waitUntilReady(
                isReady: { false }, failure: { nil }, timeout: 0.03,
                now: { clock }, pause: { clock += $0 }
            )
        }
        #expect(clock >= 0.03 && clock < 0.04)
        #expect(throws: NotchShotError.self) {
            try GIFToMovieWriter.waitUntilReady(
                isReady: { true }, failure: { NotchShotError.exportFailed("fixture failure") }
            )
        }
    }

    @Test("The encoded movie keeps the final frame's delay")
    func finalFrameDuration() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = try makeGIF(in: directory)
        let output = directory.appendingPathComponent("movie.mp4")
        try await Task.detached { try GIFToMovieWriter.write(gif: gif, to: output, fileType: .mp4) }.value
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 0.9) < 0.025)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        let frame = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
        #expect(frame.width == 64 && frame.height == 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".notchshot-convert-") })
    }

    @Test("Failure and cancellation preserve pre-existing destinations")
    func destinationPreserved() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = try makeGIF(in: directory)
        let output = directory.appendingPathComponent("existing.mp4")
        let original = Data("existing fixture".utf8)
        try original.write(to: output)
        let attempt = Task.detached { try GIFToMovieWriter.write(gif: gif, to: output, fileType: .mp4) }
        await #expect(throws: (any Error).self) { try await attempt.value }
        #expect(try Data(contentsOf: output) == original)
        let canceledOutput = directory.appendingPathComponent("canceled.mp4")
        let canceled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try GIFToMovieWriter.write(gif: gif, to: canceledOutput, fileType: .mp4)
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(!FileManager.default.fileExists(atPath: canceledOutput.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".notchshot-convert-") })
    }

    @Test("Cancellation of the public converter reaches its detached writer")
    func publicCancellation() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = try makeGIF(in: directory)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaConversion.convert(gif, to: .mp4, in: directory)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["fixture.gif"])
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeGIF(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fixture.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for (index, delay) in [0.2, 0.3, 0.4].enumerated() {
            let image = TestImage.solid(width: 64, height: 64, red: UInt8(60 + index * 70))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

@Suite("Clipboard import reporting", .serialized)
@MainActor
struct ClipboardImportRegressionTests {
    @Test("A full history reports new retained content instead of net growth")
    func fullHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(storeURL: directory.appendingPathComponent("history.json"), imageDirectory: directory, isEnabled: { true })
        for index in 0..<ClipboardStore.maximumEntryCount {
            let text = "fixture \(index)"
            store.record(ClipboardEntry(kind: .text, text: text, createdAt: Date(timeIntervalSince1970: Double(index)), contentHash: ClipboardEntry.hash(forText: text)))
        }
        let clipping = ImportedClipping(text: "new import", copiedAt: Date(), applicationName: nil, isPinned: false)
        #expect(ClipboardImporter.importClippings([clipping, clipping], into: store, sourceName: "Fixture") == 1)
        #expect(store.ordered.count == ClipboardStore.maximumEntryCount)
        #expect(ClipboardImporter.importClippings([clipping], into: store, sourceName: "Fixture") == 0)
        store.clear()
    }
}
