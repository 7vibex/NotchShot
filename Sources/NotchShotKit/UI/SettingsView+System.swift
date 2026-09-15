import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notch

struct NotchSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show the notch interface", isOn: Binding(
                    get: { preferences.notchEnabled },
                    set: { coordinator.setNotchEnabled($0) }
                ))
                Picker("Show notch on", selection: Binding(
                    get: { preferences.notchDisplayPlacement },
                    set: { coordinator.setNotchDisplayPlacement($0) }
                )) {
                    ForEach(NotchDisplayPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .disabled(!preferences.notchEnabled)
                Toggle("Mirror passive music, AI, timer, and status islands", isOn: Binding(
                    get: { preferences.mirrorsPassiveContextOnAllDisplays },
                    set: { value in
                        preferences.mirrorsPassiveContextOnAllDisplays = value
                        coordinator.windowController?.rebuildPanels()
                    }
                ))
                .disabled(!preferences.notchEnabled || preferences.notchDisplayPlacement != .allDisplays)
                Text("Built-in only keeps the notch off external monitors, even when one is set as the Main Display. It stays hidden while the MacBook lid is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System HUD") {
                Toggle("Show volume and brightness in the notch", isOn: Binding(
                    get: { preferences.systemLevelHUDEnabled },
                    set: { coordinator.setSystemLevelHUDEnabled($0) }
                ))

                Toggle("Include brightness", isOn: Binding(
                    get: { preferences.mirrorsBrightnessChanges },
                    set: { coordinator.setBrightnessMirroringEnabled($0) }
                ))
                .disabled(!preferences.systemLevelHUDEnabled)
                Text("Only a recent brightness-key press arms the notch HUD. Automatic changes from the ambient-light sensor stay silent; Control Centre or third-party brightness changes may stay silent too because macOS does not publish their source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Replace the macOS overlay", isOn: Binding(
                    get: { preferences.suppressesSystemOSD },
                    set: { coordinator.setSystemOSDSuppressed($0) }
                ))
                .disabled(!preferences.systemLevelHUDEnabled)
                Text("Experimental, direct-distribution only. On macOS 26.5 or later, Input Monitoring lets NotchShot handle only the volume, mute, and brightness keys before Control Center shows its duplicate banner. Older overlays use the signed recovery watchdog; VoiceOver always keeps Apple's native feedback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.suppressesSystemOSD,
                   coordinator.osd.needsInputMonitoringPermission,
                   coordinator.permissions.hasUnstableSigningIdentity {
                    // Naming the real cause first. Sending someone to the Input
                    // Monitoring pane cannot help an ad-hoc build: the row they
                    // would switch on belongs to a different code hash.
                    Text("The macOS overlay is back because this build is ad-hoc signed, so its Input Monitoring grant no longer applies. Rebuild NotchShot with a code-signing certificate.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if preferences.suppressesSystemOSD,
                   coordinator.osd.needsInputMonitoringPermission {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(coordinator.permissions.inputMonitoringGranted
                             ? "Input Monitoring is granted, but the media-key listener is not active. Quit and reopen NotchShot."
                             : "Input Monitoring is required. Allow NotchShot, then quit and reopen it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if coordinator.permissions.inputMonitoringGranted {
                            Button("Quit & Reopen") {
                                coordinator.permissions.relaunchApplication()
                            }
                        } else {
                            Button("Open Input Monitoring Settings") {
                                coordinator.permissions.openSettings(for: .inputMonitoring)
                            }
                        }
                    }
                }
                if !coordinator.osd.isCrashRecoveryAvailable {
                    Text("Recovery helper missing — NotchShot will refuse to suppress the native overlay.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Hover") {
                Toggle("Reveal a peek on hover", isOn: $preferences.hoverPeekEnabled)
                LabeledContent("Hover delay") {
                    HStack(spacing: 8) {
                        Slider(value: $preferences.hoverPeekDelay, in: 0 ... 1.2)
                        Text(preferences.hoverPeekDelay, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text("s").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(!preferences.hoverPeekEnabled)
                Text("Hovering only reveals a compact peek. The full interface always needs a click, a shortcut, or a drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Floating Basket") {
                Toggle("Enable jiggle-to-summon basket", isOn: Binding(
                    get: { FloatingBasketPreferences.shared.isEnabled },
                    set: { FloatingBasketPreferences.shared.isEnabled = $0 }
                ))
                .accessibilityLabel("Enable jiggle floating basket")
                Button(FloatingBasketManager.shared.isShown ? "Hide Basket Now" : "Show Basket") {
                    if FloatingBasketManager.shared.isShown {
                        FloatingBasketManager.shared.hide()
                    } else {
                        FloatingBasketManager.shared.show()
                    }
                }
                .disabled(!FloatingBasketPreferences.shared.isEnabled)
                Text("Jiggle the mouse side-to-side while dragging files and the basket flies in wherever you are — just like Droppy. Drop files in to hold them, drag them out where needed. Auto-hides when empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                ForEach(coordinator.windowController?.displayContexts ?? []) { context in
                    LabeledContent(displayName(for: context)) {
                        Text(context.metrics.hasPhysicalNotch
                             ? "Notch \(Int(context.metrics.notchSize.width))×\(Int(context.metrics.notchSize.height))"
                             : "Island (no notch)")
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsWorkbenchFormStyle()
    }

    private func displayName(for context: NotchDisplayContext) -> String {
        if context.isBuiltIn { return "Built-in MacBook display" }
        if context.isPrimary { return "Main external display" }
        return "External display \(context.displayID)"
    }
}

// MARK: - Media

struct MediaSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show what's playing", isOn: Binding(
                    get: { preferences.mediaIntegrationEnabled },
                    set: { newValue in
                        preferences.mediaIntegrationEnabled = newValue
                        coordinator.media.restart()
                    }
                ))
                Toggle("Show activity stack while Mac is locked", isOn: Binding(
                    get: { preferences.showsActivityStackWhileLocked },
                    set: { newValue in
                        preferences.showsActivityStackWhileLocked = newValue
                        coordinator.windowController?.refreshLockedPresentation()
                    }
                ))
                Text("Separate privacy opt-in. Shows Focus state and the latest NotchShot-owned alert in a display-only card stack. Replies and controls remain disabled until unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Active source", value: coordinator.media.activeSource.displayName)
                if let reason = coordinator.media.lastFailureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if coordinator.permissions.pendingRemediation == .automation {
                    Button("Open Automation Settings") {
                        coordinator.permissions.openSettings(for: .automation)
                    }
                }
            }

            Section("Notification banners") {
                Toggle("Mirror visible notifications in the notch", isOn: Binding(
                    get: { preferences.mirrorsSystemNotificationBanners },
                    set: { coordinator.setSystemNotificationMirroringEnabled($0) }
                ))
                LabeledContent("Status", value: coordinator.systemNotifications.status.title)
                if coordinator.systemNotifications.status.needsAccessibility {
                    Button("Open Accessibility Settings") {
                        coordinator.permissions.openSettings(for: .accessibility)
                    }
                }
                Text("Privacy opt-in. NotchShot reads only notification banners macOS visibly presents through Accessibility, keeps their text in memory, and never shows them while the Mac is locked. A recognized Messages or WhatsApp card can open that app to reply there; NotchShot cannot send the reply itself. Focus-suppressed notifications and hidden history are not available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Now Playing bridge") {
                LabeledContent("Adapter") {
                    HStack {
                        Text(preferences.mediaRemoteAdapterPath ?? "Not configured")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseAdapter() }
                        if preferences.mediaRemoteAdapterPath != nil {
                            Button("Clear") {
                                preferences.mediaRemoteAdapterPath = nil
                                preferences.mediaRemoteAdapterIdentity = nil
                                coordinator.media.restart()
                            }
                        }
                    }
                }
                LabeledContent(
                    "Tested against",
                    value: preferences.lastAdapterCheckBuild ?? "not yet verified"
                )
                Button("Run compatibility test") {
                    coordinator.media.restart()
                }
                .disabled(preferences.mediaRemoteAdapterPath == nil)
                if preferences.mediaRemoteAdapterPath == nil {
                    Text("Choose an adapter before running its compatibility test.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(MediaRemoteAdapterSource.licenseNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The selected executable runs with your macOS account's permissions. Choose only a copy you built yourself or obtained from a source you trust; NotchShot limits its runtime and output but cannot sandbox it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("Fallback") {
                Toggle("Use Music and Spotify via Apple Events", isOn: Binding(
                    get: { preferences.appleEventsFallbackEnabled },
                    set: { newValue in
                        preferences.appleEventsFallbackEnabled = newValue
                        coordinator.media.restart()
                    }
                ))
                Text("Used only when the Now Playing bridge is unavailable. Needs Automation permission, can't see browser audio, and fetches the active Spotify track's artwork from its HTTPS CDN once per track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
    }

    private func chooseAdapter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = "Choose a trusted mediaremote-adapter executable. It will run with your account's permissions."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            coordinator.present(error: NotchShotError.exportFailed(
                "Choose a regular executable file, not a folder, alias, or symbolic link"
            ))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run this external executable?"
        alert.informativeText = "\(url.path)\n\nIt will run with your macOS account's permissions. Continue only if you trust its source."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Executable")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard let identity = SafeAssetFile.identity(
            at: url,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ) else {
            coordinator.present(error: NotchShotError.exportFailed(
                "The executable changed before it could be approved. Choose it again."
            ))
            return
        }
        preferences.mediaRemoteAdapterIdentity = identity
        preferences.mediaRemoteAdapterPath = url.path
        coordinator.media.restart()
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(PermissionKind.allCases.filter { $0 != .accessibility }) { kind in
                    LabeledContent(kind.title) {
                        HStack {
                            Text(stateText(for: kind))
                                .foregroundStyle(stateColor(for: kind))
                            if kind == .screenRecording,
                               coordinator.permissions.requiresScreenRecordingRelaunch {
                                Button("Quit & Reopen") {
                                    coordinator.permissions.relaunchApplication()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button("Open Settings") {
                                coordinator.permissions.openSettings(for: kind)
                            }
                        }
                    }
                }
                if coordinator.permissions.hasUnstableSigningIdentity {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This build is ad-hoc signed, so macOS cannot keep any permission.")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("An ad-hoc signature's identity is the app's own code hash, so every rebuild looks like a brand-new app to macOS. The switches above stay on in Privacy & Security — they belong to the build that asked — while this one is refused, which is why screenshots fail and the macOS volume and brightness overlay came back. Rebuild with a certificate: Scripts/build_app.sh --release --identity \"Apple Development: …\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if coordinator.permissions.isScreenRecordingGrantStale {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screen Recording looks approved but macOS is still refusing it.")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("That happens when the entry in Privacy & Security belongs to an earlier build signed with a different identity. Switching it off and on again does not help — the record has to be cleared so macOS asks fresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reset Screen Recording Permission") {
                            Task {
                                if await coordinator.permissions.resetScreenRecordingPermission() {
                                    coordinator.permissions.relaunchApplication()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("NotchShot asks for each permission the first time you use the feature that needs it, never at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Toggle("Keep a capture history", isOn: $preferences.historyEnabled)
                Picker("Keep for", selection: $preferences.historyRetentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .disabled(!preferences.historyEnabled)
                .onChange(of: preferences.historyRetentionDays) { _, _ in
                    // Applying only at launch left rows past a just-shortened
                    // window alive for the rest of the session.
                    _ = coordinator.history.applyRetention()
                }

                Toggle("Search capture text", isOn: Binding(
                    get: { preferences.indexesCaptureText },
                    set: { newValue in
                        preferences.indexesCaptureText = newValue
                        // Turning it off must be retroactive, or "off" would be
                        // a lie about text already on disk.
                        if !newValue { coordinator.history.purgeIndexedText() }
                    }
                ))
                Text("When on, recognised text is stored alongside history so you can search it. Turning this off deletes the text already stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Find captures with Spotlight", isOn: Binding(
                    get: { preferences.indexesCapturesInSpotlight },
                    set: { coordinator.setCaptureSpotlightIndexEnabled($0) }
                ))
                Text("Off by default. When enabled, filenames, tags, collections, source app, and already-opted-in recognised text are indexed locally by macOS Spotlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("clearCaptureHistory")
                    .confirmationDialog(
                        "Clear all capture history?",
                        isPresented: $confirmClear
                    ) {
                        Button("Clear History Only") {
                            _ = coordinator.history.clearAll(includingFiles: false)
                        }
                        Button("Clear History and Move Files to Trash", role: .destructive) {
                            let failed = coordinator.history.clearAll(includingFiles: true)
                            if !failed.isEmpty {
                                coordinator.present(error: NotchShotError.destinationUnwritable(
                                    "Could not move \(failed.count) capture file(s) to Trash"
                                ))
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }

            Section("Clipboard") {
                Toggle("Keep a clipboard history", isOn: Binding(
                    get: { preferences.clipboardEnabled },
                    set: { coordinator.setClipboardEnabled($0) }
                ))
                Text("Off by default. NotchShot records nothing you copy until you switch this on, and switching it back off deletes what was already kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Keep for", selection: $preferences.clipboardRetentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Until cleared").tag(0)
                }
                .disabled(!preferences.clipboardEnabled)
                .onChange(of: preferences.clipboardRetentionDays) { _, _ in
                    _ = coordinator.clipboard.applyRetention()
                }

                Toggle("Clear history when NotchShot quits", isOn: $preferences.clipboardClearsOnQuit)
                    .disabled(!preferences.clipboardEnabled)
                Text("Pinned items are cleared too. The current system clipboard is left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Excluded apps (\(preferences.clipboardExcludedBundleIDs.count))") {
                    if preferences.clipboardExcludedBundleIDs.isEmpty {
                        Text("No app exclusions. Concealed and transient clippings are still never recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(preferences.clipboardExcludedBundleIDs.sorted(), id: \.self) { bundleID in
                            HStack {
                                Text(bundleID)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Button("Remove") {
                                    preferences.clipboardExcludedBundleIDs.remove(bundleID)
                                }
                                .buttonStyle(.link)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Excluded app \(bundleID)")
                        }
                    }
                    Button("Add App…") { addClipboardExclusion() }
                        .disabled(!preferences.clipboardEnabled)
                }
                Text("Clippings marked concealed or transient — what password managers set on a copied password — are never recorded, whatever app they came from. The excluded list adds whole apps on top of that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open Clipboard History…") { coordinator.openClipboard() }
                    Spacer()
                    Button("Clear Clipboard", role: .destructive) {
                        coordinator.clipboard.clear()
                    }
                    .foregroundStyle(.red)
                    .disabled(coordinator.clipboard.entries.isEmpty)
                }
            }
        }
        .settingsWorkbenchFormStyle()
        .onAppear { coordinator.permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            coordinator.permissions.refresh()
        }
    }

    private func stateText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording: coordinator.permissions.screenRecording.displayName
        case .microphone: coordinator.permissions.microphone.displayName
        case .inputMonitoring:
            coordinator.permissions.inputMonitoringGranted ? "Granted" : "Not granted"
        default: "As needed"
        }
    }

    private func addClipboardExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Exclude"
        panel.message = "Choose apps whose copies should never enter clipboard history."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
                continue
            }
            preferences.clipboardExcludedBundleIDs.insert(identifier)
        }
    }

    private func stateColor(for kind: PermissionKind) -> Color {
        if kind == .inputMonitoring {
            return coordinator.permissions.inputMonitoringGranted ? .green : .orange
        }
        let state: PermissionState? = switch kind {
        case .screenRecording: coordinator.permissions.screenRecording
        case .microphone: coordinator.permissions.microphone
        default: nil
        }
        guard let state else { return .secondary }
        return switch state {
        case .granted: .green
        case .restartRequired: .orange
        case .denied: .red
        case .notDetermined: .secondary
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @State private var bindings: [HotKeyAction: HotKeyBinding] = HotKeyController.shared.bindings
    @State private var recording: HotKeyAction?
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section("macOS shortcuts") {
                Toggle("Use the macOS screenshot shortcuts for NotchShot", isOn: Binding(
                    get: { preferences.usesSystemScreenshotShortcuts },
                    set: { newValue in
                        preferences.usesSystemScreenshotShortcuts = newValue
                        HotKeyController.shared.applySystemShortcutTakeover()
                        bindings = HotKeyController.shared.bindings
                    }
                ))
                Text("Experimental, direct-distribution only. Switches off only matching shortcuts that macOS currently owns, records each claim, and restores exactly those keys when this is off, on quit, or after a relaunch following a crash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !SystemScreenshotHotKeys.shared.isAvailable {
                    Text("This version of macOS does not allow reassigning the system shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            Button(recording == action ? "Press keys…" : (bindings[action]?.displayString ?? "None")) {
                                recording = recording == action ? nil : action
                            }
                            .frame(minWidth: 120)

                            if bindings[action] != nil {
                                Button {
                                    HotKeyController.shared.setBinding(nil, for: action)
                                    bindings = HotKeyController.shared.bindings
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Clear shortcut for \(action.title)")
                            }
                        }
                    }
                }
                Button("Restore Defaults") {
                    HotKeyController.shared.restoreDefaults()
                    bindings = HotKeyController.shared.bindings
                }
            }
        }
        .settingsWorkbenchFormStyle()
        .background(
            ShortcutRecorder(isRecording: recording != nil) { binding in
                guard let action = recording else { return }
                HotKeyController.shared.setBinding(binding, for: action)
                bindings = HotKeyController.shared.bindings
                recording = nil
            }
        )
    }
}

/// Captures the next key combination while the settings pane is recording one.
private struct ShortcutRecorder: NSViewRepresentable {
    var isRecording: Bool
    var onCapture: (HotKeyBinding) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isRecording = isRecording
        context.coordinator.onCapture = onCapture
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var isRecording = false
        var onCapture: ((HotKeyBinding) -> Void)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard self.isRecording else { return false }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    // A shortcut with no modifier would fire while typing.
                    guard !modifiers.isEmpty else { return false }
                    self.onCapture?(HotKeyBinding(
                        keyCode: UInt32(event.keyCode),
                        modifiers: HotKeyBinding.carbonModifiers(from: modifiers)
                    ))
                    return true
                }
                return handled ? nil : event
            }
        }

        /// Torn down from `dismantleNSView` rather than `deinit`, because the
        /// monitor token isn't `Sendable` and a nonisolated deinit can't reach it.
        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
