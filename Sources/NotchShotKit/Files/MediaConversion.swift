import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What a shelf file can be turned into, beyond the still-image formats
/// `ImageFormat` already covers: video to GIF, MP4, MOV or its audio; an
/// animated GIF to MP4; a PDF to one PNG per page.
///
/// Every conversion writes a new file next to the user's output folder and
/// leaves the original untouched.
public enum MediaConversionTarget: String, CaseIterable, Identifiable, Sendable {
    case gif
    case mp4
    case mov
    case m4a
    case pngPages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gif: "Animated GIF"
        case .mp4: "MP4 Video"
        case .mov: "QuickTime Movie"
        case .m4a: "Audio Only (M4A)"
        case .pngPages: "PNG Images (one per page)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .mp4: "mp4"
        case .mov: "mov"
        case .m4a: "m4a"
        case .pngPages: "png"
        }
    }
}

public enum MediaConversion {
    /// The source families conversion understands.
    public enum Source: Equatable, Sendable {
        case video
        case animatedGIF
        case pdf
    }

    /// Pages beyond this are skipped, so a 900-page manual can't fill the
    /// disk with images from one click.
    public static let maximumPDFPages = 60

    public static func source(for url: URL) -> Source? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .gif) { return .animatedGIF }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    /// Targets offered for a file, never including the format it already has.
    public static func targets(for url: URL) -> [MediaConversionTarget] {
        let ext = url.pathExtension.lowercased()
        switch source(for: url) {
        case .video:
            return [.gif, .mp4, .mov, .m4a].filter { target in
                !(target == .mp4 && ["mp4", "m4v"].contains(ext)) && !(target == .mov && ext == "mov")
            }
        case .animatedGIF:
            return [.mp4, .mov]
        case .pdf:
            return [.pngPages]
        case nil:
            return []
        }
    }

    /// Converts `url`, writing into `directory`. Returns every file written —
    /// several for a PDF, one otherwise.
    public static func convert(
        _ url: URL,
        to target: MediaConversionTarget,
        in directory: URL
    ) async throws -> [URL] {
        guard let source = source(for: url), targets(for: url).contains(target) else {
            throw NotchShotError.exportFailed("That file can't be converted to \(target.title)")
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        func destination(_ suffix: String = "") -> URL {
            AppPaths.uniqueURL(in: directory, name: baseName + suffix, extension: target.fileExtension)
        }

        switch (source, target) {
        case (.video, .gif):
            let output = destination()
            try await RecordingExportService.exportGIF(from: url, to: output, options: GIFExportOptions())
            return [output]
        case (.video, .mp4), (.video, .mov):
            let output = destination()
            try await exportMovie(url, to: output, type: target == .mp4 ? .mp4 : .mov, preset: AVAssetExportPresetHighestQuality)
            return [output]
        case (.video, .m4a):
            let output = destination()
            let asset = AVURLAsset(url: url)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
                throw NotchShotError.exportFailed("That video has no audio track")
            }
            try await exportMovie(url, to: output, type: .m4a, preset: AVAssetExportPresetAppleM4A)
            return [output]
        case (.animatedGIF, .mp4), (.animatedGIF, .mov):
            let output = destination()
            let job = Task.detached(priority: .userInitiated) {
                try GIFToMovieWriter.write(gif: url, to: output, fileType: target == .mp4 ? .mp4 : .mov)
            }
            try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            return [output]
        case (.pdf, .pngPages):
            try Task.checkCancellation()
            let job = Task.detached(priority: .userInitiated) {
                try renderPDFPages(url, baseName: baseName, directory: directory)
            }
            return try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
        default:
            throw NotchShotError.exportFailed("That file can't be converted to \(target.title)")
        }
    }

    private static func exportMovie(_ url: URL, to output: URL, type: AVFileType, preset: String) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NotchShotError.exportFailed("Could not create the exporter")
        }
        try await session.export(to: output, as: type)
    }

    // The page provider allows deterministic coverage of unavailable in-range pages.
    static func renderPDFPages(
        _ url: URL,
        baseName: String,
        directory: URL,
        pageProvider: (PDFDocument, Int) -> PDFPage? = { $0.page(at: $1) }
    ) throws -> [URL] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw NotchShotError.exportFailed("That PDF could not be read")
        }
        if document.isLocked {
            throw NotchShotError.exportFailed("That PDF is password protected")
        }
        var outputs: [(url: URL, identity: ExternalFileIdentity)] = []
        var completed = false
        defer {
            if !completed {
                // Only destinations successfully published by this attempt are owned here.
                for output in outputs where SafeAssetFile.identity(
                    at: output.url, maximumBytes: SafeAssetFile.maximumOwnedBytes
                ) == output.identity {
                    try? FileManager.default.removeItem(at: output.url)
                }
            }
        }
        let count = min(document.pageCount, maximumPDFPages)
        for index in 0..<count {
            try autoreleasepool {
                try Task.checkCancellation()
                guard let page = pageProvider(document, index) else {
                    throw NotchShotError.exportFailed("PDF page \(index + 1) could not be read")
                }
                let bounds = page.bounds(for: .mediaBox)
                // 2× the page's point size, capped so a poster-sized page stays sane.
                let scale = min(2, 6_000 / max(bounds.width, bounds.height, 1))
                let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                guard let context = CGContext(
                    data: nil,
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw NotchShotError.exportFailed("Could not allocate an image for PDF page \(index + 1)")
                }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context)
                try Task.checkCancellation()
                guard let image = context.makeImage() else {
                    throw NotchShotError.exportFailed("Could not render PDF page \(index + 1)")
                }
                let suffix = count > 1 ? "-page\(index + 1)" : ""
                let output = AppPaths.uniqueURL(in: directory, name: baseName + suffix, extension: "png")
                // Encode privately, then publish without replacing a file that appeared
                // after choosing the destination. Failed or canceled pages leave no PNG.
                let attempt = directory.appendingPathComponent(".notchshot-convert-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: attempt) }
                guard let destination = CGImageDestinationCreateWithURL(
                    attempt as CFURL, UTType.png.identifier as CFString, 1, nil
                ) else {
                    throw NotchShotError.exportFailed("Could not create a PNG for PDF page \(index + 1)")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw NotchShotError.exportFailed("Could not finish the PNG for PDF page \(index + 1)")
                }
                try Task.checkCancellation()
                guard let identity = SafeAssetFile.identity(at: attempt, maximumBytes: SafeAssetFile.maximumOwnedBytes) else {
                    throw NotchShotError.exportFailed("Could not verify the PNG for PDF page \(index + 1)")
                }
                do {
                    try FileManager.default.moveItem(at: attempt, to: output)
                } catch {
                    throw NotchShotError.exportFailed("Could not save PDF page \(index + 1): \(error.localizedDescription)")
                }
                outputs.append((output, identity))
            }
        }
        try Task.checkCancellation()
        guard !outputs.isEmpty else {
            throw NotchShotError.exportFailed("No pages could be rendered")
        }
        completed = true
        return outputs.map(\.url)
    }
}

