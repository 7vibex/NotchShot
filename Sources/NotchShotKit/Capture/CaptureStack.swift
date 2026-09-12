import AppKit
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

/// How a stack of captures is combined on export.
public enum StackExportStyle: String, Sendable, CaseIterable, Identifiable {
    /// One tall image, shots stacked top to bottom.
    case longImage
    /// One wide image, shots side by side.
    case filmstrip
    /// A grid, sized to roughly a square.
    case storyboard
    /// A multi-page PDF, one capture per page.
    case pdf

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .longImage: "Long Image"
        case .filmstrip: "Filmstrip"
        case .storyboard: "Storyboard"
        case .pdf: "PDF"
        }
    }

    public var symbolName: String {
        switch self {
        case .longImage: "arrow.up.and.down.square"
        case .filmstrip: "rectangle.split.3x1"
        case .storyboard: "square.grid.2x2"
        case .pdf: "doc.richtext"
        }
    }

    public var fileExtension: String { self == .pdf ? "pdf" : "png" }
}

public struct StackExportOptions: Sendable {
    public var style: StackExportStyle
    /// Gap between captures, in pixels.
    public var spacing: CGFloat
    /// Border around the whole sheet, in pixels.
    public var margin: CGFloat
    public var backgroundHex: String
    /// Draws a numbered badge on each capture, for step-by-step guides.
    public var numbersSteps: Bool

    public init(
        style: StackExportStyle = .longImage,
        spacing: CGFloat = 24,
        margin: CGFloat = 32,
        backgroundHex: String = "#FFFFFF",
        numbersSteps: Bool = false
    ) {
        self.style = style
        self.spacing = spacing
        self.margin = margin
        self.backgroundHex = backgroundHex
        self.numbersSteps = numbersSteps
    }
}

/// One entry in the stack.
public struct StackItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var asset: CaptureAsset

    public init(id: UUID = UUID(), asset: CaptureAsset) {
        self.id = id
        self.asset = asset
    }
}

public struct CaptureSessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var assetIDs: [UUID]
}

/// Collects several captures so they can be exported as one artefact.
///
/// The point is the workflow people actually have — take three shots of a flow,
/// then hand over *one* thing — rather than attaching three files and hoping
/// the order survives.
@MainActor
@Observable
public final class CaptureStack {
    public static let shared = CaptureStack()

    public private(set) var items: [StackItem] = []
    public private(set) var savedSessions: [CaptureSessionRecord] = []
    public private(set) var lastPersistenceError: String?
    /// While on, every new capture is added to the stack instead of replacing
    /// the shelf's single result.
    public var isCollecting = false

    /// Beyond this the exported sheet stops being useful anyway.
    public static let maximumItems = 24
    /// Bounds simultaneous decoded input memory for one export operation.
    public static let maximumDecodedPixels = 60_000_000

    private let sessionsURL: URL
    private let usesManagedStore: Bool

    public init(
        sessionsURL: URL = AppPaths.support.appendingPathComponent("CaptureSessions.json")
    ) {
        self.sessionsURL = sessionsURL
        usesManagedStore = AppPaths.owns(sessionsURL)
        loadSessions()
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    @discardableResult
    public func add(_ asset: CaptureAsset) -> Bool {
        guard items.count < Self.maximumItems else {
            Log.capture.notice("Capture stack is full (\(Self.maximumItems))")
            return false
        }
        items.append(StackItem(asset: asset))
        return true
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public func replace(id: UUID, with asset: CaptureAsset) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].asset = asset
    }

