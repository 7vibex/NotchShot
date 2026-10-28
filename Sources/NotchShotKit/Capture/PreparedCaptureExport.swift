import Foundation

/// A single recipe result and its export settings. Bounded images that already
/// fit retain the exact encoding that passed the check until the file is written.
/// This is call-owned immutable data, rather than a shared image cache.
public struct PreparedCaptureExport: Sendable {
    public let image: CapturedImage
    private let format: ImageFormat
    private let quality: Double
    private let encoding: (data: Data, format: ImageFormat)?

    init(
        image: CapturedImage, format: ImageFormat, quality: Double,
        encoding: (data: Data, format: ImageFormat)? = nil
    ) {
        self.image = image
        self.format = format
        self.quality = quality
        self.encoding = encoding
    }

    /// Uses the same capacity guard and atomic writer as an ordinary capture.
    /// The returned format includes an encoder's fallback to PNG.
    public func write(to url: URL) async throws -> ImageFormat {
        if let encoding {
            return try await Task.detached(priority: .userInitiated) {
                try ImageExport.writeEncoded(encoding.data, to: url)
                return encoding.format
            }.value
        }
        return try await ImageExport.write(image, to: url, format: format, quality: quality)
    }
}
