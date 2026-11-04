import AppKit
import Foundation
import Observation
import SwiftUI

public enum ImageComparisonRenderer {
    public static let maximumPixels = 25_000_000

    public static func normalizedPair(
        before: CGImage,
        after: CGImage
    ) throws -> (CGImage, CGImage) {
        try validateOperationSize(before)
        try validateOperationSize(after)
        let size = CGSize(width: before.width, height: before.height)
        return (before, try fit(after, to: size))
    }

    /// Both images decoded into matching RGBA planes.
    ///
    /// Decoding costs about 6 ms for a 4K pair, and the threshold slider asks
    /// for a new difference on every drag tick. Keeping the planes lets a drag
    /// re-run only the comparison itself.
    struct DifferencePlanes {
        let left: [UInt8]
        let right: [UInt8]
        let width: Int
        let height: Int

        var bytesPerRow: Int { width * 4 }
    }

    static let differenceBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func differencePlanes(before: CGImage, after: CGImage) throws -> DifferencePlanes {
        // A session's pair is already the same size, and refitting it would be a
        // full decode and resample that changes nothing the difference reads:
        // the premultiplied colour is the same, and alpha is forced opaque.
        let (lhs, rhs) = before.width == after.width && before.height == after.height
            ? try validatedPair(before: before, after: after)
            : try normalizedPair(before: before, after: after)
        return DifferencePlanes(
            left: try decodedPlane(lhs),
            right: try decodedPlane(rhs),
            width: lhs.width,
            height: lhs.height
        )
    }

    private static func validatedPair(before: CGImage, after: CGImage) throws -> (CGImage, CGImage) {
        try validateOperationSize(before)
        try validateOperationSize(after)
        return (before, after)
    }

