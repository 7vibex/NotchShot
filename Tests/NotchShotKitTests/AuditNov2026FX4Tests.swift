@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import NotchShotKit

@Suite("Nov 2026 audit: recording, export and file operations", .serialized)
@MainActor
struct AuditNov2026FX4Tests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx4-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    // MARK: Joined recordings

    private func writeTone(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0 ..< 44_100 {
            samples[index] = sin(Float(index) * 0.05) * 0.2
        }
        try file.write(from: buffer)
    }

    private func makeSegment(at url: URL, audioTracks: Int, in root: URL) async throws {
        let videoURL = root.appendingPathComponent("video-\(UUID().uuidString).mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: videoURL)
        let video = AVURLAsset(url: videoURL)
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        let composition = AVMutableComposition()
        let sourceVideo = try #require(try await video.loadTracks(withMediaType: .video).first)
        let videoTrack = try #require(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        for _ in 0 ..< audioTracks {
            let audioURL = root.appendingPathComponent("audio-\(UUID().uuidString).m4a")
            try writeTone(to: audioURL)
            let audio = AVURLAsset(url: audioURL)
            let sourceAudio = try #require(try await audio.loadTracks(withMediaType: .audio).first)
            let audioRange = try await sourceAudio.load(.timeRange).intersection(range)
            let audioTrack = try #require(composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        }
        let exporter = try #require(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ))
        try await exporter.export(to: url, as: .mp4)
    }

    private func stagingFolders(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".notchshot-export-") }
    }

    @Test("Joining keeps every audio track of every segment")
    func joinKeepsAllAudioTracks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mp4")
        let second = root.appendingPathComponent("second.mp4")
        try await makeSegment(at: first, audioTracks: 2, in: root)
        try await makeSegment(at: second, audioTracks: 2, in: root)
        let sourceDuration = try await AVURLAsset(url: first).load(.duration).seconds
            + AVURLAsset(url: second).load(.duration).seconds

        let destination = root.appendingPathComponent("joined.mp4")
        try await RecordingSegmentJoiner.join([first, second], to: destination)

        let joined = AVURLAsset(url: destination)
        #expect(try await joined.loadTracks(withMediaType: .audio).count == 2)
        #expect(try await joined.loadTracks(withMediaType: .video).count == 1)
        let joinedDuration = try await joined.load(.duration).seconds
        #expect(abs(joinedDuration - sourceDuration) <= 1)
        #expect(try stagingFolders(in: root).isEmpty)
    }

    @Test("Joining silent segments adds no empty audio track")
    func joinWithoutAudio() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mp4")
        let second = root.appendingPathComponent("second.mp4")
        try await makeSegment(at: first, audioTracks: 0, in: root)
        try await makeSegment(at: second, audioTracks: 0, in: root)

        let destination = root.appendingPathComponent("joined.mp4")
        try await RecordingSegmentJoiner.join([first, second], to: destination)

        #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test("A failed join leaves no file at the destination and keeps the sources")
    func failedJoinKeepsSources() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good.mp4")
        try await makeSegment(at: good, audioTracks: 1, in: root)
        let missing = root.appendingPathComponent("missing.mp4")

        let destination = root.appendingPathComponent("joined.mp4")
        await #expect(throws: (any Error).self) {
            try await RecordingSegmentJoiner.join([good, missing], to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: good.path))
        #expect(try stagingFolders(in: root).isEmpty)
    }

    // MARK: Discard

    @Test("Discarding a scratch file that was never created reports nothing retained")
    func discardMissingScratch() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("never-written.mp4")
        let retained = RecordingService().discardScratchRecording(
            missing,
            discardedDirectory: root.appendingPathComponent("discarded")
        ) { _ in
            throw CocoaError(.fileNoSuchFile)
        }
        #expect(retained == nil)
        #expect(!FileManager.default.fileExists(atPath: RecordingScratchRetirement.marker(for: missing).path))
    }

    // MARK: Privacy

    private var visionFailure: NotchShotError { .captureFailed("Vision failed") }

    @Test("A failed text scan never reads as a clean result")
    func failedTextScanIsIncomplete() throws {
        let result = try PrivacyReviewService.result(ocr: .failure(visionFailure), faces: .success([]))
        #expect(result.findings.isEmpty)
        #expect(result.failedChecks == [.text])
        let message = try #require(result.incompleteMessage)
        #expect(PrivacyReviewPresentation.title(
            isReviewing: false,
            errorMessage: message,
            findingCount: 0
        ) == "Review Incomplete")
    }

    @Test("A failed face scan is reported and text findings survive it")
    func failedFaceScanKeepsText() throws {
        let result = try PrivacyReviewService.result(ocr: .success(.empty), faces: .failure(visionFailure))
        #expect(result.failedChecks == [.faces])
        #expect(result.incompleteMessage == "Faces could not be checked.")

        let face = PrivacyFinding(kind: .face, rect: CGRect(x: 0, y: 0, width: 10, height: 10), confidence: 1)
        let partial = try PrivacyReviewService.result(ocr: .failure(visionFailure), faces: .success([face]))
        #expect(partial.findings.map(\.kind) == [.face])
        #expect(partial.incompleteMessage == "Text could not be checked.")
    }

    @Test("Both checks succeeding is complete, and both failing is an error")
    func completeAndTotalFailure() throws {
        let clean = try PrivacyReviewService.result(ocr: .success(.empty), faces: .success([]))
        #expect(clean.incompleteMessage == nil)
        #expect(throws: (any Error).self) {
            try PrivacyReviewService.result(ocr: .failure(visionFailure), faces: .failure(visionFailure))
        }
    }

    // MARK: Rename

    @Test("A dotted basename keeps the file's extension")
    func dottedBasename() throws {
        let current = URL(fileURLWithPath: "/tmp/Shot.png")
        #expect(try ShelfFileOperations.resolvedFilename(for: "Screen 10.30", replacing: current) == "Screen 10.30.png")
        #expect(try ShelfFileOperations.resolvedFilename(for: "release-1.2", replacing: current) == "release-1.2.png")
        #expect(try ShelfFileOperations.resolvedFilename(for: "2026.11.04", replacing: current) == "2026.11.04.png")
        #expect(try ShelfFileOperations.resolvedFilename(for: "Invoice.jpg", replacing: current) == "Invoice.jpg")
        #expect(try ShelfFileOperations.resolvedFilename(for: "Shot.PNG", replacing: current) == "Shot.PNG")
    }

    // MARK: Click zoom

    @Test("Zoom starts from the identity and never shows empty space")
    func zoomCoversTheFrame() {
        let extent = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        #expect(RecordingZoomGeometry.transform(
            focus: CGPoint(x: 10, y: 10),
            zoom: 1,
            in: extent
        ) == .identity)

        let focuses = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1_920, y: 1_080),
            CGPoint(x: 0, y: 1_080),
            CGPoint(x: 1_900, y: 20),
            CGPoint(x: 960, y: 540),
            CGPoint(x: 300, y: 800),
        ]
        for focus in focuses {
            for zoom in stride(from: CGFloat(1.01), through: 1.35, by: 0.02) {
                let transform = RecordingZoomGeometry.transform(focus: focus, zoom: zoom, in: extent)
                let mapped = extent.applying(transform)
                #expect(mapped.minX <= extent.minX + 0.001)
                #expect(mapped.minY <= extent.minY + 0.001)
                #expect(mapped.maxX >= extent.maxX - 0.001)
                #expect(mapped.maxY >= extent.maxY - 0.001)
            }
        }
    }

    @Test("The first step of a zoom moves the clicked point only slightly")
    func zoomDoesNotPop() {
        let extent = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let focus = CGPoint(x: 300, y: 800)
        let moved = focus.applying(RecordingZoomGeometry.transform(focus: focus, zoom: 1.002, in: extent))
        #expect(hypot(moved.x - focus.x, moved.y - focus.y) < 10)
    }

    @Test("At full zoom a point away from the edges reaches the centre")
    func zoomCentresTheClick() {
        let extent = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let focus = CGPoint(x: 900, y: 500)
        let moved = focus.applying(RecordingZoomGeometry.transform(
            focus: focus,
            zoom: RecordingZoomGeometry.maximumZoom,
            in: extent
        ))
        #expect(abs(moved.x - extent.midX) < 0.001)
        #expect(abs(moved.y - extent.midY) < 0.001)
    }

    // MARK: Smooth cursor

    @Test("Outside-the-target pointer samples survive joining and smoothing")
    func pointerOutsideTarget() {
        let segment = RecordingInteractionTimeline(
            duration: 2,
            pointerSamples: [
                RecordingPointerSample(time: 0, point: CGPoint(x: 0.5, y: 0.5)),
                RecordingPointerSample(time: 1, point: CGPoint(x: 1, y: 0.5), isInsideTarget: false),
            ]
        )
        #expect(segment.pointerIsInsideTarget(at: 0.5))
        #expect(!segment.pointerIsInsideTarget(at: 1.5))
        #expect(!segment.smoothed().pointerIsInsideTarget(at: 1.5))

        let joined = RecordingInteractionTimeline.joined([segment, segment])
        #expect(!joined.pointerIsInsideTarget(at: 1.5))
        #expect(joined.pointerIsInsideTarget(at: 2.5))
    }

    // MARK: Export

    @Test("A size cap that cuts the video short is detected")
    func cutShort() {
        #expect(RecordingExportService.isCutShort(5, comparedTo: 10))
        #expect(!RecordingExportService.isCutShort(9.8, comparedTo: 10))
        #expect(RecordingExportService.isCutShort(.nan, comparedTo: 10))
    }

    @Test("GIF frames stay within half of physical memory")
    func gifFrameBudget() {
        let gigabyte: UInt64 = 1_073_741_824
        #expect(RecordingExportService.gifFrameLimit(
            framePixels: 1_280 * 720,
            physicalMemory: 16 * gigabyte
        ) == RecordingExportService.maximumGIFFrames)
        #expect(RecordingExportService.gifFrameLimit(
            framePixels: 2_560 * 1_440,
            physicalMemory: 8 * gigabyte
        ) == 104)
        #expect(RecordingExportService.gifFrameLimit(
            framePixels: 1_000_000_000,
            physicalMemory: gigabyte
        ) == 1)
    }

    @Test("A GIF reports its own pixel size")
    func gifPixelSize() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: source)
        let output = root.appendingPathComponent("output.gif")
        try await RecordingExportService.exportGIF(from: source, to: output, options: GIFExportOptions())
        #expect(RecordingExportService.gifPixelSize(at: output) == CGSize(width: 64, height: 48))
    }

    // MARK: PDF

    private func makePDF(at url: URL, origin: CGPoint) throws {
        var box = CGRect(origin: origin, size: CGSize(width: 400, height: 200))
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: origin.x, y: origin.y, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
    }

    private func pixels(of url: URL) throws -> NSBitmapImageRep {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return NSBitmapImageRep(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func isRed(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent > 0.8 && color.blueComponent < 0.2
    }

    @Test("A rotated PDF page renders whole on a turned canvas")
    func rotatedPDFPage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("rotated.pdf")
        try makePDF(at: pdf, origin: .zero)
        let outputs = try MediaConversion.renderPDFPages(pdf, baseName: "page", directory: root) { document, index in
            let page = document.page(at: index)
            page?.rotation = 90
            return page
        }
        let image = try pixels(of: try #require(outputs.first))
        #expect(image.pixelsWide == 400)
        #expect(image.pixelsHigh == 800)
        // Rotating 90° clockwise takes the bottom-left corner to the top left.
        #expect(isRed(image.colorAt(x: 5, y: 5)))
    }

    @Test("A PDF page whose media box has an offset origin is not drawn off the canvas")
    func offsetPDFPage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("offset.pdf")
        try makePDF(at: pdf, origin: CGPoint(x: 100, y: 50))
        let outputs = try MediaConversion.renderPDFPages(pdf, baseName: "page", directory: root)
        let image = try pixels(of: try #require(outputs.first))
        #expect(image.pixelsWide == 800)
        #expect(image.pixelsHigh == 400)
        #expect(isRed(image.colorAt(x: 5, y: image.pixelsHigh - 6)))
    }

    // MARK: Bug report

    @Test("Display details come from the caller, only when opted in")
    func bugReportDisplays() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("capture.png")
        let encoded = try ImageExport.encode(
            TestImage.solid(width: 32, height: 24, green: 180),
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        try encoded.data.write(to: capture)
        let asset = CaptureAsset(url: capture, kind: .screenshot, pixelSize: CGSize(width: 32, height: 24))

        func manifest(optedIn: Bool, name: String) throws -> BugReportManifest {
            var options = BugReportOptions()
            options.includesDisplayDetails = optedIn
            let package = root.appendingPathComponent(name, isDirectory: true)
            try BugReportPackager.write(asset: asset, options: options, displays: ["100x100 @ 2.0x"], to: package)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                BugReportManifest.self,
                from: Data(contentsOf: package.appendingPathComponent("Manifest.json"))
            )
        }
        #expect(try manifest(optedIn: true, name: "on.notchbug").displays == ["100x100 @ 2.0x"])
        #expect(try manifest(optedIn: false, name: "off.notchbug").displays == nil)
    }

    // MARK: Uninstall

    @Test("Only a login item is unloaded before it goes to the Trash")
    func agentUnload() {
        let appURL = URL(fileURLWithPath: "/Applications/Example.app")
        let agent = AppLeftover(
            url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/com.example.app.helper.plist"),
            category: AppLeftoverScanner.loginItemCategory,
            confidence: .exact,
            byteCount: nil,
            appURL: appURL
        )
        #expect(AppLeftoverScanner.agentUnloadArguments(for: agent, userID: 501) == [
            "bootout",
            "gui/501",
            "/Users/me/Library/LaunchAgents/com.example.app.helper.plist",
        ])
        var preferences = agent
        preferences.category = "Preferences"
        #expect(AppLeftoverScanner.agentUnloadArguments(for: preferences, userID: 501) == nil)
    }
}
