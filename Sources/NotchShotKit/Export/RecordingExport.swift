import AVFoundation
import AppKit
import Darwin
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

public enum RecordingExportFormat: String, CaseIterable, Identifiable, Sendable {
    case video
    case gif

    public var id: String { rawValue }
    public var title: String { self == .video ? "MP4 Video" : "Animated GIF" }
    public var fileExtension: String { self == .video ? "mp4" : "gif" }
}

public struct ExactVideoExportOptions: Sendable, Equatable {
    public var pixelSize: CGSize
    public var maximumFileBytes: Int64?

    public init(pixelSize: CGSize, maximumFileBytes: Int64? = nil) {
        self.pixelSize = pixelSize
        self.maximumFileBytes = maximumFileBytes
    }

    public var sanitizedPixelSize: CGSize {
        let width = min(max(Int(pixelSize.width.rounded()), 2), 16_384)
        let height = min(max(Int(pixelSize.height.rounded()), 2), 16_384)
        return CGSize(width: width - width % 2, height: height - height % 2)
    }
}

public struct GIFExportOptions: Sendable, Equatable {
    public var framesPerSecond: Int
    public var maximumWidth: Int
    public var loopsForever: Bool

    public init(framesPerSecond: Int = 12, maximumWidth: Int = 1_280, loopsForever: Bool = true) {
        self.framesPerSecond = min(max(framesPerSecond, 1), 30)
        self.maximumWidth = min(max(maximumWidth, 160), 2_560)
        self.loopsForever = loopsForever
    }
}

public enum RecordingExportService {
    public static let maximumGIFFrames = 600

    public static func exportVideo(
        from sourceURL: URL,
        to destinationURL: URL,
        options: ExactVideoExportOptions
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0,
              let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NotchShotError.exportFailed("That recording has no readable video track")
        }

        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let renderSize = options.sanitizedPixelSize
        guard renderSize.width * renderSize.height <= 100_000_000 else {
            throw NotchShotError.exportFailed("That video size is too large")
        }

        let scale = min(renderSize.width / max(orientedSize.width, 1),
                        renderSize.height / max(orientedSize.height, 1))
        let fitted = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let origin = CGPoint(x: (renderSize.width - fitted.width) / 2,
                             y: (renderSize.height - fitted.height) / 2)

        let mutableAsset = AVMutableComposition()
        guard let destinationVideo = mutableAsset.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NotchShotError.exportFailed("Could not prepare the video track")
        }
        try destinationVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )
        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let destinationAudio = mutableAsset.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try destinationAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(
            assetTrack: destinationVideo
        )
        let normalized = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
        )
        let outputTransform = normalized
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        layerConfiguration.setTransform(outputTransform, at: .zero)
        let layer = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            backgroundColor: NSColor(
                calibratedRed: 0.055,
                green: 0.058,
                blue: 0.068,
                alpha: 1
            ).cgColor,
            layerInstructions: [layer],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        let videoComposition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: 60),
            instructions: [instruction],
            renderSize: renderSize
        ))

        guard let exporter = AVAssetExportSession(asset: mutableAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NotchShotError.exportFailed("Could not create the video exporter")
        }
        exporter.videoComposition = videoComposition
        if let maximum = options.maximumFileBytes, maximum > 0 {
            exporter.fileLengthLimit = maximum
        }
        let staging = try stagingURL(for: destinationURL, fileExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try await exporter.export(to: staging, as: .mp4)
        try publishOutput(at: staging, to: destinationURL)
    }

    public static func exportGIF(
        from sourceURL: URL,
        to destinationURL: URL,
        options: GIFExportOptions
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw NotchShotError.exportFailed("That recording has no readable duration")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maximumWidth, height: options.maximumWidth)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frames = try gifFrames(duration: duration.seconds, requestedFPS: options.framesPerSecond)
        let staging = try stagingURL(for: destinationURL, fileExtension: "gif")
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try await encodeGIF(generator: generator, frames: frames, at: staging,
                            loopsForever: options.loopsForever)
        try publishOutput(at: staging, to: destinationURL)
    }

    // ImageIO can flush a partially written file when its destination is
    // released. Keep that lifetime inside this call so cleanup always happens
    // after the encoder has released its file, including on cancellation.
    private static func encodeGIF(
        generator: AVAssetImageGenerator,
        frames: [(time: TimeInterval, delay: TimeInterval)],
        at url: URL,
        loopsForever: Bool
    ) async throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw NotchShotError.exportFailed("Could not create the GIF destination")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopsForever ? 0 : 1,
            ],
        ] as CFDictionary)

        for frame in frames {
            try Task.checkCancellation()
            let result = try await generator.image(at: CMTime(seconds: frame.time, preferredTimescale: 60_000))
            CGImageDestinationAddImage(destination, result.image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delay,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NotchShotError.exportFailed("The GIF encoder could not finish the file")
        }
    }

    /// GIF stores each delay in hundredths of a second. Distribute the rounding
    /// across the timeline so 600 rounded delays don't lose seconds of footage.
    private static func gifFrames(
        duration: TimeInterval,
        requestedFPS: Int
    ) throws -> [(time: TimeInterval, delay: TimeInterval)] {
        guard duration.isFinite, duration > 0,
              duration <= Double(maximumGIFFrames * 65_535) / 100 else {
            throw NotchShotError.exportFailed("That recording is too long for a complete GIF export")
        }
        let fps = min(max(requestedFPS, 1), 30)
        let count = max(1, Int(min(ceil(duration * Double(fps)), Double(maximumGIFFrames))))
        let ticks = max(count * 2, Int((duration * 100).rounded()))
        return (0 ..< count).map { index in
            let start = index * ticks / count
            let end = (index + 1) * ticks / count
            // Keep the first frame, then sample inside each interval. The last
            // interval therefore represents the tail even below one frame/sec.
            let time = index == 0 ? 0 : (Double(index) + 0.5) * duration / Double(count)
            return (time, Double(end - start) / 100)
        }
    }

    private static func stagingURL(for destination: URL, fileExtension: String) throws -> URL {
        // ImageIO may leave its own temporary sidecar when encoding is cancelled.
        // A private sibling directory contains every file owned by this attempt.
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("output.\(fileExtension)")
    }

    private static func publishOutput(at staging: URL, to destination: URL) throws {
        try validateOutput(at: staging)
        try Task.checkCancellation()
        // The staging directory is a sibling on the same volume. POSIX rename
        // atomically replaces the directory entry; failure keeps the old file.
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func validateOutput(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw NotchShotError.exportFailed("The export did not produce a complete file")
        }
    }
}