    private static func decodedPlane(_ image: CGImage) throws -> [UInt8] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        // The context writes through this pointer, so it must not outlive the closure.
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: differenceBitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard didDraw else {
            throw NotchShotError.exportFailed("Could not allocate the image difference")
        }
        return bytes
    }

    public static func difference(
        before: CGImage,
        after: CGImage,
        threshold: UInt8 = 0
    ) throws -> CGImage {
        try difference(planes: try differencePlanes(before: before, after: after), threshold: threshold)
    }

    static func difference(planes: DifferencePlanes, threshold: UInt8) throws -> CGImage {
        let differenceBytes = absoluteDifference(planes: planes, threshold: threshold)
        let data = Data(differenceBytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: planes.width,
                height: planes.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: planes.bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: differenceBitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw NotchShotError.exportFailed("Could not render the image difference")
        }
        return image
    }

    /// Per-channel |before - after|, thresholded, with alpha left opaque.
    ///
    /// Sixteen bytes is exactly four RGBA pixels, so alpha always lands on lanes
    /// 3, 7, 11 and 15 of a block and can be forced opaque inside the same pass
    /// rather than in a second sweep. Vectorising this takes a 4K comparison
    /// from about 21 ms to 9 ms, which is what the threshold slider pays per
    /// drag tick.
    static func absoluteDifference(planes: DifferencePlanes, threshold: UInt8) -> [UInt8] {
        var output = [UInt8](repeating: 255, count: planes.bytesPerRow * planes.height)
        let alphaLanes = SIMDMask<SIMD16<Int8>>([
            false, false, false, true, false, false, false, true,
            false, false, false, true, false, false, false, true,
        ])
        let thresholdVector = SIMD16<UInt8>(repeating: threshold)
        let opaque = SIMD16<UInt8>(repeating: 255)
        let zero = SIMD16<UInt8>()

        planes.left.withUnsafeBufferPointer { leftBuffer in
            planes.right.withUnsafeBufferPointer { rightBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    guard let leftBase = leftBuffer.baseAddress,
                          let rightBase = rightBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress else { return }
                    let count = min(outputBuffer.count, min(leftBuffer.count, rightBuffer.count))
                    var index = 0
                    while index + 16 <= count {
                        let lhs = SIMD16<UInt8>(UnsafeBufferPointer(start: leftBase + index, count: 16))
                        let rhs = SIMD16<UInt8>(UnsafeBufferPointer(start: rightBase + index, count: 16))
                        var delta = pointwiseMax(lhs, rhs) &- pointwiseMin(lhs, rhs)
                        if threshold > 0 {
                            delta.replace(with: zero, where: delta .< thresholdVector)
                        }
                        delta.replace(with: opaque, where: alphaLanes)
                        // One sixteen-byte store. Writing the lanes out
                        // individually instead costs three times as much: the
                        // result never leaves a vector register until it is
                        // written, so a per-lane loop spends the whole kernel
                        // extracting from one.
                        withUnsafeBytes(of: delta) { source in
                            (UnsafeMutableRawPointer(outputBase) + index)
                                .copyMemory(from: source.baseAddress!, byteCount: 16)
                        }
                        index += 16
                    }
                    while index < count {
                        if index % 4 == 3 {
                            outputBase[index] = 255
                        } else {
                            let lhs = leftBase[index]
                            let rhs = rightBase[index]
                            let delta = lhs > rhs ? lhs - rhs : rhs - lhs
                            outputBase[index] = delta >= threshold ? delta : 0
                        }
                        index += 1
                    }
                }
            }
        }
        return output
    }

    public static func split(before: CGImage, after: CGImage, position: Double) throws -> CGImage {
        let (lhs, rhs) = try normalizedPair(before: before, after: after)
        guard let context = AnnotationRenderer.makeContext(width: lhs.width, height: lhs.height) else {
            throw NotchShotError.exportFailed("Could not allocate the comparison export")
        }
        let rect = CGRect(x: 0, y: 0, width: lhs.width, height: lhs.height)
        context.draw(lhs, in: rect)
        context.saveGState()
        // Before on the leading (left) edge, after on the trailing edge, which
        // is what the toolbar labels promise.
        let fraction = CGFloat(min(max(position, 0), 1))
        context.clip(to: CGRect(
            x: CGFloat(lhs.width) * (1 - fraction),
            y: 0,
            width: CGFloat(lhs.width) * fraction,
            height: CGFloat(lhs.height)
        ))
        context.draw(rhs, in: rect)
        context.restoreGState()
        guard let output = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not render the comparison export")
        }
        return output
    }

    private static func validateOperationSize(_ image: CGImage) throws {
        guard isWithinOperationBudget(width: image.width, height: image.height) else {
            throw NotchShotError.exportFailed(
                "That image is too large for a safe in-memory comparison"
            )
        }
    }

    static func isWithinOperationBudget(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumPixels / height
    }

    private static func fit(_ image: CGImage, to size: CGSize) throws -> CGImage {
        guard let context = AnnotationRenderer.makeContext(
            width: Int(size.width),
            height: Int(size.height)
        ) else {
            throw NotchShotError.exportFailed("Could not allocate the comparison canvas")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let output = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not normalize the comparison image")
        }
        return output
    }
}

@MainActor
@Observable
public final class VisualComparisonSession {
    /// The decoded pair, ready for a session. `CGImage` is immutable.
    public struct LoadedImages: @unchecked Sendable {
        let before: CGImage
        let after: CGImage
    }

    public let beforeAsset: CaptureAsset
    public let afterAsset: CaptureAsset
    public let before: CGImage
    public let after: CGImage
    /// One image per side rather than one per body evaluation: every slider tick
    /// re-runs the body, and each new image is a new one for Core Animation to prepare.
    let beforeDisplayImage: NSImage
    let afterDisplayImage: NSImage
    public private(set) var difference: CGImage?
    public private(set) var isExporting = false
    public var sliderPosition = 0.5
    public var showsDifference = false
    public var differenceThreshold = 0.0
    public var errorMessage: String?
    private var cachedPlanes: ImageComparisonRenderer.DifferencePlanes?
    private var isLoadingDifference = false

    /// Reads, decodes and sizes both captures off the main actor.
    public nonisolated static func loadImages(
        beforeAsset: CaptureAsset,
        afterAsset: CaptureAsset
    ) async throws -> LoadedImages {
        try await Task.detached(priority: .userInitiated) {
            guard let before = SafeImageFile.cgImage(for: beforeAsset, decodeImmediately: true),
                  let after = SafeImageFile.cgImage(for: afterAsset, decodeImmediately: true) else {
                throw NotchShotError.exportFailed("Both captures must be readable images")
            }
            let pair = try ImageComparisonRenderer.normalizedPair(before: before, after: after)
            return LoadedImages(before: pair.0, after: pair.1)
        }.value
    }

