@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NotchShotKit

@Suite("Recording export and post-processing")
struct RecordingExportAndEffectsTests {
    @Test("Exact video dimensions are clamped and even")
    func exactDimensions() {
        let options = ExactVideoExportOptions(pixelSize: CGSize(width: 1_919, height: 1_079))
        #expect(options.sanitizedPixelSize == CGSize(width: 1_918, height: 1_078))

        let bounded = ExactVideoExportOptions(pixelSize: CGSize(width: 99_999, height: -2))
        #expect(bounded.sanitizedPixelSize == CGSize(width: 16_384, height: 2))
    }

    @Test("GIF settings remain inside bounded encoder limits")
    func gifBounds() {
        let options = GIFExportOptions(framesPerSecond: 200, maximumWidth: 50)
        #expect(options.framesPerSecond == 30)
        #expect(options.maximumWidth == 160)
        #expect(RecordingExportService.maximumGIFFrames == 600)
    }

    @Test("A real fixture exports to exact-size MP4 and animated GIF")
    @MainActor
    func realMediaExports() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-recording-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let video = folder.appendingPathComponent("exact.mp4")
        let gif = folder.appendingPathComponent("animated.gif")
        try await Self.makeFixtureVideo(at: source)

        try await RecordingExportService.exportVideo(
            from: source,
            to: video,
            options: ExactVideoExportOptions(pixelSize: CGSize(width: 80, height: 60))
        )
        let videoAsset = AVURLAsset(url: video)
        let videoTrack = try #require(
            try await videoAsset.loadTracks(withMediaType: .video).first
        )
        #expect(try await videoTrack.load(.naturalSize) == CGSize(width: 80, height: 60))

        try await RecordingExportService.exportGIF(
            from: source,
            to: gif,
            options: GIFExportOptions(framesPerSecond: 5, maximumWidth: 160)
        )
        let gifSource = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(gifSource) > 1)
    }

    @Test("Scrolling capture modes preserve axis and automation intent")
    func scrollingModes() {
        #expect(ScrollingCaptureMode.automaticVertical.axis == .vertical)
        #expect(ScrollingCaptureMode.automaticHorizontal.axis == .horizontal)
        #expect(ScrollingCaptureMode.automaticHorizontal.isAutomatic)
        #expect(!ScrollingCaptureMode.manualHorizontal.isAutomatic)
    }

    @Test("SRT translation input omits counters and timestamps")
    func subtitleText() {
        let source = """
        1
        00:00:00,000 --> 00:00:01,000
        Hello there

        2
        00:00:01,000 --> 00:00:02,000
        Welcome back
        """
        #expect(CaptureTranslationView.subtitleText(from: source) == "Hello there\nWelcome back")
    }

    @Test("Recipes decode files written before automation fields existed")
    func recipeBackwardCompatibility() throws {
        let original = CaptureRecipe.all[0]
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "targetMaximumBytes")
        object.removeValue(forKey: "libraryTags")
        object.removeValue(forKey: "collectionName")
        object.removeValue(forKey: "runsOCR")
        let decoded = try JSONDecoder().decode(
            CaptureRecipe.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.id == original.id)
        #expect(decoded.targetMaximumBytes == nil)
        #expect(decoded.libraryTags == nil)
        #expect(decoded.collectionName == nil)
        #expect(decoded.runsOCR == nil)
    }

    @Test("Paused interaction timelines join without time overlap")
    func joinsSegments() {
        let first = RecordingInteractionTimeline(
            duration: 2,
            pointerSamples: [RecordingPointerSample(time: 1, point: CGPoint(x: 0.1, y: 0.2))],
            clickTimes: [1.5]
        )
        let second = RecordingInteractionTimeline(
            duration: 3,
            pointerSamples: [RecordingPointerSample(time: 0.5, point: CGPoint(x: 0.7, y: 0.8))],
            clickTimes: [1],
            clickPoints: [RecordingPointerSample(time: 1, point: CGPoint(x: 0.7, y: 0.8))]
        )
        let joined = RecordingInteractionTimeline.joined([first, second])

        #expect(joined.duration == 5)
        #expect(joined.pointerSamples.map(\.time) == [1, 2.5])
        #expect(joined.clickTimes == [1.5, 3])
        #expect(joined.clickPoints.map(\.time) == [3])
    }

    @Test("Pointer smoothing dampens jumps while preserving sample timing")
    func smoothing() {
        let timeline = RecordingInteractionTimeline(
            duration: 1,
            pointerSamples: [
                RecordingPointerSample(time: 0, point: .zero),
                RecordingPointerSample(time: 1, point: CGPoint(x: 1, y: 1)),
            ]
        )
        let smoothed = timeline.smoothed(alpha: 0.25)
        #expect(smoothed.pointerSamples[1].time == 1)
        #expect(smoothed.pointerSamples[1].point == CGPoint(x: 0.25, y: 0.25))
    }

    @Test("Click zoom eases in, holds, and returns to one")
    func clickZoomCurve() {
        let timeline = RecordingInteractionTimeline(duration: 3, clickTimes: [1])
        #expect(timeline.zoom(at: 0.9) == 1)
        #expect(timeline.zoom(at: 1.3) == 1.35)
        #expect(timeline.zoom(at: 3) == 1)
    }

    @Test("Pointer interpolation uses neighboring samples")
    func pointerInterpolation() {
        let timeline = RecordingInteractionTimeline(
            pointerSamples: [
                RecordingPointerSample(time: 0, point: .zero),
                RecordingPointerSample(time: 2, point: CGPoint(x: 1, y: 0.5)),
            ]
        )
        #expect(timeline.point(at: 1) == CGPoint(x: 0.5, y: 0.25))
    }

    @Test("Click zoom remains focused on the click after the pointer moves")
    func clickFocus() {
        let timeline = RecordingInteractionTimeline(
            pointerSamples: [
                RecordingPointerSample(time: 1, point: CGPoint(x: 0.1, y: 0.2)),
                RecordingPointerSample(time: 2, point: CGPoint(x: 0.9, y: 0.8)),
            ],
            clickTimes: [1],
            clickPoints: [RecordingPointerSample(time: 1, point: CGPoint(x: 0.1, y: 0.2))]
        )
        #expect(timeline.focusPoint(at: 1.5) == CGPoint(x: 0.1, y: 0.2))
        #expect(timeline.focusPoint(at: 3) == CGPoint(x: 0.9, y: 0.8))
    }

    @MainActor
    private static func makeFixtureVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 48,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48,
            ]
        )
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< 10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                64,
                48,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            try #require(status == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                base.initializeMemory(
                    as: UInt8.self,
                    repeating: UInt8((frame * 23) % 255),
                    count: CVPixelBufferGetBytesPerRow(pixelBuffer) * 48
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            try #require(adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)
            ))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
