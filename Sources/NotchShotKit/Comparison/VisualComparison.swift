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
        let (lhs, rhs) = try normalizedPair(before: before, after: after)
        let width = lhs.width
        let height = lhs.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var leftBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var rightBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let leftContext = CGContext(
            data: &leftBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: differenceBitmapInfo
        ), let rightContext = CGContext(
            data: &rightBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: differenceBitmapInfo
        ) else {
            throw NotchShotError.exportFailed("Could not allocate the image difference")
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        leftContext.draw(lhs, in: rect)
        rightContext.draw(rhs, in: rect)
        return DifferencePlanes(left: leftBytes, right: rightBytes, width: width, height: height)
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
    public let beforeAsset: CaptureAsset
    public let afterAsset: CaptureAsset
    public let before: CGImage
    public let after: CGImage
    public private(set) var difference: CGImage?
    public var sliderPosition = 0.5
    public var showsDifference = false
    public var differenceThreshold = 0.0
    public var errorMessage: String?
    private var cachedPlanes: ImageComparisonRenderer.DifferencePlanes?

    public init(beforeAsset: CaptureAsset, afterAsset: CaptureAsset) throws {
        guard let before = SafeImageFile.cgImage(for: beforeAsset),
              let after = SafeImageFile.cgImage(for: afterAsset) else {
            throw NotchShotError.exportFailed("Both captures must be readable images")
        }
        let pair = try ImageComparisonRenderer.normalizedPair(before: before, after: after)
        self.beforeAsset = beforeAsset
        self.afterAsset = afterAsset
        self.before = pair.0
        self.after = pair.1
    }

    public func setDifferenceVisible(_ visible: Bool) {
        showsDifference = visible
        guard visible, difference == nil else { return }
        do {
            // Decoded once and kept: dragging the threshold slider re-runs only
            // the comparison, not the decode of both source images.
            let planes = try cachedPlanes ?? ImageComparisonRenderer.differencePlanes(
                before: before,
                after: after
            )
            cachedPlanes = planes
            difference = try ImageComparisonRenderer.difference(
                planes: planes,
                threshold: UInt8(differenceThreshold.rounded())
            )
        } catch {
            errorMessage = error.localizedDescription
            showsDifference = false
        }
    }

    public func updateDifferenceThreshold(_ value: Double) {
        differenceThreshold = min(max(value, 0), 255)
        difference = nil
        if showsDifference { setDifferenceVisible(true) }
    }

    public func renderedComparison() throws -> CGImage {
        if showsDifference {
            if difference == nil { setDifferenceVisible(true) }
            guard let difference else {
                throw NotchShotError.exportFailed("Could not render the image difference")
            }
            return difference
        }
        return try ImageComparisonRenderer.split(
            before: before,
            after: after,
            position: sliderPosition
        )
    }

    public func share() {
        do {
            let image = try renderedComparison()
            try MacSharePresenter.shared.present(items: [NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: .png)]
        panel.nameFieldStringValue = "NotchShot Comparison.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ImageExport.write(
                try renderedComparison(),
                to: url,
                format: .png,
                quality: 1,
                dpiScale: 1
            )
        } catch {
            errorMessage = error.localizedDescription
        }
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
                let fitted = fit(
                    CGSize(width: session.before.width, height: session.before.height),
                    into: geometry.size,
                    margin: 28
                )
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if session.showsDifference, let difference = session.difference {
                        comparisonImage(difference)
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
            Button("Export…") { session.export() }
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
            comparisonImage(session.before)
                .frame(width: fitted.width, height: fitted.height)

            comparisonImage(session.after)
                .frame(width: fitted.width, height: fitted.height)
                .mask(alignment: .trailing) {
                    Rectangle()
                        .frame(width: fitted.width * session.sliderPosition)
                }

            Rectangle()
                .fill(.white)
                .frame(width: 2, height: fitted.height)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: fitted.width * (session.sliderPosition - 0.5))

            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .overlay { Image(systemName: "arrow.left.and.right").font(.caption.bold()) }
                .shadow(color: .black.opacity(0.45), radius: 5)
                .offset(x: fitted.width * (session.sliderPosition - 0.5))
        }
        .frame(width: fitted.width, height: fitted.height)
        .position(x: fitted.midX, y: fitted.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    session.sliderPosition = min(max(value.location.x / fitted.width, 0), 1)
                }
        )
        .focusable()
        .onKeyPress(.leftArrow) {
            session.sliderPosition = max(0, session.sliderPosition - 0.02)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            session.sliderPosition = min(1, session.sliderPosition + 0.02)
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

    private func comparisonImage(_ image: CGImage) -> some View {
        Image(nsImage: NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        ))
        .resizable()
        .interpolation(.high)
    }

    private func fit(_ source: CGSize, into container: CGSize, margin: CGFloat) -> CGRect {
        let available = CGSize(
            width: max(1, container.width - margin * 2),
            height: max(1, container.height - margin * 2)
        )
        let scale = min(available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