    public init(beforeAsset: CaptureAsset, afterAsset: CaptureAsset, images: LoadedImages) {
        self.beforeAsset = beforeAsset
        self.afterAsset = afterAsset
        before = images.before
        after = images.after
        beforeDisplayImage = NSImage(
            cgImage: images.before,
            size: NSSize(width: images.before.width, height: images.before.height)
        )
        afterDisplayImage = NSImage(
            cgImage: images.after,
            size: NSSize(width: images.after.width, height: images.after.height)
        )
    }

    public func setDifferenceVisible(_ visible: Bool) {
        showsDifference = visible
        guard visible, difference == nil else { return }
        guard let cachedPlanes else {
            loadDifference()
            return
        }
        do {
            // Decoded once and kept: dragging the threshold slider re-runs only
            // the comparison, not the decode of both source images.
            difference = try ImageComparisonRenderer.difference(
                planes: cachedPlanes,
                threshold: UInt8(differenceThreshold.rounded())
            )
        } catch {
            errorMessage = error.localizedDescription
            showsDifference = false
        }
    }

    /// The first difference decodes both images, up to 200 MB of planes, so it
    /// runs off the main actor. The slider stays on screen until it lands.
    private func loadDifference() {
        guard !isLoadingDifference else { return }
        isLoadingDifference = true
        let images = LoadedImages(before: before, after: after)
        let threshold = UInt8(differenceThreshold.rounded())
        Task { [weak self] in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let planes = try ImageComparisonRenderer.differencePlanes(
                        before: images.before,
                        after: images.after
                    )
                    return LoadedDifference(
                        planes: planes,
                        image: try ImageComparisonRenderer.difference(planes: planes, threshold: threshold)
                    )
                }.value
                guard let self else { return }
                self.isLoadingDifference = false
                self.cachedPlanes = loaded.planes
                // The threshold may have moved while this ran.
                if UInt8(self.differenceThreshold.rounded()) == threshold {
                    self.difference = loaded.image
                } else if self.showsDifference {
                    self.setDifferenceVisible(true)
                }
            } catch {
                guard let self else { return }
                self.isLoadingDifference = false
                self.errorMessage = error.localizedDescription
                self.showsDifference = false
            }
        }
    }

    public func updateDifferenceThreshold(_ value: Double) {
        differenceThreshold = min(max(value, 0), 255)
        difference = nil
        if showsDifference { setDifferenceVisible(true) }
    }

    /// What the window is showing right now, as values that can leave the main actor.
    private var renderRequest: ComparisonRenderRequest {
        ComparisonRenderRequest(
            images: LoadedImages(before: before, after: after),
            showsDifference: showsDifference,
            difference: difference,
            planes: cachedPlanes,
            threshold: UInt8(differenceThreshold.rounded()),
            position: sliderPosition
        )
    }

    public func share() {
        guard !isExporting else { return }
        let request = renderRequest
        isExporting = true
        Task { [weak self] in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    CapturedImage(cgImage: try request.render(), scale: 1, sourceRect: .zero)
                }.value
                try MacSharePresenter.shared.present(items: [rendered.makeNSImage()])
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }

    public func export() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: .png)]
        panel.nameFieldStringValue = "NotchShot Comparison.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let request = renderRequest
        isExporting = true
        FileWorkTracker.shared.run { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    _ = try ImageExport.write(
                        try request.render(),
                        to: url,
                        format: .png,
                        quality: 1,
                        dpiScale: 1
                    )
                }.value
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }
}

private struct LoadedDifference: @unchecked Sendable {
    let planes: ImageComparisonRenderer.DifferencePlanes
    let image: CGImage
}

private struct ComparisonRenderRequest: @unchecked Sendable {
    let images: VisualComparisonSession.LoadedImages
    let showsDifference: Bool
    let difference: CGImage?
    let planes: ImageComparisonRenderer.DifferencePlanes?
    let threshold: UInt8
    let position: Double

