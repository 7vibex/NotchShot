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
        limits: Limits,
        expectedIdentity: ExternalFileIdentity? = nil
    ) -> CGImage? {
        guard let data = try? SafeAssetFile.readData(
            at: url,
            maximumBytes: Int64(limits.maximumBytes),
            expectedIdentity: expectedIdentity
        ) else { return nil }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
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
        if asset.ownership == .externalReference,
           asset.externalFileIdentity == nil {
            return nil
        }
        return cgImage(
            at: asset.url,
            limits: limits(for: asset.ownership),
            expectedIdentity: asset.ownership == .externalReference
                ? asset.externalFileIdentity : nil
        )
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

    // MARK: Pasteboard

    /// Bytes a pasteboard image may occupy before it is refused unread.
    ///
    /// Deliberately far above `ClipboardStore.maximumImageBytes`: that cap
    /// governs what history is willing to *keep*, while this one only has to
    /// keep a one-shot read from exhausting memory. A 6K Retina screenshot is
    /// routinely 10-20 MB of PNG and must still be readable.
    static let maximumPasteboardBytes = 100_000_000

    /// Decodes an image from a pasteboard under the same bound-before-decode
    /// discipline as `cgImage(at:limits:)`.
    ///
    /// `NSImage(pasteboard:)` cannot be used for this. It decodes the full
    /// bitmap as part of returning, so any dimension check written afterwards
    /// runs when the allocation has already happened — an 18k x 12k copy costs
    /// most of a gigabyte before the guard that was meant to reject it is ever
    /// evaluated. Reading the header through `CGImageSource` instead makes the
    /// size known while it is still only a promise.
    static func cgImage(
        fromPasteboard pasteboard: NSPasteboard,
        limits: Limits = .init(
            maximumBytes: maximumPasteboardBytes,
            maximumDimension: 16_384,
            maximumPixels: 50_000_000
        )
    ) -> CGImage? {
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type),
              data.count <= limits.maximumBytes else { return nil }
        return cgImage(from: data, limits: limits)
    }

    /// The shared tail of both pasteboard readers: header first, pixels only
    /// once the header has been accepted.
    static func cgImage(from data: Data, limits: Limits) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard data.count <= limits.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) >= 1,
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
}
