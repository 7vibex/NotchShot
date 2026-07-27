import AppKit
import Foundation
import ImageIO

/// Revalidates image files immediately before every full-resolution decode.
/// A file dragged in from Finder can be replaced after the original drop, so
/// validation only at ingestion is not a sufficient memory-safety boundary.
enum SafeImageFile {
    struct Limits: Sendable {
        var maximumBytes: Int
        var maximumDimension: Int
        var maximumPixels: Int

        static let external = Limits(
            maximumBytes: 500_000_000,
            maximumDimension: 32_768,
            maximumPixels: 50_000_000
        )
        static let generated = Limits(
            maximumBytes: 1_000_000_000,
            maximumDimension: 65_535,
            maximumPixels: 128_000_000
        )
        static let background = Limits(
            maximumBytes: 100_000_000,
            maximumDimension: 16_384,
            maximumPixels: 50_000_000
        )
    }

    static func limits(for ownership: CaptureAssetOwnership) -> Limits {
        ownership == .externalReference ? .external : .generated
    }

    static func cgImage(
        at url: URL,
        limits: Limits
    ) -> CGImage? {
        guard url.isFileURL else { return nil }
        let resolved = url.standardizedFileURL
        let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let byteCount = values?.fileSize,
              byteCount >= 0,
              byteCount <= limits.maximumBytes else { return nil }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(resolved as CFURL, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= limits.maximumDimension,
              height <= limits.maximumDimension,
              width <= limits.maximumPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width,
              image.height == height else { return nil }
        return image
    }

    static func cgImage(for asset: CaptureAsset) -> CGImage? {
        cgImage(at: asset.url, limits: limits(for: asset.ownership))
    }

    static func capturedImage(for asset: CaptureAsset) -> CapturedImage? {
        cgImage(for: asset).map {
            CapturedImage(
                cgImage: $0,
                scale: max(1, asset.scale),
                sourceRect: .zero
            )
        }
    }

    static func nsImage(for asset: CaptureAsset) -> NSImage? {
        cgImage(for: asset).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }
}