    func render() throws -> CGImage {
        guard showsDifference else {
            return try ImageComparisonRenderer.split(
                before: images.before,
                after: images.after,
                position: position
            )
        }
        if let difference { return difference }
        return try ImageComparisonRenderer.difference(
            planes: try planes ?? ImageComparisonRenderer.differencePlanes(
                before: images.before,
                after: images.after
            ),
            threshold: threshold
        )
    }
}

public struct VisualComparisonView: View {
    @Bindable var session: VisualComparisonSession

    public init(session: VisualComparisonSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                let fitted = ImageViewFit.rect(
                    source: CGSize(width: session.before.width, height: session.before.height),
                    into: geometry.size,
                    margin: 28
                )
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if session.showsDifference, let difference = session.difference {
                        comparisonImage(NSImage(
                            cgImage: difference,
                            size: NSSize(width: difference.width, height: difference.height)
                        ))
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                    } else {
                        slider(fitted: fitted)
                    }
                }
            }
            if let error = session.errorMessage {
                InlineErrorMessage(message: error)
                    .padding(8)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Before", systemImage: "1.circle.fill")
            Text(session.beforeAsset.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 120)
            Spacer(minLength: 8)
            Toggle("Difference", isOn: Binding(
                get: { session.showsDifference },
                set: { session.setDifferenceVisible($0) }
            ))
            .toggleStyle(.switch)
            if session.showsDifference {
                Slider(
                    value: Binding(
                        get: { session.differenceThreshold },
                        set: { session.updateDifferenceThreshold($0) }
                    ),
                    in: 0 ... 255
                )
                .frame(width: 110)
                .help("Difference threshold")
                .accessibilityLabel("Difference threshold")
                .accessibilityValue("\(Int(session.differenceThreshold.rounded()))")
            }
            Button("Share…") { session.share() }
                .disabled(session.isExporting)
            Button("Export…") { session.export() }
                .disabled(session.isExporting)
                .notchShotPrimaryActionStyle()
            Spacer(minLength: 8)
            Text(session.afterAsset.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 120)
            Label("After", systemImage: "2.circle.fill")
        }
        .font(.callout)
        .padding(.horizontal, NotchShotDesignSystem.toolbarHorizontalPadding)
        .padding(.vertical, NotchShotDesignSystem.toolbarVerticalPadding)
        .notchShotToolbarSurface()
    }

    private func slider(fitted: CGRect) -> some View {
        ZStack {
            comparisonImage(session.beforeDisplayImage)
                .frame(width: fitted.width, height: fitted.height)

            comparisonImage(session.afterDisplayImage)
                .frame(width: fitted.width, height: fitted.height)
                .mask(alignment: .trailing) {
                    Rectangle()
                        .frame(width: fitted.width * session.sliderPosition)
                }

            Rectangle()
                .fill(.white)
                .frame(width: 2, height: fitted.height)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: fitted.width * (0.5 - session.sliderPosition))

            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .overlay { Image(systemName: "arrow.left.and.right").font(.caption.bold()) }
                .shadow(color: .black.opacity(0.45), radius: 5)
                .offset(x: fitted.width * (0.5 - session.sliderPosition))
        }
        .frame(width: fitted.width, height: fitted.height)
        .position(x: fitted.midX, y: fitted.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // The position is the trailing fraction showing After, and
                    // this gesture reads the whole container, not the image.
                    let fraction = 1 - (value.location.x - fitted.minX) / fitted.width
                    session.sliderPosition = min(max(fraction, 0), 1)
                }
        )
        .focusable()
        .onKeyPress(.leftArrow) {
            session.sliderPosition = min(1, session.sliderPosition + 0.02)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            session.sliderPosition = max(0, session.sliderPosition - 0.02)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(session.sliderPosition * 100)) percent after image")
        .accessibilityHint("Drag or use the left and right arrow keys to reveal the before and after images.")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            session.sliderPosition = min(max(session.sliderPosition + delta, 0), 1)
        }
    }

    private func comparisonImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
    }
}
