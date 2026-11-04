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
    /// Seams carried over from a scrolling capture, drawn as warnings on the
    /// editor canvas only.
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
    private let saveOrder = ProjectSaveOrder()
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
    /// Why the base preview could not be rendered, when it could not.
    private(set) var basePreviewError: String?
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

    public var canUndo: Bool { !undoStack.isEmpty || hasPendingGesture }
    public var canRedo: Bool { !redoStack.isEmpty && !hasPendingGesture }
    var undoStepCount: Int { undoStack.count }

    private var hasPendingGesture: Bool {
        isCoalescing && document != coalescingStartDocument
    }

    /// Call before any mutation that should be undoable.
    public func checkpoint() {
        guard !isCoalescing else { return }
        undoStack.append(document)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// The undo step is only recorded when the gesture ends, and only if it
    /// changed something: a no-op must not cost the redo history or the oldest
    /// undo entry.
    public func beginCoalescing() {
        guard !isCoalescing else { return }
        coalescingStartDocument = document
        isCoalescing = true
    }

    public func endCoalescing() {
        guard isCoalescing else { return }
        isCoalescing = false
        if let start = coalescingStartDocument, document != start {
            undoStack.append(start)
            if undoStack.count > undoLimit { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        coalescingStartDocument = nil
    }

    public func undo() {
        // Undo during a gesture, like ⌘Z while typing, first closes the gesture
        // so its changes are the step that gets undone.
        let wasCoalescing = isCoalescing
        endCoalescing()
        defer { if wasCoalescing { beginCoalescing() } }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selectedElementID = nil
    }

    public func redo() {
        let wasCoalescing = isCoalescing
        endCoalescing()
        defer { if wasCoalescing { beginCoalescing() } }
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

    /// Takes back a text element the user clicked into place and never typed
    /// in. It draws nothing but still has a hit box, so it would catch later
    /// clicks. The step that added it goes too, leaving nothing to undo.
    func removeIfEmptyText(id: UUID) {
        guard let element = document.elements.first(where: { $0.id == id }),
              element.kind == .text,
              element.text.isEmpty else { return }
        document.remove(id: id)
        // Everything but the time matches the step before the click: go back
        // to it, so the document doesn't read as edited either.
        if var previous = undoStack.last {
            let restored = previous
            previous.modifiedAt = document.modifiedAt
            if previous == document {
                document = restored
                undoStack.removeLast()
            }
        }
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
            options: AnnotationRenderer.Options(isPreview: true)
        )
    }

    /// Export render: redactions are permanently burned into the pixels.
    public func renderFlattened() throws -> CGImage {
        try AnnotationRenderer.render(
            document: document,
            source: source,
            options: AnnotationRenderer.Options(isPreview: false)
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

    /// What the canvas shows: the last finished render, stretched to the current
    /// geometry until the next one lands. During a slider drag every tick
    /// discards the render in flight, so waiting for an exact match would blank
    /// the screenshot for the whole drag.
    var displayedBasePreview: NSImage? { cachedBasePreview }

    func makeRenderSnapshot() -> AnnotationRenderSnapshot {
        AnnotationRenderSnapshot(source: source, document: document)
    }

    func prepareBasePreview() async {
        let key = basePreviewKey
        if cachedBasePreviewKey == key { return }
        let requestID = UUID()
        previewRequestID = requestID
        var stripped = document
        stripped.elements = []
        let snapshot = AnnotationRenderSnapshot(source: source, document: stripped)
        do {
            let image = try await previewRenderer(snapshot)
            guard !Task.isCancelled, previewRequestID == requestID, basePreviewKey == key else { return }
            cachedBasePreviewKey = key
            cachedBasePreview = NSImage(cgImage: image.cgImage, size: image.pixelSize)
            basePreviewError = nil
        } catch {
            guard !Task.isCancelled, previewRequestID == requestID, basePreviewKey == key else { return }
            cachedBasePreviewKey = key
            cachedBasePreview = nil
            basePreviewError = error.localizedDescription
        }
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

    @discardableResult
    public func saveProject(to url: URL? = nil) throws -> URL {
        let target = url ?? defaultProjectURL
        try saveOrder.write(ifCurrent: saveOrder.claim()) {
            _ = try NotchShotPackage.write(document: document, source: source, to: target)
        }
        projectURL = target
        savedDocument = document
        return target
    }

    /// `saveProject` for the editor window, where the PNG encodes must not stop
    /// the main actor. What counts as saved is the document as it was written:
    /// edits made during the write stay unsaved.
    func saveProjectOffMain() async throws -> URL {
        let target = defaultProjectURL
        let written = document
        let snapshot = AnnotationRenderSnapshot(source: source, document: written)
        let order = saveOrder
        let claim = order.claim()
        // Unstructured, so closing the window doesn't drop what it records, and
        // so quit can wait for the write.
        let save = Task { @MainActor [weak self] in
            try await AnnotationRenderWorker.shared.saveProject(snapshot, to: target, order: order, claim: claim)
            // A save at the prompt since then wrote a newer document.
            guard let self, order.isCurrent(claim) else { return }
            self.projectURL = target
            self.savedDocument = written
        }
        FileWorkTracker.shared.run { _ = await save.result }
        try await save.value
        return target
    }

    private var defaultProjectURL: URL {
        projectURL ?? NotchShotPackage.defaultURL(
            named: asset.map { $0.url.deletingPathExtension().lastPathComponent }
                ?? Preferences.shared.expandFilename()
        )
    }

    public static func open(projectAt url: URL) throws -> AnnotationDocumentController {
        open(contents: try NotchShotPackage.read(from: url), projectAt: url)
    }

    /// `open(projectAt:)` with the file read and decoded off the main actor.
    public static func openOffMain(projectAt url: URL) async throws -> AnnotationDocumentController {
        let contents = try await Task.detached(priority: .userInitiated) {
            try NotchShotPackage.read(from: url)
        }.value
        return open(contents: contents, projectAt: url)
    }

    static func open(
        contents: NotchShotPackage.Contents,
        projectAt url: URL
    ) -> AnnotationDocumentController {
        let controller = AnnotationDocumentController(
            source: contents.source,
            document: contents.document
        )
        controller.projectURL = url
        return controller
    }
}