@MainActor
@Observable
public final class RecordingExportSession {
    public let asset: CaptureAsset
    public var format: RecordingExportFormat = .video
    public var width: Int
    public var height: Int
    public var maximumMegabytes = 0
    public var gifFramesPerSecond = 12
    public var gifMaximumWidth = 1_280
    public var gifLoopsForever = true
    public var isExporting = false
    public var errorMessage: String?
    public var exportedAsset: CaptureAsset?
    public var onExported: ((CaptureAsset) -> Void)?

    public init(asset: CaptureAsset) {
        self.asset = asset
        width = max(2, Int(asset.pixelSize.width))
        height = max(2, Int(asset.pixelSize.height))
    }

    public func export() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .video ? [.mpeg4Movie] : [.gif]
        panel.directoryURL = Preferences.shared.outputFolder
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent
            + "-export.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await export(to: url) }
    }

    /// The Save panel owns user destination approval; this entry point also
    /// lets filesystem failure checks exercise the actual session error path.
    func export(to url: URL) async {
        guard !isExporting else { return }
        guard SafeAssetFile.isCurrentAndSafe(asset) else {
            errorMessage = "That recording changed or is no longer safely readable. Add it again before exporting."
            return
        }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        // Controls remain editable while encoding. Each operation keeps the
        // choices it began with, including the format used for its result.
        let exportFormat = format
        let exportSize = CGSize(width: width, height: height)
        let videoOptions = ExactVideoExportOptions(
            pixelSize: exportSize,
            maximumFileBytes: maximumMegabytes > 0
                ? Int64(maximumMegabytes) * 1_024 * 1_024 : nil
        )
        let gifOptions = GIFExportOptions(
            framesPerSecond: gifFramesPerSecond,
            maximumWidth: gifMaximumWidth,
            loopsForever: gifLoopsForever
        )
        do {
            if exportFormat == .video {
                try await RecordingExportService.exportVideo(
                    from: asset.url,
                    to: url,
                    options: videoOptions
                )
            } else {
                try await RecordingExportService.exportGIF(
                    from: asset.url,
                    to: url,
                    options: gifOptions
                )
            }
            let metadata = await VideoThumbnail.metadata(for: url)
            let exported = CaptureAsset(
                url: url,
                kind: exportFormat == .video ? .recording : .screenshot,
                pixelSize: metadata?.pixelSize ?? exportSize,
                scale: 1,
                duration: exportFormat == .video ? metadata?.duration : nil,
                ownership: .userDocument
            )
            exportedAsset = exported
            onExported?(exported)
        } catch {
            // Only the service's staging file belongs to a failed attempt.
            // The selected destination may still be the user's previous file.
            errorMessage = error.localizedDescription
        }
    }

}

public struct RecordingExportView: View {
    @Bindable var session: RecordingExportSession

    public init(session: RecordingExportSession) { self.session = session }

    public var body: some View {
        Form {
            Picker("Format", selection: $session.format) {
                ForEach(RecordingExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            if session.format == .video {
                LabeledContent("Exact pixel size") {
                    HStack {
                        TextField("Width", value: $session.width, format: .number)
                        Text("×")
                        TextField("Height", value: $session.height, format: .number)
                    }
                    .frame(width: 250)
                }
                Stepper(
                    session.maximumMegabytes == 0
                        ? "File-size cap: Off"
                        : "File-size cap: \(session.maximumMegabytes) MB",
                    value: $session.maximumMegabytes,
                    in: 0 ... 2_048
                )
            } else {
                Stepper("Frame rate: \(session.gifFramesPerSecond) fps",
                        value: $session.gifFramesPerSecond, in: 1 ... 30)
                Stepper("Maximum width: \(session.gifMaximumWidth) px",
                        value: $session.gifMaximumWidth, in: 160 ... 2_560, step: 160)
                Toggle("Loop forever", isOn: $session.gifLoopsForever)
                Text("GIF export is capped at \(RecordingExportService.maximumGIFFrames) frames to bound memory and file size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = session.errorMessage {
                InlineErrorMessage(message: error)
            }
            HStack {
                Spacer()
                if session.isExporting { ProgressView().controlSize(.small) }
                Button("Export…") { session.export() }
                    .disabled(session.isExporting)
                    .notchShotPrimaryActionStyle()
            }
        }
        .notchShotFormStyle()
        .padding(20)
        .frame(minWidth: 560, minHeight: 330)
    }
}
