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
    @State private var showsBackgroundPanel = false
    @State private var editingTextID: UUID?
    @State private var errorMessage: String?
    @State private var colorEditingTask: Task<Void, Never>?
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
                        .frame(width: 260)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Couldn't finish", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
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
                withAnimation(reduceMotion ? nil : .snappy) { showsBackgroundPanel.toggle() }
            } label: {
                Image(systemName: "square.on.square.dashed")
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
                Color(nsColor: .underPageBackgroundColor)

                if let preview = controller.basePreviewImage() {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.outputViewRect.width, height: layout.outputViewRect.height)
                        .position(x: layout.outputViewRect.midX, y: layout.outputViewRect.midY)
                        .shadow(radius: 6)
                }

                Canvas { context, _ in
                    var elements: [AnnotationElement] = controller.document.sortedElements
                    if let inProgress { elements.append(inProgress) }
                    context.withCGContext { cgContext in
                        cgContext.saveGState()
                        defer { cgContext.restoreGState() }
                        cgContext.addPath(CGPath(
                            roundedRect: layout.contentViewRect,
                            cornerWidth: layout.contentCornerRadius,
                            cornerHeight: layout.contentCornerRadius,
                            transform: nil
                        ))
                        cgContext.clip()
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

            Button("Copy") { performCopy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Share…") { performShare() }
            Button("Save Project") { performSaveProject() }
            Button("Export…") { performExport() }
                .keyboardShortcut("s", modifiers: .command)
                .notchShotPrimaryActionStyle()
            Button("Close") { onClose() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func performCopy() {
        do {
            try controller.copyFlattenedToPasteboard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performShare() {
        do {
            let flattened = try controller.renderFlattened()
            let image = NSImage(
                cgImage: flattened,
                size: NSSize(width: flattened.width, height: flattened.height)
            )
            try MacSharePresenter.shared.present(items: [image])
        } catch {
            errorMessage = error.localizedDescription
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
        let format = Preferences.shared.imageFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: format)]
        panel.nameFieldStringValue = "\(Preferences.shared.expandFilename()).\(format.fileExtension)"
        panel.directoryURL = Preferences.shared.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try controller.exportImageResult(to: url, format: format)
            onExported(CaptureAsset(
                url: result.url,
                kind: .screenshot,
                pixelSize: result.pixelSize,
                scale: controller.document.sourceScale
            ))
        } catch {
            errorMessage = error.localizedDescription
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
struct AnnotationEditorGeometry: Sendable {
    let visibleSourceRect: CGRect
    let rotation: RotationAngle
    let rotatedContentSize: CGSize
    let outputPixelSize: CGSize
    let outputViewRect: CGRect
    let contentViewRect: CGRect
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
        contentCornerRadius = min(
            document.background.cornerRadius * document.sourceScale * min(scaleX, scaleY),
            min(fittedContentViewRect.width, fittedContentViewRect.height) / 2
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

struct BackgroundPanel: View {
    @Bindable var controller: AnnotationDocumentController
    @State private var backgroundError: String?

    var body: some View {
        Form {
            Section("Preset") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                    ForEach(BackgroundPreset.all) { preset in
                        let isSelected = controller.document.background == preset.configuration
                        Button {
                            controller.applyBackgroundPreset(preset)
                        } label: {
                            VStack(spacing: 4) {
                                swatch(for: preset.configuration.fill)
                                Text(preset.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(3)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .padding(5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.title) background")
                        .accessibilityValue(isSelected ? "Selected" : "")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
            }

            Section("Layout") {
                LabeledContent("Padding") {
                    Slider(
                        value: binding(\.padding, default: 0),
                        in: 0 ... 200,
                        onEditingChanged: updateContinuousEditing
                    )
                }
                LabeledContent("Corner radius") {
                    Slider(
                        value: binding(\.cornerRadius, default: 0),
                        in: 0 ... 48,
                        onEditingChanged: updateContinuousEditing
                    )
                }
                LabeledContent("Shadow") {
                    Slider(
                        value: binding(\.shadowRadius, default: 0),
                        in: 0 ... 60,
                        onEditingChanged: updateContinuousEditing
                    )
                }
                Toggle("Balance automatically", isOn: Binding(
                    get: { controller.document.background.balancesAutomatically },
                    set: { newValue in
                        var background = controller.document.background
                        background.balancesAutomatically = newValue
                        controller.applyBackground(background)
                    }
                ))
                Toggle("Inner border", isOn: Binding(
                    get: { controller.document.background.drawsInnerBorder },
                    set: { newValue in
                        var background = controller.document.background
                        background.drawsInnerBorder = newValue
                        controller.applyBackground(background)
                    }
                ))
            }

            Section("Aspect ratio") {
                Picker("Ratio", selection: Binding(
                    get: { controller.document.background.aspectRatio ?? 0 },
                    set: { newValue in
                        var background = controller.document.background
                        background.aspectRatio = newValue == 0 ? nil : newValue
                        controller.applyBackground(background)
                    }
                )) {
                    Text("Natural").tag(0.0)
                    Text("16 : 9").tag(16.0 / 9.0)
                    Text("4 : 3").tag(4.0 / 3.0)
                    Text("1 : 1").tag(1.0)
                    Text("9 : 16").tag(9.0 / 16.0)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Section("Custom") {
                Button("Choose Image…") { chooseBackgroundImage() }
                Button("Clear Background") {
                    controller.applyBackground(.none)
                }
            }
        }
        .notchShotFormStyle()
        .alert("Background image unavailable", isPresented: Binding(
            get: { backgroundError != nil },
            set: { if !$0 { backgroundError = nil } }
        )) {
            Button("OK") { backgroundError = nil }
        } message: {
            Text(backgroundError ?? "")
        }
    }

    private func binding(
        _ keyPath: WritableKeyPath<BackgroundConfiguration, Double>,
        default fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { controller.document.background[keyPath: keyPath] },
            set: { newValue in
                var background = controller.document.background
                background[keyPath: keyPath] = newValue
                controller.applyBackground(background)
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

    @ViewBuilder
    private func swatch(for fill: BackgroundFill) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        switch fill {
        case .none:
            shape.strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(height: 40)
        case .solid(let hex):
            shape.fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(height: 40)
        case .gradient(let start, let end, _):
            shape.fill(LinearGradient(
                colors: [
                    Color(nsColor: NSColor(hex: start) ?? .blue),
                    Color(nsColor: NSColor(hex: end) ?? .purple),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(height: 40)
        case .image:
            shape.fill(.tertiary).frame(height: 40)
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
        var background = controller.document.background
        background.fill = .image(path: url.path)
        if background.padding == 0 { background.padding = 64 }
        controller.applyBackground(background)
    }
}
