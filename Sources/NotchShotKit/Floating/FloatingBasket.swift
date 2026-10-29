import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - JiggleDetector

/// Detects a "jiggle" while the left mouse button is dragging.
///
/// Droppy's signature gesture: wiggle the mouse side-to-side while holding
/// files and a floating basket flies in wherever you are. The heuristic is
/// deliberately loose — 4 direction reversals with at least 8 pt travel each
/// inside 0.6 s — so it feels intentional but never requires precision.
@MainActor
public final class JiggleDetector {
    public var onJiggle: (() -> Void)?

    private struct Sample {
        var x: CGFloat
        var time: TimeInterval // seconds since boot via CACurrentMediaTime
        var dx: CGFloat
    }

    private var samples: [Sample] = []
    private var lastX: CGFloat?
    private var lastTrigger: TimeInterval = -10
    nonisolated(unsafe) private var monitors: [Any] = []

    private let reversalThreshold: CGFloat = 8
    private let reversalWindow: TimeInterval = 0.6
    private let requiredReversals = 4
    private let cooldown: TimeInterval = 1.2

    public init() {}

    public func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    public func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        samples.removeAll()
        lastX = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            lastX = event.locationInWindow.x
            // Also consider screen position for global monitor where window coords are meaningless
            if let screenX = NSScreen.main?.frame.midX {
                // Keep lastX as screen location when global
                lastX = NSEvent.mouseLocation.x
                _ = screenX
            }
            samples.removeAll()
        case .leftMouseUp:
            lastX = nil
            samples.removeAll()
        case .leftMouseDragged:
            let x = NSEvent.mouseLocation.x
            guard let prev = lastX else {
                lastX = x
                return
            }
            let dx = x - prev
            lastX = x
            guard abs(dx) >= 1 else { return }
            let now = CACurrentMediaTime()
            // Ignore tiny moves
            if abs(dx) < 1 { return }
            samples.append(Sample(x: x, time: now, dx: dx))
            // Trim window
            samples.removeAll { now - $0.time > reversalWindow }
            // Count sign reversals with meaningful travel
            var reversals = 0
            var lastSignificantDX: CGFloat = 0
            for s in samples {
                guard abs(s.dx) >= reversalThreshold else { continue }
                if lastSignificantDX != 0 && s.dx * lastSignificantDX < 0 {
                    reversals += 1
                }
                lastSignificantDX = s.dx
            }
            if reversals >= requiredReversals, now - lastTrigger > cooldown {
                // Only trigger if left button is actually down (pressedMouseButtons bit 0)
                let pressed = NSEvent.pressedMouseButtons
                guard pressed & 1 != 0 else { return }
                lastTrigger = now
                samples.removeAll()
                onJiggle?()
            }
        default:
            break
        }
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Floating Basket Window

public final class FloatingBasketWindow: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    public init() {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 280)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // `FloatingWindowPresenter` plays the appear and disappear.
        animationBehavior = .none
        // Exclude from future captures while it is visible — the same
        // registry that hides the notch, floating pins, and History.
        MainActor.assumeIsolated {
            WindowExclusionRegistry.shared.register(self)
        }
        hasShadow = true
        // Rounded corners are handled by the SwiftUI content's clip shape.
        isReleasedWhenClosed = false
    }

    func setContent(_ view: AnyView) {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = contentView?.bounds ?? frame
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        hostingView = hosting
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    // WindowExclusionRegistry is @MainActor, so unregistration must hop.
    // Deinit cannot be @MainActor; do it explicitly when hiding.
    func unregisterFromExclusion() {
        MainActor.assumeIsolated {
            WindowExclusionRegistry.shared.unregister(self)
        }
    }
}

// MARK: - Basket colours

/// Colour-coded baskets. Every shelf item belongs to exactly one; items
/// nobody sorted stay in the first. The floating basket shows one colour at a
/// time, and the notch shelf still shows them all.
public enum BasketColor: String, CaseIterable, Identifiable, Sendable {
    case blue, green, orange, pink, purple

    public static let standard: BasketColor = .blue

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var tint: Color {
        switch self {
        case .blue: Color(nsColor: .systemBlue)
        case .green: Color(nsColor: .systemGreen)
        case .orange: Color(nsColor: .systemOrange)
        case .pink: Color(nsColor: .systemPink)
        case .purple: Color(nsColor: .systemPurple)
        }
    }
}

// MARK: - Floating Basket Manager

@MainActor
@Observable
public final class FloatingBasketManager {
    public static let shared = FloatingBasketManager()

