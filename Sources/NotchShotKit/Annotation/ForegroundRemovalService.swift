import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Lifts the noticeable foreground subjects from an image on this Mac.
///
/// Vision produces the instance mask and the masked pixel buffer. Nothing is
/// uploaded, and the result stays full-size with transparent pixels where the
/// background used to be so it can go straight into NotchShot's PNG/export
/// pipeline without changing the subject's placement.
public actor ForegroundRemovalService {
    public static let shared = ForegroundRemovalService()

    /// One RGBA bitmap of this size is about 128 MB, and the lift holds
    /// several at once — the source, Vision's mask, the masked pixel buffer,
    /// and the rendered result — before the caller adds a PNG encode on top.
    /// The previous 50-megapixel ceiling put that peak near a gigabyte. This
    /// still covers a full 6K display and a tall stitched scroll capture.
    static let maximumPixels = 32_000_000

    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func removeBackground(from image: CGImage) async throws -> CGImage {
        guard image.width > 0, image.height > 0,
              image.width <= 32_768, image.height <= 32_768,
              image.width <= Self.maximumPixels / max(image.height, 1) else {
            throw NotchShotError.exportFailed("That image is too large to lift safely")
        }

        let handler = ImageRequestHandler(image)
        let observation: InstanceMaskObservation?
        do {
            observation = try await handler.perform(GenerateForegroundInstanceMaskRequest())
        } catch {
            Log.capture.error("Foreground mask generation failed: \(error.localizedDescription)")
            throw NotchShotError.exportFailed("Could not identify a foreground subject")
        }

        guard let observation, !observation.allInstances.isEmpty else {
            throw NotchShotError.exportFailed("No clear foreground subject was found")
        }

        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateMaskedImage(
                for: observation.allInstances,
                imageFrom: handler,
                croppedToInstancesExtent: false
            )
        } catch {
            Log.capture.error("Foreground image generation failed: \(error.localizedDescription)")
            throw NotchShotError.exportFailed("Could not separate the subject from its background")
        }

        let masked = CIImage(cvPixelBuffer: buffer)
        guard masked.extent.width > 0, masked.extent.height > 0,
              let result = context.createCGImage(masked, from: masked.extent),
              result.width == image.width, result.height == image.height else {
            throw NotchShotError.exportFailed("Could not render the lifted subject")
        }
        return result
    }

    public nonisolated static func suggestedFilename(for sourceURL: URL) -> String {
        let rawBase = sourceURL.deletingPathExtension().lastPathComponent
        guard let base = ShelfFileOperations.sanitizedName(rawBase) else {
            return "Subject.png"
        }
        return "\(base) Subject.png"
    }
}
