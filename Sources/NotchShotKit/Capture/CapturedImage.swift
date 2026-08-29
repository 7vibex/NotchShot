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

    /// `write`, moved off the caller's actor.
    ///
    /// Encoding a full-screen Retina capture as PNG takes well over 200 ms.
    /// Called straight from the `@MainActor` capture flow that lands squarely in
    /// the moment the capture is meant to feel instant, stalling the notch
    /// animation and everything queued behind it on the main thread.
    public static func write(
        _ image: CapturedImage,
        to url: URL,
        format: ImageFormat,
        quality: Double
    ) async throws -> ImageFormat {
        try await Task.detached(priority: .userInitiated) {
            try write(
                image.cgImage,
                to: url,
                format: format,
                quality: quality,
                dpiScale: image.scale
            )
        }.value
    }

    /// `makeThumbnail`, moved off the caller's actor for the same reason.
    public static func makeThumbnail(
        from image: CapturedImage,
        maximumDimension: CGFloat = 512
    ) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            makeThumbnail(from: image.cgImage, maximumDimension: maximumDimension)
        }.value
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

    /// Offers an image on the general pasteboard as both TIFF (universal) and
    /// PNG (lossless, what most editors prefer), encoded on demand.
    ///
    /// Encoding a full-screen Retina capture costs roughly 330 ms for PNG and
    /// another 90 ms for TIFF. Doing that here froze the main actor for close to
    /// half a second on every single capture — paid in full even though most
    /// captures are never pasted anywhere. Promising the types instead defers
    /// the work to whoever actually asks for the bytes, and holding the
    /// immutable `CGImage` in the meantime costs less memory than the
    /// uncompressed TIFF it replaces.
    @MainActor
    public static func copyToPasteboard(_ image: CGImage) {
        copyToPasteboard(image, to: .general)
    }

    /// Injectable so tests can prove the promise resolves without commandeering
    /// the user's real clipboard.
    @MainActor
    static func copyToPasteboard(_ image: CGImage, to pasteboard: NSPasteboard) {
        let changeCount = pasteboard.clearContents()
        let provider = PromisedImage(image: image)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: PromisedImage.types)
        if pasteboard === NSPasteboard.general {
            promisedImage = provider
            promisedImageChangeCount = changeCount
        }
        pasteboard.writeObjects([item])
        noteSelfWrite(pasteboard.changeCount, to: pasteboard)
    }

    /// Encodes any clipboard image still held as a promise.
    ///
    /// AppKit does not redeem outstanding promises when the promising process
    /// exits, so without this, quitting NotchShot would empty a clipboard the
    /// user had just filled from it. Call it on the way out.
    @MainActor
    public static func redeemPromisedPasteboardImage() {
        guard promisedImage != nil else { return }
        // Someone else has copied since, so there is no promise of ours left to
        // redeem — and nothing left to hold the pixels for.
        guard NSPasteboard.general.changeCount == promisedImageChangeCount else {
            releasePromisedImage()
            return
        }
        // Asking is what drives the callback; the bytes then replace the promise
        // on the pasteboard itself, which outlives this process.
        for type in PromisedImage.types {
            _ = NSPasteboard.general.data(forType: type)
        }
        releasePromisedImage()
    }

    /// Retained only so the promise can still be redeemed at termination. The
    /// pasteboard holds its own reference for as long as the content is current.
    ///
    /// Dropped as soon as the pasteboard is finished with it: a full-screen
    /// capture is tens of megabytes, and holding the last copied one for the
    /// rest of the session — long after the user has copied something else —
    /// would trade a main-thread stall for a permanent memory cost.
    @MainActor private static var promisedImage: PromisedImage?
    @MainActor private static var promisedImageChangeCount = -1

    /// Change count of the last write NotchShot made to the general pasteboard.
    ///
    /// The clipboard history has to skip these. Not to avoid a duplicate — that
    /// would be cosmetic — but because a copied capture is offered as a
    /// *promise*, and reading its data to record it would force the very
    /// encode the promise exists to defer, on every single capture.
    @MainActor public private(set) static var lastSelfWriteChangeCount = -1

    @MainActor
    private static func noteSelfWrite(_ changeCount: Int, to pasteboard: NSPasteboard) {
        guard pasteboard === NSPasteboard.general else { return }
        lastSelfWriteChangeCount = changeCount
    }

    @MainActor
    private static func releasePromisedImage() {
        promisedImage = nil
        promisedImageChangeCount = -1
    }

    /// Called by the provider once the pasteboard no longer needs it.
    ///
    /// Takes an identity rather than the provider itself: the callback arrives
    /// from whatever thread finished with the pasteboard, and an
    /// `ObjectIdentifier` crosses to the main actor without carrying the object.
    static func promisedImageFinished(_ provider: ObjectIdentifier) {
        Task { @MainActor in
            // Identity-checked: a newer copy may already have replaced it, and
            // that one is still live.
            guard promisedImage.map(ObjectIdentifier.init) == provider else { return }
            releasePromisedImage()
        }
    }

    @MainActor
    public static func copyToPasteboard(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        noteSelfWrite(pasteboard.changeCount, to: pasteboard)
    }

    @MainActor
    public static func copyToPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        noteSelfWrite(pasteboard.changeCount, to: pasteboard)
    }
}

/// Holds the pixels behind a clipboard promise and encodes them when a
/// receiving app asks for a particular representation.
///
/// The pasteboard keeps this alive while its content is current, so the source
/// image stays valid for as long as the promise can be redeemed.
///
/// `NSPasteboardItemDataProvider` carries no actor isolation, and the callback
/// arrives on whichever thread redeems the promise, so the cache is locked
/// rather than assumed to be on the main one. `CGImage` is immutable and safe
/// to read from anywhere.
private final class PromisedImage: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    /// TIFF first: the order is what the pasteboard advertises, and apps that
    /// take the first type they recognise have historically expected TIFF.
    static let types: [NSPasteboard.PasteboardType] = [.tiff, .png]

    private let image: CGImage
    private let lock = NSLock()
    /// Encoding the same representation twice is pure waste when several apps
    /// read one clipboard entry, and TIFF of a full-screen capture is not cheap.
    private var encoded: [NSPasteboard.PasteboardType: Data] = [:]

    init(image: CGImage) {
        self.image = image
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let data = data(for: type) else { return }
        item.setData(data, forType: type)
    }

    /// The pasteboard has moved on, so nothing can ask for these pixels again.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        ImageExport.promisedImageFinished(ObjectIdentifier(self))
    }

    private func data(for type: NSPasteboard.PasteboardType) -> Data? {
        let fileType: NSBitmapImageRep.FileType? = switch type {
        case .png: .png
        case .tiff: .tiff
        default: nil
        }
        guard let fileType else { return nil }

        lock.lock()
        let cached = encoded[type]
        lock.unlock()
        if let cached { return cached }

        // Encoded outside the lock: this is the expensive part, and a second
        // reader waiting on it would be worse than encoding twice.
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: fileType, properties: [:]) else {
            return nil
        }

        lock.lock()
        encoded[type] = data
        lock.unlock()
        return data
    }
}
