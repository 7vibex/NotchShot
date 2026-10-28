import AppKit
import SwiftUI

/// The window behind the menu-bar mascot.
///
/// A borderless panel rather than an `NSPopover` or `NSMenu`: both draw the
/// system's own chrome, and this menu should look like the island it controls.
/// It is non-activating for the same reason `NotchPanel` is — opening it must
/// not pull focus from the app the user is about to capture.
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge; a window shadow traced from the
        // translucent content would outline it a second time.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Key so Escape and the toggles work; never main, so it never competes
    // with Settings or the editor.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Opens, places and dismisses the menu-bar panel.
@MainActor
final class MenuBarPanelController {
    /// Gap between the bottom of the menu bar and the top of the panel, as
    /// the system leaves under its own menus.
    private static let menuBarGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    private let panel = MenuBarPanel()
    private weak var button: NSStatusBarButton?
    private let makeContent: (_ dismiss: @escaping () -> Void) -> AnyView
    private var outsideClickMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    /// Bumped on every open so a fade-out that finishes after a reopen does
    /// not order the new panel out.
    private var generation = 0
    private var lastClosed = Date.distantPast

    private(set) var isOpen = false

    init(button: NSStatusBarButton, content: @escaping (_ dismiss: @escaping () -> Void) -> AnyView) {
        self.button = button
        self.makeContent = content
        panel.onCancel = { [weak self] in self?.close(animated: true) }
    }

    func toggle() {
        if isOpen {
            close(animated: true)
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            // A click on the mascot can take key from the panel and close it
            // a moment before the click's own action arrives here; reopening
            // then would make the mascot unable to close its own menu.
            open()
        }
    }

    func open() {
        guard !isOpen, let button, let buttonWindow = button.window else { return }
        isOpen = true
        generation += 1

        // A fresh view per opening, so the content's entrance animation runs
        // each time and counts are read when the menu is looked at.
        let hosting = NSHostingView(rootView: makeContent { [weak self] in
            self?.close(animated: false)
        })
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(
            max(anchor.midX - size.width / 2, visible.minX + Self.screenMargin),
            visible.maxX - size.width - Self.screenMargin
        )
        let frame = CGRect(
            x: x,
            y: anchor.minY - Self.menuBarGap - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        // The button's own mouse tracking clears the highlight when the click
        // ends, which is after this runs. Default mode only comes back once
        // that tracking loop has finished.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.button?.highlight(true)
            }
        }
        installDismissTriggers()
    }

    /// - Parameter animated: false when an action in the menu closed it. A
    ///   capture that starts while the panel is still fading would freeze it
    ///   into the selection overlay's backdrop.
    func close(animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        lastClosed = Date()
        removeDismissTriggers()
        button?.highlight(false)

        guard animated else {
            orderOut(ifStillClosedAfter: generation)
            return
        }
        let closingGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(ifStillClosedAfter: closingGeneration) }
        })
    }

    private func orderOut(ifStillClosedAfter closingGeneration: Int) {
        guard generation == closingGeneration, !isOpen else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func installDismissTriggers() {
        // Clicks in other apps. Clicks on the mascot itself arrive as the
        // status item's action and toggle the panel closed there.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: true) }
        }
        // Clicks in NotchShot's own windows, Command-Tab, and Mission Control
        // all take key away. A submenu opened from the panel does not.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: true) }
        }
    }

    private func removeDismissTriggers() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
    }
}
