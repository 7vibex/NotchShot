import AppKit
import CoreGraphics
import Foundation
import Observation

enum EditableProjectPrivacyAlertPolicy {
    static let buttonTitles = ["Cancel", "Save Editable Project"]

    static func allowsSave(for response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }
}

/// Editable state for one open capture: the document, the tool in hand, the
/// selection, and undo/redo.
///
/// Undo is snapshot-based. The documents are small value types (a few hundred
/// elements at worst), so storing whole copies is simpler and less bug-prone
/// than inverse operations, and makes "undo across a crop" work for free.
@MainActor
@Observable
public final class AnnotationDocumentController {

    struct BasePreviewCacheKey: Equatable, Sendable {
        var sourcePixelSize: CGSize
        var sourceScale: CGFloat
        var cropRect: CGRect?
        var rotation: RotationAngle
        var background: BackgroundConfiguration
    }

    public private(set) var document: AnnotationDocument
    public let source: CGImage
    /// The asset this document came from, when it has one.
    public let asset: CaptureAsset?
    /// Seams carried over from a scrolling capture, drawn as warnings.
    public var seams: [StitchSeam] = []

    public var selectedTool: AnnotationKind = .arrow
    public var selectedElementID: UUID?
    public var strokeColorHex: String
    public var lineWidth: Double
    public var projectURL: URL?
    /// Dirty state is derived from the last saved document rather than set by
    /// callers, so undoing back to the saved state (or a no-op gesture) can
    /// never leave a false "unsaved changes" prompt behind.
    public var hasUnsavedChanges: Bool { document != savedDocument }
    private var savedDocument: AnnotationDocument
    private var hasAcknowledgedProjectPrivacyWarning = false

    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []
    private let undoLimit = 60
    /// Set while a drag is in flight so the whole gesture is one undo step.
    private var isCoalescing = false
    private var coalescingStartDocument: AnnotationDocument?
    /// Rendering the composed source is one of the editor's most expensive
    /// operations. Annotation drags and selection changes do not affect this
    /// layer, so keep it until crop, rotation, or background geometry changes.
    @ObservationIgnored private var cachedBasePreviewKey: BasePreviewCacheKey?
    private var cachedBasePreview: NSImage?
    @ObservationIgnored private var previewRequestID: UUID?
    @ObservationIgnored var previewRenderer: @Sendable (AnnotationRenderSnapshot) async throws -> CapturedImage = {
        try await AnnotationRenderWorker.shared.render($0, isPreview: true)
    }

    public init(source: CGImage, document: AnnotationDocument, asset: CaptureAsset? = nil) {
        self.source = source
        self.document = document
        self.savedDocument = document
        self.asset = asset
        self.strokeColorHex = Preferences.shared.annotationColorHex
        self.lineWidth = Preferences.shared.annotationLineWidth
        self.projectURL = asset?.projectURL
    }

    public convenience init(image: CapturedImage, asset: CaptureAsset? = nil) {
        let document = AnnotationDocument(
            sourcePixelSize: image.pixelSize,
            sourceScale: image.scale,
            background: BackgroundPreset
                .preset(id: Preferences.shared.defaultBackgroundPresetID)?
                .configuration ?? .none
        )
        self.init(source: image.cgImage, document: document, asset: asset)
    }

    // MARK: Undo / redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    var undoStepCount: Int { undoStack.count }

