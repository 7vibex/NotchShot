import CoreGraphics
import Foundation

public enum ScrollingAxis: String, Sendable, Codable, CaseIterable, Identifiable {
    case vertical
    case horizontal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        }
    }
}

/// Where two frames were joined, and how sure we are about it.
public struct StitchSeam: Sendable, Equatable {
    /// Position along `axis` in the finished image, in pixels. The legacy name
    /// remains source-compatible with the original vertical-only model.
    public var y: Int
    public var axis: ScrollingAxis
    /// 0…1. Below `StitchSettings.warningConfidence` the UI flags the seam.
    public var confidence: Double
    /// Rows of new content the frame contributed.
    public var addedRows: Int

    public var isSuspect: Bool { confidence < StitchSettings.warningConfidence }

    public init(
        y: Int,
        axis: ScrollingAxis = .vertical,
        confidence: Double,
        addedRows: Int
    ) {
        self.y = y
        self.axis = axis
        self.confidence = confidence
        self.addedRows = addedRows
    }
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

/// Memory and dimension guard rails for untrusted or unusually large capture
/// input. A scrolling capture holds every source frame plus a decoded composite,
/// so frame count alone is not a sufficient bound.
public struct StitchLimits: Sendable, Equatable {
    public var maximumFrames: Int
    public var maximumFrameDimension: Int
    public var maximumFramePixels: Int
    public var maximumInputPixels: Int
    public var maximumInputBytes: Int
    public var maximumCompositeDimension: Int
    public var maximumCompositePixels: Int
    public var maximumCompositeBytes: Int

