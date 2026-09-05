import AppKit
import Combine
import SwiftUI

enum LockedMediaPresentationPolicy {
    enum Content: Equatable {
        case none
        case compactMedia
        case activityStack
    }

    static func content(
        mediaOptedIn: Bool,
        hasMediaContent: Bool,
        activityStackOptedIn: Bool,
        hasActivityContent: Bool,
        isPrimaryDisplay: Bool = true
    ) -> Content {
        // A playing track wins over the stack. The song card is the one the
        // user is looking for at a locked screen, and the stack renders in the
        // notch band at the top of the display where it went unnoticed; the
        // stack still owns the screen whenever there is no track to show.
        if mediaOptedIn, hasMediaContent, isPrimaryDisplay {
            return .compactMedia
        }
        // Activity cards may still be useful on another display, but the song
        // itself belongs only on the configured Main Display. Media alone must
        // never create an external stack containing a second player.
        if activityStackOptedIn,
           hasActivityContent || (hasMediaContent && isPrimaryDisplay) {
            return .activityStack
        }
        return .none
    }

    static func effectiveActivity(
        sessionIsActive: Bool,
        currentActivity: NotchActivity,
        mediaOptedIn: Bool,
        hasMediaContent: Bool,
        activityStackOptedIn: Bool = false,
        hasActivityContent: Bool = false,
        isPrimaryDisplay: Bool = true
    ) -> NotchActivity {
        guard !sessionIsActive else { return currentActivity }
        return content(
            mediaOptedIn: mediaOptedIn,
            hasMediaContent: hasMediaContent,
            activityStackOptedIn: activityStackOptedIn,
            hasActivityContent: hasActivityContent,
            isPrimaryDisplay: isPrimaryDisplay
        ) == .none ? .idle : .media
    }

    static func shouldShowPanel(
        sessionIsActive: Bool,
        screenIsLocked: Bool = true,
        activity: NotchActivity,
        mediaOptedIn: Bool,
        hasMediaContent: Bool,
        activityStackOptedIn: Bool = false,
        hasActivityContent: Bool = false,
        isPrimaryDisplay: Bool = true
    ) -> Bool {
        if sessionIsActive { return true }
        // `sessionDidResignActive` arrives before loginwindow publishes the
        // secure-lock signal (and also covers Fast User Switching). Showing the
        // card in that gap flashes the Lock Screen layout on the ordinary
        // desktop. Only the narrower secure-lock state may reveal it.
        guard screenIsLocked else { return false }
        return effectiveActivity(
            sessionIsActive: false,
            currentActivity: activity,
            mediaOptedIn: mediaOptedIn,
            hasMediaContent: hasMediaContent,
            activityStackOptedIn: activityStackOptedIn,
            hasActivityContent: hasActivityContent,
            isPrimaryDisplay: isPrimaryDisplay
        ) == .media
    }

    /// Either opt-in permits the panel to draw over loginwindow. Neither one
    /// makes it interactive: `acceptsInput` stays false for a locked session.
    static func canBecomeVisibleWithoutLogin(
        mediaOptedIn: Bool,
        activityStackOptedIn: Bool
    ) -> Bool {
        mediaOptedIn || activityStackOptedIn
    }

    static func acceptsInput(sessionIsActive: Bool) -> Bool { sessionIsActive }
}

/// One display's notch, from the UI's point of view.
public struct NotchDisplayContext: Sendable, Equatable, Identifiable {
    public var displayID: CGDirectDisplayID
    public var metrics: NotchMetrics
    public var isPrimary: Bool
    public var isBuiltIn: Bool

    public var id: CGDirectDisplayID { displayID }
}

/// Owns one `NotchPanel` per active display, keeps them positioned across
/// hot-plugs, sleep/wake, resolution changes and Space switches, and routes
/// hover state back to the app.
@MainActor
public final class NotchWindowController {

    /// Keeps the click-through panel in sync with fast pointer movement. At
    /// 150 ms a click could land before the panel noticed that the pointer had
    /// re-entered the expanded island; 50 ms closes that practical race while
    /// the poll still runs only during interaction at the top of the display.
    static let presencePollInterval: TimeInterval = 0.05

