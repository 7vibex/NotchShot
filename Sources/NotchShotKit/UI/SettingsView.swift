import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var preferences = Preferences.shared

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        TabView {
            GeneralSettings(coordinator: coordinator, preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings(preferences: preferences)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            RecordingSettings(preferences: preferences)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            NotchSettings(coordinator: coordinator, preferences: preferences)
                .tabItem { Label("Notch", systemImage: "macbook") }
            MediaSettings(coordinator: coordinator, preferences: preferences)
                .tabItem { Label("Media", systemImage: "music.note") }
            PrivacySettings(coordinator: coordinator, preferences: preferences)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { preferences.launchesAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show icon in the Dock", isOn: Binding(
                    get: { preferences.showsDockIcon },
                    set: { newValue in
                        preferences.showsDockIcon = newValue
                        NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                    }
                ))
                Toggle("Play a sound when capturing", isOn: $preferences.playsCaptureSound)
            }

            Section("Storage") {
                LabeledContent("Save captures to") {
                    HStack {
                        Text(preferences.outputFolder.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Save captures to disk", isOn: $preferences.saveToDiskAfterCapture)
                Toggle("Copy captures to the clipboard", isOn: $preferences.copyToClipboardAfterCapture)
            }

            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                Text("Everything NotchShot captures stays on this Mac. There is no account, no backend, and no telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            preferences.launchesAtLogin = enabled
            loginItemError = nil
        } catch {
            // Unsigned or unbundled builds can't register a login item; say so
            // rather than silently leaving the toggle on.
            loginItemError = "Couldn't update the login item: \(error.localizedDescription)"
            preferences.launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.setOutputFolder(url)
    }
}

// MARK: - Capture

private struct CaptureSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section("Format") {
                Picker("Image format", selection: $preferences.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                if preferences.imageFormat != .png {
                    LabeledContent("Quality") {
                        Slider(value: $preferences.jpegQuality, in: 0.4 ... 1)
                    }
                }
                LabeledContent("Filename") {
                    TextField("Template", text: $preferences.filenameTemplate)
                }
                Text("Tokens: {date} {time} {app} {timestamp}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Selection") {
                Toggle("Freeze the screen while selecting", isOn: $preferences.freezeScreenDuringSelection)
                Toggle("Show the pixel magnifier", isOn: $preferences.showsMagnifier)
                Toggle("Include the pointer in screenshots", isOn: $preferences.includesCursorInScreenshots)
            }

            Section("After capture") {
                Toggle("Show the shelf in the notch", isOn: $preferences.showsShelfAfterCapture)
                Picker("Hide the shelf after", selection: $preferences.shelfDuration) {
                    ForEach(ShelfDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .disabled(!preferences.showsShelfAfterCapture)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    @Bindable var preferences: Preferences
    @State private var microphones: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("Video") {
                Picker("Quality", selection: $preferences.recordingQuality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Picker("Resolution", selection: $preferences.recordingResolution) {
                    ForEach(RecordingResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                Picker("Frame rate", selection: $preferences.recordingFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }

            Section("Audio") {
                Toggle("Record system audio", isOn: $preferences.recordsSystemAudio)
                Toggle("Record microphone", isOn: $preferences.recordsMicrophone)
                Picker("Microphone", selection: Binding(
                    get: { preferences.preferredMicrophoneID ?? "" },
                    set: { preferences.preferredMicrophoneID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .disabled(!preferences.recordsMicrophone)
            }

            Section("Pointer") {
                Toggle("Show the pointer", isOn: $preferences.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $preferences.recordingHighlightsClicks)
            }
        }
        .formStyle(.grouped)
        .task {
            microphones = PermissionCenter.shared.availableMicrophones()
        }
    }
}

// MARK: - Notch

private struct NotchSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show the notch interface", isOn: Binding(
                    get: { preferences.notchEnabled },
                    set: { newValue in
                        preferences.notchEnabled = newValue
                        coordinator.windowController?.rebuildPanels()
                    }
                ))
                Toggle("Show an island on other displays", isOn: Binding(
                    get: { preferences.showsIslandOnExternalDisplays },
                    set: { newValue in
                        preferences.showsIslandOnExternalDisplays = newValue
                        coordinator.windowController?.rebuildPanels()
                    }
                ))
            }

            Section("Hover") {
                Toggle("Reveal a peek on hover", isOn: $preferences.hoverPeekEnabled)
                LabeledContent("Hover delay") {
                    Slider(value: $preferences.hoverPeekDelay, in: 0 ... 1.2)
                }
                Text("Hovering only reveals a compact peek. The full interface always needs a click, a shortcut, or a drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                ForEach(coordinator.windowController?.displayContexts ?? []) { context in
                    LabeledContent(context.isPrimary ? "Main display" : "Display \(context.displayID)") {
                        Text(context.metrics.hasPhysicalNotch
                             ? "Notch \(Int(context.metrics.notchSize.width))×\(Int(context.metrics.notchSize.height))"
                             : "Island (no notch)")
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Media

private struct MediaSettings: View {
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
                LabeledContent("Active source", value: coordinator.media.activeSource.displayName)
                if let reason = coordinator.media.lastFailureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                Text(MediaRemoteAdapterSource.licenseNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fallback") {
                Toggle("Use Music and Spotify via Apple Events", isOn: Binding(
                    get: { preferences.appleEventsFallbackEnabled },
                    set: { newValue in
                        preferences.appleEventsFallbackEnabled = newValue
                        coordinator.media.restart()
                    }
                ))
                Text("Used only when the Now Playing bridge is unavailable. Needs Automation permission, and can't see browser audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseAdapter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the mediaremote-adapter executable."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.mediaRemoteAdapterPath = url.path
        coordinator.media.restart()
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
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
                            Button("Open Settings") {
                                coordinator.permissions.openSettings(for: kind)
                            }
                        }
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

                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .confirmationDialog(
                        "Clear all capture history?",
                        isPresented: $confirmClear
                    ) {
                        Button("Clear History Only") {
                            coordinator.history.clearAll(includingFiles: false)
                        }
                        Button("Clear History and Move Files to Trash", role: .destructive) {
                            coordinator.history.clearAll(includingFiles: true)
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.permissions.refresh() }
    }

    private func stateText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording: coordinator.permissions.screenRecording.rawValue
        case .microphone: coordinator.permissions.microphone.rawValue
        default: "as needed"
        }
    }

    private func stateColor(for kind: PermissionKind) -> Color {
        let state: PermissionState? = switch kind {
        case .screenRecording: coordinator.permissions.screenRecording
        case .microphone: coordinator.permissions.microphone
        default: nil
        }
        guard let state else { return .secondary }
        return switch state {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @State private var bindings: [HotKeyAction: HotKeyBinding] = HotKeyController.shared.bindings
    @State private var recording: HotKeyAction?

    var body: some View {
        Form {
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
        .formStyle(.grouped)
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