    public init(
        maximumFrames: Int = 120,
        maximumFrameDimension: Int = 16_384,
        maximumFramePixels: Int = 64 * 1_024 * 1_024,
        maximumInputPixels: Int = 192 * 1_024 * 1_024,
        maximumInputBytes: Int = 768 * 1_024 * 1_024,
        maximumCompositeDimension: Int = 65_535,
        maximumCompositePixels: Int = 128 * 1_024 * 1_024,
        maximumCompositeBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.maximumFrames = maximumFrames
        self.maximumFrameDimension = maximumFrameDimension
        self.maximumFramePixels = maximumFramePixels
        self.maximumInputPixels = maximumInputPixels
        self.maximumInputBytes = maximumInputBytes
        self.maximumCompositeDimension = maximumCompositeDimension
        self.maximumCompositePixels = maximumCompositePixels
        self.maximumCompositeBytes = maximumCompositeBytes
    }
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
        axis: ScrollingAxis = .vertical,
        settings: StitchSettings = StitchSettings(),
        limits: StitchLimits = StitchLimits(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> StitchOutput {
        try Task.checkCancellation()
        try validate(settings: settings, limits: limits)
        progress?(0)

        guard let first = frames.first else {
            throw NotchShotError.stitchFailed("No frames were captured")
        }
        guard frames.count <= limits.maximumFrames else {
            throw NotchShotError.stitchFailed(
                "Too many frames (\(frames.count)); the limit is \(limits.maximumFrames)"
            )
        }

        var inputPixels = 0
        var inputBytes = 0
        for frame in frames {
            try Task.checkCancellation()
            let cost = try validateFrame(
                frame,
                aggregatePixels: inputPixels,
                aggregateBytes: inputBytes,
                limits: limits
            )
            inputPixels += cost.pixels
            inputBytes += cost.decodedBytes
        }

        try validateComposite(width: first.width, height: first.height, limits: limits)
        guard frames.count > 1 else {
            progress?(1)
            return StitchOutput(image: first, seams: [], warnings: [], droppedFrameIndices: [])
        }

        let crossLength = axis == .vertical ? first.width : first.height
        guard frames.allSatisfy({
            axis == .vertical ? $0.width == crossLength : $0.height == crossLength
        }) else {
            throw NotchShotError.stitchFailed(
                axis == .vertical ? "Frames have different widths" : "Frames have different heights"
            )
        }

        var buffers: [GrayBuffer] = []
        buffers.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let decodeStride = axis == .vertical ? settings.columnStride : 1
            guard let decoded = GrayBuffer(image: frame, columnStride: decodeStride) else {
                throw NotchShotError.stitchFailed("Could not read frame pixels")
            }
            buffers.append(axis == .vertical
                ? decoded
                : decoded.transposed().stridingColumns(by: settings.columnStride))
            progress?(0.05 + (0.20 * Double(index + 1) / Double(frames.count)))
        }

        // Regions that never move between frames — sticky headers, toolbars,
        // floating footers — are excluded from matching, otherwise they anchor
        // every comparison to a false zero-scroll answer.
        let sticky = try detectStickyBandsCancellable(buffers: buffers)
        progress?(0.28)
        var warnings: [String] = []
        if sticky.top > 0 {
            warnings.append(axis == .vertical
                ? "Ignored a \(sticky.top)px fixed header while matching."
                : "Ignored a \(sticky.top)px fixed leading edge while matching.")
        }
        if sticky.bottom > 0 {
            warnings.append(axis == .vertical
                ? "Ignored a \(sticky.bottom)px fixed footer while matching."
                : "Ignored a \(sticky.bottom)px fixed trailing edge while matching.")
        }

        var seams: [StitchSeam] = []
        var dropped: [Int] = []
        // (sourceFrameIndex, sourceTopRow, rowCount) draw instructions.
        let firstLength = axis == .vertical ? frames[0].height : frames[0].width
        var segments: [(frame: Int, top: Int, rows: Int)] = [(0, 0, firstLength)]
        var totalLength = axis == .vertical ? frames[0].height : frames[0].width
        var previousIndex = 0

        for index in 1 ..< frames.count {
            try Task.checkCancellation()

            let match = try bestMatchCancellable(
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
                progress?(0.30 + (0.60 * Double(index) / Double(frames.count - 1)))
                continue
            }

            let (nextLength, lengthOverflow) = totalLength.addingReportingOverflow(match.addedRows)
            guard !lengthOverflow else {
                throw NotchShotError.stitchFailed("The composite length overflowed")
            }
            let nextWidth = axis == .vertical ? crossLength : nextLength
            let nextHeight = axis == .vertical ? nextLength : crossLength
            try validateComposite(width: nextWidth, height: nextHeight, limits: limits)
            segments.append((index, match.sourceTop, match.addedRows))
            seams.append(StitchSeam(
                y: totalLength,
                axis: axis,
                confidence: match.confidence,
                addedRows: match.addedRows
            ))
            totalLength = nextLength
            previousIndex = index
            progress?(0.30 + (0.60 * Double(index) / Double(frames.count - 1)))
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

        try Task.checkCancellation()
        progress?(0.92)
        let composite = try compose(
            frames: frames,
            segments: segments,
            axis: axis,
            crossLength: crossLength,
            totalLength: totalLength
        )
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
        try? bestMatchCancellable(
            previous: previous,
            next: next,
            sticky: sticky,
            settings: settings
        )
    }

    private static func bestMatchCancellable(
        previous: GrayBuffer,
        next: GrayBuffer,
        sticky: StickyBands,
        settings: StitchSettings
    ) throws -> Match? {
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

        var positionsChecked = 0
        for position in stride(from: searchUpperBound, through: usableTop, by: -1) {
            if positionsChecked.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            positionsChecked += 1
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
        (try? detectStickyBandsCancellable(buffers: buffers)) ?? StickyBands(top: 0, bottom: 0)
    }

    private static func detectStickyBandsCancellable(buffers: [GrayBuffer]) throws -> StickyBands {
        guard let first = buffers.first, buffers.count > 1 else {
            return StickyBands(top: 0, bottom: 0)
        }
        let height = first.height
        let limit = height / 3

        var top = 0
        outerTop: while top < limit {
            if top.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            for buffer in buffers.dropFirst() where !buffer.rowsMatch(first, row: top, tolerance: 3) {
                break outerTop
            }
            top += 1
        }

        var bottom = 0
        outerBottom: while bottom < limit {
            if bottom.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
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

    // MARK: Resource limits

    struct FrameCost: Sendable, Equatable {
        let pixels: Int
        let decodedBytes: Int
    }

    /// Validates one frame and its aggregate contribution. Kept internal so
    /// the capture session can reject oversized input before retaining it.
    static func validateFrame(
        _ image: CGImage,
        aggregatePixels: Int,
        aggregateBytes: Int,
        limits: StitchLimits
    ) throws -> FrameCost {
        guard image.width <= limits.maximumFrameDimension,
              image.height <= limits.maximumFrameDimension else {
            throw NotchShotError.stitchFailed(
                "A frame is \(image.width)×\(image.height)px; each dimension is limited to \(limits.maximumFrameDimension)px"
            )
        }

        let pixels = try checkedProduct(image.width, image.height, subject: "frame pixel count")
        guard pixels <= limits.maximumFramePixels else {
            throw NotchShotError.stitchFailed(
                "A frame contains \(pixels) pixels; the per-frame limit is \(limits.maximumFramePixels)"
            )
        }

        let bytesPerPixel = max(4, (image.bitsPerPixel + 7) / 8)
        let decodedPixelBytes = try checkedProduct(pixels, bytesPerPixel, subject: "frame byte count")
        let rowBytes = try checkedProduct(image.bytesPerRow, image.height, subject: "frame row-byte count")
        let decodedBytes = max(decodedPixelBytes, rowBytes)

        let (newPixels, pixelOverflow) = aggregatePixels.addingReportingOverflow(pixels)
        guard !pixelOverflow, newPixels <= limits.maximumInputPixels else {
            throw NotchShotError.stitchFailed(
                "Captured frames exceed the \(limits.maximumInputPixels)-pixel input budget"
            )
        }
        let (newBytes, byteOverflow) = aggregateBytes.addingReportingOverflow(decodedBytes)
        guard !byteOverflow, newBytes <= limits.maximumInputBytes else {
            throw NotchShotError.stitchFailed(
                "Captured frames exceed the \(limits.maximumInputBytes)-byte decoded input budget"
            )
        }

        return FrameCost(pixels: pixels, decodedBytes: decodedBytes)
    }

    private static func validate(settings: StitchSettings, limits: StitchLimits) throws {
        guard settings.templateHeight > 0,
              settings.columnStride > 0,
              settings.maximumMeanDifference.isFinite,
              settings.maximumMeanDifference > 0,
              settings.minimumAdvance > 0 else {
            throw NotchShotError.stitchFailed("Invalid stitch settings")
        }
        guard limits.maximumFrames > 0,
              limits.maximumFrameDimension > 0,
              limits.maximumFramePixels > 0,
              limits.maximumInputPixels > 0,
              limits.maximumInputBytes > 0,
              limits.maximumCompositeDimension > 0,
              limits.maximumCompositePixels > 0,
              limits.maximumCompositeBytes > 0 else {
            throw NotchShotError.stitchFailed("Invalid stitch resource limits")
        }
    }

    private static func validateComposite(width: Int, height: Int, limits: StitchLimits) throws {
        guard width <= limits.maximumCompositeDimension,
              height <= limits.maximumCompositeDimension else {
            throw NotchShotError.stitchFailed(
                "The composite would be \(width)×\(height)px; each dimension is limited to \(limits.maximumCompositeDimension)px"
            )
        }
        let pixels = try checkedProduct(width, height, subject: "composite pixel count")
        guard pixels <= limits.maximumCompositePixels else {
            throw NotchShotError.stitchFailed(
                "The composite would contain \(pixels) pixels; the limit is \(limits.maximumCompositePixels)"
            )
        }
        let bytes = try checkedProduct(pixels, 4, subject: "composite byte count")
        guard bytes <= limits.maximumCompositeBytes else {
            throw NotchShotError.stitchFailed(
                "The composite would require about \(bytes) bytes; the limit is \(limits.maximumCompositeBytes)"
            )
        }
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int, subject: String) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw NotchShotError.stitchFailed("The \(subject) overflowed")
        }
        return value
    }

    // MARK: Composition

    private static func compose(
        frames: [CGImage],
        segments: [(frame: Int, top: Int, rows: Int)],
        axis: ScrollingAxis,
        crossLength: Int,
        totalLength: Int
    ) throws -> CGImage {
        let width = axis == .vertical ? crossLength : totalLength
        let height = axis == .vertical ? totalLength : crossLength
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
        var offset = 0
        for segment in segments {
            try Task.checkCancellation()
            guard segment.rows > 0 else { continue }
            let cropRect = axis == .vertical
                ? CGRect(x: 0, y: segment.top, width: crossLength, height: segment.rows)
                : CGRect(x: segment.top, y: 0, width: segment.rows, height: crossLength)
            guard let slice = frames[segment.frame].cropping(to: cropRect) else {
                throw NotchShotError.stitchFailed("Could not crop a frame segment for composition")
            }
            // CGContext draws bottom-up, so the first segment goes at the top.
            let destination = axis == .vertical
                ? CGRect(
                    x: 0,
                    y: height - offset - segment.rows,
                    width: crossLength,
                    height: segment.rows
                )
                : CGRect(
                    x: offset,
                    y: 0,
                    width: segment.rows,
                    height: crossLength
                )
            context.draw(slice, in: destination)
            offset += segment.rows
        }

        guard offset == totalLength else {
            throw NotchShotError.stitchFailed("The composed segments did not fill the output image")
        }
        try Task.checkCancellation()
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

    /// Reflects the matching buffer across its main diagonal. Horizontal page
    /// motion then becomes the same one-dimensional problem as vertical page
    /// motion, while the full-resolution source pixels stay untouched.
    func transposed() -> GrayBuffer {
        var output = Array(repeating: UInt8.zero, count: pixels.count)
        for row in 0 ..< height {
            for column in 0 ..< width {
                output[column * height + row] = pixels[row * width + column]
            }
        }
        return GrayBuffer(pixels: output, width: height, height: width)
    }

    func stridingColumns(by stride: Int) -> GrayBuffer {
        let stride = max(1, stride)
        guard stride > 1 else { return self }
        let targetWidth = max(1, width / stride)
        var output = Array(repeating: UInt8.zero, count: targetWidth * height)
        for row in 0 ..< height {
            for column in 0 ..< targetWidth {
                output[row * targetWidth + column] = pixels[row * width + column * stride]
            }
        }
        return GrayBuffer(pixels: output, width: targetWidth, height: height)
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
