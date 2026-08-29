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

// MARK: - Floating Basket Manager

@MainActor
@Observable
public final class FloatingBasketManager {
    public static let shared = FloatingBasketManager()

    private var window: FloatingBasketWindow?
    private var jiggle = JiggleDetector()
    private var autoHideWorkItem: DispatchWorkItem?
    private var isVisible = false
    private weak var coordinator: AppCoordinator?

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
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        isVisible = true
        scheduleAutoHide()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    public func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        window?.orderOut(nil)
        window?.unregisterFromExclusion()
        isVisible = false
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

    public init(manager: FloatingBasketManager, coordinator: AppCoordinator) {
        self.manager = manager
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 10) {
            header
            if coordinator.shelfItems.isEmpty {
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.14), lineWidth: isDropTargeted ? 2 : 1)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating Basket")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "basket.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(coordinator.shelfItems.isEmpty ? "Basket — drop files here" : "\(coordinator.shelfItems.count) \(coordinator.shelfItems.count == 1 ? "file" : "files")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if !coordinator.shelfItems.isEmpty {
                Text(totalSize)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
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
        let total = coordinator.shelfItems.reduce(Int64.zero) { partial, item in
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
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18))
                }
        }
        .animation(reduceMotion ? nil : .snappy, value: isDropTargeted)
    }

    private var itemList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                ForEach(Array(coordinator.shelfItems.enumerated()), id: \.element.id) { index, item in
                    BasketRow(item: item)
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
            .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !coordinator.shelfItems.isEmpty {
                Button("Clear Basket") {
                    for item in coordinator.shelfItems {
                        coordinator.dismissShelfItem(item)
                    }
                    manager.hide()
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
                .foregroundStyle(.secondary)
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
