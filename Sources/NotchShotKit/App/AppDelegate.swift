import AppKit
import AppIntents
import QuickLookUI
import ServiceManagement
import SwiftUI

/// Application lifecycle: brings up the notch panels, the menu-bar item, global
/// shortcuts, and the auxiliary windows.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = AppCoordinator()
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var secureUpdates: SecureUpdateController?

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var clipboardWindow: NSWindow?
    private var productivityWindow: NSWindow?
    private var editorWindows: [ObjectIdentifier: NSWindow] = [:]
    private var editorControllers: [ObjectIdentifier: AnnotationDocumentController] = [:]
    private var privacyReviewWindows: [ObjectIdentifier: NSWindow] = [:]
    private var bugReportWindows: [ObjectIdentifier: NSWindow] = [:]
    private var comparisonWindows: [ObjectIdentifier: NSWindow] = [:]
    private var smartExportWindows: [ObjectIdentifier: NSWindow] = [:]
    private var videoTrimWindows: [ObjectIdentifier: NSWindow] = [:]
    private var inspectorWindows: [ObjectIdentifier: NSWindow] = [:]
    private var capturePreviewWindows: [UUID: NSWindow] = [:]
    private var documentSummaryWindows: [ObjectIdentifier: NSWindow] = [:]
    private let automationRateLimiter = URLCommandRateLimiter()
    private var isFinalizingForTermination = false

    public override init() { super.init() }

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        secureUpdates = SecureUpdateController()
        NotchShotAppShortcuts.updateAppShortcutParameters()

        NSApp.setActivationPolicy(Preferences.shared.showsDockIcon ? .regular : .accessory)
        NSApp.servicesProvider = self
        // Services are normally rebuilt at login. Refreshing the public
        // Services registry on launch makes a newly installed or updated
        // NotchShot command available without requiring a logout.
        NSUpdateDynamicServices()

        let controller = NotchWindowController { [coordinator] context in
            AnyView(NotchRootView(coordinator: coordinator, context: context))
        }
        controller.onHoverChange = { [weak self] displayID in
            self?.coordinator.setHovering(displayID != nil)
        }
        controller.onTriggerClick = { [weak self, weak controller] _ in
            guard let self else { return }
            if coordinator.activity == .media {
                coordinator.setPeeking(true)
                controller?.focusActivePanel()
            } else if case .context = coordinator.activity {
                coordinator.setContextExpanded(true)
            } else {
                coordinator.toggleExpanded()
            }
        }
        windowController = controller
        coordinator.windowController = controller

        coordinator.onOpenSettings = { [weak self] in self?.showSettings() }
        coordinator.onOpenHistory = { [weak self] in self?.showHistory() }
        coordinator.onOpenClipboard = { [weak self] in self?.showClipboard() }
        coordinator.onOpenProductivity = { [weak self] in self?.showProductivity() }
        coordinator.onOpenEditor = { [weak self] documentController in
            self?.showEditor(documentController)
        }
        coordinator.onOpenPrivacyReview = { [weak self] session in
            self?.showPrivacyReview(session)
        }
        coordinator.onOpenBugReport = { [weak self] session in
            self?.showBugReport(session)
        }
        coordinator.onOpenComparison = { [weak self] session in
            self?.showComparison(session)
        }
        coordinator.onOpenSmartExport = { [weak self] session in
            self?.showSmartExport(session)
        }
        coordinator.onOpenVideoTrim = { [weak self] session in
            self?.showVideoTrim(session)
        }
        coordinator.onOpenInspector = { [weak self] session in
            self?.showInspector(session)
        }
        coordinator.onOpenCapturePreview = { [weak self] item in
            self?.showCapturePreview(item)
        }
        coordinator.onOpenDocumentSummary = { [weak self] session in
            self?.showDocumentSummary(session)
        }

        controller.start()
        controller.onPanelAvailabilityChange = { [weak self] _ in
            self?.coordinator.reconcileSystemLevelIntegration()
        }
        coordinator.start()
        ProductivityNotificationCenter.shared.configure { [weak self] in
            self?.coordinator.openProductivity(tool: .notifications)
        }

        HotKeyController.shared.handler = { [weak self] action in
            self?.handle(action)
        }
        HotKeyController.shared.phaseHandler = { [weak self] action, phase in
            let usesHoldBehavior = action == .pushToTalk
                || (action == .toggleDictation
                    && Preferences.shared.dictationTriggerMode == .holdToTalk)
            guard usesHoldBehavior else { return }
            self?.coordinator.dictation.handlePushToTalk(pressed: phase == .pressed)
        }
        HotKeyController.shared.start()

        installStatusItem()

        // Anything a crash left behind is offered back before the temp
        // directory gets swept.
        coordinator.recoverOrphanedRecordings()

        if !Preferences.shared.hasCompletedFirstRun {
            showOnboarding()
        } else {
            coordinator.resumePendingFirstCaptureIfPossible()
        }

        Log.app.notice("NotchShot \(Bundle.main.shortVersion) launched")
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from Privacy & Security is the common permission handoff.
        // Refresh globally rather than only while the Privacy settings page is
        // visible, so menu-bar captures and the notch never use a stale value.
        coordinator.permissions.refresh()
        coordinator.resumePendingFirstCaptureIfPossible()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Before anything else: a paused system overlay must never outlive the
        // app that paused it.
        SystemOSDSuppressor.shared.stop()
        coordinator.dictation.cancel()
        coordinator.context.stop()
        HotKeyController.shared.stop()
        // A copied capture is offered to the pasteboard as a promise, and a
        // promise dies with the process that made it. Redeem it while there is
        // still something to redeem it with.
        ImageExport.redeemPromisedPasteboardImage()
        if Preferences.shared.clipboardClearsOnQuit {
            coordinator.clipboard.clear()
        }
        do {
            try coordinator.clipboard.save()
        } catch {
            Log.history.error("Final Clipboard save failed: \(error.localizedDescription)")
        }
        do {
            try coordinator.history.save()
        } catch {
            // `applicationShouldTerminate` already gave the user Retry,
            // Cancel, and Quit Without Saving. This is only a final best-effort
            // write for nonstandard termination paths.
            Log.history.error("Final History save failed: \(error.localizedDescription)")
        }
        coordinator.history.removeUntrackedManagedFiles()
        windowController?.stop()
        FloatingCaptureManager.shared.closeAll()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinalizingForTermination else { return .terminateLater }
        guard resolveUnsavedEditorsBeforeTermination() else { return .terminateCancel }
        isFinalizingForTermination = true

        // Dictation is transient: discard audio and text on quit.
        coordinator.dictation.cancel()
        // Close the voice-note audio file first and synchronously. Unlike the
        // screen recording below it needs no async writer drain, and doing it
        // before anything can fail or be cut short means the note on disk is a
        // complete WAV even on an abrupt logout. Its transcript is skipped
        // deliberately — it can be regenerated from the audio, and speech
        // recognition does not belong inside a termination reply.
        coordinator.context.voiceNotes.finalizeForTermination()

        // The save/discard decisions above are now final. Hide editor windows
        // while the recording writer drains so no late edit can land after its
        // document was saved but before AppKit completes termination.
        for window in editorWindows.values {
            window.orderOut(nil)
        }

        Task { [weak self, weak sender] in
            guard let self, let sender else { return }
            do {
                if let asset = try await coordinator.finishRecordingForTermination() {
                    coordinator.history.record(asset: asset, image: nil)
                }
            } catch {
                // The in-progress file remains in the recovery directory when
                // finalization cannot produce a valid destination.
                Log.recording.error("Could not finalize recording before quit: \(error.localizedDescription)")
            }
            await coordinator.media.stopAndWait()
            let shouldTerminate = resolveHistoryPersistenceBeforeTermination()
            if !shouldTerminate {
                for window in editorWindows.values {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            isFinalizingForTermination = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    private func resolveHistoryPersistenceBeforeTermination() -> Bool {
        while true {
            do {
                try coordinator.history.save()
                return true
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "History could not be saved"
                alert.informativeText = "Your capture files remain on disk, but recent History details may be missing after NotchShot quits.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "Retry Save")
                alert.addButton(withTitle: "Quit Without Saving")
                alert.addButton(withTitle: "Cancel Quit")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    continue
                case .alertSecondButtonReturn:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func resolveUnsavedEditorsBeforeTermination() -> Bool {
        for (key, documentController) in editorControllers
            where documentController.hasUnsavedChanges {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save \(editorWindows[key]?.title ?? "annotation") before quitting?"
            alert.informativeText = "Your annotation changes will be lost if you discard them."
            alert.addButton(withTitle: "Save Project")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel Quit")
            if let window = editorWindows[key] {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard documentController.confirmProjectPrivacyBeforeSaving() else { return false }
                do {
                    let url = try documentController.saveProject()
                    coordinator.handleEditorProjectSaved(
                        from: documentController,
                        projectURL: url
                    )
                } catch {
                    NSAlert(error: error).runModal()
                    return false
                }
            case .alertSecondButtonReturn:
                continue
            default:
                return false
            }
        }
        return true
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Quick Look

    // Quick Look drives itself from the responder chain. An accessory app whose
    // only windows are nonactivating panels has nothing in that chain to answer,
    // so the application delegate — which is always in it — answers for the
    // presenter.

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Quick Look calls these from its own panel machinery, which is
        // declared without isolation but only ever runs on the main thread.
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPresenter.shared
            panel.delegate = QuickLookPresenter.shared
        }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    /// Opening a `.notchshot` project from Finder or a documented automation URL.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "notchshot" {
                handleAutomationURL(url)
                continue
            }
            guard NotchShotPackage.isProject(url) else { continue }
            guard let controller = try? AnnotationDocumentController.open(projectAt: url) else {
                coordinator.present(error: NotchShotError.exportFailed(
                    "Couldn't open \(url.lastPathComponent)"
                ))
                continue
            }
            showEditor(controller)
        }
    }

    /// Finder's Services menu sends selected file URLs through a pasteboard.
    /// The app keeps references to those files; it does not copy, move, or
    /// inspect their contents merely because they were added to the shelf.
    @objc(addFilesToShelf:userData:error:)
    public func addFilesToShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL])?.map { $0 as URL } ?? []
        guard !urls.isEmpty else {
            error.pointee = "NotchShot received no regular file URLs." as NSString
            return
        }
        coordinator.acceptFilesFromFinderService(urls)
    }

    private func handleAutomationURL(_ url: URL) {
        guard automationRateLimiter.accept() else {
            coordinator.present(error: NotchShotError.captureFailed(
                "Automation request ignored because NotchShot is being triggered too quickly"
            ))
            return
        }
        do {
            let command = try NotchShotURLRouter.parse(url)
            guard authorizeExternalURLCommand(command) else { return }
            performAutomationCommand(command)
        } catch {
            coordinator.present(error: error)
        }
    }

    private func authorizeExternalURLCommand(_ command: NotchShotURLCommand) -> Bool {
        guard command.requiresExternalURLConsent else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow this NotchShot automation request?"
        alert.informativeText = command.externalURLConsentDescription
        // Keep the safe choice as the default button. Consent must be a
        // deliberate click, not an accidental Return key press.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow Once")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Shared by App Intents and the validated URL scheme. This accepts only
    /// NotchShot's closed command enum; no executable, arbitrary URL, or
    /// experimental preference can enter through this boundary.
    public func performAutomationCommand(_ command: NotchShotURLCommand) {
        switch command {
        case .capture(let command):
            coordinator.performAutomationCapture(command)
        case .recordArea:
            coordinator.startRecording(mode: .area)
        case .ocrClipboard(let format):
            coordinator.recognizeClipboard(format: format)
        case .openLatest:
            coordinator.openLatestCapture()
        case .pinFile(let fileURL):
            coordinator.pinExternalFile(fileURL)
        }
    }

    // MARK: Shortcuts

    private func handle(_ action: HotKeyAction) {
        switch action {
        case .captureArea: coordinator.capture(.area)
        case .captureAreaToClipboard: coordinator.capture(.area, clipboardOnly: true)
        case .captureWindow: coordinator.capture(.window)
        case .captureDisplay: coordinator.capture(.display)
        case .captureDisplayToClipboard: coordinator.capture(.display, clipboardOnly: true)
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
        case .showClipboard: coordinator.openClipboard()
        case .toggleDictation:
            if Preferences.shared.dictationTriggerMode == .toggle {
                coordinator.toggleDictation()
            }
        case .pushToTalk:
            // Press and release are handled by `phaseHandler`; doing work here
            // would turn the initial press into an accidental toggle.
            break
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
        add(menu, title: "Collect Captures in Stack", action: #selector(toggleStack))
        add(menu, title: "Add Latest Capture to Stack", action: #selector(addToStack))
        add(menu, title: "Clear Stack", action: #selector(clearStack))

        menu.addItem(.separator())
        add(menu, title: "History…", action: #selector(showHistoryFromMenu))
        add(menu, title: "Clipboard History…", action: #selector(showClipboardFromMenu))
        add(menu, title: "Productivity Center…", action: #selector(showProductivityFromMenu))
        add(menu, title: "Summarize Document…", action: #selector(summarizeDocumentFromMenu))
        add(menu, title: "Restore Last Capture", action: #selector(restoreLastCapture))
        add(menu, title: "Unlock All Pinned Captures", action: #selector(unlockPins))
        add(menu, title: "Close All Pinned Captures", action: #selector(closePins))

        menu.addItem(.separator())
        add(menu, title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        add(menu, title: "Check for Updates…", action: #selector(checkForUpdates))
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

    @objc private func toggleStack() { coordinator.toggleStackCollecting() }
    @objc private func addToStack() { coordinator.addSelectedToStack() }
    @objc private func clearStack() { coordinator.stack.clear() }
    @objc private func startRecording() { coordinator.startRecording() }
    @objc private func stopRecording() { coordinator.stopRecording() }
    @objc private func restoreLastCapture() { coordinator.restoreLastDismissed() }
    @objc private func unlockPins() { FloatingCaptureManager.shared.unlockAll() }
    @objc private func closePins() { FloatingCaptureManager.shared.closeAll() }
    @objc private func showSettingsFromMenu() { showSettings() }
    @objc private func showHistoryFromMenu() { showHistory() }
    @objc private func showClipboardFromMenu() { showClipboard() }
    @objc private func showProductivityFromMenu() { showProductivity() }
    @objc private func summarizeDocumentFromMenu() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a document to summarize locally on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.summarizeDocument(at: url)
    }
    @objc private func checkForUpdates() {
        guard secureUpdates?.isConfigured == true else {
            coordinator.present(error: NotchShotError.exportFailed(
                "This build has no signed update feed configured"
            ))
            return
        }
        secureUpdates?.checkForUpdates(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    private func showOnboarding() {
        if let onboardingWindow {
            bringToFront(onboardingWindow)
            return
        }
        let window = makeWindow(
            title: "Welcome to NotchShot",
            content: OnboardingView(
                onTakeFirstCapture: { [weak self] outcome in
                    guard let self else { return }
                    let preferences = Preferences.shared
                    switch outcome {
                    case .copyAndSave:
                        preferences.copyToClipboardAfterCapture = true
                        preferences.saveToDiskAfterCapture = true
                    case .copyOnly:
                        preferences.copyToClipboardAfterCapture = true
                        preferences.saveToDiskAfterCapture = false
                    case .saveOnly:
                        preferences.copyToClipboardAfterCapture = false
                        preferences.saveToDiskAfterCapture = true
                    }
                    preferences.hasCompletedFirstRun = true
                    onboardingWindow?.close()
                    coordinator.beginFirstCapture()
                },
                onFinishLater: { [weak self] in
                    Preferences.shared.hasCompletedFirstRun = true
                    self?.onboardingWindow?.close()
                }
            ),
            size: CGSize(width: 680, height: 480)
        )
        attachCloseHandler(to: window) { [weak self] in self?.onboardingWindow = nil }
        onboardingWindow = window
        bringToFront(window)
    }

    private func showSettings() {
        if let settingsWindow {
            bringToFront(settingsWindow)
            return
        }
        let window = makeWindow(
            title: "NotchShot Settings",
            content: SettingsView(coordinator: coordinator),
            size: CGSize(width: 820, height: 580)
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

    private func showClipboard() {
        if let clipboardWindow {
            bringToFront(clipboardWindow)
            return
        }
        let window = makeWindow(
            title: "Clipboard History",
            content: ClipboardView(coordinator: coordinator),
            size: CGSize(width: 520, height: 560)
        )
        attachCloseHandler(to: window) { [weak self] in self?.clipboardWindow = nil }
        clipboardWindow = window
        bringToFront(window)
    }

    private func showProductivity() {
        if let productivityWindow {
            bringToFront(productivityWindow)
            return
        }
        let window = makeWindow(
            title: "NotchShot Productivity Center",
            content: ProductivitySuiteView(coordinator: coordinator),
            size: CGSize(width: 940, height: 640)
        )
        attachCloseHandler(to: window) { [weak self] in self?.productivityWindow = nil }
        productivityWindow = window
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
            onClose: {
                windowBox.window?.performClose(nil)
            },
            onExported: { [weak self] asset in
                self?.coordinator.history.record(asset: asset, image: nil)
                self?.coordinator.handleEditorExport(from: documentController, asset: asset)
            },
            onProjectSaved: { [weak self] url in
                self?.coordinator.handleEditorProjectSaved(
                    from: documentController,
                    projectURL: url
                )
            }
        )
        let window = makeWindow(
            title: documentController.projectURL?.lastPathComponent ?? "Annotate",
            content: view,
            size: CGSize(width: 980, height: 660)
        )
        windowBox.window = window
        attachCloseHandler(
            to: window,
            shouldClose: { [weak self, weak documentController, weak window] in
                guard let documentController, documentController.hasUnsavedChanges else { return true }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Save changes before closing?"
                alert.informativeText = "Your annotation changes will be lost if you discard them."
                alert.addButton(withTitle: "Save Project")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                if let window {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard documentController.confirmProjectPrivacyBeforeSaving() else { return false }
                    do {
                        let url = try documentController.saveProject()
                        self?.coordinator.handleEditorProjectSaved(
                            from: documentController,
                            projectURL: url
                        )
                        return true
                    } catch {
                        let errorAlert = NSAlert(error: error)
                        errorAlert.runModal()
                        return false
                    }
                case .alertSecondButtonReturn:
                    return true
                default:
                    return false
                }
            },
            handler: { [weak self] in
                self?.editorWindows.removeValue(forKey: key)
                self?.editorControllers.removeValue(forKey: key)
                self?.coordinator.discardEditorExportAction(for: documentController)
            }
        )
        editorWindows[key] = window
        editorControllers[key] = documentController
        bringToFront(window)
    }

    private func showPrivacyReview(_ session: PrivacyReviewSession) {
        let key = ObjectIdentifier(session)
        if let existing = privacyReviewWindows[key] {
            bringToFront(existing)
            return
        }

        let windowBox = WindowBox()
        let view = PrivacyReviewView(session: session) { [weak self] findings in
            self?.coordinator.applyPrivacySuggestions(from: session, findings: findings)
            self?.privacyReviewWindows.removeValue(forKey: key)
            windowBox.window?.performClose(nil)
        }
        let window = makeWindow(
            title: "Privacy Review — \(session.asset.displayName)",
            content: view,
            size: CGSize(width: 900, height: 600)
        )
        windowBox.window = window
        attachCloseHandler(to: window) { [weak self] in
            self?.privacyReviewWindows.removeValue(forKey: key)
        }
        privacyReviewWindows[key] = window
        bringToFront(window)
    }

    private func showBugReport(_ session: BugReportSession) {
        let key = ObjectIdentifier(session)
        if let existing = bugReportWindows[key] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Bug Report Package",
            content: BugReportView(session: session),
            size: CGSize(width: 620, height: 580)
        )
        attachCloseHandler(to: window) { [weak self] in
            self?.bugReportWindows.removeValue(forKey: key)
        }
        bugReportWindows[key] = window
        bringToFront(window)
    }

    private func showComparison(_ session: VisualComparisonSession) {
        let key = ObjectIdentifier(session)
        if let existing = comparisonWindows[key] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Visual Comparison",
            content: VisualComparisonView(session: session),
            size: CGSize(width: 900, height: 620)
        )
        attachCloseHandler(to: window) { [weak self] in
            self?.comparisonWindows.removeValue(forKey: key)
        }
        comparisonWindows[key] = window
        bringToFront(window)
    }

    private func showSmartExport(_ session: SmartExportSession) {
        let key = ObjectIdentifier(session)
        if let existing = smartExportWindows[key] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Optimize Export",
            content: SmartExportView(session: session),
            size: CGSize(width: 760, height: 420)
        )
        attachCloseHandler(to: window) { [weak self] in
            self?.smartExportWindows.removeValue(forKey: key)
        }
        smartExportWindows[key] = window
        bringToFront(window)
    }

    private func showVideoTrim(_ session: VideoTrimSession) {
        let key = ObjectIdentifier(session)
        if let existing = videoTrimWindows[key] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Quick Trim — \(session.asset.displayName)",
            content: VideoTrimView(session: session),
            size: CGSize(width: 780, height: 520)
        )
        attachCloseHandler(to: window) { [weak self] in
            self?.videoTrimWindows.removeValue(forKey: key)
        }
        videoTrimWindows[key] = window
        bringToFront(window)
    }

    private func showInspector(_ session: ImageInspectionSession) {
        let key = ObjectIdentifier(session)
        if let existing = inspectorWindows[key] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Image Inspector",
            content: ImageInspectorView(session: session),
            size: CGSize(width: 920, height: 640)
        )
        attachCloseHandler(to: window) { [weak self] in
            self?.inspectorWindows.removeValue(forKey: key)
        }
        inspectorWindows[key] = window
        bringToFront(window)
    }

    private func showCapturePreview(_ item: ShelfItem) {
        if let existing = capturePreviewWindows[item.id] {
            bringToFront(existing)
            return
        }
        let window = makeWindow(
            title: "Preview — \(item.asset.displayName)",
            content: CapturePreviewView(coordinator: coordinator, item: item),
            size: CGSize(width: 960, height: 700)
        )
        window.minSize = CGSize(width: 520, height: 380)
        attachCloseHandler(to: window) { [weak self] in
            self?.capturePreviewWindows.removeValue(forKey: item.id)
        }
        capturePreviewWindows[item.id] = window
        bringToFront(window)
    }

    private func showDocumentSummary(_ session: DocumentSummarySession) {
        let key = ObjectIdentifier(session)
        if let existing = documentSummaryWindows[key] {
            bringToFront(existing)
            return
        }
        let windowBox = WindowBox()
        let view = DocumentSummaryView(session: session) { [weak self] in
            self?.documentSummaryWindows.removeValue(forKey: key)
            windowBox.window?.performClose(nil)
        }
        let window = makeWindow(
            title: "Document Summary",
            content: view,
            size: CGSize(width: 680, height: 540)
        )
        windowBox.window = window
        attachCloseHandler(to: window) { [weak self, weak session] in
            session?.cancel()
            self?.documentSummaryWindows.removeValue(forKey: key)
        }
        documentSummaryWindows[key] = window
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

    private func attachCloseHandler(
        to window: NSWindow,
        shouldClose: (() -> Bool)? = nil,
        handler: @escaping () -> Void
    ) {
        window.delegate = WindowCloseObserver.shared
        let key = ObjectIdentifier(window)
        WindowCloseObserver.shared.onClose[key] = handler
        WindowCloseObserver.shared.shouldClose[key] = shouldClose
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
    var shouldClose: [ObjectIdentifier: () -> Bool] = [:]

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose[ObjectIdentifier(sender)]?() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        WindowExclusionRegistry.shared.unregister(window)
        onClose[key]?()
        onClose.removeValue(forKey: key)
        shouldClose.removeValue(forKey: key)
    }
}