/// Re-encodes an animated GIF's frames as H.264, keeping each frame's delay.
enum GIFToMovieWriter {
    static let maximumFrames = 1_500

    static func write(gif url: URL, to output: URL, fileType: AVFileType) throws {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NotchShotError.exportFailed("That GIF could not be read")
        }
        let frameCount = min(CGImageSourceGetCount(source), maximumFrames)
        guard frameCount > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NotchShotError.exportFailed("That GIF has no frames")
        }
        // H.264 wants even dimensions.
        let width = max(2, first.width - first.width % 2)
        let height = max(2, first.height - first.height % 2)

        // A failed writer owns only this attempt, never a pre-existing output.
        let attempt = output.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-convert-\(UUID().uuidString).\(output.pathExtension)")
        let writer = try AVAssetWriter(outputURL: attempt, fileType: fileType)
        defer {
            if writer.status != .completed { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: attempt)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw NotchShotError.exportFailed("Could not prepare the video writer") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NotchShotError.exportFailed("Could not start writing the video")
        }
        writer.startSession(atSourceTime: .zero)

        var time = CMTime.zero
        for index in 0..<frameCount {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let pool = adaptor.pixelBufferPool else {
                throw NotchShotError.exportFailed("Could not prepare GIF frame \(index + 1)")
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer,
                  CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                throw NotchShotError.exportFailed("Could not allocate GIF frame \(index + 1)")
            }
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                ) else { throw NotchShotError.exportFailed("Could not draw GIF frame \(index + 1)") }
                // GIF transparency becomes white rather than black.
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            try waitUntilReady(
                isReady: { input.isReadyForMoreMediaData },
                failure: {
                    writer.status == .writing ? nil
                        : writer.error ?? NotchShotError.exportFailed("The video writer stopped accepting frames")
                }
            )
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? NotchShotError.exportFailed("Could not encode GIF frame \(index + 1)")
            }
            time = CMTimeAdd(time, CMTime(seconds: frameDelay(source, index), preferredTimescale: 600))
        }
        // Include the last frame's delay instead of ending at its start time.
        writer.endSession(atSourceTime: time)
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        let finishDeadline = ProcessInfo.processInfo.systemUptime + 30
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            try Task.checkCancellation()
            guard writer.status == .writing,
                  ProcessInfo.processInfo.systemUptime < finishDeadline else {
                throw writer.error ?? NotchShotError.exportFailed("The video writer did not finish")
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? NotchShotError.exportFailed("The video could not be finished")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: attempt, to: output)
    }

    /// A stalled/failed encoder must not park its worker indefinitely.
    static func waitUntilReady(
        isReady: () -> Bool,
        failure: () -> Error?,
        timeout: TimeInterval = 30,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            if let error = failure() { throw error }
            if isReady() { return }
            guard now() < deadline else {
                throw NotchShotError.exportFailed("The video writer stopped responding")
            }
            pause(0.005)
        }
    }

    /// A frame's delay, with browsers' floor: under 20 ms plays as 100 ms.
    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }
}
