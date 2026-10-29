import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The post-capture shelf: CleanShot's Quick Access Overlay idea, moved into
/// the notch so results appear where the capture was launched from.
struct ShelfContent: View {
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoveredAction: ShareAction?
    @State private var gridOverflow = ShelfScrollOverflow()
    /// A page turn whose direction has landed and whose move is under way.
    @State private var pageTurn: ShelfPageTurn?
    @State private var pageTurns = 0
    /// The newest capture once a view switch has shown it. From then on it
    /// has arrived, and the other layout draws it in place instead of having
    /// it rise from the screen again; a new capture is not this, so it rises.
    @State private var settledNewestID: ShelfItem.ID?

    private var items: [ShelfItem] { coordinator.shelfItems }
    private var selected: ShelfItem? { coordinator.selectedShelfItem }
    private var style: ShelfPresentationStyle { Preferences.shared.shelfPresentationStyle }
    private var newestIsArriving: Bool { items.first?.id != settledNewestID }

    /// The grid strip: its 48 pt tiles with room for the selection ring.
    private static let gridStripHeight: CGFloat = 50
    /// The strip, then the action toolbar under it, as `NotchLayout` sizes
    /// the grid shelf.
    private static let gridLayoutHeight = gridStripHeight + 10 + NotchIconButton.minimumHitSize

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    if let selected {
                        // Grid and Detail overlap while one gives way to the
                        // other, each at its own fixed size. The frame is the
                        // size of the layout being switched to, so the rows
                        // under it are in place from the first frame.
                        ZStack(alignment: .top) {
                            if style == .grid {
                                VStack(spacing: 10) {
                                    grid
                                    actions(for: selected)
                                }
                                .transition(ShelfMotion.layoutTransition(reduceMotion: reduceMotion))
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    thumbnail(for: selected)
                                    VStack(alignment: .leading, spacing: 0) {
                                        pagedDetails(for: selected)
                                        Spacer(minLength: 0)
                                        actions(for: selected)
                                    }
                                    .frame(height: NotchLayout.shelfDetailRowHeight)
                                }
                                .transition(ShelfMotion.layoutTransition(reduceMotion: reduceMotion))
                            }
                        }
                        .frame(
                            height: style == .grid ? Self.gridLayoutHeight : NotchLayout.shelfDetailRowHeight,
                            alignment: .top
                        )
                    }

                    if !coordinator.stack.isEmpty || coordinator.stack.isCollecting {
                        stackBar
                    }

                    if items.count > 1, style == .detail {
                        pager
                            .transition(ShelfMotion.layoutTransition(reduceMotion: reduceMotion))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Switching view mode resizes the island on a spring while the
            // layouts crossfade, so for the length of that animation the
            // content can be taller than the panel and a scroller rode the
            // whole transition. `.hidden` was not enough: with a mouse
            // attached the system uses legacy scrollers, which `.hidden` lets
            // through and which would also steal layout width from a
            // fixed-size island.
            .scrollIndicators(.never)
            .accessibilityLabel("Capture shelf content")
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .focusable()
        // Keyboard navigation without AppKit's blue focus ring. The ring traced
        // this view's rounded rect inside the island, which read as the notch's
        // corners randomly turning blue whenever the panel took key focus.
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            turnPage(.step(-1))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            turnPage(.step(1))
            return .handled
        }
        .onKeyPress(.escape) {
            coordinator.hideShelf()
            return .handled
        }
        .onChange(of: pageTurn) { _, turn in
            guard let turn else { return }
            withAnimation(NotchMotion.content(reduceMotion: reduceMotion)) {
                move(turn.move)
            } completion: {
                // Later changes (a new capture, one removed) are not page
                // turns, and crossfade.
                if pageTurn?.serial == turn.serial { pageTurn = nil }
            }
        }
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: coordinator.selectedShelfIndex)
    }

    // MARK: Paging

    /// Moves the selection, the next capture coming in from the side it lies
    /// on. The move itself waits for the direction to land (`ShelfPageTurn`).
    private func turnPage(_ move: ShelfPageTurn.Move) {
        let turn = ShelfPageTurn(move: move, from: coordinator.selectedShelfIndex, serial: pageTurns + 1)
        guard items.count > 1, turn.edge != nil else {
            self.move(move)
            return
        }
        pageTurns += 1
        pageTurn = turn
    }

    private func move(_ move: ShelfPageTurn.Move) {
        switch move {
        case .step(let step): coordinator.advanceShelfSelection(by: step)
        case .to(let index): coordinator.selectShelfItem(at: index)
        }
    }

    private var pageTransition: AnyTransition {
        ShelfMotion.pageTransition(edge: pageTurn?.edge, reduceMotion: reduceMotion)
    }

    // MARK: Pieces

    /// The count left of the camera, the view switch and Hide right of it.
    /// This row used to sit below the camera band, which stayed empty above it.
    private var header: some View {
        IslandBandHeader(leadingInset: 16, trailingInset: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                Text("\(items.count) \(items.count == 1 ? "File" : "Files")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()

                // A single capture's size is already on its details line.
                if items.count > 1 {
                    Text(totalSizeDescription)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .monospacedDigit()
                        .lineLimit(1)
                }

                if let warnings = selected?.stitchWarnings, !warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(warnings.joined(separator: "\n"))
                        .accessibilityLabel("Stitch warnings: \(warnings.joined(separator: ". "))")
                }
            }
        } trailing: {
            HStack(spacing: 2) {
                // Words, not glyphs: a list icon and a grid icon in an accent
                // segment outweighed the captures themselves.
                HStack(spacing: 0) {
                    ForEach(ShelfPresentationStyle.allCases) { style in
                        let isSelected = Preferences.shared.shelfPresentationStyle == style
                        Button {
                            guard !isSelected else { return }
                            // The newest capture has arrived by now: the
                            // other layout shows it in place.
                            settledNewestID = items.first?.id
                            Preferences.shared.shelfPresentationStyle = style
                        } label: {
                            Text(style.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.islandInk(isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.tertiary))
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(
                                    Color.islandInk(isSelected ? NotchIsland.Surface.selected : 0),
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(style == .grid ? "Show every capture as a thumbnail" : "Show the selected capture with its details")
                        .accessibilityLabel("\(style.title) shelf view")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
                .padding(2)
                .islandControlSurface(Capsule())
                .fixedSize()
                .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: Preferences.shared.shelfPresentationStyle)

                IslandBandButton(systemName: "chevron.up", label: "Hide shelf") {
                    coordinator.hideShelf()
                }
                .help("Tuck the shelf away. Captures stay on it until you remove them.")
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
            // Five tiles at most (`AppCoordinator.maximumShelfItems`), so a
            // plain stack: a lazy grid could rebuild a tile scrolled back into
            // view, replaying its arrival and losing the ring's anchor.
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        coordinator.selectShelfItem(at: index)
                    } label: {
                        ShelfGridCell(item: item)
                            // A fresh capture rises into the strip, as it
                            // does into the detail thumbnail.
                            .shelfArrival(id: item.id, isArriving: index == 0 && newestIsArriving)
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .shelfSelectionAnchor(isSelected: index == coordinator.selectedShelfIndex)
                    .contextMenu { shelfMenuContent(for: item) }
                    .accessibilityLabel(item.asset.displayName)
                    .accessibilityValue(
                        "\(item.asset.kind.displayName), \(item.asset.fileSizeDescription), item \(index + 1) of \(items.count)"
                    )
                    .accessibilityAddTraits(index == coordinator.selectedShelfIndex ? [.isSelected] : [])
                }
            }
            // The selected tile's white outline: one ring that slides from
            // tile to tile rather than jumping between them.
            .shelfSelectionRing(selection: coordinator.selectedShelfIndex, reduceMotion: reduceMotion) {
                NotchIsland.cardShape.stroke(Color.white, lineWidth: 2)
            }
        }
        .scrollIndicators(.never)
        // The last tile used to be cut straight through by the island's edge,
        // which read as a rendering bug rather than "there is more".
        .onScrollGeometryChange(for: ShelfScrollOverflow.self) { geometry in
            ShelfScrollOverflow(
                leading: geometry.contentOffset.x > 1,
                trailing: geometry.contentSize.width - geometry.contentOffset.x > geometry.containerSize.width + 1
            )
        } action: { _, overflow in
            gridOverflow = overflow
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: gridOverflow.leading ? 28 : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: gridOverflow.trailing ? 36 : 0)
            }
        }
        .frame(height: Self.gridStripHeight)
    }

    private func thumbnail(for item: ShelfItem) -> some View {
        Button {
            if item.asset.kind.isImage {
                coordinator.openPreview(for: item)
            } else {
                coordinator.perform(.open, on: item)
            }
        } label: {
            // The picture turns with the page inside a card that stays put,
            // so paging never replays the card's arrival.
            ZStack {
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
                .frame(width: 128, height: NotchLayout.shelfDetailRowHeight)
                .id(item.id)
                .transition(pageTransition)
            }
            .frame(width: 128, height: NotchLayout.shelfDetailRowHeight)
            .background(Color.islandInk(NotchIsland.Ink.fill), in: NotchIsland.cardShape)
            .clipShape(NotchIsland.cardShape)
            .overlay {
                NotchIsland.cardShape
                    .stroke(.white.opacity(0.14))
            }
            .contentShape(NotchIsland.cardShape)
            // A fresh capture rises into the notch instead of simply appearing.
            .shelfArrival(id: items.first?.id, isArriving: newestIsArriving)
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
        .accessibilityLabel(item.asset.kind.isImage ? "Open capture preview" : "Open \(item.asset.displayName)")
        .accessibilityHint(item.asset.kind.isImage
            ? "Opens a larger preview. The image can also be dragged to another app."
            : "Opens this file in its default app. The file can also be dragged to another app.")
    }

    /// The details turn with the picture beside them; the actions under
    /// them stay where they are.
    private func pagedDetails(for item: ShelfItem) -> some View {
        ZStack(alignment: .topLeading) {
            details(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(item.id)
                .transition(pageTransition)
        }
        .clipped()
    }

    /// Name, then one metadata line, then a single line of recognised text
    /// or the first detected link. Table copies and further detected items
    /// live in the More menu, so the column never overflows its thumbnail.
    private func details(for item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.asset.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            // The hovered toolbar action is named here, in place of the
            // metadata, rather than on a line of its own.
            Group {
                if let hoveredAction {
                    Text(hoveredAction.title(for: item.asset))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                } else {
                    Text(metadataLine(for: item))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .animation(nil, value: hoveredAction)

            if let detected = item.ocrResult?.detectedItems.first {
                Button {
                    coordinator.openDetectedItem(detected)
                } label: {
                    Label(detected.value, systemImage: detected.kind.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Open \(detected.value)")
            } else if let text = item.ocrResult?.fullText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
            }
        }
    }

    private func metadataLine(for item: ShelfItem) -> String {
        var parts = [item.asset.dimensionsDescription]
        if let duration = item.asset.duration {
            parts.append(durationText(duration))
        }
        parts.append(item.asset.fileSizeDescription)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One quiet toolbar: the quick actions and More side by side, with no
    /// box around them. Each control lights only under the pointer, and its
    /// name replaces the metadata line while it does.
    private func actions(for item: ShelfItem) -> some View {
        HStack(spacing: 2) {
            ForEach(primaryActions(for: item.asset)) { action in
                actionButton(action, item: item)
            }

            Menu { shelfMenuContent(for: item) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .frame(
                        width: NotchIconButton.minimumHitSize,
                        height: NotchIconButton.minimumHitSize
                    )
                    .contentShape(Rectangle())
            }
            .islandMenuStyle()
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More capture actions")

            Spacer(minLength: 0)
        }
        .padding(.leading, -8)
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
            menuAction(.shareLink, item: item)
            menuAction(.sendToAgent, item: item)
        }

        if let result = item.ocrResult,
           !result.tables.isEmpty || result.detectedItems.count > 1 {
            Section("Recognized Text") {
                ForEach(result.detectedItems.dropFirst().prefix(5)) { detected in
                    Button {
                        coordinator.openDetectedItem(detected)
                    } label: {
                        Label(detected.value, systemImage: detected.kind.symbolName)
                    }
                }
                if !result.tables.isEmpty {
                    Button("Copy Table as TSV") {
                        Task { await coordinator.copyRecognizedContent(from: item, format: .tsv) }
                    }
                    Button("Copy Table as Markdown") {
                        Task { await coordinator.copyRecognizedContent(from: item, format: .markdown) }
                    }
                }
            }
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
        for action in available
        where !result.contains(action) && result.count < ShareAction.shelfQuickActionSlots {
            result.append(action)
        }
        return Array(result.prefix(ShareAction.shelfQuickActionSlots))
    }

    private func actionButton(_ action: ShareAction, item: ShelfItem) -> some View {
        let title = action.title(for: item.asset)
        let isHovered = hoveredAction == action
        return Button {
            coordinator.perform(action, on: item)
        } label: {
            ShelfActionGlyph(
                symbolName: action.symbolName,
                isConfirmed: coordinator.shelfConfirmation?.action == action
                    && coordinator.shelfConfirmation?.itemID == item.id
            )
                .frame(
                    width: NotchIconButton.minimumHitSize,
                    height: NotchIconButton.minimumHitSize
                )
                .foregroundStyle(Color.islandInk(isHovered ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .background(
                    Color.islandInk(isHovered ? NotchIsland.Surface.hover : 0),
                    in: NotchIsland.cardShape
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { hovering in
            if hovering {
                hoveredAction = action
            } else if hoveredAction == action {
                hoveredAction = nil
            }
        }
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
            .scrollIndicators(.never)
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
                    .foregroundStyle(.white)
                    .contentTransition(NotchSymbolMotion.swap(reduceMotion: false))
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
            NotchIsland.cardShape.fill(.white.opacity(0.07))
        }
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: coordinator.stack.count)
    }

    private var pager: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            turnPage(.to(index))
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
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            }
                        }
                        .buttonStyle(NotchPressButtonStyle())
                        .shelfSelectionAnchor(isSelected: index == coordinator.selectedShelfIndex)
                        .accessibilityLabel("Capture \(index + 1) of \(items.count)")
                        .accessibilityAddTraits(index == coordinator.selectedShelfIndex ? [.isSelected] : [])
                    }
                }
                .shelfSelectionRing(selection: coordinator.selectedShelfIndex, reduceMotion: reduceMotion) {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white, lineWidth: 2)
                }
            }
            .scrollIndicators(.never)
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

/// Whether the horizontal grid has tiles beyond either edge.
private struct ShelfScrollOverflow: Equatable {
    var leading = false
    var trailing = false
}

/// A capture is recognised by its picture, not its file name, so the tile is
/// all thumbnail and the name only appears under the pointer. The selected
/// tile gets a white outline (the old navy fill sank into the island's
/// black), drawn by the strip over the tiles so it can slide between them.
private struct ShelfGridCell: View {
    let item: ShelfItem

    @State private var isHovered = false

    var body: some View {
        let shape = NotchIsland.cardShape
        Group {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.islandInk(0.08))
                    .overlay {
                        Image(systemName: item.asset.kind.symbolName)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    }
            }
        }
        .frame(width: Self.width, height: 48)
        .overlay(alignment: .bottomLeading) {
            if isHovered {
                Text(item.asset.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    )
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let duration = item.asset.duration {
                let total = Int(duration.rounded())
                Text(String(format: "%d:%02d", total / 60, total % 60))
                    .font(.system(size: NotchIsland.TextSize.badge, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(3)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(item.asset.displayName)
    }

    static let width: CGFloat = 72
}

/// A shelf action's glyph. When the action has just finished, a checkmark
/// draws itself on in its place, as the system's own confirmations arrive,
/// and gives the glyph back a moment later.
private struct ShelfActionGlyph: View {
    var symbolName: String
    var isConfirmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isConfirmed {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    // Drawing has no travel, so it stays under Reduce Motion.
                    .transition(.symbolEffect(.drawOn))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .transition(.opacity)
            }
        }
        .animation(NotchMotion.content(reduceMotion: reduceMotion), value: isConfirmed)
    }
}
