import AVFoundation
import CoreGraphics
import Foundation
import NotchShotKit

/// A deliberately narrow runtime check that executes from the signed app
/// binary, so macOS evaluates the same TCC identity the real UI uses.
@MainActor
func runBundledSelfTest() async -> Int32 {
    print("NotchShot signed runtime self-test")
    print("Screen Recording preflight: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
    guard CGPreflightScreenCaptureAccess() else {
        print("SELF-TEST FAILED: allow Screen Recording, quit NotchShot, and run this again.")
        return 2
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchShot-SelfTest-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        print("SELF-TEST FAILED: \(error.localizedDescription)")
        return 1
    }
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        let snapshot = try await ShareableContentProvider.shared.snapshot(forceRefresh: true)
        guard let display = snapshot.displays.first else {
            print("SELF-TEST FAILED: ScreenCaptureKit reported no displays.")
            return 1
        }

        let testArea = CGRect(
            x: display.frame.midX - 160,
            y: display.frame.midY - 100,
            width: 320,
            height: 200
        )
        let capture = try await CaptureService.shared.captureArea(
            testArea,
            excludedWindows: WindowExclusionRegistry.shared.excludedWindowNumbers,
            showsCursor: false
        )
        let pngURL = directory.appendingPathComponent("Screenshot.png")
        _ = try ImageExport.write(
            capture.cgImage,
            to: pngURL,
            format: .png,
            quality: 1,
            dpiScale: capture.scale
        )
        let pngSize = try pngURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard pngSize > 1_000 else {
            print("SELF-TEST FAILED: screenshot output was unexpectedly empty.")
            return 1
        }
        print("Screenshot: \(capture.cgImage.width)x\(capture.cgImage.height), \(pngSize) bytes")

        let recordingConfiguration = RecordingConfiguration(
            target: .area(testArea, display.id),
            audioSources: [],
            resolution: .p720,
            framesPerSecond: 30,
            showsCursor: false,
            framesWithBackground: true
        )
        try await RecordingService.shared.start(recordingConfiguration)
        try await Task.sleep(for: .seconds(1.5))
        let movieURL = directory.appendingPathComponent("Recording.mp4")
        let recording = try await RecordingService.shared.stop(destination: movieURL)
        let movieSize = try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let duration = recording.duration ?? 0
        let isPlayable = try await AVURLAsset(url: movieURL).load(.isPlayable)
        print(
            "Recording candidate: \(Int(recording.pixelSize.width))x\(Int(recording.pixelSize.height)), "
                + String(format: "%.2fs, %d bytes, playable=%@", duration, movieSize, isPlayable.description)
        )
        guard duration >= 1, movieSize > 1_000, isPlayable else {
            print("SELF-TEST FAILED: recording was not finalized into a playable file.")
            return 1
        }
        print(
            "Recording: \(Int(recording.pixelSize.width))x\(Int(recording.pixelSize.height)), "
                + String(format: "%.2fs, %d bytes", duration, movieSize)
        )
        print("SELF-TEST PASSED")
        return 0
    } catch {
        if RecordingService.shared.isRecording {
            await RecordingService.shared.cancel()
        }
        print("SELF-TEST FAILED: \(error.localizedDescription)")
        return 1
    }
}