    /// Call before any mutation that should be undoable.
    public func checkpoint() {
        guard !isCoalescing else { return }
        undoStack.append(document)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Groups every mutation inside `body` into a single undo step.
    public func coalescing(_ body: () -> Void) {
        let startedHere = !isCoalescing
        if startedHere { beginCoalescing() }
        body()
        if startedHere { endCoalescing() }
    }

    public func beginCoalescing() {
        guard !isCoalescing else { return }
        coalescingStartDocument = document
        checkpoint()
        isCoalescing = true
    }

    public func endCoalescing() {
        guard isCoalescing else { return }
        isCoalescing = false
        if document == coalescingStartDocument {
            _ = undoStack.popLast()
        }
        coalescingStartDocument = nil
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selectedElementID = nil
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        selectedElementID = nil
    }

    // MARK: Editing

    public func add(_ element: AnnotationElement) {
        checkpoint()
        document.add(element)
        selectedElementID = element.id
    }

    public func update(_ element: AnnotationElement) {
        document.update(element)
    }

    public func deleteSelection() {
        guard let selectedElementID else { return }
        checkpoint()
        document.remove(id: selectedElementID)
        self.selectedElementID = nil
    }

    public func selectElement(at point: CGPoint) {
        selectedElementID = document.element(at: point)?.id
    }

    public var selectedElement: AnnotationElement? {
        guard let selectedElementID else { return nil }
        return document.elements.first { $0.id == selectedElementID }
    }

    public func makeElement(kind: AnnotationKind, points: [CGPoint]) -> AnnotationElement {
        AnnotationElement(
            kind: kind,
            points: points,
            style: .default(for: kind, baseColorHex: strokeColorHex, lineWidth: lineWidth),
            counterValue: document.nextCounterValue
        )
    }

    public func setCrop(_ rect: CGRect?) {
        checkpoint()
        if let rect {
            let bounds = CGRect(origin: .zero, size: document.sourcePixelSize)
            document.cropRect = ScreenGeometry.clamp(rect, to: bounds, minimumSide: 8)
        } else {
            document.cropRect = nil
        }
    }

    public func rotateLeft() {
        checkpoint()
        document.rotation = document.rotation.rotatedLeft()
    }

    public func rotateRight() {
        checkpoint()
        document.rotation = document.rotation.rotatedRight()
    }

    public func applyBackground(_ configuration: BackgroundConfiguration) {
        checkpoint()
        document.background = configuration
    }

    public func applyBackgroundPreset(_ preset: BackgroundPreset) {
        applyBackground(preset.configuration)
    }

    // MARK: Rendering

    /// Live preview: redactions are drawn as placeholders rather than burned in,
    /// so the underlying pixels stay editable while the document is open.
    public func renderPreview() throws -> CGImage {
        try AnnotationRenderer.render(
            document: document,
            source: source,
            options: AnnotationRenderer.Options(isPreview: true, seams: seams)
        )
    }

    /// Export render: redactions are permanently burned into the pixels.
    public func renderFlattened() throws -> CGImage {
        try AnnotationRenderer.render(
            document: document,
            source: source,
            options: AnnotationRenderer.Options(isPreview: false, seams: seams)
        )
    }

    /// Base image used behind the editor's live annotation canvas.
    ///
    /// This deliberately excludes annotation elements from the cache key:
    /// they are rendered by the live `Canvas`, not burned into this image.
    var basePreviewKey: BasePreviewCacheKey {
        BasePreviewCacheKey(
            sourcePixelSize: document.sourcePixelSize,
            sourceScale: document.sourceScale,
            cropRect: document.cropRect,
            rotation: document.rotation,
            background: document.background
        )
    }

    /// A cache-only read: SwiftUI view evaluation never renders a bitmap.
    func basePreviewImage() -> NSImage? {
        // Read the observed image even on a miss so its later publication
        // invalidates the view that is currently displaying the placeholder.
        let preview = cachedBasePreview
        return cachedBasePreviewKey == basePreviewKey ? preview : nil
    }

    func makeRenderSnapshot() -> AnnotationRenderSnapshot {
        AnnotationRenderSnapshot(source: source, document: document, seams: seams)
    }

    func prepareBasePreview() async {
        let key = basePreviewKey
        if cachedBasePreviewKey == key { return }
        let requestID = UUID()
        previewRequestID = requestID
        var stripped = document
        stripped.elements = []
        let snapshot = AnnotationRenderSnapshot(source: source, document: stripped, seams: [])
        do {
            let image = try await previewRenderer(snapshot)
            guard !Task.isCancelled, previewRequestID == requestID, basePreviewKey == key else { return }
            cachedBasePreviewKey = key
            cachedBasePreview = NSImage(cgImage: image.cgImage, size: image.pixelSize)
        } catch {
            guard !Task.isCancelled, previewRequestID == requestID, basePreviewKey == key else { return }
            cachedBasePreviewKey = key
            cachedBasePreview = nil
        }
    }

    public func renderFlattenedAsync() async throws -> CapturedImage {
        try await AnnotationRenderWorker.shared.render(makeRenderSnapshot())
    }

    // MARK: Saving

    /// Editable projects intentionally retain the original source pixels so
    /// redactions can be changed later. Require one explicit acknowledgement
    /// per open document before writing that sensitive package.
    public func confirmProjectPrivacyBeforeSaving() -> Bool {
        if hasAcknowledgedProjectPrivacyWarning { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Editable projects contain the original pixels"
        alert.informativeText = "A .notchshot project is not share-safe: blackout and pixelation remain editable, and the original image is stored inside. Export a flattened image when you need permanently applied redactions."
        for title in EditableProjectPrivacyAlertPolicy.buttonTitles {
            alert.addButton(withTitle: title)
        }
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard EditableProjectPrivacyAlertPolicy.allowsSave(for: alert.runModal()) else { return false }
        hasAcknowledgedProjectPrivacyWarning = true
        return true
    }

    /// Writes a flattened image. This is the only path that should ever be
    /// shared, copied, or uploaded.
    @discardableResult
    public func exportImage(to url: URL, format: ImageFormat) throws -> URL {
        try exportImageResult(to: url, format: format).url
    }

    public struct ImageExportResult: Sendable {
        public let url: URL
        public let pixelSize: CGSize
        public let sourceScale: CGFloat
    }

    /// Metadata comes from the exact flattened image written to disk, avoiding
    /// a second render and preserving crop, rotation and background dimensions.
    public func exportImageResult(to url: URL, format: ImageFormat) throws -> ImageExportResult {
        try makeRenderSnapshot().export(to: url, format: format, quality: Preferences.shared.jpegQuality)
    }

    public func exportImageResultAsync(to url: URL, format: ImageFormat) async throws -> ImageExportResult {
        let snapshot = makeRenderSnapshot()
        let quality = Preferences.shared.jpegQuality
        return try await AnnotationRenderWorker.shared.export(snapshot, to: url, format: format, quality: quality)
    }

    @discardableResult
    public func saveProject(to url: URL? = nil) throws -> URL {
        let target = url ?? projectURL ?? NotchShotPackage.defaultURL(
            named: asset.map { $0.url.deletingPathExtension().lastPathComponent }
                ?? Preferences.shared.expandFilename()
        )
        try NotchShotPackage.write(document: document, source: source, to: target)
        projectURL = target
        savedDocument = document
        return target
    }

    public func copyFlattenedToPasteboard() throws {
        ImageExport.copyToPasteboard(try renderFlattened())
    }

    public static func open(projectAt url: URL) throws -> AnnotationDocumentController {
        let contents = try NotchShotPackage.read(from: url)
        let controller = AnnotationDocumentController(
            source: contents.source,
            document: contents.document
        )
        controller.projectURL = url
        return controller
    }
}
