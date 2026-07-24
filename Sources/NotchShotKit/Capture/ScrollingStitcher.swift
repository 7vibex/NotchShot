import CoreGraphics
import Foundation

/// Where two frames were joined, and how sure we are about it.
public struct StitchSeam: Sendable, Equatable {
    /// Y position of the seam in the finished image, in pixels.
    public var y: Int
    /// 0…1. Below `StitchSettings.warningConfidence` the UI flags the seam.
    public var confidence: Double
    /// Rows of new content the frame contributed.
    public var addedRows: Int

    public var isSuspect: Bool { confidence < StitchSettings.warningConfidence }
}

public struct StitchSettings: Sendable {
    /// Height of the band matched between frames, in pixels.
    public var templateHeight = 140
    /// Horizontal downsampling used while matching. Matching at full width is
    /// pointlessly slow; 1-in-4 columns is plenty to localise a scroll.
    public var columnStride = 4
    /// Mean absolute difference (0…255) above which a match is rejected.
    public var maximumMeanDifference = 26.0
    /// Frames must advance at least this many pixels to count as new content.
    public var minimumAdvance = 8
    public static let warningConfidence = 0.72

    public init() {}
}

public struct StitchOutput: @unchecked Sendable {
    public let image: CGImage
    public let seams: [StitchSeam]
    public let warnings: [String]
    /// Frames that could not be joined and were dropped from the composite.
    public let droppedFrameIndices: [Int]
}

/// Joins a sequence of vertically-scrolled frames into one tall image.
///
/// The approach is deliberately simple and explainable: for each new frame,
/// find where the previous frame's bottom band reappears, and append whatever
/// sits below it. No feature detection, no warping — page content scrolls
/// rigidly, and anything that doesn't (video, parallax) is reported as a
/// low-confidence seam rather than silently smeared.
public enum ScrollingStitcher {

