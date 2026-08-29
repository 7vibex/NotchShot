import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipboardKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case text
    case link
    case color
    case image
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .color: "Colour"
        case .image: "Image"
        case .files: "Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "eyedropper.halffull"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

/// One thing the user copied.
///
/// Text lives in the row; an image lives in a file beside it, named by the
/// entry's own UUID exactly the way History names thumbnails, so a row can
/// never authorise reading a path it did not create.
public struct ClipboardEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ClipboardKind
    /// Optional user-authored label for finding a clipping by its purpose
    /// rather than by a fragment of its potentially sensitive contents.
    public var label: String?
    /// The text, the URL, or the hex colour. Images gain text only after the
    /// user explicitly asks NotchShot to index that clipping with local OCR.
    public var text: String?
    /// Paths for a `.files` copy. Their identities are captured at copy time so
    /// replay cannot silently paste a different file that later reused a path.
    public var filePaths: [String]
    public var fileIdentities: [ExternalFileIdentity]?
    /// `<uuid>.png` inside the managed clipboard directory. Images only.
    public var imageFilename: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var sourceApplicationName: String?
    public var sourceApplicationBundleID: String?
    public var createdAt: Date
    public var isPinned: Bool
    /// Identifies the same content copied twice, so a re-copy moves the
    /// existing row to the top rather than adding a duplicate.
    public var contentHash: String

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        label: String? = nil,
        text: String? = nil,
        filePaths: [String] = [],
        fileIdentities: [ExternalFileIdentity]? = nil,
        imageFilename: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        sourceApplicationName: String? = nil,
        sourceApplicationBundleID: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        contentHash: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.text = text
        self.filePaths = filePaths
        self.fileIdentities = fileIdentities
        self.imageFilename = imageFilename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceApplicationName = sourceApplicationName
        self.sourceApplicationBundleID = sourceApplicationBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.contentHash = contentHash
    }

    /// Managed image location, validated the way History validates thumbnails:
    /// the filename must be exactly this row's UUID, and the result must sit
    /// physically inside the app's own storage.
    public var imageURL: URL? {
        guard let imageFilename, imageFilename == "\(id.uuidString).png" else { return nil }
        let url = AppPaths.clipboard.appendingPathComponent(imageFilename, isDirectory: false)
        return AppPaths.owns(url) ? url : nil
    }

    /// One line for the list. Never the whole clipping — a copied file can be
    /// megabytes of text and the row has to stay cheap to draw.
    public var preview: String {
        switch kind {
        case .image:
            if let text, !text.isEmpty {
                let collapsed = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return collapsed.count > 180 ? String(collapsed.prefix(180)) + "…" : collapsed
            }
            if let pixelWidth, let pixelHeight { return "Image · \(pixelWidth) × \(pixelHeight)" }
            return "Image"
        case .files:
            if filePaths.count == 1 {
                return URL(fileURLWithPath: filePaths[0]).lastPathComponent
            }
            return "\(filePaths.count) files"
        case .text, .link, .color:
            let raw = text ?? ""
            let collapsed = raw
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.count > 180 ? String(collapsed.prefix(180)) + "…" : collapsed
        }
    }

    public var displayTitle: String { label ?? kind.displayName }

    public var isSearchable: Bool { kind != .image || !(text?.isEmpty ?? true) }

    public func matches(_ query: HistoryQuery) -> Bool {
        guard !query.isEmpty else { return true }
        return query.appears(in: label)
            || query.appears(in: text)
            || query.appears(in: sourceApplicationName)
            || query.appears(in: kind.displayName)
            || filePaths.contains { query.appears(in: $0) }
    }

    /// Stable identity for deduplication.
    public static func hash(for data: some DataProtocol) -> String {
        SHA256.hash(data: data)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func hash(forText text: String) -> String {
        hash(for: Data(text.utf8))
    }
}
