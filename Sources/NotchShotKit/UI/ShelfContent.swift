import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The post-capture shelf: CleanShot's Quick Access Overlay idea, moved into
/// the notch so results appear where the capture was launched from.
struct ShelfContent: View {
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var items: [ShelfItem] { coordinator.shelfItems }
    private var selected: ShelfItem? { coordinator.selectedShelfItem }

    var body: some View {
        VStack(spacing: 10) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    if let selected {
                        if Preferences.shared.shelfPresentationStyle == .grid {
                            grid
                        } else {
                            HStack(spacing: 12) {
                                thumbnail(for: selected)
                                details(for: selected)
                                Spacer(minLength: 0)
                            }
                        }

                        actions(for: selected)
                    }

                    if !coordinator.stack.isEmpty || coordinator.stack.isCollecting {
                        stackBar
                    }

                    if items.count > 1, Preferences.shared.shelfPresentationStyle == .detail {
                        pager
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel("Capture shelf content")
        }
        .padding(14)
        .focusable()
        .onKeyPress(.leftArrow) {
            coordinator.advanceShelfSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            coordinator.advanceShelfSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            coordinator.hideShelf()
            return .handled
        }
        .animation(reduceMotion ? nil : .snappy, value: coordinator.selectedShelfIndex)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Text("\(items.count) \(items.count == 1 ? "File" : "Files")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)

            Text(totalSizeDescription)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .monospacedDigit()

            if let warnings = selected?.stitchWarnings, !warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(warnings.joined(separator: "\n"))
                    .accessibilityLabel("Stitch warnings: \(warnings.joined(separator: ". "))")
            }

            Spacer()

            HStack(spacing: 2) {
                ForEach(ShelfPresentationStyle.allCases) { style in
                    Button {
                        Preferences.shared.shelfPresentationStyle = style
                    } label: {
                        Image(systemName: style.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                Preferences.shared.shelfPresentationStyle == style
                                    ? Color.black : Color.white.opacity(0.72)
                            )
                            .frame(
                                width: NotchShotDesignSystem.minimumControlTarget,
                                height: NotchShotDesignSystem.minimumControlTarget
                            )
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        Preferences.shared.shelfPresentationStyle == style
                                            ? Color.white : Color.white.opacity(0.001)
                                    )
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show shelf as \(style.title.lowercased())")
                    .accessibilityLabel("\(style.title) shelf view")
                    .accessibilityAddTraits(
                        Preferences.shared.shelfPresentationStyle == style ? [.isSelected] : []
                    )
                }
            }
            .padding(2)
            .notchControlSurface(
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                reduceTransparency: reduceTransparency
            )

            NotchIconButton(systemName: "eye.slash", label: "Hide shelf", visualScale: 0.72) {
                coordinator.hideShelf()
            }
        }
    }

    private var totalSizeDescription: String {
        let total = items.reduce(Int64.zero) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.asset.fileSize)
            return overflow ? Int64.max : sum
        }
        return ByteCountFormatter.string(fromByteCount: max(0, total), countStyle: .file)
    }

    private var grid: some View {
        ScrollView(.horizontal) {
            LazyHGrid(rows: [GridItem(.fixed(48))], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        coordinator.selectShelfItem(at: index)
                    } label: {
                        ShelfGridCell(
                            item: item,
                            isSelected: index == coordinator.selectedShelfIndex
                        )
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .contextMenu { shelfMenuContent(for: item) }
                    .accessibilityLabel(item.asset.displayName)
                    .accessibilityValue(
                        "\(item.asset.kind.displayName), \(item.asset.fileSizeDescription), item \(index + 1) of \(items.count)"
                    )
                    .accessibilityAddTraits(index == coordinator.selectedShelfIndex ? [.isSelected] : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 50)
    }

    private func thumbnail(for item: ShelfItem) -> some View {
        Button {
            coordinator.openPreview(for: item)
        } label: {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.1))
                        .overlay {
                            Image(systemName: item.asset.kind.symbolName)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
            }
            .frame(width: 96, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.white.opacity(0.16))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(NotchPressButtonStyle())
        // Dragging the thumbnail is the fastest route into Finder, Mail,
        // Slack, or an upload field — no save dialog in between.
        .onDrag {
            let provider = NSItemProvider(contentsOf: item.asset.url) ?? NSItemProvider()
            provider.suggestedName = item.asset.url.lastPathComponent
            return provider
        } preview: {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail).resizable().frame(width: 160, height: 110)
            } else {
                Color.gray.frame(width: 160, height: 110)
            }
        }
        .help("Click to open. Drag to a folder or app.")
        .accessibilityLabel("Open capture preview")
        .accessibilityHint("Opens a larger preview. The image can also be dragged to another app.")
    }

    private func details(for item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.asset.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(item.asset.dimensionsDescription)
                if let duration = item.asset.duration {
                    Text(durationText(duration))
                }
                Text(item.asset.fileSizeDescription)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.55))

            if let text = item.ocrResult?.fullText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }

            if let items = item.ocrResult?.detectedItems, !items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(items.prefix(3)) { detected in
                        Button {
                            coordinator.openDetectedItem(detected)
                        } label: {
                            Label(detected.value, systemImage: detected.kind.symbolName)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                }
            }

            if let result = item.ocrResult, !result.tables.isEmpty {
                HStack(spacing: 8) {
                    Button("Copy Table TSV") {
                        Task { await coordinator.copyRecognizedContent(from: item, format: .tsv) }
                    }
                    .frame(minHeight: 32)
                    Button("Copy Table Markdown") {
                        Task { await coordinator.copyRecognizedContent(from: item, format: .markdown) }
                    }
                    .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func actions(for item: ShelfItem) -> some View {
        let primary = primaryActions(for: item.asset)

        return HStack(spacing: 6) {
            ForEach(primary) { action in
                actionButton(action, item: item)
            }

            Spacer(minLength: 0)

            Menu { shelfMenuContent(for: item) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(
                        width: NotchIconButton.minimumHitSize,
                        height: NotchIconButton.minimumHitSize
                    )
                    .foregroundStyle(.white)
                    .notchControlSurface(
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                        reduceTransparency: reduceTransparency
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More capture actions")
        }
    }

    @ViewBuilder
    private func shelfMenuContent(for item: ShelfItem) -> some View {
        Section("File") {
            menuAction(.copy, item: item)
            menuAction(.open, item: item)

            let applications = coordinator.applicationsThatCanOpen(item.asset)
            if !applications.isEmpty {
                Menu("Open With") {
                    ForEach(applications, id: \.self) { applicationURL in
                        Button {
                            coordinator.open(item.asset, with: applicationURL)
                        } label: {
                            Label(
                                applicationURL.deletingPathExtension().lastPathComponent,
                                systemImage: "app"
                            )
                        }
                    }
                }
            }

            menuAction(.quickLook, item: item)
            menuAction(.save, item: item)
            menuAction(.share, item: item)
            menuAction(.airDrop, item: item)
            menuAction(.localSend, item: item)
        }

        Section("Create & transform") {
            ForEach([
                ShareAction.annotate, .trim, .privacyReview, .removeBackground,
                .bugReport, .ocr, .pin, .inspect, .optimize, .convert, .compress,
            ].filter { $0.isAvailable(for: item.asset) }) { action in
                menuAction(action, item: item)
            }
        }

        Section("Organize") {
            ForEach([
                ShareAction.rename, .moveTo, .reveal,
            ].filter { $0.isAvailable(for: item.asset) }) { action in
                menuAction(action, item: item)
            }
            Button {
                coordinator.onOpenSettings?()
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
        }

        Divider()

        Button {
            coordinator.dismissShelfItem(item)
        } label: {
            Label("Remove from Shelf", systemImage: "xmark.circle")
        }

        if item.asset.ownership != .externalReference {
            Button(role: .destructive) {
                coordinator.perform(.delete, on: item)
            } label: {
                Label("Move File to Trash", systemImage: "trash")
            }
        }
    }

    private func menuAction(_ action: ShareAction, item: ShelfItem) -> some View {
        Button {
            coordinator.perform(action, on: item)
        } label: {
            Label(action.title(for: item.asset), systemImage: action.symbolName)
        }
    }

    private func primaryActions(for asset: CaptureAsset) -> [ShareAction] {
        let available = ShareAction.customizableShelfCases.filter { $0.isAvailable(for: asset) }
        var result = Preferences.shared.shelfQuickActions.filter { available.contains($0) }
        for action in available where !result.contains(action) && result.count < 4 {
            result.append(action)
        }
        return Array(result.prefix(4))
    }

    private func actionButton(_ action: ShareAction, item: ShelfItem) -> some View {
        let title = action.title(for: item.asset)
        return Button {
            coordinator.perform(action, on: item)
        } label: {
            Image(systemName: action.symbolName)
                .font(.system(size: 12))
                .frame(
                    width: NotchIconButton.minimumHitSize,
                    height: NotchIconButton.minimumHitSize
                )
                .foregroundStyle(.white)
                .notchControlSurface(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    reduceTransparency: reduceTransparency
                )
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    /// Capture Stack strip: collect several shots, reorder them, then export
    /// the set as one artefact instead of handing over four separate files.
    private var stackBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 10))
                .foregroundStyle(coordinator.stack.isCollecting ? Color.accentColor : .white.opacity(0.6))

            Text("\(coordinator.stack.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(coordinator.stack.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            coordinator.stack.moveItem(id: item.id, by: -1)
                        } label: {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                                .frame(
                                    width: NotchIconButton.minimumHitSize,
                                    height: NotchIconButton.minimumHitSize
                                )
                                .notchControlSurface(
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous),
                                    reduceTransparency: reduceTransparency
                                )
                        }
                        .buttonStyle(NotchPressButtonStyle())
                        .help("Move earlier")
                        .accessibilityLabel(index == 0
                            ? "\(item.asset.displayName), first stack item"
                            : "Move \(item.asset.displayName) earlier")
                        .accessibilityValue("Item \(index + 1) of \(coordinator.stack.count)")
                        .accessibilityAction(named: Text("Move later")) {
                            coordinator.stack.moveItem(id: item.id, by: 1)
                        }
                        .accessibilityAction(named: Text("Remove from stack")) {
                            coordinator.stack.remove(id: item.id)
                        }
                        .contextMenu {
                            Button("Move Earlier") { coordinator.stack.moveItem(id: item.id, by: -1) }
                            Button("Move Later") { coordinator.stack.moveItem(id: item.id, by: 1) }
                            Button("Annotate…") { coordinator.openEditor(for: item) }
                            Divider()
                            Button("Remove", role: .destructive) { coordinator.stack.remove(id: item.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            Menu {
                ForEach(StackExportStyle.allCases) { style in
                    Button {
                        coordinator.exportStack(style: style, numbersSteps: false)
                    } label: {
                        Label(style.title, systemImage: style.symbolName)
                    }
                }
                Divider()
                Section("Numbered steps") {
                    ForEach(StackExportStyle.allCases) { style in
                        Button("\(style.title) with steps") {
                            coordinator.exportStack(style: style, numbersSteps: true)
                        }
                    }
                }
                Divider()
                Menu("Share") {
                    Button("Long Image…") {
                        coordinator.shareStack(style: .longImage)
                    }
                    Button("Storyboard…") {
                        coordinator.shareStack(style: .storyboard)
                    }
                    Button("PDF…") {
                        coordinator.shareStack(style: .pdf)
                    }
                }
                Divider()
                Button("Compare First Two") {
                    coordinator.compareFirstTwoStackItems()
                }
                .disabled(coordinator.stack.count < 2)
                Divider()
                Button("Save Capture Session…") {
                    coordinator.saveCurrentCaptureSession()
                }
                if !coordinator.stack.savedSessions.isEmpty {
                    Menu("Resume Session") {
                        ForEach(coordinator.stack.savedSessions) { session in
                            Button(session.name) {
                                coordinator.resumeCaptureSession(session)
                            }
                        }
                    }
                }
                Divider()
                Button("Clear Stack", role: .destructive) { coordinator.stack.clear() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.white)
            .disabled(coordinator.stack.isEmpty)

            Button {
                coordinator.toggleStackCollecting()
            } label: {
                Image(systemName: coordinator.stack.isCollecting ? "pause.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(coordinator.stack.isCollecting ? Color.accentColor : .white)
                    .frame(
                        width: NotchIconButton.minimumHitSize,
                        height: NotchIconButton.minimumHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressButtonStyle())
            .help(coordinator.stack.isCollecting
                  ? "Stop adding new captures to the stack"
                  : "Add every new capture to the stack")
            .accessibilityLabel(coordinator.stack.isCollecting
                ? "Stop collecting captures"
                : "Collect new captures")
            .accessibilityValue(coordinator.stack.isCollecting ? "On" : "Off")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07))
        }
        .animation(reduceMotion ? nil : .snappy, value: coordinator.stack.count)
    }

    private var pager: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            coordinator.selectShelfItem(at: index)
                        } label: {
                            Group {
                                if let thumbnail = item.thumbnail {
                                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.white.opacity(0.12)
                                }
                            }
                            .frame(width: 44, height: NotchIconButton.minimumHitSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        index == coordinator.selectedShelfIndex
                                            ? Color.accentColor : .white.opacity(0.18),
                                        lineWidth: index == coordinator.selectedShelfIndex ? 2 : 1
                                    )
                            }
                        }
                        .buttonStyle(NotchPressButtonStyle())
                        .accessibilityLabel("Capture \(index + 1) of \(items.count)")
                        .accessibilityAddTraits(index == coordinator.selectedShelfIndex ? [.isSelected] : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            if coordinator.canRestoreDismissed {
                Button {
                    coordinator.restoreLastDismissed()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(NotchPressButtonStyle())
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ShelfGridCell: View {
    let item: ShelfItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .overlay {
                            Image(systemName: item.asset.kind.symbolName)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }
            }
            .frame(width: 38, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.asset.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.asset.fileSizeDescription)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: 132)
        .frame(minHeight: 48)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.23) : Color.white.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
