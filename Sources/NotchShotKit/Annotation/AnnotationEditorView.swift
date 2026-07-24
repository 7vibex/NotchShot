import AppKit
import SwiftUI

/// The annotation and background editor.
public struct AnnotationEditorView: View {
    @Bindable var controller: AnnotationDocumentController
    var onClose: () -> Void
    var onExported: (CaptureAsset) -> Void

    @State private var inProgress: AnnotationElement?
    @State private var isCropping = false
    @State private var cropDraft: CGRect?
    @State private var showsBackgroundPanel = false
    @State private var editingTextID: UUID?
    @State private var errorMessage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        controller: AnnotationDocumentController,
        onClose: @escaping () -> Void,
        onExported: @escaping (CaptureAsset) -> Void
    ) {
        self.controller = controller
        self.onClose = onClose
        self.onExported = onExported
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
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
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(AnnotationKind.allCases) { kind in
                Button {
                    controller.selectedTool = kind
                    isCropping = false
                } label: {
                    Image(systemName: kind.symbolName)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.accessoryBar)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(controller.selectedTool == kind && !isCropping
                              ? Color.accentColor.opacity(0.22) : .clear)
                )
                .help(kind.title)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(controller.selectedTool == kind ? [.isSelected] : [])
            }

            Divider().frame(height: 20)

            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: controller.strokeColorHex) ?? .systemRed) },
                set: { newValue in
                    let hex = NSColor(newValue).hexString
                    controller.strokeColorHex = hex
                    Preferences.shared.annotationColorHex = hex
                    updateSelectedStyle { $0.colorHex = hex }
                }
            ))
            .labelsHidden()
            .frame(width: 40)
            .help("Stroke colour")

            Slider(value: Binding(
                get: { controller.lineWidth },
                set: { newValue in
                    controller.lineWidth = newValue
                    Preferences.shared.annotationLineWidth = newValue
                    updateSelectedStyle { $0.lineWidth = newValue }
                }
            ), in: 1 ... 24)
            .frame(width: 90)
            .help("Stroke width")
            .accessibilityLabel("Stroke width")

            Divider().frame(height: 20)

            Button {
                isCropping.toggle()
                cropDraft = nil
            } label: {
                Image(systemName: "crop")
            }
            .buttonStyle(.accessoryBar)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCropping ? Color.accentColor.opacity(0.22) : .clear)
            )
            .help("Crop")

            Button { controller.rotateLeft() } label: { Image(systemName: "rotate.left") }
                .buttonStyle(.accessoryBar)
                .help("Rotate left")
            Button { controller.rotateRight() } label: { Image(systemName: "rotate.right") }
                .buttonStyle(.accessoryBar)
                .help("Rotate right")

            Button {
                withAnimation(reduceMotion ? nil : .snappy) { showsBackgroundPanel.toggle() }
            } label: {
                Image(systemName: "square.on.square.dashed")
            }
            .buttonStyle(.accessoryBar)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(showsBackgroundPanel ? Color.accentColor.opacity(0.22) : .clear)
            )
            .help("Background")

            Spacer()

            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.accessoryBar)
                .disabled(!controller.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo")
            Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.accessoryBar)
                .disabled(!controller.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let visible = visibleSourceRect
            let content = fittedRect(for: visible.size, in: geometry.size)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let preview = basePreview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: content.width, height: content.height)
                        .position(x: content.midX, y: content.midY)
                        .shadow(radius: 6)
                }

                Canvas { context, _ in
                    var elements = controller.document.sortedElements
                    if let inProgress { elements.append(inProgress) }
                    context.withCGContext { cgContext in
                        AnnotationRenderer.drawInteractive(
                            elements: elements,
                            in: cgContext,
                            contentRect: content,
                            visibleSourceRect: visible,
                            isPreview: true
                        )
                    }
                }
                .allowsHitTesting(false)

                if let selected = controller.selectedElement {
                    selectionOverlay(for: selected, content: content, visible: visible)
                }

                if isCropping, let cropDraft {
                    let rect = viewRect(from: cropDraft, content: content, visible: visible)
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(content: content, visible: visible))
            .onTapGesture { location in
                guard !isCropping else { return }
                let point = sourcePoint(from: location, content: content, visible: visible)
                controller.selectElement(at: point)
            }
            .onKeyPress(.delete) {
                controller.deleteSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                if isCropping { isCropping = false; cropDraft = nil }
                controller.selectedElementID = nil
                return .handled
            }
        }
    }

    private func selectionOverlay(
        for element: AnnotationElement,
        content: CGRect,
        visible: CGRect
    ) -> some View {
        let rect = viewRect(from: element.hitRect, content: content, visible: visible)
        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func dragGesture(content: CGRect, visible: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = sourcePoint(from: value.startLocation, content: content, visible: visible)
                let current = sourcePoint(from: value.location, content: content, visible: visible)

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
            Button("Save Project") { performSaveProject() }
            Button("Export…") { performExport() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
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

    private func performSaveProject() {
        do {
            _ = try controller.saveProject()
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
            _ = try controller.exportImage(to: url, format: format)
            let flattened = try controller.renderFlattened()
            onExported(CaptureAsset(
                url: url,
                kind: .screenshot,
                pixelSize: CGSize(width: flattened.width, height: flattened.height),
                scale: controller.document.sourceScale,
                projectURL: controller.projectURL
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

    // MARK: Geometry

    /// The source region currently shown, i.e. the crop or the whole image.
    private var visibleSourceRect: CGRect {
        controller.document.effectiveCrop
    }

    /// Base image behind the live annotation layer: redaction placeholders,
    /// crop and rotation applied, but no elements drawn.
    private var basePreview: NSImage? {
        var stripped = controller.document
        stripped.elements = stripped.elements.filter { $0.kind.isRedaction }
        guard let image = try? AnnotationRenderer.render(
            document: stripped,
            source: controller.source,
            options: AnnotationRenderer.Options(isPreview: true)
        ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func fittedRect(for size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let inset = container.insetBy(24)
        let scale = min(inset.width / size.width, inset.height / size.height, 1)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func sourcePoint(from viewPoint: CGPoint, content: CGRect, visible: CGRect) -> CGPoint {
        guard content.width > 0, content.height > 0 else { return .zero }
        let normalizedX = (viewPoint.x - content.minX) / content.width
        let normalizedY = (viewPoint.y - content.minY) / content.height
        return CGPoint(
            x: visible.minX + normalizedX * visible.width,
            y: visible.minY + normalizedY * visible.height
        )
    }

    private func viewRect(from sourceRect: CGRect, content: CGRect, visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return .zero }
        let scaleX = content.width / visible.width
        let scaleY = content.height / visible.height
        return CGRect(
            x: content.minX + (sourceRect.minX - visible.minX) * scaleX,
            y: content.minY + (sourceRect.minY - visible.minY) * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )
    }
}

private extension CGSize {
    func insetBy(_ amount: CGFloat) -> CGSize {
        CGSize(width: max(1, width - amount * 2), height: max(1, height - amount * 2))
    }
}

// MARK: - Background panel

struct BackgroundPanel: View {
    @Bindable var controller: AnnotationDocumentController

    var body: some View {
        Form {
            Section("Preset") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                    ForEach(BackgroundPreset.all) { preset in
                        Button {
                            controller.applyBackgroundPreset(preset)
                        } label: {
                            VStack(spacing: 4) {
                                swatch(for: preset.configuration.fill)
                                Text(preset.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.title) background")
                    }
                }
            }

            Section("Layout") {
                LabeledContent("Padding") {
                    Slider(
                        value: binding(\.padding, default: 0),
                        in: 0 ... 200
                    )
                }
                LabeledContent("Corner radius") {
                    Slider(value: binding(\.cornerRadius, default: 0), in: 0 ... 48)
                }
                LabeledContent("Shadow") {
                    Slider(value: binding(\.shadowRadius, default: 0), in: 0 ... 60)
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
        .formStyle(.grouped)
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
        var background = controller.document.background
        background.fill = .image(path: url.path)
        if background.padding == 0 { background.padding = 64 }
        controller.applyBackground(background)
    }
}