    /// Cadence for the same poll while the pointer is nowhere near the notch.
    ///
    /// Media alone arms the poll, and media plays for hours, so the fast rate
    /// was sampling the pointer twenty times a second all day to keep concluding
    /// it is still at the bottom of the screen. Out there the global mouse
    /// monitor is doing the real work — it only goes blind once the pointer is
    /// over one of our own panels — so this rate is a backstop, not the
    /// mechanism, and an approach is noticed by the monitor long before the
    /// pointer arrives.
    static let idlePresencePollInterval: TimeInterval = 0.25

    /// How close to the notch counts as an approach, in points. Sized to cover
    /// the widest island comfortably: the deadlock this poll exists to break
    /// happens when the pointer is already inside the island's interactive rect
    /// without having acquired hover, and that is exactly where both monitors
    /// stop reporting.
    static let presenceApproachBand: CGFloat = 160

    private struct PanelEntry {
        var panel: NotchPanel
        var hosting: NSHostingView<AnyView>
        var context: NotchDisplayContext
    }

    private var entries: [CGDirectDisplayID: PanelEntry] = [:]
    private var mouseMonitors: [Any] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var rebuildWorkItem: DispatchWorkItem?
    private var presenceTimer: Timer?
    /// Re-asserts the locked card's level and ordering while the shield is up.
    ///
    /// loginwindow raises its shield *after* it posts `com.apple.screenIsLocked`,
    /// and it re-orders the display when it redraws — a wake, a failed unlock,
    /// a second display coming back. A card ordered once at the moment of the
    /// notification can therefore end up behind a shield that appeared after
    /// it, which looks exactly like the card never being drawn at all.
    private var lockedPresenceTimer: Timer?
    /// Cadence the live timer was created with, so a tick that changes nothing
    /// does not tear the timer down and build it again.
    private var presenceTimerInterval: TimeInterval?
    /// Whether the pointer is inside any panel's interactive rect, and so
    /// whether that panel is currently swallowing mouse events.
    private var isPointerOverIsland = false
    private var isSessionActive = true
    /// Unlike a workspace resign (which also covers Fast User Switching), this
    /// is true only after loginwindow publishes its secure-lock signal.
    private var isScreenLocked = false

    private let lockScreenSpace = LockScreenSpaceBridge.shared

    private let makeContent: (NotchDisplayContext) -> AnyView

    /// Called with the display under the pointer (or nil) whenever hover changes.
    public var onHoverChange: ((CGDirectDisplayID?) -> Void)?
    /// A click in the physical notch trigger band. The cutout itself has no
    /// pixels for SwiftUI to hit-test, so AppKit must bridge this deliberate
    /// action into the coordinator.
    public var onTriggerClick: ((CGDirectDisplayID) -> Void)?
    /// Lets the coordinator fail open whenever no notch panel can render the
    /// custom replacement for a suppressed system OSD.
    public var onPanelAvailabilityChange: ((Bool) -> Void)?

    /// Display the pointer is currently over the island of.
    public private(set) var hoveredDisplayID: CGDirectDisplayID?

    /// Display that should own transient UI — the hovered one, else the one
    /// with the pointer, else the main screen.
    public var activeDisplayID: CGDirectDisplayID? {
        if let hoveredDisplayID, entries[hoveredDisplayID] != nil {
            return hoveredDisplayID
        }
        let mouse = NSEvent.mouseLocation
        if let screen = ScreenLookup.screen(containingCocoaPoint: mouse),
           let id = ScreenLookup.displayID(for: screen),
           entries[id] != nil {
            return id
        }
        if let main = NSScreen.main.flatMap({ ScreenLookup.displayID(for: $0) }),
           entries[main] != nil {
            return main
        }
        return entries.keys.sorted().first
    }

    public var hasRenderablePanel: Bool { !entries.isEmpty }

