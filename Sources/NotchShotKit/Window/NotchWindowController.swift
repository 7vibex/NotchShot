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

    public func update(activity: NotchActivity, isPeeking: Bool, resultCount: Int) {
        self.currentActivity = activity
        self.isPeeking = isPeeking
        self.resultCount = resultCount
        applyLayout()
    }

    private func applyLayout() {
        for entry in entries.values {
            let metrics = entry.context.metrics
            // Only the display the user is working on expands; the rest stay
            // in their closed state so a second monitor doesn't grow a panel.
            let isActive = entry.context.displayID == activeDisplayID
            let effectiveActivity: NotchActivity = isActive ? currentActivity : (currentActivity == .media ? .media : .idle)
            let layout = NotchLayout.layout(
                for: effectiveActivity,
                metrics: metrics,
                isPeeking: isPeeking && isActive,
                resultCount: resultCount
            )
            var island = layout.islandRect(in: metrics)
            // Give the pointer a few points of slack so small mouse jitter at
            // the island's edge doesn't flicker hover off and on.
            island = island.insetBy(dx: -4, dy: -4)
            entry.panel.setInteractiveRectFromScreenRect(island)
        }
        updateHover(at: NSEvent.mouseLocation)
    }

    private func installMouseMonitors() {
        let matching: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
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

    private func updateHover(at screenPoint: CGPoint) {
        var newHover: CGDirectDisplayID?
        for (displayID, entry) in entries {
            if entry.panel.updateMouseTransparency(screenPoint: screenPoint) {
                newHover = displayID
            }
        }
        if newHover != hoveredDisplayID {
            hoveredDisplayID = newHover
            onHoverChange?(newHover)
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

    public func resignFocus() {
        for entry in entries.values where entry.panel.isKeyWindow {
            entry.panel.resignKey()
        }
    }
}
