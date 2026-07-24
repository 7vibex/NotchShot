import AppKit
import Combine
import SwiftUI

/// One display's notch, from the UI's point of view.
public struct NotchDisplayContext: Sendable, Equatable, Identifiable {
    public var displayID: CGDirectDisplayID
    public var metrics: NotchMetrics
    public var isPrimary: Bool

    public var id: CGDirectDisplayID { displayID }
}

/// Owns one `NotchPanel` per active display, keeps them positioned across
/// hot-plugs, sleep/wake, resolution changes and Space switches, and routes
/// hover state back to the app.
@MainActor
public final class NotchWindowController {

    private struct PanelEntry {
        var panel: NotchPanel
        var hosting: NSHostingView<AnyView>
        var context: NotchDisplayContext
    }

    private var entries: [CGDirectDisplayID: PanelEntry] = [:]
    private var mouseMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var rebuildWorkItem: DispatchWorkItem?
    private var presenceTimer: Timer?

    private let makeContent: (NotchDisplayContext) -> AnyView

    /// Called with the display under the pointer (or nil) whenever hover changes.
    public var onHoverChange: ((CGDirectDisplayID?) -> Void)?

    /// Display the pointer is currently over the island of.
    public private(set) var hoveredDisplayID: CGDirectDisplayID?

    /// Display that should own transient UI — the hovered one, else the one
    /// with the pointer, else the main screen.
    public var activeDisplayID: CGDirectDisplayID? {
        if let hoveredDisplayID { return hoveredDisplayID }
        let mouse = NSEvent.mouseLocation
        if let screen = ScreenLookup.screen(containingCocoaPoint: mouse),
           let id = ScreenLookup.displayID(for: screen) {
            return id
        }
        return NSScreen.main.flatMap { ScreenLookup.displayID(for: $0) }
    }

    private var currentActivity: NotchActivity = .idle
    private var isPeeking = false
    private var resultCount = 0
    private var hasStack = false

    public init(makeContent: @escaping (NotchDisplayContext) -> AnyView) {
        self.makeContent = makeContent
    }

    // MARK: Lifecycle

    public func start() {
        rebuildPanels()
        installObservers()
        installMouseMonitors()
    }

