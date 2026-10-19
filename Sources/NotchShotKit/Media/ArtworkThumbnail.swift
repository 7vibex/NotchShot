import AppKit
import ImageIO

/// Cover art resampled once to the largest size any NotchShot surface draws.
enum ArtworkThumbnail {
    /// Pixels on the long edge: the 56 pt expanded cover at 2x, with headroom
    /// for the lyrics backdrop. Anything larger is never seen.
    static let maximumPixelSize = 256

    /// Thread-safe; ImageIO decodes straight to the target size instead of
    /// decoding the full cover and scaling it afterwards.
    nonisolated static func make(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Point size is half the pixel size, so the image is a 2x asset.
    static func image(from cgImage: CGImage) -> NSImage {
        NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
        )
    }
}
