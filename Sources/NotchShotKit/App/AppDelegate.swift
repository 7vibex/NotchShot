import AppKit
import ServiceManagement
import SwiftUI

/// Application lifecycle: brings up the notch panels, the menu-bar item, global
/// shortcuts, and the auxiliary windows.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = AppCoordinator()
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var editorWindows: [ObjectIdentifier: NSWindow] = [:]

    public override init() { super.init() }

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()

        NSApp.setActivationPolicy(Preferences.shared.showsDockIcon ? .regular : .accessory)

        let controller = NotchWindowController { [coordinator] context in
            AnyView(NotchRootView(coordinator: coordinator, context: context))
        }
        controller.onHoverChange = { [weak self] displayID in
            self?.coordinator.setPeeking(displayID != nil)
        }
        windowController = controller
        coordinator.windowController = controller

        coordinator.onOpenSettings = { [weak self] in self?.showSettings() }
        coordinator.onOpenHistory = { [weak self] in self?.showHistory() }
        coordinator.onOpenEditor = { [weak self] documentController in
            self?.showEditor(documentController)
        }

        controller.start()
        coordinator.start()

        HotKeyController.shared.handler = { [weak self] action in
            self?.handle(action)
        }
        HotKeyController.shared.start()

        installStatusItem()

        // Anything a crash left behind is offered back before the temp
        // directory gets swept.
        coordinator.recoverOrphanedRecordings()

        if !Preferences.shared.hasCompletedFirstRun {
            Preferences.shared.hasCompletedFirstRun = true
            showSettings()
        }

        Log.app.notice("NotchShot \(Bundle.main.shortVersion) launched")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        HotKeyController.shared.stop()
        coordinator.history.save()
        windowController?.stop()
        FloatingCaptureManager.shared.closeAll()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Opening a `.notchshot` project from the Finder.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where NotchShotPackage.isProject(url) {
            guard let controller = try? AnnotationDocumentController.open(projectAt: url) else {
                coordinator.present(error: NotchShotError.exportFailed(
                    "Couldn't open \(url.lastPathComponent)"
                ))
                continue
            }
            showEditor(controller)
        }
    }

    // MARK: Shortcuts

    private func handle(_ action: HotKeyAction) {
        switch action {
        case .captureArea: coordinator.capture(.area)
        case .captureWindow: coordinator.capture(.window)
        case .captureDisplay: coordinator.capture(.display)
        case .capturePreviousArea: coordinator.capture(.previousArea)
        case .captureScrolling: coordinator.capture(.scrolling)
        case .captureText: coordinator.capture(.ocr)
        case .startRecording: coordinator.startRecording()
        case .stopRecording:
            if coordinator.activity == .recording {
                coordinator.stopRecording()
            } else {
                coordinator.cancelCurrentOperation()
            }
        case .toggleNotch: coordinator.toggleExpanded()
        case .restoreLastCapture: coordinator.restoreLastDismissed()
        }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "NotchShot"
        )
        item.button?.image?.isTemplate = true
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        for intent in [CaptureIntent.area, .window, .display, .scrolling, .ocr, .previousArea] {
            let item = NSMenuItem(
                title: intent.title,
                action: #selector(captureFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = intent.rawValue
            item.image = NSImage(systemSymbolName: intent.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add(menu, title: "Start Recording", action: #selector(startRecording))
        add(menu, title: "Stop Recording", action: #selector(stopRecording))

        menu.addItem(.separator())
        add(menu, title: "History…", action: #selector(showHistoryFromMenu))
        add(menu, title: "Restore Last Capture", action: #selector(restoreLastCapture))
        add(menu, title: "Close All Pinned Captures", action: #selector(closePins))

        menu.addItem(.separator())
        add(menu, title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        add(menu, title: "Quit NotchShot", action: #selector(quit), keyEquivalent: "q")

        return menu
    }

    private func add(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let intent = CaptureIntent(rawValue: raw) else { return }
        coordinator.capture(intent)
    }

    @objc private func startRecording() { coordinator.startRecording() }
    @objc private func stopRecording() { coordinator.stopRecording() }
    @objc private func restoreLastCapture() { coordinator.restoreLastDismissed() }
    @objc private func closePins() { FloatingCaptureManager.shared.closeAll() }
    @objc private func showSettingsFromMenu() { showSettings() }
    @objc private func showHistoryFromMenu() { showHistory() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    private func showSettings() {
        if let settingsWindow {
            bringToFront(settingsWindow)
            return
        }
        let window = makeWindow(
            title: "NotchShot Settings",
            content: SettingsView(coordinator: coordinator),
            size: CGSize(width: 560, height: 460)
        )
        attachCloseHandler(to: window) { [weak self] in self?.settingsWindow = nil }
        settingsWindow = window
        bringToFront(window)
    }

    private func showHistory() {
        if let historyWindow {
            bringToFront(historyWindow)
            return
        }
        let window = makeWindow(
            title: "Capture History",
            content: HistoryView(coordinator: coordinator),
            size: CGSize(width: 860, height: 540)
        )
        attachCloseHandler(to: window) { [weak self] in self?.historyWindow = nil }
        historyWindow = window
        bringToFront(window)
    }

    private func showEditor(_ documentController: AnnotationDocumentController) {
        let key = ObjectIdentifier(documentController)
        if let existing = editorWindows[key] {
            bringToFront(existing)
            return
        }

        // The close button needs the window it lives in, which doesn't exist
        // until the view is built; the box breaks the cycle.
        let windowBox = WindowBox()
        let view = AnnotationEditorView(
            controller: documentController,
            onClose: { [weak self] in
                self?.editorWindows.removeValue(forKey: key)
                windowBox.window?.performClose(nil)
            },
            onExported: { [weak self] asset in
                self?.coordinator.history.record(asset: asset, image: nil)
            }
        )
        let window = makeWindow(
            title: documentController.projectURL?.lastPathComponent ?? "Annotate",
            content: view,
            size: CGSize(width: 980, height: 660)
        )
        windowBox.window = window
        attachCloseHandler(to: window) { [weak self] in
            self?.editorWindows.removeValue(forKey: key)
        }
        editorWindows[key] = window
        bringToFront(window)
    }

    private func makeWindow(title: String, content: some View, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        // Registered so an open editor or settings window can't leak into a
        // capture taken while it is on screen.
        WindowExclusionRegistry.shared.register(window)
        return window
    }

    private func attachCloseHandler(to window: NSWindow, handler: @escaping () -> Void) {
        window.delegate = WindowCloseObserver.shared
        WindowCloseObserver.shared.onClose[ObjectIdentifier(window)] = handler
    }

    private func bringToFront(_ window: NSWindow) {
        // Auxiliary windows are the one place NotchShot activates: they need
        // real keyboard focus, unlike the notch itself.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Weak-ish holder so a SwiftUI closure can reach the window that hosts it.
@MainActor
private final class WindowBox {
    weak var window: NSWindow?
}

/// One delegate for every auxiliary window, so each can clear its own reference
/// without needing a delegate class per window.
@MainActor
final class WindowCloseObserver: NSObject, NSWindowDelegate {
    static let shared = WindowCloseObserver()

    var onClose: [ObjectIdentifier: () -> Void] = [:]

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        WindowExclusionRegistry.shared.unregister(window)
        onClose[key]?()
        onClose.removeValue(forKey: key)
    }
}
