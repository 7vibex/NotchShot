import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettings: View {
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
                    InlineErrorMessage(message: loginItemError)
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

            Section("Updates") {
                Picker("Update channel", selection: $preferences.updateChannel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                Text("Automatic update checks are enabled for signed public builds. Beta includes the stable channel and may be less reliable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                Text("Everything NotchShot captures stays on this Mac. There is no account, no backend, and no telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
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

struct CaptureSettings: View {
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

            Section("Notch") {
                Toggle("Show the notch in screenshots and recordings", isOn: $preferences.includesNotchInCaptures)
                Text("Off by default. When on, the notch and its controls appear in every screen capture and recording, including NotchShot's own — useful for demos and product screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Shelf quick actions") {
                ForEach(preferences.shelfQuickActions.indices, id: \.self) { index in
                    Picker("Action \(index + 1)", selection: Binding(
                        get: { preferences.shelfQuickActions[index] },
                        set: { preferences.setShelfQuickAction($0, at: index) }
                    )) {
                        ForEach(ShareAction.customizableShelfCases) { action in
                            Label(action.title, systemImage: action.symbolName).tag(action)
                        }
                    }
                }
                Text("These six actions stay visible on every result. Actions that do not apply to the selected file are replaced temporarily; everything else remains under More.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @Bindable var preferences: Preferences
    @State private var microphones: [AVCaptureDevice] = []
    @State private var retainedDiscardCount = 0
    @State private var retainedDiscardMessage: String?

    var body: some View {
        Form {
            Section("Video") {
                Picker("Default target", selection: $preferences.recordingTargetMode) {
                    ForEach(RecordingTargetMode.allCases) { target in
                        Label(target.title, systemImage: target.symbolName).tag(target)
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
                Toggle("Smooth pointer movement after recording", isOn: $preferences.recordingSmoothsCursor)
                    .disabled(!preferences.recordingShowsCursor)
                Toggle("Zoom around clicks after recording", isOn: $preferences.recordingAutoZoomsOnClicks)
            }

            Section("Presentation") {
                Toggle("Presenter camera overlay", isOn: $preferences.recordingPresenterCamera)
                Toggle("Show keyboard shortcuts", isOn: $preferences.recordingShowsKeystrokes)
                Toggle("Frame the recording on a dark background", isOn: $preferences.recordingFramesWithBackground)
                Text("Presenter overlays are visible and movable. Shortcut display excludes ordinary typing so passwords are never shown. Camera and shortcut overlays are composited into area and display recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Captions") {
                Toggle("Create an on-device transcript and .srt captions", isOn: $preferences.recordingGeneratesCaptions)
                Text("Speech stays on this Mac. NotchShot uses an already installed language model and never uploads recording audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interrupted and discarded recordings") {
                if retainedDiscardCount > 0 {
                    Text("\(retainedDiscardCount) partial recording(s) were retained because macOS could not move them to Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Reveal") {
                            let urls = RecordingService.retainedDiscardedRecordings()
                            if !urls.isEmpty {
                                NSWorkspace.shared.activateFileViewerSelecting(urls)
                            }
                        }
                        Button("Retry Trash", role: .destructive) {
                            let failed = RecordingService.retryTrashRetainedDiscards()
                            retainedDiscardCount = failed.count
                            retainedDiscardMessage = failed.isEmpty
                                ? "All retained partials were moved to Trash."
                                : "\(failed.count) partial recording(s) still could not be moved to Trash."
                        }
                    }
                } else {
                    Text("No retained discarded recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let retainedDiscardMessage {
                    Text(retainedDiscardMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsWorkbenchFormStyle()
        .task {
            microphones = PermissionCenter.shared.availableMicrophones()
            retainedDiscardCount = RecordingService.retainedDiscardedRecordings().count
        }
    }
}

// MARK: - Dictation

struct DictationSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences
    @State private var tryText = ""
    @State private var supportedLanguages: [Locale] = []
    @State private var reservedLanguages: [Locale] = []

    var body: some View {
        Form {
            Section("Notch Dictation") {
                Toggle("Enable Notch Dictation", isOn: $preferences.dictationEnabled)
                Text("Speech recognition runs locally. A one-time language/model download may be required. Dictation audio is not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                Picker("Trigger", selection: $preferences.dictationTriggerMode) {
                    ForEach(DictationTriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("The Toggle Dictation shortcut follows this trigger mode: press once to start/stop, or hold it to talk. Both modes use a macOS global hot key and need no Accessibility or Input Monitoring permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // HotKey assignment is in Shortcuts tab – link there
                Text("Assign Toggle Dictation in Shortcuts & Automation. The optional Push to Talk action always uses hold behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone & Language") {
                LabeledContent("Microphone", value: "System default")
                Picker("Language", selection: $preferences.dictationLanguage) {
                    Text("System (\(DictationModelCatalog.displayName(for: Locale.current)))")
                        .tag(Locale.current.identifier)
                    // Listing only languages Apple ships a model for: a
                    // hardcoded list let the user pick one that could never be
                    // installed, then told them it was not installed.
                    ForEach(supportedLanguages, id: \.identifier) { locale in
                        Text(DictationModelCatalog.displayName(for: locale))
                            .tag(locale.identifier)
                    }
                }
                .task {
                    if supportedLanguages.isEmpty {
                        supportedLanguages = await DictationModelCatalog.supportedLanguages()
                    }
                }
                Picker("Engine", selection: $preferences.dictationEngine) {
                    ForEach(DictationEngineKind.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .disabled(true)
                Text("Benchmark FluidAudio with Parakeet as challenger; adopts only if measured latency/accuracy proves better without memory, thermal, download-size or language regressions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Insertion") {
                Picker("Insert", selection: $preferences.dictationInsertMode) {
                    ForEach(DictationInsertMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Processing", selection: $preferences.dictationPostProcessing) {
                    ForEach(DictationPostProcessingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Append", selection: $preferences.dictationAppendMode) {
                    ForEach(DictationAppendMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Remove filler words", isOn: $preferences.dictationRemovesFillerWords)
                Toggle("Spoken formatting commands", isOn: $preferences.dictationSpokenFormattingEnabled)
                Text("Accessibility is used to insert text into another application. The app never inserts into secure/password fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maximum Duration") {
                LabeledContent("Maximum") {
                    HStack {
                        Slider(value: $preferences.dictationMaximumDuration, in: 30...300, step: 10)
                        Text("\(Int(preferences.dictationMaximumDuration))s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Visible maximum duration; dictation stops automatically after this time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictionary") {
                TextField("Custom words, comma separated", text: Binding(
                    get: { preferences.dictationCustomWords.joined(separator: ", ") },
                    set: { preferences.dictationCustomWords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
                ))
                Text("Deterministic replacements and custom dictionary are applied locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language Model") {
                modelStatusRow
                if let progress = coordinator.dictation.modelInstallProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        HStack {
                            Text("Downloading \(Int((progress * 100).rounded()))%")
                            Spacer()
                            Button("Cancel") { coordinator.dictation.cancelModelInstall() }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if let error = coordinator.dictation.modelInstallError {
                    InlineErrorMessage(message: error)
                }
                Text(modelExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !reservedLanguages.isEmpty {
                    // macOS caps how many languages an app can keep ready.
                    // Without a way to see and free them, hitting the cap left
                    // dictation permanently stuck on "not installed".
                    LabeledContent("Kept ready") {
                        Text("\(reservedLanguages.count) of \(DictationModelCatalog.reservationCapacity)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(reservedLanguages, id: \.identifier) { locale in
                        HStack {
                            Text(DictationModelCatalog.displayName(for: locale))
                            Spacer()
                            Button("Remove") {
                                Task {
                                    await DictationModelCatalog.release(locale)
                                    await refreshReserved()
                                    await coordinator.dictation.refreshModelStatus(
                                        for: preferences.dictationLanguage
                                    )
                                }
                            }
                            .buttonStyle(.link)
                            .disabled(coordinator.dictation.isInstallingModel)
                        }
                        .font(.caption)
                    }
                }
            }
            .task(id: coordinator.dictation.modelStatus) { await refreshReserved() }

            Section("Permissions") {
                LabeledContent("Accessibility", value: coordinator.permissions.accessibilityGranted ? "Granted" : "Not granted")
                // Accessibility check via AXIsProcessTrusted
                if !AXIsProcessTrusted() {
                    Button("Open Accessibility Settings") {
                        coordinator.permissions.openSettings(for: .accessibility)
                    }
                    Text("Accessibility is used to insert text at the cursor. Without it, dictation copies to clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Dictation audio is not saved. No transcript history by default. No screen or clipboard context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Try Dictation") {
                TextField("Scratch field", text: $tryText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Start Dictation") { coordinator.toggleDictation() }
                    Button("Stop") { coordinator.stopDictation() }
                    Button("Cancel") { coordinator.cancelDictation() }
                }
                Text(tryText.isEmpty ? "Place cursor here then start dictation." : tryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
    }

    /// Availability plus the action that resolves it. The old pane could only
    /// report "not installed" and left the user with nowhere to go.
    /// A live install outranks the last polled status, so the row does not read
    /// "Not installed" with a disabled button while its own download runs.
    private var effectiveAvailability: DictationModelAvailability? {
        if let progress = coordinator.dictation.modelInstallProgress {
            return .downloading(progress: progress)
        }
        return coordinator.dictation.modelStatus?.availability
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        LabeledContent("On-device model") {
            HStack(spacing: 8) {
                if let availability = effectiveAvailability {
                    Image(systemName: modelSymbol(for: availability))
                        .foregroundStyle(modelTint(for: availability))
                    Text(availability.title)
                        .foregroundStyle(availability.isInstalled ? .primary : .secondary)

                    if availability.isInstallable {
                        Button("Install") {
                            coordinator.dictation.installModel(for: preferences.dictationLanguage)
                        }
                        .disabled(coordinator.dictation.isInstallingModel)
                    }
                } else if coordinator.dictation.isCheckingModel {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: preferences.dictationLanguage) {
            await coordinator.dictation.refreshModelStatus(for: preferences.dictationLanguage)
        }
    }

    private func refreshReserved() async {
        reservedLanguages = await DictationModelCatalog.reservedLanguages()
    }

    private var modelExplanation: String {
        switch effectiveAvailability {
        case .unsupported:
            "macOS has no on-device dictation model for this language. Choose another language above."
        case .unavailable:
            "This Mac does not support on-device speech recognition."
        case .installed:
            "Dictation runs entirely on this Mac. Remove downloaded languages in System Settings → General → Language & Region."
        default:
            "A one-time download from Apple, roughly the size of a large app update. Dictation cannot start until it finishes."
        }
    }

    private func modelSymbol(for availability: DictationModelAvailability) -> String {
        switch availability {
        case .installed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .availableToInstall: "arrow.down.circle.dotted"
        case .unsupported, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private func modelTint(for availability: DictationModelAvailability) -> Color {
        switch availability {
        case .installed: .green
        case .downloading, .availableToInstall: .accentColor
        case .unsupported, .unavailable: .orange
        }
    }
}