    public static func stitch(
        frames: [CGImage],
        settings: StitchSettings = StitchSettings(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> StitchOutput {
        guard let first = frames.first else {
            throw NotchShotError.stitchFailed("No frames were captured")
        }
        guard frames.count > 1 else {
            return StitchOutput(image: first, seams: [], warnings: [], droppedFrameIndices: [])
        }

        let width = first.width
        guard frames.allSatisfy({ $0.width == width }) else {
            throw NotchShotError.stitchFailed("Frames have different widths")
        }

        var buffers: [GrayBuffer] = []
        buffers.reserveCapacity(frames.count)
        for frame in frames {
            guard let buffer = GrayBuffer(image: frame, columnStride: settings.columnStride) else {
                throw NotchShotError.stitchFailed("Could not read frame pixels")
            }
            buffers.append(buffer)
        }

        // Regions that never move between frames — sticky headers, toolbars,
        // floating footers — are excluded from matching, otherwise they anchor
        // every comparison to a false zero-scroll answer.
        let sticky = detectStickyBands(buffers: buffers)
        var warnings: [String] = []
        if sticky.top > 0 {
            warnings.append("Ignored a \(sticky.top)px fixed header while matching.")
        }
        if sticky.bottom > 0 {
            warnings.append("Ignored a \(sticky.bottom)px fixed footer while matching.")
        }

        var seams: [StitchSeam] = []
        var dropped: [Int] = []
        // (sourceFrameIndex, sourceTopRow, rowCount) draw instructions.
        var segments: [(frame: Int, top: Int, rows: Int)] = [(0, 0, frames[0].height)]
        var totalHeight = frames[0].height
        var previousIndex = 0

        for index in 1 ..< frames.count {
            progress?(Double(index) / Double(frames.count))

            let match = bestMatch(
                previous: buffers[previousIndex],
                next: buffers[index],
                sticky: sticky,
                settings: settings
            )

            guard let match, match.addedRows >= settings.minimumAdvance else {
                // Either nothing moved (a duplicate frame) or the content
                // changed too much to correlate. Dropping is safer than
                // guessing an offset and producing a torn image.
                dropped.append(index)
                continue
            }

            segments.append((index, match.sourceTop, match.addedRows))
            seams.append(StitchSeam(
                y: totalHeight,
                confidence: match.confidence,
                addedRows: match.addedRows
            ))
            totalHeight += match.addedRows
            previousIndex = index
        }

        guard seams.count > 0 else {
            throw NotchShotError.stitchFailed(
                "None of the \(frames.count) frames overlapped — try scrolling in smaller steps"
            )
        }
        if !dropped.isEmpty {
            warnings.append("\(dropped.count) frame(s) didn't overlap and were skipped.")
        }
        if seams.contains(where: \.isSuspect) {
            warnings.append("Some joins are uncertain — check the marked seams before sharing.")
        }

        let composite = try compose(frames: frames, segments: segments, width: width, height: totalHeight)
        progress?(1)
        return StitchOutput(
            image: composite,
            seams: seams,
            warnings: warnings,
            droppedFrameIndices: dropped
        )
    }

    // MARK: Matching

    struct Match: Equatable {
        /// First row of the next frame that is genuinely new content.
        var sourceTop: Int
        var addedRows: Int
        var confidence: Double
    }

    /// Locates the previous frame's bottom band inside the next frame and
    /// returns how many rows of genuinely new content the next frame carries.
    static func bestMatch(
        previous: GrayBuffer,
        next: GrayBuffer,
        sticky: StickyBands,
        settings: StitchSettings
    ) -> Match? {
        let usableBottom = previous.height - sticky.bottom
        let usableTop = sticky.top
        guard usableBottom - usableTop > settings.templateHeight else { return nil }

        let templateHeight = min(settings.templateHeight, (usableBottom - usableTop) / 2)
        let templateTop = usableBottom - templateHeight

        var bestScore = Double.greatestFiniteMagnitude
        var bestPosition = -1

        // The band can only have moved up, so search from the template's own
        // position back toward the top of the frame.
        let searchUpperBound = min(templateTop, next.height - sticky.bottom - templateHeight)
        guard searchUpperBound >= usableTop else { return nil }

        for position in stride(from: searchUpperBound, through: usableTop, by: -1) {
            let score = previous.meanAbsoluteDifference(
                templateTop: templateTop,
                templateHeight: templateHeight,
                against: next,
                at: position,
                earlyExit: bestScore
            )
            if score < bestScore {
                bestScore = score
                bestPosition = position
            }
            // A pixel-perfect match can't be beaten; stop hunting.
            if bestScore < 0.5 { break }
        }

        guard bestPosition >= 0, bestScore <= settings.maximumMeanDifference else { return nil }

        // Everything below the matched band — and above any fixed footer — is
        // content the previous frame never showed.
        let sourceTop = bestPosition + templateHeight
        let newRows = (next.height - sticky.bottom) - sourceTop
        guard newRows > 0 else { return nil }

        let confidence = max(0, 1 - bestScore / settings.maximumMeanDifference)
        return Match(sourceTop: sourceTop, addedRows: newRows, confidence: confidence)
    }

    public struct StickyBands: Sendable, Equatable {
        public var top: Int
        public var bottom: Int
        public init(top: Int, bottom: Int) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// Counts leading/trailing rows that are identical across every frame.
    static func detectStickyBands(buffers: [GrayBuffer]) -> StickyBands {
        guard let first = buffers.first, buffers.count > 1 else {
            return StickyBands(top: 0, bottom: 0)
        }
        let height = first.height
        let limit = height / 3

        var top = 0
        outerTop: while top < limit {
            for buffer in buffers.dropFirst() where !buffer.rowsMatch(first, row: top, tolerance: 3) {
                break outerTop
            }
            top += 1
        }

        var bottom = 0
        outerBottom: while bottom < limit {
            let row = height - 1 - bottom
            for buffer in buffers.dropFirst() where !buffer.rowsMatch(first, row: row, tolerance: 3) {
                break outerBottom
            }
            bottom += 1
        }

        // A band that eats the whole frame means the page never scrolled; treat
        // it as no sticky content so the caller sees a normal failure instead.
        if top + bottom >= height { return StickyBands(top: 0, bottom: 0) }
        return StickyBands(top: top, bottom: bottom)
    }

    // MARK: Composition

    private static func compose(
        frames: [CGImage],
        segments: [(frame: Int, top: Int, rows: Int)],
        width: Int,
        height: Int
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw NotchShotError.stitchFailed("Could not allocate the composite image")
        }

        context.interpolationQuality = .none
        var y = 0
        for segment in segments {
            guard segment.rows > 0 else { continue }
            let cropRect = CGRect(x: 0, y: segment.top, width: width, height: segment.rows)
            guard let slice = frames[segment.frame].cropping(to: cropRect) else { continue }
            // CGContext draws bottom-up, so the first segment goes at the top.
            let destination = CGRect(
                x: 0,
                y: height - y - segment.rows,
                width: width,
                height: segment.rows
            )
            context.draw(slice, in: destination)
            y += segment.rows
        }

        guard let image = context.makeImage() else {
            throw NotchShotError.stitchFailed("Could not render the composite image")
        }
        return image
    }
}

/// A downsampled 8-bit grayscale view of a frame, used only for matching.
struct GrayBuffer: @unchecked Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    init?(image: CGImage, columnStride: Int) {
        let targetWidth = max(1, image.width / max(1, columnStride))
        let targetHeight = image.height
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let data = context.data else { return nil }

        let count = targetWidth * targetHeight
        // A CGBitmapContext's *coordinate space* is bottom-up, but its backing
        // memory is laid out top-down — row 0 in `data` is already the top of
        // the image, which is the orientation the scroll maths assumes. No flip
        // is needed here, and adding one silently reverses scroll direction.
        let raw = data.bindMemory(to: UInt8.self, capacity: count)
        let buffer = [UInt8](UnsafeBufferPointer(start: raw, count: count))

        self.pixels = buffer
        self.width = targetWidth
        self.height = targetHeight
    }

    init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    func rowsMatch(_ other: GrayBuffer, row: Int, tolerance: Int) -> Bool {
        guard width == other.width, row >= 0, row < height, row < other.height else { return false }
        let start = row * width
        for column in 0 ..< width {
            let delta = abs(Int(pixels[start + column]) - Int(other.pixels[start + column]))
            if delta > tolerance { return false }
        }
        return true
    }

    /// Mean absolute difference between this buffer's template band and the
    /// same-sized band of `other` starting at `position`. Bails out early once
    /// the running average can no longer beat `earlyExit`.
    func meanAbsoluteDifference(
        templateTop: Int,
        templateHeight: Int,
        against other: GrayBuffer,
        at position: Int,
        earlyExit: Double
    ) -> Double {
        guard width == other.width,
              templateTop >= 0,
              templateTop + templateHeight <= height,
              position >= 0,
              position + templateHeight <= other.height else {
            return .greatestFiniteMagnitude
        }

        var total = 0
        var counted = 0
        // A non-finite `earlyExit` means "no incumbent yet", so don't bail out.
        // Clamped to the 0…255 range a mean absolute difference can occupy;
        // converting an unbounded Double straight to Int would trap.
        let budget: Int? = earlyExit.isFinite ? Int(min(max(earlyExit, 0), 255)) : nil

        for row in 0 ..< templateHeight {
            let lhs = (templateTop + row) * width
            let rhs = (position + row) * width
            for column in 0 ..< width {
                total += abs(Int(pixels[lhs + column]) - Int(other.pixels[rhs + column]))
            }
            counted += width
            // Check every few rows so the early exit costs almost nothing.
            if let budget, row % 8 == 7, total / counted > budget {
                return .greatestFiniteMagnitude
            }
        }

        return counted == 0 ? .greatestFiniteMagnitude : Double(total) / Double(counted)
    }
}
