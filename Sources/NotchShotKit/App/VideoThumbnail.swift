import AppKit
import AVFoundation
import CoreMedia

/// Pulls a poster frame out of a finished recording for the shelf.
enum VideoThumbnail {
    struct Metadata {
        var pixelSize: CGSize
        var duration: TimeInterval
    }

    static func metadata(for url: URL) async -> Metadata? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0 else { return nil }
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return Metadata(
            pixelSize: CGSize(width: abs(transformed.width), height: abs(transformed.height)),
            duration: duration
        )
    }

    static func make(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        // A frame from a little way in avoids the black first frame most
        // screen recordings start with.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(max(duration * 0.1, 0.2), 3), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
