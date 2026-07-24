import AppKit
import Foundation

public enum CaptureAssetKind: String, Sendable, Codable, CaseIterable {
    case screenshot
    case scrollingScreenshot
    case recording
    case text

    public var displayName: String {
        switch self {
        case .screenshot: "Screenshot"
        case .scrollingScreenshot: "Scrolling Screenshot"
        case .recording: "Recording"
        case .text: "Text"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenshot: "photo"
        case .scrollingScreenshot: "arrow.up.and.down.text.horizontal"
        case .recording: "video"
        case .text: "text.alignleft"
        }
    }
}

/// A finished capture on disk, plus the metadata the shelf and history need.
public struct CaptureAsset: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var kind: CaptureAssetKind
    /// Pixel dimensions of the underlying media.
    public var pixelSize: CGSize
    /// Backing scale the capture was taken at (2.0 on Retina).
    public var scale: CGFloat
    public var createdAt: Date
    /// Bundle identifier of the frontmost app when the capture was taken.
    public var sourceApplication: String?
    public var sourceApplicationName: String?
    /// Recording duration, seconds. Nil for stills.
    public var duration: TimeInterval?
    /// Text recognised by OCR, if any was requested.
    public var recognizedText: String?
    /// Sidecar `.notchshot` project, when the asset has been annotated.
    public var projectURL: URL?

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: CaptureAssetKind,
        pixelSize: CGSize,
        scale: CGFloat = 2,
        createdAt: Date = Date(),
        sourceApplication: String? = nil,
        sourceApplicationName: String? = nil,
        duration: TimeInterval? = nil,
        recognizedText: String? = nil,
        projectURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.pixelSize = pixelSize
        self.scale = scale
        self.createdAt = createdAt
        self.sourceApplication = sourceApplication
        self.sourceApplicationName = sourceApplicationName
        self.duration = duration
        self.recognizedText = recognizedText
        self.projectURL = projectURL
    }

    public var pointSize: CGSize {
        CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    public var displayName: String { url.lastPathComponent }

    public var dimensionsDescription: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    public var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    public var fileSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

/// What the user can do with a finished capture.
public enum ShareAction: String, Sendable, CaseIterable, Identifiable {
    case copy
    case save
    case annotate
    case ocr
    case pin
    case airDrop
    case reveal
    case delete

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .save: "Save…"
        case .annotate: "Annotate"
        case .ocr: "Copy Text"
        case .pin: "Pin"
        case .airDrop: "AirDrop"
        case .reveal: "Reveal in Finder"
        case .delete: "Delete"
        }
    }

    public var symbolName: String {
        switch self {
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .annotate: "pencil.tip.crop.circle"
        case .ocr: "text.viewfinder"
        case .pin: "pin"
        case .airDrop: "airplayaudio"
        case .reveal: "folder"
        case .delete: "trash"
        }
    }

    public func isAvailable(for asset: CaptureAsset) -> Bool {
        switch self {
        case .annotate, .ocr, .pin: asset.kind != .recording
        default: true
        }
    }
}
