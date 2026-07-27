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

    public static func difference(before: CGImage, after: CGImage) throws -> CGImage {
        let (lhs, rhs) = try normalizedPair(before: before, after: after)
        let width = lhs.width
        let height = lhs.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        var leftBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var rightBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let leftContext = CGContext(
            data: &leftBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let rightContext = CGContext(
            data: &rightBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NotchShotError.exportFailed("Could not allocate the image difference")
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        leftContext.draw(lhs, in: rect)
        rightContext.draw(rhs, in: rect)

        var differenceBytes = [UInt8](repeating: 255, count: bytesPerRow * height)
        for offset in stride(from: 0, to: differenceBytes.count, by: 4) {
            differenceBytes[offset] = UInt8(abs(Int(leftBytes[offset]) - Int(rightBytes[offset])))
            differenceBytes[offset + 1] = UInt8(abs(Int(leftBytes[offset + 1]) - Int(rightBytes[offset + 1])))
            differenceBytes[offset + 2] = UInt8(abs(Int(leftBytes[offset + 2]) - Int(rightBytes[offset + 2])))
        }

        let data = Data(differenceBytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw NotchShotError.exportFailed("Could not render the image difference")
        }
        return image
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
    public var errorMessage: String?

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
            difference = try ImageComparisonRenderer.difference(before: before, after: after)
        } catch {
            errorMessage = error.localizedDescription
            showsDifference = false
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
            Divider()
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
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
            Spacer()
            Toggle("Difference", isOn: Binding(
                get: { session.showsDifference },
                set: { session.setDifferenceVisible($0) }
            ))
            .toggleStyle(.switch)
            Spacer()
            Text(session.afterAsset.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Label("After", systemImage: "2.circle.fill")
        }
        .font(.callout)
        .padding(12)
    }

    private func slider(fitted: CGRect) -> some View {
        ZStack {
            comparisonImage(session.before)
                .frame(width: fitted.width, height: fitted.height)

            comparisonImage(session.after)
                .frame(width: fitted.width, height: fitted.height)
                .mask(alignment: .leading) {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(session.sliderPosition * 100)) percent after image")
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