    private var window: FloatingBasketWindow?
    private let presentation = FloatingWindowPresenter()
    private var jiggle = JiggleDetector()
    private var autoHideWorkItem: DispatchWorkItem?
    private var isVisible = false
    private weak var coordinator: AppCoordinator?
    /// The basket the floating panel is showing, and the one drops go into.
    public private(set) var activeColor: BasketColor = .standard
    /// Bumped on every switch so the view can flash the switcher.
    public private(set) var switchCount = 0
    /// Keyed by standardized file path: a dropped file keeps its own URL, and
    /// a path outlives the shelf item made from it if the file is re-added.
    /// Absent means the standard basket. In memory only, like the shelf.
    private var colorsByPath: [String: BasketColor] = [:]

    public init() {}

    public func start(coordinator: AppCoordinator? = nil) {
        if let coordinator { self.coordinator = coordinator }
        jiggle.onJiggle = { [weak self] in
            MainActor.assumeIsolated { self?.handleJiggle() }
        }
        jiggle.start()
    }

    public func stop() {
        jiggle.stop()
        hide()
    }

    private func handleJiggle() {
        guard Preferences.shared.notchEnabled else { return }
        if FloatingBasketPreferences.shared.isEnabled == false { return }
        show(at: NSEvent.mouseLocation)
    }

    public func show(at screenPoint: CGPoint? = nil) {
        guard let hostCoordinator = coordinator else { return }
        let point = screenPoint ?? NSEvent.mouseLocation
        let window = window ?? FloatingBasketWindow()
        self.window = window
        // Position slightly offset from cursor so the pointer isn't trapped inside the panel
        let count = hostCoordinator.shelfItems.count
        let size = NSSize(width: 380, height: min(420, max(220, CGFloat(count * 56 + 140))))
        var origin = CGPoint(
            x: point.x - size.width / 2,
            y: point.y - size.height - 28
        )
        // Clamp to visible screen
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }

        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.setContent(AnyView(FloatingBasketView(manager: self, coordinator: hostCoordinator)))
        // `hide()` takes the window out of the registry, and it is reused.
        WindowExclusionRegistry.shared.register(window)
        // Also cancels a hide still fading out, so a quick jiggle after
        // closing keeps the basket on screen.
        presentation.present(window) { basket in
            basket.orderFrontRegardless()
            basket.makeKeyAndOrderFront(nil)
        }
        isVisible = true
        scheduleAutoHide()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    public func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        isVisible = false
        guard let window else { return }
        presentation.dismiss(window) { [weak window] in
            window?.unregisterFromExclusion()
        }
    }

    public func toggle() {
        if isVisible { hide() } else { show() }
    }

    public var isShown: Bool { isVisible }

    private func scheduleAutoHide() {
        autoHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let host = self.coordinator else {
                    self.hide()
                    return
                }
                if host.shelfItems.isEmpty {
                    self.hide()
                } else {
                    self.scheduleAutoHide()
                }
            }
        }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    func keepAlive() {
        scheduleAutoHide()
    }

    // MARK: Colours

    public func color(for item: ShelfItem) -> BasketColor {
        colorsByPath[item.asset.url.standardizedFileURL.path] ?? .standard
    }

    public func items(in color: BasketColor, from shelf: [ShelfItem]) -> [ShelfItem] {
        shelf.filter { self.color(for: $0) == color }
    }

    /// Files dropped on the floating panel go into the basket it shows.
    func assignToActiveBasket(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            colorsByPath[path] = activeColor == .standard ? nil : activeColor
        }
    }

    public func move(_ item: ShelfItem, to color: BasketColor) {
        let path = item.asset.url.standardizedFileURL.path
        colorsByPath[path] = color == .standard ? nil : color
    }

    public func select(_ color: BasketColor) {
        guard color != activeColor else { return }
        activeColor = color
        switchCount &+= 1
        keepAlive()
    }

    /// ⌘-Tab style: step to the next basket, wrapping.
    public func cycle(forward: Bool) {
        let all = BasketColor.allCases
        guard let index = all.firstIndex(of: activeColor) else { return }
        let next = (index + (forward ? 1 : all.count - 1)) % all.count
        select(all[next])
    }
}

// Helper to access AppCoordinator from MainActor-isolated manager without
// a static shared. The manager keeps a weak coordinator reference set at start.
extension AppCoordinator {
    // No static shared — the app owns a single instance via AppDelegate.
    // FloatingBasketManager keeps a weak reference after start(coordinator:).
}

