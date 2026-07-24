import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A captured bitmap plus the scale it was taken at.
///
/// `CGImage` is immutable and safe to read from any thread, but Core Graphics
/// predates `Sendable`, so the box carries the annotation explicitly rather
/// than forcing every call site to be `@MainActor`.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Backing scale of the display it came from (2.0 on Retina).
    public let scale: CGFloat
    /// Global CG-space (top-left origin) rect the pixels came from, in points.
    public let sourceRect: CGRect

    public init(cgImage: CGImage, scale: CGFloat, sourceRect: CGRect) {
        self.cgImage = cgImage
        self.scale = scale
        self.sourceRect = sourceRect
    }

    public var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    public var pointSize: CGSize {
        CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    }

    /// An `NSImage` sized in points, so it draws at the right size on Retina.
    @MainActor
    public func makeNSImage() -> NSImage {
        NSImage(cgImage: cgImage, size: pointSize)
    }

    public func cropped(to pixelRect: CGRect) -> CapturedImage? {
        guard let cropped = cgImage.cropping(to: pixelRect.integral) else { return nil }
        let pointRect = CGRect(
            x: sourceRect.origin.x + pixelRect.origin.x / scale,
            y: sourceRect.origin.y + pixelRect.origin.y / scale,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale
        )
        return CapturedImage(cgImage: cropped, scale: scale, sourceRect: pointRect)
    }
}

/// Writes bitmaps to disk and the pasteboard.
public enum ImageExport {

    public static func utType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    /// Encodes `image` and returns the bytes. Falls back to PNG if the system
    /// can't produce the requested container (HEIC on unusual colour spaces).
    public static func encode(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        dpiScale: CGFloat
    ) throws -> (data: Data, format: ImageFormat) {
        if let data = encodeAttempt(image, format: format, quality: quality, dpiScale: dpiScale) {
            return (data, format)
        }
        if format != .png, let data = encodeAttempt(image, format: .png, quality: 1, dpiScale: dpiScale) {
            Log.capture.warning("Falling back to PNG: \(format.rawValue) encoding failed")
            return (data, .png)
        }
        throw NotchShotError.exportFailed("Could not encode image as \(format.title)")
    }

    private static func encodeAttempt(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        dpiScale: CGFloat
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            utType(for: format).identifier as CFString,
            1,
            nil
        ) else { return nil }

        // 72 dpi × scale keeps Preview and Finder reporting the point size a
        // Retina screenshot should have, matching the system screenshot tool.
        let dpi = 72.0 * Double(dpiScale)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes to `url`, checking free space first so a full disk fails loudly
    /// instead of leaving a truncated file.
    public static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        quality: Double,
        dpiScale: CGFloat
    ) throws -> ImageFormat {
        let (data, usedFormat) = try encode(image, format: format, quality: quality, dpiScale: dpiScale)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let available = AppPaths.availableCapacity(at: directory)
        guard available > Int64(data.count) + 10_000_000 else {
            throw NotchShotError.diskSpaceUnavailable
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotchShotError.destinationUnwritable(url.path)
        }
        return usedFormat
    }

    /// Downsamples for the shelf and history list. Uses Core Graphics directly
    /// so it can run off the main actor.
    public static func makeThumbnail(from image: CGImage, maximumDimension: CGFloat = 512) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > 0 else { return nil }
        let factor = min(1, maximumDimension / longest)
        let targetWidth = Int((width * factor).rounded())
        let targetHeight = Int((height * factor).rounded())
        guard targetWidth > 0, targetHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Puts an image on the general pasteboard as both TIFF (universal) and PNG
    /// (lossless, what most editors prefer).
    @MainActor
    public static func copyToPasteboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        var items: [NSPasteboardItem] = []
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            item.setData(tiff, forType: .tiff)
        }
        items.append(item)
        pasteboard.writeObjects(items)
    }

    @MainActor
    public static func copyToPasteboard(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }

    @MainActor
    public static func copyToPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
