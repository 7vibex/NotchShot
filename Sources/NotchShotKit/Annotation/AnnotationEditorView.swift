import AppKit
import SwiftUI

/// The annotation and background editor.
public struct AnnotationEditorView: View {
    @Bindable var controller: AnnotationDocumentController
    var onClose: () -> Void
    var onExported: (CaptureAsset) -> Void
    var onProjectSaved: (URL) -> Void

    @State private var inProgress: AnnotationElement?
    @State private var isCropping = false
    @State private var cropDraft: CGRect?
    /// Framing is half of what the editor is for, so it starts open; the
    /// choice sticks once someone closes it.
    @AppStorage("notchshot.editor.showsBackgroundPanel") private var showsBackgroundPanel = true
    @State private var editingTextID: UUID?
    @State private var errorMessage: String?
    @State private var colorEditingTask: Task<Void, Never>?
    @State private var imageActionTask: Task<Void, Never>?
    @State private var imageActionID: UUID?
    @FocusState private var isEditingSelectedText: Bool
    @FocusState private var isCanvasFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        controller: AnnotationDocumentController,
        onClose: @escaping () -> Void,
        onExported: @escaping (CaptureAsset) -> Void,
        onProjectSaved: @escaping (URL) -> Void = { _ in }
    ) {
        self.controller = controller
        self.onClose = onClose
        self.onExported = onExported
        self.onProjectSaved = onProjectSaved
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                canvas
                if showsBackgroundPanel {
                    Divider()
                    BackgroundPanel(controller: controller)
                        .frame(width: 280)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(white: 0.09))
        // NotchShot's surfaces are dark, and a framed capture reads best on
        // a dark table, the way it will on most of the places it is posted.
        .preferredColorScheme(.dark)
        .alert("Couldn't finish", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: controller.basePreviewKey) {
            await controller.prepareBasePreview()
        }
        .onDisappear {
            imageActionID = nil
            imageActionTask?.cancel()
            imageActionTask = nil
            finishColorEditing()
            if isEditingSelectedText { controller.endCoalescing() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarControls(compactToolPicker: false)
                .fixedSize(horizontal: true, vertical: false)
            toolbarControls(compactToolPicker: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NotchShotDesignSystem.toolbarHorizontalPadding)
        .padding(.vertical, 6)
        .notchShotToolbarSurface()
    }

    @ViewBuilder
    private func toolbarControls(compactToolPicker: Bool) -> some View {
        HStack(spacing: 6) {
            if compactToolPicker {
                compactAnnotationToolMenu
            } else {
                annotationToolButtons
            }

            Divider().frame(height: 20)

            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: controller.strokeColorHex) ?? .systemRed) },
                set: { newValue in updateStrokeColor(newValue) }
            ))
            .labelsHidden()
            .frame(width: 40)
            .help("Stroke colour")
            .accessibilityLabel("Stroke colour")

            Slider(value: Binding(
                get: { controller.lineWidth },
                set: { newValue in
                    controller.lineWidth = newValue
                    Preferences.shared.annotationLineWidth = newValue
                    updateSelectedStyle { $0.lineWidth = newValue }
                }
            ), in: 1 ... 24, onEditingChanged: updateContinuousEditing)
            .frame(width: 90)
            .help("Stroke width")
            .accessibilityLabel("Stroke width")

            Divider().frame(height: 20)

            Button {
                isCropping.toggle()
                cropDraft = nil
            } label: {
                Image(systemName: "crop")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .background { toolbarSelectionChrome(isSelected: isCropping) }
            .help("Crop")
            .accessibilityLabel("Crop image")
            .accessibilityAddTraits(isCropping ? [.isSelected] : [])

            Button { controller.rotateLeft() } label: {
                Image(systemName: "rotate.left")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .help("Rotate left")
            .accessibilityLabel("Rotate left")

            Button { controller.rotateRight() } label: {
                Image(systemName: "rotate.right")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .help("Rotate right")
            .accessibilityLabel("Rotate right")

            Button {
                withAnimation(NotchMotion.selection(reduceMotion: reduceMotion)) { showsBackgroundPanel.toggle() }
            } label: {
                Image(systemName: "photo.artframe")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .background { toolbarSelectionChrome(isSelected: showsBackgroundPanel) }
            .help("Background")
            .accessibilityLabel("Background options")
            .accessibilityValue(showsBackgroundPanel ? "Shown" : "Hidden")
            .accessibilityAddTraits(showsBackgroundPanel ? [.isSelected] : [])

            Divider().frame(height: 20)

            Button { controller.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .disabled(!controller.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")
            .accessibilityLabel("Undo")

            Button { controller.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(
                        width: NotchShotDesignSystem.minimumControlTarget,
                        height: NotchShotDesignSystem.minimumControlTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .disabled(!controller.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")
            .accessibilityLabel("Redo")
        }
        .animation(
            NotchShotMotion.selection(reduceMotion: reduceMotion),
            value: controller.selectedTool
        )
    }

    private var annotationToolButtons: some View {
        ForEach(AnnotationKind.allCases) { kind in
            annotationToolButton(kind)
        }
    }

    private var compactAnnotationToolMenu: some View {
        Menu {
            ForEach(AnnotationKind.allCases) { kind in
                Button {
                    selectAnnotationTool(kind)
                } label: {
                    Label(kind.title, systemImage: kind.symbolName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.selectedTool.symbolName)
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .frame(
                minWidth: NotchShotDesignSystem.minimumControlTarget,
                minHeight: NotchShotDesignSystem.minimumControlTarget
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .help("Annotation tool: \(controller.selectedTool.title)")
        .accessibilityLabel("Annotation tool")
        .accessibilityValue(controller.selectedTool.title)
    }

    private func annotationToolButton(_ kind: AnnotationKind) -> some View {
        Button {
            selectAnnotationTool(kind)
        } label: {
            Image(systemName: kind.symbolName)
                .frame(
                    width: NotchShotDesignSystem.minimumControlTarget,
                    height: NotchShotDesignSystem.minimumControlTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.accessoryBar)
        .background {
            toolbarSelectionChrome(
                isSelected: controller.selectedTool == kind && !isCropping
            )
        }
        .help(kind.title)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(
            controller.selectedTool == kind && !isCropping ? [.isSelected] : []
        )
    }

    private func selectAnnotationTool(_ kind: AnnotationKind) {
        controller.selectedTool = kind
        isCropping = false
    }

    private func toolbarSelectionChrome(isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if isSelected {
            return AnyView(
                shape
                    .fill(Color.accentColor.opacity(
                        colorSchemeContrast == .increased ? 0.30 : 0.18
                    ))
                    .overlay {
                        shape.stroke(
                            Color.accentColor.opacity(
                                colorSchemeContrast == .increased ? 1 : 0.72
                            ),
                            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                        )
                    }
            )
        }
        return AnyView(shape.fill(.clear))
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let layout = AnnotationEditorGeometry(
                document: controller.document,
                containerSize: geometry.size
            )

            ZStack {
                EditorCanvasBackdrop()

                if let preview = controller.basePreviewImage() {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.outputViewRect.width, height: layout.outputViewRect.height)
                        .position(x: layout.outputViewRect.midX, y: layout.outputViewRect.midY)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                }

                Canvas { context, _ in
                    var elements: [AnnotationElement] = controller.document.sortedElements
                    if let inProgress { elements.append(inProgress) }
                    context.withCGContext { cgContext in
                        cgContext.saveGState()
                        defer { cgContext.restoreGState() }
                        // The rounded corners belong to the whole frame; under
                        // a title bar the screenshot's top corners are square.
                        cgContext.addPath(CGPath(
                            roundedRect: layout.frameViewRect,
                            cornerWidth: layout.contentCornerRadius,
                            cornerHeight: layout.contentCornerRadius,
                            transform: nil
                        ))
                        cgContext.clip()
                        cgContext.clip(to: layout.contentViewRect)
                        cgContext.concatenate(layout.sourceToViewTransform)
                        AnnotationRenderer.drawInteractive(
                            elements: elements,
                            in: cgContext,
                            contentRect: layout.visibleSourceRect,
                            visibleSourceRect: layout.visibleSourceRect,
                            isPreview: true
                        )
                    }
                }
                .allowsHitTesting(false)

                if let selected = controller.selectedElement {
                    selectionOverlay(for: selected, layout: layout)
                }

                if isCropping, let cropDraft {
                    let rect = layout.viewRect(from: cropDraft)
                    adaptiveSelectionOutline(cornerRadius: 0, dashed: false)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layout: layout))
            .onTapGesture { location in
                isCanvasFocused = true
                guard !isCropping else { return }
                guard let point = layout.sourcePoint(from: location) else { return }
                controller.selectElement(at: point)
            }
            .focusable()
            .focused($isCanvasFocused)
            .onKeyPress(.delete) {
                controller.deleteSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                if isCropping { isCropping = false; cropDraft = nil }
                controller.selectedElementID = nil
                return .handled
            }
            .accessibilityLabel("Annotation canvas")
            .accessibilityValue(canvasAccessibilityValue)
            .accessibilityHint(
                isCropping
                    ? "Drag over the image to choose a crop area. Press Escape to cancel."
                    : "Use the Actions menu to add, select, move, resize, crop, or delete annotations."
            )
            .accessibilityActions {
                Button("Add \(controller.selectedTool.title) at center") { addSelectedToolAtCenter() }
                Button("Select next annotation") { selectAnnotation(by: 1) }
                Button("Select previous annotation") { selectAnnotation(by: -1) }
                Button("Move selected annotation left") { moveSelectedAnnotation(dx: -8, dy: 0) }
                Button("Move selected annotation right") { moveSelectedAnnotation(dx: 8, dy: 0) }
                Button("Move selected annotation up") { moveSelectedAnnotation(dx: 0, dy: -8) }
                Button("Move selected annotation down") { moveSelectedAnnotation(dx: 0, dy: 8) }
                Button("Grow selected annotation") { resizeSelectedAnnotation(by: 1.1) }
                Button("Shrink selected annotation") { resizeSelectedAnnotation(by: 0.9) }
                Button("Crop to centered 80 percent") { cropToCenteredEightyPercent() }
                Button("Reset crop") { controller.setCrop(nil) }
                Button("Delete selected annotation") { controller.deleteSelection() }
            }
        }
    }

    private func selectionOverlay(
        for element: AnnotationElement,
        layout: AnnotationEditorGeometry
    ) -> some View {
        let rect = layout.viewRect(from: element.hitRect)
        return adaptiveSelectionOutline(cornerRadius: 4, dashed: true)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func adaptiveSelectionOutline(cornerRadius: CGFloat, dashed: Bool) -> some View {
        let dash: [CGFloat] = dashed ? [4, 3] : []
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    .black.opacity(0.86),
                    style: StrokeStyle(lineWidth: 5, dash: dash)
                )
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    .white.opacity(0.94),
                    style: StrokeStyle(lineWidth: 3, dash: dash)
                )
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: dash)
                )
        }
    }

    private func dragGesture(layout: AnnotationEditorGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                isCanvasFocused = true
                guard let start = layout.sourcePoint(from: value.startLocation),
                      let current = layout.sourcePoint(from: value.location, clamped: true)
                else { return }

                if isCropping {
                    cropDraft = ScreenGeometry.rect(from: start, to: current)
                    return
                }

                // Dragging inside a selected element moves it instead of
                // starting a new one — the expected direct-manipulation feel.
                if let selected = controller.selectedElement, selected.contains(start) {
                    if inProgress == nil { controller.beginCoalescing() }
                    let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
                    inProgress = selected.moved(by: delta)
                    return
                }

                if controller.selectedTool.isFreehand {
                    if var element = inProgress {
                        element.points.append(current)
                        inProgress = element
                    } else {
                        inProgress = controller.makeElement(
                            kind: controller.selectedTool,
                            points: [start, current]
                        )
                    }
                } else if controller.selectedTool.isPointAnchored {
                    inProgress = controller.makeElement(kind: controller.selectedTool, points: [current])
                } else {
                    inProgress = controller.makeElement(
                        kind: controller.selectedTool,
                        points: [start, current]
                    )
                }
            }
            .onEnded { value in
                defer { inProgress = nil }

                if isCropping {
                    if let cropDraft, cropDraft.width > 8, cropDraft.height > 8 {
                        controller.setCrop(cropDraft)
                    }
                    self.cropDraft = nil
                    isCropping = false
                    return
                }

                guard let element = inProgress else { return }

                if let selected = controller.selectedElement, selected.id == element.id {
                    controller.update(element)
                    controller.endCoalescing()
                    return
                }

                // A tap with no drag only makes sense for anchored tools.
                let dragged = hypot(
                    value.translation.width,
                    value.translation.height
                ) > 3
                guard dragged || controller.selectedTool.isPointAnchored else { return }

                controller.add(element)
                if element.kind == .text {
                    editingTextID = element.id
                }
            }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let selected = controller.selectedElement, selected.kind == .text {
                TextField("Text", text: Binding(
                    get: { selected.text },
                    set: { newValue in
                        var copy = selected
                        copy.text = newValue
                        controller.update(copy)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .accessibilityLabel("Annotation text")
                .focused($isEditingSelectedText)
                .onChange(of: isEditingSelectedText) { _, editing in
                    updateContinuousEditing(editing)
                }
            }

            if controller.document.hasRedactions {
                Label(
                    "Redacted areas are flattened on export",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if controller.seams.contains(where: \.isSuspect) {
                Label("Some stitch seams look uncertain", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if imageActionTask != nil { ProgressView().controlSize(.small) }
            Group {
                Button("Close") { onClose() }
                Button("Save Project") { performSaveProject() }
                Button("Share…") { performShare() }
                    .disabled(imageActionTask != nil)
                Button("Copy") { performCopy() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(imageActionTask != nil)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            Button("Export…") { performExport() }
                .disabled(imageActionTask != nil)
                .keyboardShortcut("s", modifiers: .command)
                .buttonBorderShape(.capsule)
                .notchShotPrimaryActionStyle()
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func beginImageAction(_ operation: @escaping @MainActor () async throws -> Void) {
        guard imageActionTask == nil else { return }
        let actionID = UUID()
        imageActionID = actionID
        imageActionTask = Task { @MainActor in
            defer {
                if imageActionID == actionID {
                    imageActionID = nil
                    imageActionTask = nil
                }
            }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, imageActionID == actionID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performCopy() {
        guard imageActionTask == nil else { return }
        let snapshot = controller.makeRenderSnapshot()
        beginImageAction {
            let flattened = try await AnnotationRenderWorker.shared.render(snapshot)
            try Task.checkCancellation()
            ImageExport.copyToPasteboard(flattened.cgImage)
        }
    }

    private func performShare() {
        guard imageActionTask == nil else { return }
        let snapshot = controller.makeRenderSnapshot()
        beginImageAction {
            let flattened = try await AnnotationRenderWorker.shared.render(snapshot)
            try Task.checkCancellation()
            let image = NSImage(cgImage: flattened.cgImage, size: flattened.pixelSize)
            try MacSharePresenter.shared.present(items: [image])
        }
    }

    private func performSaveProject() {
        guard controller.confirmProjectPrivacyBeforeSaving() else { return }
        do {
            let url = try controller.saveProject()
            onProjectSaved(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performExport() {
        guard imageActionTask == nil else { return }
        let format = Preferences.shared.imageFormat
        let quality = Preferences.shared.jpegQuality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: format)]
        panel.nameFieldStringValue = "\(Preferences.shared.expandFilename()).\(format.fileExtension)"
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = controller.makeRenderSnapshot()
        beginImageAction {
            let result = try await AnnotationRenderWorker.shared.export(snapshot, to: url, format: format, quality: quality)
            guard !Task.isCancelled else { return }
            onExported(CaptureAsset(
                url: result.url, kind: .screenshot,
                pixelSize: result.pixelSize, scale: result.sourceScale
            ))
        }
    }

    private func updateSelectedStyle(_ mutate: (inout AnnotationStyle) -> Void) {
        guard var selected = controller.selectedElement else { return }
        controller.checkpoint()
        mutate(&selected.style)
        controller.update(selected)
    }

    private func updateContinuousEditing(_ editing: Bool) {
        if editing {
            finishColorEditing()
            controller.beginCoalescing()
        } else {
            controller.endCoalescing()
        }
    }

    /// SwiftUI's ColorPicker has no begin/end editing callback. A short idle
    /// boundary turns its rapid intermediate values into one undo gesture.
    private func updateStrokeColor(_ newValue: Color) {
        if colorEditingTask == nil { controller.beginCoalescing() }
        let hex = NSColor(newValue).hexString
        controller.strokeColorHex = hex
        Preferences.shared.annotationColorHex = hex
        updateSelectedStyle { $0.colorHex = hex }

        colorEditingTask?.cancel()
        colorEditingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            colorEditingTask = nil
            controller.endCoalescing()
        }
    }

    private func finishColorEditing() {
        guard colorEditingTask != nil else { return }
        colorEditingTask?.cancel()
        colorEditingTask = nil
        controller.endCoalescing()
    }

    private func addSelectedToolAtCenter() {
        let bounds = controller.document.cropRect
            ?? CGRect(origin: .zero, size: controller.document.sourcePixelSize)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let halfWidth = min(80, bounds.width * 0.2)
        let halfHeight = min(50, bounds.height * 0.2)
        let points: [CGPoint]
        if controller.selectedTool.isPointAnchored {
            points = [center]
        } else if controller.selectedTool.isFreehand {
            points = [
                CGPoint(x: center.x - halfWidth, y: center.y),
                CGPoint(x: center.x, y: center.y - halfHeight),
                CGPoint(x: center.x + halfWidth, y: center.y),
            ]
        } else {
            points = [
                CGPoint(x: center.x - halfWidth, y: center.y - halfHeight),
                CGPoint(x: center.x + halfWidth, y: center.y + halfHeight),
            ]
        }
        controller.add(controller.makeElement(kind: controller.selectedTool, points: points))
    }

    private func selectAnnotation(by offset: Int) {
        let elements = controller.document.sortedElements
        guard !elements.isEmpty else {
            controller.selectedElementID = nil
            return
        }
        let current = elements.firstIndex { $0.id == controller.selectedElementID }
        let base = current ?? (offset > 0 ? -1 : 0)
        let next = (base + offset + elements.count) % elements.count
        controller.selectedElementID = elements[next].id
    }

    private func moveSelectedAnnotation(dx: CGFloat, dy: CGFloat) {
        guard let selected = controller.selectedElement else { return }
        controller.checkpoint()
        controller.update(selected.moved(by: CGSize(width: dx, height: dy)))
    }

    private func resizeSelectedAnnotation(by factor: CGFloat) {
        guard var selected = controller.selectedElement,
              !selected.kind.isPointAnchored,
              !selected.points.isEmpty else { return }
        let rect = selected.hitRect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        controller.checkpoint()
        selected.points = selected.points.map { point in
            CGPoint(
                x: center.x + (point.x - center.x) * factor,
                y: center.y + (point.y - center.y) * factor
            )
        }
        controller.update(selected)
    }

    private func cropToCenteredEightyPercent() {
        let bounds = CGRect(origin: .zero, size: controller.document.sourcePixelSize)
        controller.setCrop(bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1))
    }

    private var canvasAccessibilityValue: String {
        guard let selected = controller.selectedElement else { return "No annotation selected" }
        return "\(selected.kind.title) selected"
    }

}

/// The one coordinate model used by the editor's preview, drawing, selection,
/// crop and hit-testing paths. Source coordinates remain unrotated pixels;
/// `contentViewRect` is the rotated capture inside any composed background.
/// The table the capture sits on while it is edited: near-black with a faint
/// dot grid, so a framed capture's own backdrop and shadow read as the result.
private struct EditorCanvasBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.075)))
            let spacing: CGFloat = 18
            var dots = Path()
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.white.opacity(0.07)))
        }
        .accessibilityHidden(true)
    }
}

struct AnnotationEditorGeometry: Sendable {
    let visibleSourceRect: CGRect
    let rotation: RotationAngle
    let rotatedContentSize: CGSize
    let outputPixelSize: CGSize
    let outputViewRect: CGRect
    let contentViewRect: CGRect
    /// The screenshot plus its window title bar, when it has one; this is
    /// the shape that carries the rounded corners.
    let frameViewRect: CGRect
    let contentCornerRadius: CGFloat

    init(document: AnnotationDocument, containerSize: CGSize) {
        visibleSourceRect = document.effectiveCrop
        rotation = document.rotation
        rotatedContentSize = rotation.swapsAxes
            ? CGSize(width: visibleSourceRect.height, height: visibleSourceRect.width)
            : visibleSourceRect.size

        let backgroundLayout = document.background.layout(
            for: rotatedContentSize,
            scale: document.sourceScale
        )
        outputPixelSize = backgroundLayout.canvas
        outputViewRect = Self.fittedRect(for: outputPixelSize, in: containerSize)

        let scaleX = outputPixelSize.width > 0
            ? outputViewRect.width / outputPixelSize.width
            : 0
        let scaleY = outputPixelSize.height > 0
            ? outputViewRect.height / outputPixelSize.height
            : 0
        let fittedContentViewRect = CGRect(
            x: outputViewRect.minX + backgroundLayout.content.minX * scaleX,
            y: outputViewRect.minY + backgroundLayout.content.minY * scaleY,
            width: backgroundLayout.content.width * scaleX,
            height: backgroundLayout.content.height * scaleY
        )
        contentViewRect = fittedContentViewRect
        let chromeViewHeight = document.background.chromeHeight(scale: document.sourceScale) * scaleY
        frameViewRect = CGRect(
            x: fittedContentViewRect.minX,
            y: fittedContentViewRect.minY - chromeViewHeight,
            width: fittedContentViewRect.width,
            height: fittedContentViewRect.height + chromeViewHeight
        )
        contentCornerRadius = min(
            document.background.cornerRadius * document.sourceScale * min(scaleX, scaleY),
            min(frameViewRect.width, frameViewRect.height) / 2
        )
    }

    /// Affine source-pixel to view-space mapping, including crop and quarter-turn rotation.
    var sourceToViewTransform: CGAffineTransform {
        let origin = viewPoint(from: .zero)
        let unitX = viewPoint(from: CGPoint(x: 1, y: 0))
        let unitY = viewPoint(from: CGPoint(x: 0, y: 1))
        return CGAffineTransform(
            a: unitX.x - origin.x,
            b: unitX.y - origin.y,
            c: unitY.x - origin.x,
            d: unitY.y - origin.y,
            tx: origin.x,
            ty: origin.y
        )
    }

    func viewPoint(from sourcePoint: CGPoint) -> CGPoint {
        guard rotatedContentSize.width > 0, rotatedContentSize.height > 0 else {
            return contentViewRect.origin
        }

        let local = CGPoint(
            x: sourcePoint.x - visibleSourceRect.minX,
            y: sourcePoint.y - visibleSourceRect.minY
        )
        let rotated: CGPoint
        switch rotation {
        case .none:
            rotated = local
        case .ninety:
            rotated = CGPoint(x: visibleSourceRect.height - local.y, y: local.x)
        case .oneEighty:
            rotated = CGPoint(
                x: visibleSourceRect.width - local.x,
                y: visibleSourceRect.height - local.y
            )
        case .twoSeventy:
            rotated = CGPoint(x: local.y, y: visibleSourceRect.width - local.x)
        }

        return CGPoint(
            x: contentViewRect.minX + rotated.x * contentViewRect.width / rotatedContentSize.width,
            y: contentViewRect.minY + rotated.y * contentViewRect.height / rotatedContentSize.height
        )
    }

    /// Converts a point over the rendered capture back into unrotated source pixels.
    /// Points on the composed background are ignored unless an in-flight drag requests clamping.
    func sourcePoint(from viewPoint: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard contentViewRect.width > 0, contentViewRect.height > 0,
              rotatedContentSize.width > 0, rotatedContentSize.height > 0
        else { return nil }

        if !clamped, !contentViewRect.contains(viewPoint) { return nil }
        let point = clamped
            ? CGPoint(
                x: min(max(viewPoint.x, contentViewRect.minX), contentViewRect.maxX),
                y: min(max(viewPoint.y, contentViewRect.minY), contentViewRect.maxY)
            )
            : viewPoint
        let rotated = CGPoint(
            x: (point.x - contentViewRect.minX) * rotatedContentSize.width / contentViewRect.width,
            y: (point.y - contentViewRect.minY) * rotatedContentSize.height / contentViewRect.height
        )

        let local: CGPoint
        switch rotation {
        case .none:
            local = rotated
        case .ninety:
            local = CGPoint(x: rotated.y, y: visibleSourceRect.height - rotated.x)
        case .oneEighty:
            local = CGPoint(
                x: visibleSourceRect.width - rotated.x,
                y: visibleSourceRect.height - rotated.y
            )
        case .twoSeventy:
            local = CGPoint(x: visibleSourceRect.width - rotated.y, y: rotated.x)
        }

        return CGPoint(
            x: visibleSourceRect.minX + local.x,
            y: visibleSourceRect.minY + local.y
        )
    }

    func viewRect(from sourceRect: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: sourceRect.minX, y: sourceRect.minY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
            CGPoint(x: sourceRect.minX, y: sourceRect.maxY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.maxY),
        ].map(viewPoint(from:))

        guard let first = corners.first else { return .zero }
        return corners.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private static func fittedRect(for size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let inset = CGSize(
            width: max(1, container.width - 48),
            height: max(1, container.height - 48)
        )
        let scale = min(inset.width / size.width, inset.height / size.height, 1)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

// MARK: - Background panel

/// Frames the capture: what it sits on, how it is framed, and the canvas shape.
///
/// Each backdrop tile is painted by the export renderer with a stand-in
/// window on it, so the grid previews the finished look rather than a
/// colour chip.
struct BackgroundPanel: View {
    @Bindable var controller: AnnotationDocumentController
    @State private var backgroundError: String?

    private var background: BackgroundConfiguration { controller.document.background }

    private static let ratios: [(title: String, value: Double?)] = [
        ("Natural", nil), ("16:9", 16.0 / 9.0), ("4:3", 4.0 / 3.0), ("1:1", 1), ("9:16", 9.0 / 16.0),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Backdrop", accessory: { defaultBackdropControl }) { backdropGrid }
                section("Frame") { frameControls }
                section("Canvas") { canvasControls }

                Button("Remove Background", role: .destructive) {
                    controller.applyBackground(.none)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .disabled(!background.isEnabled)
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
        .background(Color(white: 0.11))
        .alert("Background image unavailable", isPresented: Binding(
            get: { backgroundError != nil },
            set: { if !$0 { backgroundError = nil } }
        )) {
            Button("OK") { backgroundError = nil }
        } message: {
            Text(backgroundError ?? "")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
    }

    /// The preset whose backdrop is showing, if the backdrop is one.
    private var currentPreset: BackgroundPreset? {
        BackgroundPreset.all.first {
            $0.configuration.fill == background.fill
                && $0.configuration.isEnabled == background.isEnabled
        }
    }

    /// New editor documents open with this backdrop already applied.
    @ViewBuilder
    private var defaultBackdropControl: some View {
        if let preset = currentPreset {
            if Preferences.shared.defaultBackgroundPresetID == preset.id {
                Text("Default")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Button("Use by Default") {
                    Preferences.shared.defaultBackgroundPresetID = preset.id
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Open new captures in the editor with \(preset.title)")
            }
        }
    }

    // MARK: Backdrop

    private var backdropGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(BackgroundPreset.all) { preset in
                let isSelected = background.fill == preset.configuration.fill
                    && (preset.configuration.isEnabled || !background.isEnabled)
                Button {
                    applyPreset(preset)
                } label: {
                    BackdropTile(
                        title: preset.title,
                        isSelected: isSelected,
                        thumbnail: BackdropThumbnails.image(for: preset)
                    )
                }
                .buttonStyle(.plain)
                .help(preset.title)
                .accessibilityLabel("\(preset.title) background")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            Button { chooseBackgroundImage() } label: {
                BackdropTile(title: "Image…", isSelected: isImageFill, thumbnail: nil)
            }
            .buttonStyle(.plain)
            .help("Use a picture as the backdrop")
            .accessibilityLabel("Choose a background image")
            .accessibilityAddTraits(isImageFill ? [.isSelected] : [])
        }
    }

    private var isImageFill: Bool {
        if case .image = background.fill { return true }
        return false
    }

    /// Switching backdrops keeps the framing the user already tuned; only a
    /// capture with no framing yet takes the preset's.
    private func applyPreset(_ preset: BackgroundPreset) {
        guard background.isEnabled, preset.configuration.isEnabled else {
            controller.applyBackgroundPreset(preset)
            return
        }
        var updated = background
        updated.fill = preset.configuration.fill
        if preset.configuration.aspectRatio != nil {
            updated.aspectRatio = preset.configuration.aspectRatio
        }
        updated.shadowOpacity = preset.configuration.shadowOpacity
        controller.applyBackground(updated)
    }

    // MARK: Frame

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderRow("Padding", value: binding(\.padding), range: 0 ... 200)
            sliderRow("Corners", value: binding(\.cornerRadius), range: 0 ... 48)
            sliderRow("Shadow", value: binding(\.shadowRadius), range: 0 ... 60)

            VStack(alignment: .leading, spacing: 6) {
                Text("Window bar")
                    .font(.system(size: 12))
                Picker("Window bar", selection: Binding(
                    get: { background.windowChrome },
                    set: { newValue in
                        var updated = background
                        updated.windowChrome = newValue
                        // A bare title bar floating on nothing reads as a
                        // mistake; give it a little room and a soft edge.
                        if newValue != nil, updated.padding == 0 { updated.padding = 48 }
                        if newValue != nil, updated.cornerRadius == 0 { updated.cornerRadius = 10 }
                        controller.applyBackground(updated)
                    }
                )) {
                    Text("None").tag(BackgroundWindowChrome?.none)
                    ForEach(BackgroundWindowChrome.allCases) { chrome in
                        Text(chrome.title).tag(Optional(chrome))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Edge highlight", isOn: Binding(
                get: { background.drawsInnerBorder },
                set: { newValue in
                    var updated = background
                    updated.drawsInnerBorder = newValue
                    controller.applyBackground(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: updateContinuousEditing)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    // MARK: Canvas

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Self.ratios, id: \.title) { ratio in
                    let isSelected = background.aspectRatio == ratio.value
                    Button {
                        var updated = background
                        updated.aspectRatio = ratio.value
                        if ratio.value != nil, updated.padding == 0 { updated.padding = 48 }
                        controller.applyBackground(updated)
                    } label: {
                        Text(ratio.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                Capsule().fill(isSelected ? Color.accentColor : Color.white.opacity(0.07))
                            )
                            .overlay(Capsule().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.1)))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ratio.value == nil ? "Natural aspect ratio" : "\(ratio.title) aspect ratio")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }

            Toggle("Balance automatically", isOn: Binding(
                get: { background.balancesAutomatically },
                set: { newValue in
                    var updated = background
                    updated.balancesAutomatically = newValue
                    controller.applyBackground(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .disabled(background.aspectRatio == nil)
            .help("Lifts the capture slightly above centre when a ratio adds space")
        }
    }

    // MARK: Helpers

    private func binding(_ keyPath: WritableKeyPath<BackgroundConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { controller.document.background[keyPath: keyPath] },
            set: { newValue in
                var updated = controller.document.background
                updated[keyPath: keyPath] = newValue
                controller.applyBackground(updated)
            }
        )
    }

    private func updateContinuousEditing(_ editing: Bool) {
        if editing {
            controller.beginCoalescing()
        } else {
            controller.endCoalescing()
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SafeImageFile.cgImage(at: url, limits: .background) != nil else {
            backgroundError = "Choose a regular, single-frame image no larger than 16,384 pixels per side or 50 megapixels."
            return
        }
        var updated = controller.document.background
        updated.fill = .image(path: url.path)
        if updated.padding == 0 { updated.padding = 64 }
        controller.applyBackground(updated)
    }
}

private struct BackdropTile: View {
    var title: String
    var isSelected: Bool
    var thumbnail: NSImage?

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(spacing: 5) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        Color.white.opacity(0.06)
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(isHovered ? 0.25 : 0),
                        lineWidth: 2
                    )
            )
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Small renders of each preset: the backdrop with a stand-in window on it.
@MainActor
enum BackdropThumbnails {
    private static var cache: [String: NSImage] = [:]
    static let pixelSize = CGSize(width: 168, height: 126)

    static func image(for preset: BackgroundPreset) -> NSImage {
        if let cached = cache[preset.id] { return cached }
        let image = render(preset.configuration)
        cache[preset.id] = image
        return image
    }

    static func render(_ configuration: BackgroundConfiguration) -> NSImage {
        let size = pixelSize
        guard let context = AnnotationRenderer.makeContext(width: Int(size.width), height: Int(size.height)) else {
            return NSImage(size: CGSize(width: size.width / 2, height: size.height / 2))
        }
        let canvas = CGRect(origin: .zero, size: size)
        if configuration.fill.isTransparent {
            // A checkerboard says "transparent" the way every image editor does.
            let cell: CGFloat = 12
            for row in 0 ..< Int(size.height / cell) + 1 {
                for column in 0 ..< Int(size.width / cell) + 1 {
                    context.setFillColor(CGColor(gray: (row + column).isMultiple(of: 2) ? 0.22 : 0.17, alpha: 1))
                    context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        } else {
            // Painted at a third of the export scale so grain, stipple and
            // grid read at thumbnail size the way they will in the file.
            AnnotationRenderer.drawFill(configuration.fill, in: context, rect: canvas, scale: 0.6)
        }

        let window = canvas.insetBy(dx: 30, dy: 26)
        let path = CGPath(roundedRect: window, cornerWidth: 7, cornerHeight: 7, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let bar = CGRect(x: window.minX, y: window.maxY - 14, width: window.width, height: 14)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(bar)
        for (index, gray) in [0.72, 0.78, 0.84].enumerated() {
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: window.minX + 10, y: window.maxY - 30 - CGFloat(index) * 12, width: window.width * (0.7 - CGFloat(index) * 0.15), height: 6))
        }
        context.restoreGState()

        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: CGSize(width: size.width / 2, height: size.height / 2))
    }
}
