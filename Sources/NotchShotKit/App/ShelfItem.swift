import AppKit
import Observation

/// A shelf action that has just completed on one item.
public struct ShelfActionConfirmation: Equatable, Sendable {
    static let duration = Duration.milliseconds(1400)

    public let action: ShareAction
    public let itemID: UUID
    let token = UUID()
}

/// A finished capture sitting in the notch shelf.
@MainActor
@Observable
public final class ShelfItem: Identifiable {
    public let id: UUID
    public var asset: CaptureAsset
    public var thumbnail: NSImage?
    /// Kept in memory so Annotate and OCR don't have to re-read from disk.
    public var image: CapturedImage?
    public var ocrResult: OCRResult?
    public var stitchWarnings: [String]
    public var seams: [StitchSeam]

    public init(
        asset: CaptureAsset,
        thumbnail: NSImage?,
        image: CapturedImage?,
        stitchWarnings: [String] = [],
        seams: [StitchSeam] = []
    ) {
        self.id = asset.id
        self.asset = asset
        self.thumbnail = thumbnail
        self.image = image
        self.stitchWarnings = stitchWarnings
        self.seams = seams
    }
}
