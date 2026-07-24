import AppKit
import CoreGraphics
import Foundation

/// The `.notchshot` editable project format.
///
/// A file package (a directory the Finder shows as one document) holding:
///
/// ```
/// Name.notchshot/
///   Info.json          format + app version
///   source.png         the untouched original capture
///   document.json      crop, rotation, elements, background
///   background.json    the background alone, for external tooling
///   preview.png        flattened render, for Quick Look and the shelf
///   Assets/            any custom background image
/// ```
///
/// The original is stored unmodified so edits stay non-destructive. That means
/// a project file still contains whatever a redaction hides — which is correct
/// for a local editable document, and exactly why the *exported* image is
/// rendered through the burn-in path instead.
public enum NotchShotPackage {

    public static let fileExtension = "notchshot"

    public struct Info: Codable, Sendable {
        public var formatVersion: Int
        public var applicationVersion: String
        public var createdAt: Date
        public var modifiedAt: Date
    }

    public struct Contents: @unchecked Sendable {
        public var document: AnnotationDocument
        public var source: CGImage
        public var info: Info
    }

    private enum Entry {
        static let info = "Info.json"
        static let source = "source.png"
        static let document = "document.json"
        static let background = "background.json"
        static let preview = "preview.png"
        static let assets = "Assets"
    }

    // MARK: Write

    /// Writes (or overwrites) a project package atomically.
    @discardableResult
    public static func write(
        document: AnnotationDocument,
        source: CGImage,
        to url: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let info = Info(
            formatVersion: document.version,
            applicationVersion: Bundle.main.shortVersion,
            createdAt: document.createdAt,
            modifiedAt: Date()
        )

        let (sourceData, _) = try ImageExport.encode(
            source,
            format: .png,
            quality: 1,
            dpiScale: document.sourceScale
        )
        let preview = try AnnotationRenderer.render(document: document, source: source)
        let (previewData, _) = try ImageExport.encode(
            preview,
            format: .png,
            quality: 1,
            dpiScale: document.sourceScale
        )

        var children: [String: FileWrapper] = [
            Entry.info: FileWrapper(regularFileWithContents: try encoder.encode(info)),
            Entry.document: FileWrapper(regularFileWithContents: try encoder.encode(document)),
            Entry.background: FileWrapper(regularFileWithContents: try encoder.encode(document.background)),
            Entry.source: FileWrapper(regularFileWithContents: sourceData),
            Entry.preview: FileWrapper(regularFileWithContents: previewData),
        ]

        // A custom background image is copied in, so the project stays valid if
        // the user later moves or deletes the original file.
        if case .image(let path) = document.background.fill,
           !path.isEmpty,
           !path.hasPrefix(Entry.assets),
           let data = FileManager.default.contents(atPath: path) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let assets = FileWrapper(directoryWithFileWrappers: [
                name: FileWrapper(regularFileWithContents: data),
            ])
            children[Entry.assets] = assets

            var copy = document
            copy.background.fill = .image(path: "\(Entry.assets)/\(name)")
            children[Entry.document] = FileWrapper(regularFileWithContents: try encoder.encode(copy))
            children[Entry.background] = FileWrapper(
                regularFileWithContents: try encoder.encode(copy.background)
            )
        }

        let package = FileWrapper(directoryWithFileWrappers: children)
        // `.withNameUpdating` + a temp directory gives us replace-in-place
        // semantics: a failed write can't leave a half-written project behind.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.write(to: url, options: [.atomic, .withNameUpdating], originalContentsURL: nil)

        // Finder shows a directory with a known extension as a document only if
        // it is flagged as a bundle.
        try? (url as NSURL).setResourceValue(true, forKey: .isPackageKey)
        return url
    }

    // MARK: Read

    public static func read(from url: URL) throws -> Contents {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw NotchShotError.exportFailed("\(url.lastPathComponent) is not a NotchShot project")
        }

        guard let documentData = children[Entry.document]?.regularFileContents else {
            throw NotchShotError.exportFailed("Project is missing its document")
        }
        guard let sourceData = children[Entry.source]?.regularFileContents,
              let provider = CGDataProvider(data: sourceData as CFData),
              let source = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            throw NotchShotError.exportFailed("Project is missing its source image")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = try decoder.decode(AnnotationDocument.self, from: documentData)

        let info: Info
        if let infoData = children[Entry.info]?.regularFileContents {
            info = try decoder.decode(Info.self, from: infoData)
        } else {
            info = Info(
                formatVersion: document.version,
                applicationVersion: "unknown",
                createdAt: document.createdAt,
                modifiedAt: document.modifiedAt
            )
        }

        guard info.formatVersion <= 1 else {
            throw NotchShotError.exportFailed(
                "This project was made by a newer version of NotchShot"
            )
        }

        // Re-anchor a packaged background image to its absolute path.
        if case .image(let path) = document.background.fill, path.hasPrefix("\(Entry.assets)/") {
            document.background.fill = .image(path: url.appendingPathComponent(path).path)
        }

        return Contents(document: document, source: source, info: info)
    }

    public static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Default project location for a capture, alongside the app's other data.
    public static func defaultURL(named name: String) -> URL {
        AppPaths.uniqueURL(in: AppPaths.projects, name: name, extension: fileExtension)
    }
}

public extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    var buildVersion: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}