// Lightweight preferences bridge — keeps FloatingBasketManager from importing
// the whole Preferences observation graph on every jiggle test.
public final class FloatingBasketPreferences: @unchecked Sendable {
    public static let shared = FloatingBasketPreferences()
    private let key = "notchshot.floatingBasketEnabled"
    public var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private init() {}
}

// MARK: - Floating Basket SwiftUI View

public struct FloatingBasketView: View {
    @Bindable var coordinator: AppCoordinator
    var manager: FloatingBasketManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var isShowingSwitcher = false
    @State private var switcherDismissal: Task<Void, Never>?

    public init(manager: FloatingBasketManager, coordinator: AppCoordinator) {
        self.manager = manager
        self.coordinator = coordinator
    }

    /// Only the active basket's files.
    private var visibleItems: [ShelfItem] {
        manager.items(in: manager.activeColor, from: coordinator.shelfItems)
    }

    private var tint: Color { manager.activeColor.tint }

    public var body: some View {
        VStack(spacing: 10) {
            header
            if visibleItems.isEmpty {
                emptyDropZone
            } else {
                itemList
                dropHint
            }
            footer
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .overlay {
            if isDropTargeted {
                MarchingDashStroke(
                    shape: RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 1),
                    color: tint.opacity(0.9),
                    lineWidth: 2,
                    dash: [8, 5]
                )
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .onChange(of: isDropTargeted) { _, targeted in
            coordinator.setDraggingFiles(targeted)
            if targeted { manager.keepAlive() }
        }
        .overlay {
            if isShowingSwitcher {
                BasketSwitcher(active: manager.activeColor) { color in
                    coordinator.shelfItems.filter { manager.color(for: $0) == color }.count
                }
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.94)))
            }
        }
        .animation(NotchMotion.content(reduceMotion: reduceMotion), value: isShowingSwitcher)
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: manager.activeColor)
        .onChange(of: manager.switchCount) { _, _ in flashSwitcher() }
        // Tab and Shift-Tab step through the baskets while the panel is key,
        // like ⌘-Tab through apps; ⌘1…⌘5 jump straight to one. With Full
        // Keyboard Access on, Tab is how the user reaches the basket's own
        // controls, so it keeps that job there.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.tab, phases: .down) { press in
            guard !NSApp.isFullKeyboardAccessEnabled else { return .ignored }
            manager.cycle(forward: !press.modifiers.contains(.shift))
            return .handled
        }
        .background { basketShortcuts }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating Basket, \(manager.activeColor.title)")
    }

    private var basketShortcuts: some View {
        ForEach(Array(BasketColor.allCases.enumerated()), id: \.element) { index, color in
            Button("\(color.title) basket") { manager.select(color) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func flashSwitcher() {
        isShowingSwitcher = true
        switcherDismissal?.cancel()
        switcherDismissal = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            isShowingSwitcher = false
        }
    }

    /// One dot per basket; the active one is ringed. A dot with files in it is
    /// filled, an empty one is an outline.
    private var basketDots: some View {
        HStack(spacing: 5) {
            ForEach(BasketColor.allCases) { color in
                let count = coordinator.shelfItems.filter { manager.color(for: $0) == color }.count
                Button {
                    manager.select(color)
                } label: {
                    Circle()
                        .fill(count > 0 ? color.tint : color.tint.opacity(0.22))
                        .frame(width: 10, height: 10)
                        .padding(2.5)
                        .overlay {
                            Circle().strokeBorder(
                                color == manager.activeColor ? color.tint : .clear,
                                lineWidth: 1.5
                            )
                        }
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(color.title) basket (⌘\((BasketColor.allCases.firstIndex(of: color) ?? 0) + 1))")
                .accessibilityLabel("\(color.title) basket, \(count) \(count == 1 ? "file" : "files")")
                .accessibilityAddTraits(color == manager.activeColor ? [.isSelected] : [])
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "basket.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(visibleItems.isEmpty ? "Drop files here" : "\(visibleItems.count) \(visibleItems.count == 1 ? "file" : "files")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if !visibleItems.isEmpty {
                Text(totalSize)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            basketDots
            Button {
                manager.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide basket")
            .accessibilityLabel("Hide basket")
        }
    }

    private var totalSize: String {
        let total = visibleItems.reduce(Int64.zero) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.asset.fileSize)
            return overflow ? Int64.max : sum
        }
        return ByteCountFormatter.string(fromByteCount: max(0, total), countStyle: .file)
    }

    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("Jiggle while dragging to summon the basket")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Drop files here to hold them, then drag them out where you need them.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? tint.opacity(0.12) : Color.primary.opacity(0.04))
                .overlay {
                    MarchingDashStroke(
                        shape: RoundedRectangle(cornerRadius: 12, style: .continuous).inset(by: 0.6),
                        color: isDropTargeted ? tint.opacity(0.7) : Color.secondary.opacity(0.18),
                        lineWidth: 1.2,
                        isMarching: isDropTargeted
                    )
                }
        }
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: isDropTargeted)
    }

    private var itemList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                ForEach(visibleItems) { item in
                    BasketRow(item: item, tint: tint)
                        .onDrag {
                            let provider = NSItemProvider(contentsOf: item.asset.url) ?? NSItemProvider()
                            provider.suggestedName = item.asset.url.lastPathComponent
                            return provider
                        } preview: {
                            if let thumb = item.thumbnail {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 160, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Color.gray.frame(width: 160, height: 100)
                            }
                        }
                        .contextMenu {
                            Button("Open") { coordinator.perform(.open, on: item) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.asset.url]) }
                            Menu("Move to Basket") {
                                ForEach(BasketColor.allCases) { color in
                                    Button(color.title) { manager.move(item, to: color) }
                                        .disabled(color == manager.color(for: item))
                                }
                            }
                            Divider()
                            Button("Remove from Basket") { coordinator.dismissShelfItem(item) }
                            if item.asset.ownership != .externalReference {
                                Button("Move to Trash", role: .destructive) { coordinator.perform(.delete, on: item) }
                            }
                        }
                        .accessibilityActions {
                            Button("Open") { coordinator.perform(.open, on: item) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.asset.url])
                            }
                            Button("Remove from Basket") { coordinator.dismissShelfItem(item) }
                            if item.asset.ownership != .externalReference {
                                Button("Move to Trash") { coordinator.perform(.delete, on: item) }
                            }
                        }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 240)
    }

    private var dropHint: some View {
        Label(isDropTargeted ? "Release to add to basket" : "Drag files here or out", systemImage: isDropTargeted ? "arrow.down.circle.fill" : "arrow.left.arrow.right")
            .font(.caption.weight(.medium))
            .foregroundStyle(isDropTargeted ? tint : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTargeted ? tint.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .animation(NotchMotion.hover(reduceMotion: reduceMotion), value: isDropTargeted)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !visibleItems.isEmpty {
                Button("Clear Basket") {
                    for item in visibleItems {
                        coordinator.dismissShelfItem(item)
                    }
                    if coordinator.shelfItems.isEmpty { manager.hide() }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Show in Notch") {
                if !coordinator.arbiter.userExpanded {
                    coordinator.toggleExpanded()
                }
                manager.hide()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.plain)
            .help("Open the notch shelf")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let expectedItemCount = providers.count
        // The same tap as a drop on the notch: the file is on the shelf.
        IslandHaptics.perform(.dropSwallowed)
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) else { continue }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
            await MainActor.run {
                manager.assignToActiveBasket(urls)
                coordinator.performFileDropAction(
                    .shelf,
                    urls: urls,
                    expectedItemCount: expectedItemCount
                )
            }
        }
    }
}

private struct BasketRow: View {
    let item: ShelfItem
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                        .overlay { Image(systemName: item.asset.kind.symbolName).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.08)) }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.asset.displayName).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.asset.dimensionsDescription).foregroundStyle(.secondary)
                    Text(item.asset.fileSizeDescription).foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.8))
                .help("Drag this file out to any app or folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.06)) }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.asset.displayName)
        .accessibilityValue("\(item.asset.dimensionsDescription), \(item.asset.fileSizeDescription)")
    }
}

/// The ⌘-Tab style strip that flashes over the basket when it switches: every
/// basket as a tile, the active one lifted and ringed, with its file count.
private struct BasketSwitcher: View {
    var active: BasketColor
    var count: (BasketColor) -> Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BasketColor.allCases) { color in
                let isActive = color == active
                VStack(spacing: 4) {
                    Image(systemName: "basket.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color.tint)
                        .frame(width: 46, height: 40)
                        .background(
                            color.tint.opacity(isActive ? 0.22 : 0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isActive ? color.tint : .clear, lineWidth: 2)
                        }
                    Text("\(count(color))")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? .primary : .secondary)
                }
                .scaleEffect(isActive ? 1.08 : 1)
            }
        }
        .padding(12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