    public func stop() {
        presenceTimer?.invalidate()
        presenceTimer = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers.removeAll()
        for entry in entries.values {
            WindowExclusionRegistry.shared.unregister(entry.panel)
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            })
        }
    }

    /// Screen-parameter notifications arrive in bursts while a display wakes or
    /// changes mode; coalescing avoids rebuilding panels a dozen times.
    private func scheduleRebuild() {
        rebuildWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        rebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    // MARK: Panels

    public func rebuildPanels() {
        guard Preferences.shared.notchEnabled else {
            for entry in entries.values {
                WindowExclusionRegistry.shared.unregister(entry.panel)
                entry.panel.orderOut(nil)
            }
            entries.removeAll()
            return
        }

        let showExternal = Preferences.shared.showsIslandOnExternalDisplays
        let mainDisplayID = NSScreen.main.flatMap { ScreenLookup.displayID(for: $0) }

        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let displayID = ScreenLookup.displayID(for: screen) else { continue }
            let metrics = NotchMetrics.metrics(for: screen)

            // A notchless secondary display only gets an island if the user
            // asked for one; the built-in notch always gets one.
            if !metrics.hasPhysicalNotch && !showExternal && displayID != mainDisplayID { continue }

            seen.insert(displayID)
            let context = NotchDisplayContext(
                displayID: displayID,
                metrics: metrics,
                isPrimary: displayID == mainDisplayID
            )

            if var entry = entries[displayID] {
                entry.context = context
                entry.hosting.rootView = makeContent(context)
                position(panel: entry.panel, for: metrics)
                entries[displayID] = entry
            } else {
                let panel = NotchPanel(contentRect: panelFrame(for: metrics))
                let hosting = NSHostingView(rootView: makeContent(context))
                hosting.translatesAutoresizingMaskIntoConstraints = true
                hosting.autoresizingMask = [.width, .height]
                hosting.frame = CGRect(origin: .zero, size: panel.frame.size)
                panel.contentView = hosting
                panel.orderFrontRegardless()
                WindowExclusionRegistry.shared.register(panel)
                entries[displayID] = PanelEntry(panel: panel, hosting: hosting, context: context)
                Log.window.info("Created notch panel for display \(displayID), notch: \(metrics.hasPhysicalNotch)")
            }
        }

        for (displayID, entry) in entries where !seen.contains(displayID) {
            WindowExclusionRegistry.shared.unregister(entry.panel)
            entry.panel.orderOut(nil)
            entries.removeValue(forKey: displayID)
            Log.window.info("Removed notch panel for disconnected display \(displayID)")
        }

        applyLayout()
    }

    /// The panel is always big enough for the largest island, so state changes
    /// animate content instead of resizing the window (which stutters and
    /// fights SwiftUI's own transitions).
    private func panelFrame(for metrics: NotchMetrics) -> CGRect {
        let width = min(
            NotchLayout.maximumSize.width + NotchLayout.shadowPadding * 2,
            metrics.screenFrame.width
        )
        let height = min(
            NotchLayout.maximumSize.height + NotchLayout.shadowPadding,
            metrics.screenFrame.height
        )
        return CGRect(
            x: metrics.screenFrame.midX - width / 2,
            y: metrics.screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func position(panel: NotchPanel, for metrics: NotchMetrics) {
        let frame = panelFrame(for: metrics)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        }
        // Re-assert the level: a Space change or fullscreen transition can drop
        // a panel behind the menu bar.
        panel.level = NotchPanel.notchLevel
        panel.orderFrontRegardless()
    }

    // MARK: Layout / hit testing

    public func update(activity: NotchActivity, isPeeking: Bool, resultCount: Int, hasStack: Bool) {
        self.currentActivity = activity
        self.isPeeking = isPeeking
        self.resultCount = resultCount
        self.hasStack = hasStack
        applyLayout()
    }

    /// The island a display should currently draw.
    private func currentLayout(for context: NotchDisplayContext) -> NotchLayout {
        // Only the display the user is working on expands; the rest stay in
        // their closed state so a second monitor doesn't grow a panel.
        let isActive = context.displayID == activeDisplayID
        let effectiveActivity: NotchActivity = isActive
            ? currentActivity
            : (currentActivity == .media ? .media : .idle)
        return NotchLayout.layout(
            for: effectiveActivity,
            metrics: context.metrics,
            isPeeking: isPeeking && isActive,
            resultCount: resultCount,
            hasStack: hasStack
        )
    }

    /// Updates click-through regions. Deliberately does **not** re-evaluate
    /// hover: hover changes drive layout, so evaluating hover from here closes
    /// a feedback loop that makes the notch flap open on its own.
    private func applyLayout() {
        for entry in entries.values {
            entry.panel.setInteractiveRectFromScreenRect(
                interactiveRect(for: entry.context)
            )
        }
        refreshMouseTransparency()
        updatePresencePoll()
    }

    /// Region that accepts clicks: the island as drawn, plus the fixed trigger
    /// zone so the closed notch is always clickable.
    private func interactiveRect(for context: NotchDisplayContext) -> CGRect {
        let island = currentLayout(for: context).islandRect(in: context.metrics)
        return island.union(triggerZone(for: context.metrics))
    }

    /// The zone that *starts* a hover.
    ///
    /// Fixed to the closed notch regardless of what the notch is currently
    /// showing. Deriving it from the live island instead means an expanded
    /// island keeps re-triggering its own hover, which reads to the user as the
    /// notch opening when they never went near it.
    private func triggerZone(for metrics: NotchMetrics) -> CGRect {
        metrics.notchRect.insetBy(dx: -6, dy: -4)
    }

    /// The zone that *sustains* an existing hover — the island as drawn, with a
    /// little slack. Wider than the trigger zone on purpose: easy to keep, and
    /// deliberate to start.
    private func keepAliveZone(for context: NotchDisplayContext) -> CGRect {
        currentLayout(for: context)
            .islandRect(in: context.metrics)
            .insetBy(dx: -8, dy: -8)
            .union(triggerZone(for: context.metrics))
    }

    private func installMouseMonitors() {
        let matching: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .mouseExited,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: matching, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
        }) {
            mouseMonitors.append(global)
        }
        // The global monitor stops firing once one of our panels is key, so a
        // local monitor keeps hover accurate while the user is in the notch.
        if let local = NSEvent.addLocalMonitorForEvents(matching: matching, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// Resolves which display's island the pointer is over, with hysteresis so
    /// a pointer resting on the boundary can't oscillate.
    private func updateHover(at screenPoint: CGPoint) {
        var newHover: CGDirectDisplayID?
        for (displayID, entry) in entries {
            let zone = hoveredDisplayID == displayID
                ? keepAliveZone(for: entry.context)
                : triggerZone(for: entry.context.metrics)
            if zone.contains(screenPoint) {
                newHover = displayID
                break
            }
        }

        refreshMouseTransparency(mouseLocation: screenPoint)

        guard newHover != hoveredDisplayID else { return }
        hoveredDisplayID = newHover
        updatePresencePoll()
        onHoverChange?(newHover)
    }

    private func refreshMouseTransparency(mouseLocation: CGPoint? = nil) {
        let point = mouseLocation ?? NSEvent.mouseLocation
        for entry in entries.values {
            entry.panel.updateMouseTransparency(screenPoint: point)
        }
    }

    // MARK: Presence poll

    /// While the notch is open, a slow poll confirms the pointer is still
    /// there.
    ///
    /// Mouse-move events stop arriving if the pointer ends up over a window
    /// that swallows them, or leaves via a screen edge — without this the notch
    /// can stay stuck open with the pointer nowhere near it. Runs only while
    /// something is open, so an idle notch still costs nothing.
    private func updatePresencePoll() {
        let needsPoll = hoveredDisplayID != nil || currentActivity.isExpanded
        if needsPoll, presenceTimer == nil {
            let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
            }
            RunLoop.main.add(timer, forMode: .common)
            presenceTimer = timer
        } else if !needsPoll, let presenceTimer {
            presenceTimer.invalidate()
            self.presenceTimer = nil
        }
    }

    // MARK: Access

    public var displayContexts: [NotchDisplayContext] {
        entries.values.map(\.context).sorted { $0.displayID < $1.displayID }
    }

    public func metrics(for displayID: CGDirectDisplayID) -> NotchMetrics? {
        entries[displayID]?.context.metrics
    }

    /// Makes the panel on the active display key so it can take keyboard input
    /// (shelf navigation, text annotation). Never activates the app.
    public func focusActivePanel() {
        guard let displayID = activeDisplayID, let entry = entries[displayID] else { return }
        entry.panel.makeKeyAndOrderFront(nil)
    }

    /// Puts every panel back on screen at the right level.
    ///
    /// Needed after anything that activates the app or takes over the display —
    /// a selection overlay, a Space switch, a fullscreen transition — any of
    /// which can leave a panel ordered out or stuck behind the menu bar.
    public func reassertPanels() {
        for entry in entries.values {
            entry.panel.level = NotchPanel.notchLevel
            entry.panel.orderFrontRegardless()
            position(panel: entry.panel, for: entry.context.metrics)
        }
        applyLayout()
    }

    public func resignFocus() {
        for entry in entries.values where entry.panel.isKeyWindow {
            entry.panel.resignKey()
        }
    }
}