    public func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Swaps an item with its neighbour — the reorder affordance that fits in a
    /// notch, where drag-to-reorder has nowhere to go.
    public func moveItem(id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    public func clear() {
        items.removeAll()
        isCollecting = false
    }

    @discardableResult
    public func saveSession(named proposedName: String) throws -> CaptureSessionRecord? {
        guard !items.isEmpty else { return nil }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = CaptureSessionRecord(
            id: UUID(),
            name: trimmed.isEmpty ? "Capture Session" : trimmed,
            createdAt: Date(),
            assetIDs: items.map { $0.asset.id }
        )
        var candidate = savedSessions
        candidate.insert(session, at: 0)
        do {
            try persistSessions(candidate)
            savedSessions = candidate
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
        return session
    }

    @discardableResult
    public func resume(_ session: CaptureSessionRecord, history: HistoryRepository) -> Int {
        let assets = session.assetIDs.compactMap { history.entry(id: $0)?.asset }
            .filter { SafeAssetFile.isCurrentAndSafe($0) }
        items = Array(assets.prefix(Self.maximumItems)).map { StackItem(asset: $0) }
        isCollecting = true
        return items.count
    }

    public func deleteSession(id: UUID) throws {
        let candidate = savedSessions.filter { $0.id != id }
        do {
            try persistSessions(candidate)
            savedSessions = candidate
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    private func loadSessions() {
        guard let values = try? sessionsURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: sessionsURL),
              let decoded = try? JSONDecoder().decode([CaptureSessionRecord].self, from: data) else {
            return
        }
        savedSessions = Array(decoded.prefix(100))
    }

    private func persistSessions(_ sessions: [CaptureSessionRecord]) throws {
        guard !usesManagedStore || AppPaths.ensureDirectories() else {
            throw NotchShotError.destinationUnwritable(sessionsURL.path)
        }
        let data = try JSONEncoder().encode(sessions)
        guard data.count <= 1_000_000 else {
            throw NotchShotError.exportFailed("Capture sessions exceeded their safe size limit")
        }
        try FileManager.default.createDirectory(
            at: sessionsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sessionsURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sessionsURL.path
        )
    }

    /// Renders the stack and writes it to `url`.
    @discardableResult
    public func export(to url: URL, options: StackExportOptions) throws -> URL {
        let images = try loadImagesForExport()

        if options.style == .pdf {
            try StackRenderer.writePDF(images: images, options: options, to: url)
            return url
        }

        let sheet = try StackRenderer.render(images: images, options: options)
        _ = try ImageExport.write(sheet, to: url, format: .png, quality: 1, dpiScale: 2)
        return url
    }

    /// Rendered preview of what export would produce.
    public func renderPreview(options: StackExportOptions) -> CGImage? {
        guard let images = try? loadImagesForExport() else { return nil }
        var preview = options
        if preview.style == .pdf { preview.style = .longImage }
        return try? StackRenderer.render(images: images, options: preview)
    }

    private func loadImagesForExport() throws -> [CGImage] {
        guard !items.isEmpty else {
            throw NotchShotError.exportFailed("The capture stack is empty")
        }
        var images: [CGImage] = []
        var decodedPixels = 0
        for item in items {
            guard let image = SafeImageFile.cgImage(for: item.asset) else {
                throw NotchShotError.exportFailed(
                    "Could not safely read stacked capture \(item.asset.displayName)"
                )
            }
            guard image.height > 0,
                  image.width <= (Self.maximumDecodedPixels - decodedPixels) / image.height else {
                throw NotchShotError.exportFailed(
                    "The stacked captures are too large to decode safely in one operation"
                )
            }
            decodedPixels += image.width * image.height
            images.append(image)
        }
        return images
    }
}

/// Lays out and draws a stack sheet. Pure, so the geometry is testable.
public enum StackRenderer {
    static let maximumCanvasDimension = 32_768
    static let maximumCanvasPixels = 80_000_000

    /// Where each capture sits on the sheet, and how big the sheet is.
    ///
    /// Captures are scaled to a common width (or height, for a filmstrip) so a
    /// Retina shot and a 1× shot don't come out wildly different sizes.
    public static func layout(
        sizes: [CGSize],
        options: StackExportOptions
    ) -> (canvas: CGSize, frames: [CGRect]) {
        guard !sizes.isEmpty else { return (.zero, []) }
        let spacing = options.spacing
        let margin = options.margin

        switch options.style {
        case .longImage, .pdf:
            let targetWidth = sizes.map(\.width).max() ?? 1
            var frames: [CGRect] = []
            var y = margin
            for size in sizes {
                let scale = size.width > 0 ? targetWidth / size.width : 1
                let height = size.height * scale
                frames.append(CGRect(x: margin, y: y, width: targetWidth, height: height))
                y += height + spacing
            }
            let canvasHeight = y - spacing + margin
            return (CGSize(width: targetWidth + margin * 2, height: canvasHeight), frames)

        case .filmstrip:
            let targetHeight = sizes.map(\.height).max() ?? 1
            var frames: [CGRect] = []
            var x = margin
            for size in sizes {
                let scale = size.height > 0 ? targetHeight / size.height : 1
                let width = size.width * scale
                frames.append(CGRect(x: x, y: margin, width: width, height: targetHeight))
                x += width + spacing
            }
            let canvasWidth = x - spacing + margin
            return (CGSize(width: canvasWidth, height: targetHeight + margin * 2), frames)

        case .storyboard:
            // Roughly square grid, filled row-major.
            let columns = max(1, Int(Double(sizes.count).squareRoot().rounded(.up)))
            let rows = Int((Double(sizes.count) / Double(columns)).rounded(.up))
            let cellWidth = sizes.map(\.width).max() ?? 1
            let cellHeight = sizes.map(\.height).max() ?? 1

            var frames: [CGRect] = []
            for (index, size) in sizes.enumerated() {
                let column = index % columns
                let row = index / columns
                let cell = CGRect(
                    x: margin + CGFloat(column) * (cellWidth + spacing),
                    y: margin + CGFloat(row) * (cellHeight + spacing),
                    width: cellWidth,
                    height: cellHeight
                )
                // Aspect-fit inside the cell so mixed shapes stay undistorted.
                let scale = min(cell.width / max(size.width, 1), cell.height / max(size.height, 1))
                let width = size.width * scale
                let height = size.height * scale
                frames.append(CGRect(
                    x: cell.midX - width / 2,
                    y: cell.midY - height / 2,
                    width: width,
                    height: height
                ))
            }
            return (
                CGSize(
                    width: margin * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing,
                    height: margin * 2 + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
                ),
                frames
            )
        }
    }

    public static func render(images: [CGImage], options: StackExportOptions) throws -> CGImage {
        try validate(images: images, options: options)
        let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let (canvas, frames) = layout(sizes: sizes, options: options)
        guard canvas.width.isFinite,
              canvas.height.isFinite,
              canvas.width >= 1,
              canvas.height >= 1,
              canvas.width <= CGFloat(maximumCanvasDimension),
              canvas.height <= CGFloat(maximumCanvasDimension)
        else {
            throw NotchShotError.exportFailed("Could not allocate the stack canvas")
        }
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width <= maximumCanvasPixels / height,
              let context = AnnotationRenderer.makeContext(
                width: width,
                height: height
              )
        else {
            throw NotchShotError.exportFailed("Could not allocate the stack canvas")
        }

        context.setFillColor((NSColor(hex: options.backgroundHex) ?? .white).cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))

        for (index, image) in images.enumerated() {
            let frame = frames[index]
            // Layout is top-down; the context is bottom-up.
            let flipped = CGRect(
                x: frame.origin.x,
                y: canvas.height - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -4),
                blur: 18,
                color: NSColor.black.withAlphaComponent(0.22).cgColor
            )
            context.draw(image, in: flipped)
            context.restoreGState()

            if options.numbersSteps {
                drawStepBadge(index + 1, at: flipped, in: context)
            }
        }

        guard let sheet = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not render the stack")
        }
        return sheet
    }

