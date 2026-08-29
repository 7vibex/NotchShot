import AppKit
import CoreGraphics
import Foundation
import ImageIO

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

    private static let maximumJSONBytes = 8_000_000
    private static let maximumImageBytes = 100_000_000
    private static let maximumImageDimension = 16_384
    private static let maximumImagePixels = 50_000_000
    private static let maximumRenderDimension = 32_768
    private static let maximumRenderPixels = 80_000_000
    private static let maximumElements = 5_000
    private static let maximumPoints = 500_000

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
           !path.hasPrefix(Entry.assets) {
            guard let backgroundImage = SafeImageFile.cgImage(
                at: URL(fileURLWithPath: path),
                limits: .background
            ) else {
                throw NotchShotError.exportFailed("The custom background is unsafe or no longer readable")
            }
            let (data, _) = try ImageExport.encode(
                backgroundImage,
                format: .png,
                quality: 1,
                dpiScale: 1
            )
            let name = "background.png"
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
        let packageValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageValues?.isDirectory == true, packageValues?.isSymbolicLink != true else {
            throw NotchShotError.exportFailed("\(url.lastPathComponent) is not a NotchShot project")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Validate the light-weight version header before decoding a large
        // source image. Older packages without Info.json remain supported.
        let infoURL = url.appendingPathComponent(Entry.info)
        let decodedInfo: Info? = if FileManager.default.fileExists(atPath: infoURL.path) {
            try decoder.decode(
                Info.self,
                from: safeRegularFileData(at: infoURL, maximumBytes: maximumJSONBytes)
            )
        } else {
            nil
        }
        if let decodedInfo, decodedInfo.formatVersion > 1 {
            throw NotchShotError.exportFailed(
                "This project was made by a newer version of NotchShot"
            )
        }

        let documentData = try safeRegularFileData(
            at: url.appendingPathComponent(Entry.document),
            maximumBytes: maximumJSONBytes
        )
        var document = try decoder.decode(AnnotationDocument.self, from: documentData)
        guard document.version <= 1 else {
            throw NotchShotError.exportFailed(
                "This project was made by a newer version of NotchShot"
            )
        }

        let info = decodedInfo ?? Info(
            formatVersion: document.version,
            applicationVersion: "unknown",
            createdAt: document.createdAt,
            modifiedAt: document.modifiedAt
        )

        let sourceData = try safeRegularFileData(
            at: url.appendingPathComponent(Entry.source),
            maximumBytes: maximumImageBytes
        )
        guard let provider = CGDataProvider(data: sourceData as CFData),
              let source = CGImage(
                  pngDataProviderSource: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw NotchShotError.exportFailed("Project is missing a valid source image")
        }
        guard source.width > 0, source.height > 0,
              source.width <= maximumImageDimension,
              source.height <= maximumImageDimension,
              source.width <= maximumImagePixels / source.height else {
            throw NotchShotError.exportFailed("Project source image is too large")
        }

        try validate(document: document, source: source)

        // Imported projects can reference only a regular file directly inside
        // their own Assets directory. Absolute paths, traversal, and symlinks
        // would otherwise let an untrusted project read local files.
        if case .image(let path) = document.background.fill {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !(path as NSString).isAbsolutePath,
                  components.count == 2,
                  components[0] == Substring(Entry.assets),
                  !components[1].isEmpty,
                  components[1] != ".",
                  components[1] != ".." else {
                throw NotchShotError.exportFailed("Project contains an unsafe background path")
            }
            let assetsURL = url.appendingPathComponent(Entry.assets, isDirectory: true)
            let assetDirectoryValues = try? assetsURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard assetDirectoryValues?.isDirectory == true,
                  assetDirectoryValues?.isSymbolicLink != true else {
                throw NotchShotError.exportFailed("Project contains an unsafe Assets directory")
            }
            let assetURL = assetsURL
                .appendingPathComponent(String(components[1]))
            let backgroundData = try safeRegularFileData(
                at: assetURL,
                maximumBytes: maximumImageBytes
            )
            try validateEncodedImage(backgroundData, entryName: assetURL.lastPathComponent)
            document.background.fill = .image(path: assetURL.path)
        }

        return Contents(document: document, source: source, info: info)
    }

    private static func safeRegularFileData(at url: URL, maximumBytes: Int) throws -> Data {
        do {
            return try SafeAssetFile.readData(
                at: url,
                maximumBytes: Int64(maximumBytes)
            )
        } catch {
            throw NotchShotError.exportFailed(
                "Project entry \(url.lastPathComponent) is unsafe or too large"
            )
        }
    }

    private static func validate(document: AnnotationDocument, source: CGImage) throws {
        let pointCount = document.elements.reduce(into: 0) { total, element in
            total += element.points.count
        }
        let sourceWidth = document.sourcePixelSize.width
        let sourceHeight = document.sourcePixelSize.height
        // Existing projects can contain off-canvas annotations after a crop or
        // resize. Permit a generous but finite editing margin.
        let coordinateSlack = CGFloat(maximumRenderDimension) * 2
        guard document.elements.count <= maximumElements,
              pointCount <= maximumPoints,
              sourceWidth.isFinite,
              sourceHeight.isFinite,
              document.sourceScale.isFinite,
              sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth <= CGFloat(maximumImageDimension),
              sourceHeight <= CGFloat(maximumImageDimension),
              sourceWidth * sourceHeight <= CGFloat(maximumImagePixels),
              abs(sourceWidth - CGFloat(source.width)) <= 1,
              abs(sourceHeight - CGFloat(source.height)) <= 1,
              (0.25 ... 8).contains(document.sourceScale),
              document.elements.allSatisfy({ element in
                  let style = element.style
                  return element.points.allSatisfy {
                      $0.x.isFinite && $0.y.isFinite
                          && (-coordinateSlack ... sourceWidth + coordinateSlack).contains($0.x)
                          && (-coordinateSlack ... sourceHeight + coordinateSlack).contains($0.y)
                  }
                      && (0 ... 512).contains(style.lineWidth)
                      && (0 ... 1).contains(style.opacity)
                      && (1 ... 1_024).contains(style.fontSize)
                      && (0 ... 4_096).contains(style.cornerRadius)
                      && (1 ... 1_024).contains(style.pixelBlockSize)
                      && style.colorHex.utf8.count <= 32
                      && element.text.utf8.count <= 100_000
                      && (-1_000_000 ... 1_000_000).contains(element.order)
                      && (0 ... 1_000_000).contains(element.counterValue)
              }) else {
            throw NotchShotError.exportFailed(
                "Project contains invalid or excessive annotation data"
            )
        }

        let background = document.background
        guard (0 ... 2_048).contains(background.padding),
              (0 ... 4_096).contains(background.cornerRadius),
              (0 ... 1_024).contains(background.shadowRadius),
              (0 ... 1).contains(background.shadowOpacity),
              (-1 ... 1).contains(background.horizontalAlignment),
              (-1 ... 1).contains(background.verticalAlignment),
              background.aspectRatio.map({ (0.2 ... 5).contains($0) }) ?? true,
              isSafe(fill: background.fill) else {
            throw NotchShotError.exportFailed("Project contains invalid background geometry")
        }

        var contentSize = document.cropRect?.size ?? document.sourcePixelSize
        if document.rotation.swapsAxes {
            contentSize = CGSize(width: contentSize.height, height: contentSize.width)
        }
        let renderLayout = background.layout(for: contentSize, scale: document.sourceScale)
        guard renderLayout.canvas.width.isFinite,
              renderLayout.canvas.height.isFinite,
              renderLayout.canvas.width > 0,
              renderLayout.canvas.height > 0,
              renderLayout.canvas.width <= CGFloat(maximumRenderDimension),
              renderLayout.canvas.height <= CGFloat(maximumRenderDimension),
              renderLayout.canvas.width * renderLayout.canvas.height <= CGFloat(maximumRenderPixels) else {
            throw NotchShotError.exportFailed("Project render canvas is too large")
        }

        if let crop = document.cropRect {
            guard crop.origin.x.isFinite, crop.origin.y.isFinite,
                  crop.width.isFinite, crop.height.isFinite,
                  crop.width > 0, crop.height > 0,
                  CGRect(origin: .zero, size: document.sourcePixelSize)
                    .insetBy(dx: -1, dy: -1)
                    .contains(crop) else {
                throw NotchShotError.exportFailed("Project contains invalid crop geometry")
            }
        }
    }

    private static func isSafe(fill: BackgroundFill) -> Bool {
        switch fill {
        case .none:
            true
        case .solid(let hex):
            hex.utf8.count <= 32
        case .gradient(let startHex, let endHex, let angle):
            startHex.utf8.count <= 32
                && endHex.utf8.count <= 32
                && angle.isFinite
                && abs(angle) <= 36_000
        case .image(let path):
            path.utf8.count <= 1_024
        }
    }

    /// Reads only encoded metadata, avoiding an attacker-controlled full
    /// background decode before dimensions are bounded.
    private static func validateEncodedImage(_ data: Data, entryName: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumImageDimension,
              height <= maximumImageDimension,
              width <= maximumImagePixels / height else {
            throw NotchShotError.exportFailed(
                "Project entry \(entryName) is not a safe image"
            )
        }
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