    private var currentActivity: NotchActivity = .idle
    private var isPeeking = false
    private var resultCount = 0
    private var hasStack = false
    private var hasMediaContent = false
    private var hasLockedActivityContent = false
    private var mediaPanelRowCount = 0

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
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        presenceTimerInterval = nil
        lockedPresenceTimer?.invalidate()
        lockedPresenceTimer = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        for observer in applicationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        applicationObservers.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
        for entry in entries.values {
            WindowExclusionRegistry.shared.unregister(entry.panel)
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
        lockScreenSpace.resetAttachedWindows()
        LockedMediaNotificationController.shared.clear()
        LockedMediaNotificationController.shared.setCustomPresentationAvailable(false)
        onPanelAvailabilityChange?(false)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        applicationObservers.append(center.addObserver(
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
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name != NSWorkspace.activeSpaceDidChangeNotification, self?.isScreenLocked == true {
                        self?.lockScreenSpace.refreshPresentation()
                    }
                    self?.scheduleRebuild()
                }
            })
        }
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionActive(false) }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScreenLocked(false) }
        })

        let distributed = DistributedNotificationCenter.default()
        for name in [ScreenLockSignal.lockedNotification, ScreenLockSignal.unlockedNotification] {
            distributedObservers.append(distributed.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let active = ScreenLockSignal.sessionIsActive(for: name) else {
                        return
                    }
                    self?.setScreenLocked(!active)
                }
            })
        }
    }

    private func setScreenLocked(_ locked: Bool) {
        let lockStateChanged = locked != isScreenLocked
        isScreenLocked = locked
        let sessionStateChanged = (isSessionActive == locked)
        setSessionActive(!locked)
        // The workspace session normally resigns just before the narrower
        // secure-lock notification. In that common ordering the active state
        // is already false, so the lock event still has to attach and redraw.
        if lockStateChanged, !sessionStateChanged {
            if !locked, rebuildPanelsAfterLockSpaceIfNeeded() { return }
            applyLayout()
        }
    }

    private func setSessionActive(_ active: Bool) {
        guard active != isSessionActive else { return }
        isSessionActive = active
        Log.window.notice(
            "Session \(active ? "active" : "inactive"); panels: \(self.entries.count), locked opt-in: \(self.allowsLockedPresentation), media available: \(self.hasMediaContent)"
        )
        if !active {
            hoveredDisplayID = nil
            isPointerOverIsland = false
            isPeeking = false
            onHoverChange?(nil)
        }
        if active, rebuildPanelsAfterLockSpaceIfNeeded() { return }
        applyLayout()
        if active { scheduleRebuild() }
    }

    /// SkyLight moves an attached panel out of its ordinary user Spaces. A
    /// fresh AppKit panel after unlock is both safer and less dependent on
    /// undocumented inverse flags than trying to move that window back.
    @discardableResult
    private func rebuildPanelsAfterLockSpaceIfNeeded() -> Bool {
        let needsRebuild = lockScreenSpace.hasAttachedWindows
        // An exhausted setup attempt may have attached no windows. Reset its
        // retry budget on unlock too, so the next lock gets a fresh attempt.
        lockScreenSpace.resetAttachedWindows()
        LockedMediaNotificationController.shared.clear()
        LockedMediaNotificationController.shared.setCustomPresentationAvailable(false)
        guard needsRebuild else { return false }
        for entry in entries.values {
            WindowExclusionRegistry.shared.unregister(entry.panel)
            entry.panel.orderOut(nil)
            // An SLS-attached surface can remain in the private Space even
            // after `orderOut`. Destroy the old WindowServer surface before
            // rebuilding so the next lock cannot resurrect a stale card on a
            // previous display or at its previous frame.
            entry.panel.contentView = nil
            entry.panel.close()
        }
        entries.removeAll()
        rebuildPanels()
        Log.window.notice("Rebuilt notch panels after leaving the Lock Screen Space")
        return true
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
        let previouslyAvailable = hasRenderablePanel
        defer {
            if hasRenderablePanel != previouslyAvailable {
                onPanelAvailabilityChange?(hasRenderablePanel)
            }
        }
        guard Preferences.shared.notchEnabled else {
            for entry in entries.values {
                WindowExclusionRegistry.shared.unregister(entry.panel)
                entry.panel.orderOut(nil)
            }
            entries.removeAll()
            return
        }

        let placement = Preferences.shared.notchDisplayPlacement
        // `NSScreen.main` follows the key window and can change as loginwindow
        // takes focus. The configured Main Display is the stable CoreGraphics
        // display with the menu bar; using it prevents the song card from
        // jumping to an external monitor during the lock transition.
        let mainDisplayID = CGMainDisplayID()

        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let displayID = ScreenLookup.displayID(for: screen) else { continue }
            let metrics = NotchMetrics.metrics(for: screen)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

            // Hardware identity, not the user's Main Display arrangement,
            // determines whether this is the MacBook's own panel.
            guard placement.includesDisplay(isBuiltIn: isBuiltIn) else { continue }

            seen.insert(displayID)
            let context = NotchDisplayContext(
                displayID: displayID,
                metrics: metrics,
                isPrimary: displayID == mainDisplayID,
                isBuiltIn: isBuiltIn
            )

            if var entry = entries[displayID] {
                entry.context = context
                entry.hosting.rootView = makeContent(context)
                position(panel: entry.panel, for: context)
                entries[displayID] = entry
            } else {
                let panel = NotchPanel(contentRect: panelFrame(for: metrics))
                panel.canBecomeVisibleWithoutLogin = allowsLockedPresentation
                let hosting = NSHostingView(rootView: makeContent(context))
                hosting.translatesAutoresizingMaskIntoConstraints = true
                hosting.autoresizingMask = [.width, .height]
                hosting.frame = CGRect(origin: .zero, size: panel.frame.size)
                panel.contentView = hosting
                applyVisibilityPolicy(to: panel, context: context)
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
            // Anchor the fixed panel to the hardware gap rather than assuming
            // an odd-width notch is centred on a whole point. SwiftUI centres
            // the island inside this panel, so this keeps drawing, hover, and
            // AppKit click bridging on the same physical pixels.
            x: metrics.notchCenterX - width / 2,
            y: metrics.screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The frame this panel should occupy right now.
    ///
    /// While locked with the song card showing, that is not the notch: the card
    /// moves into the lower-middle part of the screen, clear of the password field.
    private func targetFrame(for context: NotchDisplayContext) -> CGRect {
        // Only the song card moves. The activity stack is laid out against the
        // notch band and would clip in the narrower card frame.
        guard isScreenLocked,
              !isSessionActive,
              lockedContent(for: context) == .compactMedia else {
            return panelFrame(for: context.metrics)
        }
        return LockedCardGeometry.panelFrame(in: context.metrics.screenFrame)
    }

    private func lockedContent(
        for context: NotchDisplayContext
    ) -> LockedMediaPresentationPolicy.Content {
        LockedMediaPresentationPolicy.content(
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            hasMediaContent: hasMediaContent,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
            hasActivityContent: hasLockedActivityContent,
            isPrimaryDisplay: context.isPrimary
        )
    }

    private func position(panel: NotchPanel, for context: NotchDisplayContext) {
        let frame = targetFrame(for: context)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        }
        // Re-assert the level: a Space change or fullscreen transition can drop
        // a panel behind the menu bar.
        panel.level = NotchPanel.notchLevel
        applyVisibilityPolicy(to: panel, context: context)
    }

    // MARK: Layout / hit testing

    public func update(
        activity: NotchActivity,
        isPeeking: Bool,
        resultCount: Int,
        hasStack: Bool,
        hasMediaContent: Bool,
        hasLockedActivityContent: Bool,
        mediaPanelRowCount: Int = 0
    ) {
        self.currentActivity = activity
        self.isPeeking = isPeeking
        self.resultCount = resultCount
        self.hasStack = hasStack
        self.hasMediaContent = hasMediaContent
        self.hasLockedActivityContent = hasLockedActivityContent
        self.mediaPanelRowCount = mediaPanelRowCount
        applyLayout()
    }

    /// The island a display should currently draw.
    private func currentLayout(for context: NotchDisplayContext) -> NotchLayout {
        NotchLayout.layout(
            for: effectiveActivity(for: context),
            metrics: context.metrics,
            isPeeking: isPeeking && context.displayID == activeDisplayID,
            resultCount: resultCount,
            hasStack: hasStack,
            mediaPanelRows: mediaPanelRowCount
        )
    }

    /// Updates click-through regions. Deliberately does **not** re-evaluate
    /// hover: hover changes drive layout, so evaluating hover from here closes
    /// a feedback loop that makes the notch flap open on its own.
    private func applyLayout() {
        if !LockedMediaPresentationPolicy.acceptsInput(sessionIsActive: isSessionActive) {
            presenceTimer?.invalidate()
            presenceTimer = nil
            presenceTimerInterval = nil
            for entry in entries.values {
                entry.panel.level = NotchPanel.level(sessionIsActive: false)
                entry.panel.canBecomeVisibleWithoutLogin = allowsLockedPresentation
                entry.panel.setInteractiveRectFromScreenRect(.zero)
                entry.panel.ignoresMouseEvents = true
                applyFrame(to: entry)
                if isScreenLocked, shouldShowLockedPanel(on: entry.context) {
                    attachToLockScreenSpace(
                        entry.panel,
                        context: entry.context,
                        reportFailure: true
                    )
                }
                applyVisibilityPolicy(to: entry.panel, context: entry.context)
            }
            // Marked public: this is the line that says whether the card was
            // even asked for, and it is unreadable in a bug report otherwise.
            Log.window.notice("Locked presentation: show=\(self.shouldShowLockedPanel, privacy: .public), songOptIn=\(Preferences.shared.showsMediaWhileLocked, privacy: .public), stackOptIn=\(Preferences.shared.showsActivityStackWhileLocked, privacy: .public), hasMedia=\(self.hasMediaContent, privacy: .public), level=\(NotchPanel.lockedMediaLevel.rawValue, privacy: .public)")
            if isScreenLocked {
                startLockedPresenceTimer()
            } else {
                stopLockedPresenceTimer()
                LockedMediaNotificationController.shared.clear()
                LockedMediaNotificationController.shared
                    .setCustomPresentationAvailable(false)
            }
            return
        }
        stopLockedPresenceTimer()
        LockedMediaNotificationController.shared.clear()
        LockedMediaNotificationController.shared.setCustomPresentationAvailable(false)
        for entry in entries.values {
            entry.panel.level = NotchPanel.level(sessionIsActive: true)
            entry.panel.canBecomeVisibleWithoutLogin = allowsLockedPresentation
            applyFrame(to: entry)
            applyVisibilityPolicy(to: entry.panel, context: entry.context)
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
        return island.union(triggerZone(for: context))
    }

    /// The zone that *starts* a hover: the closed notch, plus whatever the notch
    /// is drawing beside it while at rest.
    ///
    /// It cannot be derived from the *live* island, because an expanded island
    /// would keep re-triggering its own hover — the notch would read as opening
    /// on its own when the user never went near it. But pinning it to the bare
    /// notch was wrong in the other direction: compact media draws artwork and a
    /// playback wave in wings 38 pt beyond the notch on each side, and only the
    /// first 6 pt of that could start a hover. The remaining band was visible,
    /// looked live, and did nothing — and because the wings are inside
    /// `interactiveRect`, the panel there stops ignoring mouse events, which
    /// blinds the global monitor (the pointer is over our own window) while the
    /// local one stays silent (a nonactivating panel is never key). Reaching for
    /// the wave was the one approach that could not open the notch.
    ///
    /// So the trigger follows the *resting* island — what the user is actually
    /// looking at when they reach for it — and falls back to the bare notch
    /// whenever that resting layout is itself an opened one.
    private func triggerZone(for context: NotchDisplayContext) -> CGRect {
        let layout = restingLayout(for: context)
        return Self.triggerZone(
            notchRect: context.metrics.notchRect,
            restingIsland: layout.island.islandRect(in: context.metrics),
            isExpanded: layout.activity.isExpanded
        )
    }

    /// The geometry on its own, so the wings can be shown to be reachable
    /// without standing up a display.
    nonisolated static func triggerZone(
        notchRect: CGRect,
        restingIsland: CGRect,
        isExpanded: Bool
    ) -> CGRect {
        let base = notchRect.insetBy(dx: -6, dy: -4)
        return isExpanded ? base : base.union(restingIsland)
    }

    /// The island as drawn when nothing is hovering it, paired with the activity
    /// that produced it so callers can tell a resting island from an open one.
    private func restingLayout(
        for context: NotchDisplayContext
    ) -> (island: NotchLayout, activity: NotchActivity) {
        let activity = effectiveActivity(for: context)
        return (
            NotchLayout.layout(
                for: activity,
                metrics: context.metrics,
                isPeeking: false,
                resultCount: resultCount,
                hasStack: hasStack
            ),
            activity
        )
    }

    /// Only the display the user is working on expands; the rest stay in their
    /// closed state so a second monitor doesn't grow a panel.
    private func effectiveActivity(for context: NotchDisplayContext) -> NotchActivity {
        if !isSessionActive {
            return LockedMediaPresentationPolicy.effectiveActivity(
                sessionIsActive: false,
                currentActivity: currentActivity,
                mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
                hasMediaContent: hasMediaContent,
                activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
                hasActivityContent: hasLockedActivityContent,
                isPrimaryDisplay: context.isPrimary
            )
        }
        if case .dictation(let snap) = currentActivity, let did = snap.displayID {
            return context.displayID == did ? currentActivity : .idle
        }
        let isActive = context.displayID == activeDisplayID
        if isActive { return currentActivity }
        if currentActivity == .media { return .media }
        if Preferences.shared.mirrorsPassiveContextOnAllDisplays,
           case .context = currentActivity {
            return currentActivity
        }
        return .idle
    }

    /// The zone that *sustains* an existing hover — the island as drawn, with a
    /// little slack. Wider than the trigger zone on purpose: easy to keep, and
    /// deliberate to start.
    private func keepAliveZone(for context: NotchDisplayContext) -> CGRect {
        currentLayout(for: context)
            .islandRect(in: context.metrics)
            .insetBy(dx: -8, dy: -8)
            .union(triggerZone(for: context))
    }

    private func installMouseMonitors() {
        let matching: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDragged, .mouseExited,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: matching, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event, at: NSEvent.mouseLocation) }
        }) {
            mouseMonitors.append(global)
        }
        // The global monitor stops firing once one of our panels is key, so a
        // local monitor keeps hover accurate while the user is in the notch.
        if let local = NSEvent.addLocalMonitorForEvents(matching: matching, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event, at: NSEvent.mouseLocation) }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func handleMouseEvent(_ event: NSEvent, at screenPoint: CGPoint) {
        guard LockedMediaPresentationPolicy.acceptsInput(sessionIsActive: isSessionActive) else { return }
        updateHover(at: screenPoint)
        guard event.type == .leftMouseDown else { return }
        let acceptsTriggerClick: Bool = switch currentActivity {
        case .idle, .media, .context: true
        default: false
        }
        guard !isPeeking, acceptsTriggerClick else { return }
        // Normal visible pixels are handled by SwiftUI. Bridging those here as
        // well would deliver one click twice and toggle the notch open and then
        // immediately closed. Only the physical camera cutout has no view that
        // can receive the click, so only that exact region needs AppKit help.
        for (displayID, entry) in entries where Self.shouldBridgeTriggerClick(
            at: screenPoint,
            metrics: entry.context.metrics
        ) {
            onTriggerClick?(displayID)
            return
        }
    }

    static func shouldBridgeTriggerClick(at point: CGPoint, metrics: NotchMetrics) -> Bool {
        metrics.hasPhysicalNotch && metrics.notchRect.contains(point)
    }

    /// Resolves which display's island the pointer is over, with hysteresis so
    /// a pointer resting on the boundary can't oscillate.
    private func updateHover(at screenPoint: CGPoint) {
        var newHover: CGDirectDisplayID?
        for (displayID, entry) in entries {
            // Hover zones are all anchored to the top centre and never extend
            // more than ~450 pt below the menu bar (440 pt max island + 8 pt
            // keep-alive slack). A point on the bottom half of the screen can't
            // be hover, so avoid building a NotchLayout for it at all.
            let topStripMaxY = entry.context.metrics.screenFrame.maxY
            if screenPoint.y < topStripMaxY - 500 { continue }
            // If the point isn't even on this display, its top strip can't
            // contain it either.
            if !entry.context.metrics.screenFrame.contains(screenPoint) {
                // Allow a 8 pt slack beyond the frame edge for keep-alive hysteresis
                // before dismissing outright.
                let slackFrame = entry.context.metrics.screenFrame.insetBy(dx: -8, dy: -8)
                if !slackFrame.contains(screenPoint) { continue }
            }
            let zone = hoveredDisplayID == displayID
                ? keepAliveZone(for: entry.context)
                : triggerZone(for: entry.context)
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
        var overIsland = false
        for entry in entries.values {
            if entry.panel.updateMouseTransparency(screenPoint: point) {
                overIsland = true
            }
        }
        guard overIsland != isPointerOverIsland else { return }
        isPointerOverIsland = overIsland
        // The panel just changed whether it swallows mouse events, which changes
        // whether the monitors can still see the pointer at all.
        updatePresencePoll()
    }

    // MARK: Presence poll

    /// While the notch is open — or the pointer is anywhere over the island — a
    /// poll confirms where the pointer actually is.
    ///
    /// Mouse-move events stop arriving if the pointer ends up over a window
    /// that swallows them, or leaves via a screen edge — without this the notch
    /// can stay stuck open with the pointer nowhere near it.
    ///
    /// `isPointerOverIsland` is in the condition because of a deadlock that made
    /// hover fail to *start*. The island is wider than the trigger zone whenever
    /// the notch shows media or is expanded, so the pointer can sit inside the
    /// interactive rect without having acquired hover. At that moment the panel
    /// stops ignoring mouse events — and that blinds both monitors: the global
    /// one no longer fires because the pointer is over our own window, and the
    /// local one gets no `mouseMoved` because AppKit only sends those to the key
    /// window, which a nonactivating panel is not. Nothing was left to notice
    /// the pointer reaching the notch, so hover never began. Approaching across
    /// that band is what made it look intermittent and side-dependent.
    ///
    /// An idle notch does not poll at all, and a notch showing media polls
    /// slowly until the pointer comes near.
    private func updatePresencePoll(pointerLocation: CGPoint? = nil) {
        let needsPoll = Self.shouldPollPresence(
            activity: currentActivity,
            isPeeking: isPeeking,
            isPointerOverIsland: isPointerOverIsland,
            hasHoveredDisplay: hoveredDisplayID != nil
        )
        guard needsPoll else {
            presenceTimer?.invalidate()
            presenceTimer = nil
            presenceTimerInterval = nil
            return
        }

        // Fast enough to feel like hover, not a poll: the peek delay alone is
        // 0.35s, so this must not be the slower of the two — but only where that
        // responsiveness is capable of mattering.
        let interval = Self.presencePollInterval(
            isEngaged: hoveredDisplayID != nil
                || currentActivity.isExpanded
                || isPeeking
                || isPointerOverIsland,
            isPointerNearNotch: isPointerNearNotch(pointerLocation ?? NSEvent.mouseLocation)
        )
        guard presenceTimer == nil || presenceTimerInterval != interval else { return }

        presenceTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let location = NSEvent.mouseLocation
                self.updateHover(at: location)
                // Re-evaluated every tick because proximity changes on its own,
                // without any of the state transitions that call in here.
                self.updatePresencePoll(pointerLocation: location)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
        presenceTimerInterval = interval
    }

    /// Full rate while the notch is open or the pointer is close enough to
    /// reach it before the next slow tick; the backstop rate otherwise.
    static func presencePollInterval(
        isEngaged: Bool,
        isPointerNearNotch: Bool
    ) -> TimeInterval {
        isEngaged || isPointerNearNotch ? presencePollInterval : idlePresencePollInterval
    }

    private func isPointerNearNotch(_ point: CGPoint) -> Bool {
        entries.values.contains { entry in
            triggerZone(for: entry.context)
                .insetBy(dx: -Self.presenceApproachBand, dy: -Self.presenceApproachBand)
                .contains(point)
        }
    }

    /// Media keeps the low-cost pointer poll armed before hover begins. Without
    /// it, a fast move-and-click can reach a click-through panel before the
    /// global mouse monitor has switched that panel back to interactive.
    static func shouldPollPresence(
        activity: NotchActivity,
        isPeeking: Bool,
        isPointerOverIsland: Bool,
        hasHoveredDisplay: Bool
    ) -> Bool {
        let hasCompactContext: Bool = if case .context = activity { true } else { false }
        return hasHoveredDisplay
            || activity.isExpanded
            || activity == .media
            || hasCompactContext
            || isPeeking
            || isPointerOverIsland
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
            position(panel: entry.panel, for: entry.context)
        }
        applyLayout()
    }

    /// Re-applies the lock-window opt-in immediately after Settings changes.
    public func refreshLockedPresentation() {
        for entry in entries.values {
            entry.panel.level = NotchPanel.level(sessionIsActive: isSessionActive)
            entry.panel.canBecomeVisibleWithoutLogin = allowsLockedPresentation
        }
        applyLayout()
    }

    public func refreshLockedMediaPresentation() { refreshLockedPresentation() }

    /// Whether the locked card is currently wanted on screen.
    private var shouldShowLockedPanel: Bool {
        entries.values.contains { shouldShowLockedPanel(on: $0.context) }
    }

    private func shouldShowLockedPanel(on context: NotchDisplayContext) -> Bool {
        LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: isSessionActive,
            screenIsLocked: isScreenLocked,
            activity: currentActivity,
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            hasMediaContent: hasMediaContent,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
            hasActivityContent: hasLockedActivityContent,
            isPrimaryDisplay: context.isPrimary
        )
    }

    private func applyFrame(to entry: PanelEntry) {
        let frame = targetFrame(for: entry.context)
        guard entry.panel.frame != frame else { return }
        entry.panel.setFrame(frame, display: true)
        entry.panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
    }

    private func startLockedPresenceTimer() {
        guard lockedPresenceTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSessionActive else { return }
                guard self.shouldShowLockedPanel else { return }
                for entry in self.entries.values {
                    guard self.shouldShowLockedPanel(on: entry.context) else {
                        entry.panel.orderOut(nil)
                        continue
                    }
                    entry.panel.level = NotchPanel.lockedMediaLevel
                    self.applyFrame(to: entry)
                    if self.isScreenLocked {
                        self.attachToLockScreenSpace(
                            entry.panel,
                            context: entry.context,
                            reportFailure: false
                        )
                    }
                    entry.panel.orderFrontRegardless()
                }
            }
        }
        // Common mode so the tick survives a tracking loop, and tolerant so a
        // locked, throttled app never stacks up missed fires.
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        lockedPresenceTimer = timer
    }

    private func attachToLockScreenSpace(
        _ panel: NotchPanel,
        context: NotchDisplayContext,
        reportFailure: Bool
    ) {
        let isPrimaryMediaCard = lockedContent(for: context) == .compactMedia
        switch lockScreenSpace.attach(panel) {
        case .attached(let spaceID):
            if isPrimaryMediaCard {
                LockedMediaNotificationController.shared
                    .setCustomPresentationAvailable(true)
            }
            Log.window.notice(
                "Attached Lock Screen card window \(panel.windowNumber, privacy: .public) to Space \(spaceID, privacy: .public)"
            )
        case .alreadyAttached:
            if isPrimaryMediaCard {
                LockedMediaNotificationController.shared
                    .setCustomPresentationAvailable(true)
            }
        case .unavailable:
            if isPrimaryMediaCard {
                LockedMediaNotificationController.shared
                    .setCustomPresentationAvailable(false)
            }
            if reportFailure {
                Log.window.error(
                    "Lock Screen Space APIs are unavailable; using the system notification fallback"
                )
            }
        case .failed(let operation, let code):
            if isPrimaryMediaCard {
                LockedMediaNotificationController.shared
                    .setCustomPresentationAvailable(false)
            }
            if reportFailure {
                Log.window.error(
                    "Lock Screen Space operation \(operation, privacy: .public) failed with code \(code, privacy: .public); using the system notification fallback"
                )
            }
        }
    }

    private func stopLockedPresenceTimer() {
        lockedPresenceTimer?.invalidate()
        lockedPresenceTimer = nil
    }

    private func applyVisibilityPolicy(
        to panel: NotchPanel,
        context: NotchDisplayContext
    ) {
        if LockedMediaPresentationPolicy.shouldShowPanel(
            sessionIsActive: isSessionActive,
            screenIsLocked: isScreenLocked,
            activity: currentActivity,
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            hasMediaContent: hasMediaContent,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked,
            hasActivityContent: hasLockedActivityContent,
            isPrimaryDisplay: context.isPrimary
        ) {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var allowsLockedPresentation: Bool {
        LockedMediaPresentationPolicy.canBecomeVisibleWithoutLogin(
            mediaOptedIn: Preferences.shared.showsMediaWhileLocked,
            activityStackOptedIn: Preferences.shared.showsActivityStackWhileLocked
        )
    }

    public func resignFocus() {
        for entry in entries.values where entry.panel.isKeyWindow {
            entry.panel.resignKey()
        }
    }
}