    private static func drawStepBadge(_ number: Int, at frame: CGRect, in context: CGContext) {
        let radius: CGFloat = max(min(frame.width, frame.height) * 0.045, 18)
        let centre = CGPoint(x: frame.minX + radius * 1.2, y: frame.maxY - radius * 1.2)

        context.saveGState()
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributed = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: radius, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// One capture per page, each page sized to its capture.
    public static func writePDF(images: [CGImage], options: StackExportOptions, to url: URL) throws {
        try validate(images: images, options: options)
        let parent = url.deletingLastPathComponent()
        let estimatedBytes = try estimatedPDFWorkingBytes(images: images)
        guard AppPaths.availableCapacity(at: parent) > estimatedBytes else {
            throw NotchShotError.exportFailed("There is not enough free space to safely export the PDF")
        }

        let stagingURL = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).partial"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let margin = options.margin
        var firstPage = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(images[0].width) + margin * 2,
            height: CGFloat(images[0].height) + margin * 2
        )
        guard let consumer = CGDataConsumer(url: stagingURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &firstPage, nil)
        else {
            throw NotchShotError.exportFailed("Could not create the PDF")
        }

        for (index, image) in images.enumerated() {
            var page = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(image.width) + margin * 2,
                height: CGFloat(image.height) + margin * 2
            )
            let info = [kCGPDFContextMediaBox as String: NSData(
                bytes: &page,
                length: MemoryLayout<CGRect>.size
            )] as CFDictionary

            context.beginPDFPage(info)
            context.setFillColor((NSColor(hex: options.backgroundHex) ?? .white).cgColor)
            context.fill(page)
            let frame = CGRect(
                x: margin,
                y: margin,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
            context.draw(image, in: frame)
            if options.numbersSteps {
                drawStepBadge(index + 1, at: frame, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()

        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0,
              let document = CGPDFDocument(stagingURL as CFURL),
              document.numberOfPages == images.count else {
            throw NotchShotError.exportFailed("The PDF could not be finalized safely")
        }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: url)
        }
    }

    private static func validate(images: [CGImage], options: StackExportOptions) throws {
        guard !images.isEmpty else {
            throw NotchShotError.exportFailed("The capture stack is empty")
        }
        guard options.spacing.isFinite,
              options.margin.isFinite,
              options.spacing >= 0,
              options.margin >= 0,
              options.spacing <= 4_096,
              options.margin <= 4_096 else {
            throw NotchShotError.exportFailed("The stack spacing or margin is invalid")
        }
    }

    private static func estimatedPDFWorkingBytes(images: [CGImage]) throws -> Int64 {
        var bytes: Int64 = 16 * 1_024 * 1_024
        for image in images {
            let (pixels, pixelOverflow) = Int64(image.width).multipliedReportingOverflow(
                by: Int64(image.height)
            )
            let (decodedBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            let (sum, sumOverflow) = bytes.addingReportingOverflow(decodedBytes)
            guard !pixelOverflow, !byteOverflow, !sumOverflow else {
                throw NotchShotError.exportFailed("The PDF is too large to export safely")
            }
            bytes = sum
        }
        return bytes
    }
}
