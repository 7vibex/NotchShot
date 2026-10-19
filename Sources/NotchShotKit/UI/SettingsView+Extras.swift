import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Share links

struct ShareLinkSettings: View {
    @Bindable private var extras = ExtrasPreferences.shared
    @State private var secret = ""
    @State private var savedSecretFor: String?
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(URL)
        case failed(String)
    }

    private var hasSavedSecret: Bool {
        savedSecretFor == extras.shareLink.accessKeyID && !extras.shareLink.accessKeyID.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("Upload a capture to storage you own and copy a link to it. NotchShot has no server: links work only once you point it at an S3-compatible bucket — Cloudflare R2, AWS S3, Backblaze B2, Wasabi or MinIO.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Storage") {
                LabeledContent("Endpoint") {
                    TextField("https://<account>.r2.cloudflarestorage.com", text: $extras.shareLink.endpoint)
                        .textContentType(.URL)
                }
                if !extras.shareLink.endpoint.isEmpty, extras.shareLink.endpointURL == nil {
                    SettingsWarningRow(message: "The endpoint must be an https:// address.")
                }
                LabeledContent("Bucket") {
                    TextField("my-captures", text: $extras.shareLink.bucket)
                }
                LabeledContent("Region") {
                    TextField("auto", text: $extras.shareLink.region)
                }
                Toggle("Path-style addresses", isOn: $extras.shareLink.usesPathStyle)
                Text("R2 uses region “auto”. Leave path-style on unless your provider asks for bucket subdomains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Access Key") {
                LabeledContent("Access key ID") {
                    TextField("Key ID", text: $extras.shareLink.accessKeyID)
                        .font(.body.monospaced())
                        .onChange(of: extras.shareLink.accessKeyID) { _, _ in loadSecret() }
                }
                LabeledContent("Secret access key") {
                    HStack {
                        SecureField(hasSavedSecret ? "Saved in Keychain" : "Secret", text: $secret)
                        Button("Save") { saveSecret() }
                            .disabled(secret.isEmpty || extras.shareLink.accessKeyID.isEmpty)
                    }
                }
                Text("The secret is stored in your login Keychain, never in NotchShot's settings file. Use a key that can only write to this bucket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Links") {
                LabeledContent("Public address") {
                    TextField("https://captures.example.com", text: $extras.shareLink.publicBaseURL)
                        .textContentType(.URL)
                }
                LabeledContent("Folder") {
                    TextField("notchshot", text: $extras.shareLink.pathPrefix)
                }
                Toggle("Random file names", isOn: $extras.shareLink.randomizesNames)
                Toggle("Copy the link when the upload finishes", isOn: $extras.copiesShareLinkAfterUpload)
                Text("The public address is where the bucket is served — a custom domain or R2's r2.dev address. Without one, links point at the endpoint and work only if the bucket allows public reads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                HStack {
                    Button(testState == .running ? "Uploading…" : "Upload a Test File") { runTest() }
                        .disabled(testState == .running || !extras.shareLink.isComplete || !hasSavedSecret)
                    Spacer()
                }
                switch testState {
                case .idle, .running:
                    EmptyView()
                case .succeeded(let url):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(url.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                    }
                case .failed(let message):
                    SettingsWarningRow(message: message)
                }
            }
        }
        .settingsWorkbenchFormStyle()
        .onAppear(perform: loadSecret)
    }

    private func loadSecret() {
        secret = ""
        let id = extras.shareLink.accessKeyID
        savedSecretFor = ShareLinkKeychain.secret(for: id) == nil ? nil : id
    }

    private func saveSecret() {
        let id = extras.shareLink.accessKeyID
        if ShareLinkKeychain.setSecret(secret, for: id) {
            savedSecretFor = id
            secret = ""
        } else {
            testState = .failed("The secret couldn't be saved to the Keychain.")
        }
    }

    private func runTest() {
        testState = .running
        let configuration = extras.shareLink
        Task {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchshot-test.txt")
            do {
                try Data("NotchShot share-link test — \(Date().formatted())\n".utf8).write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let url = try await ShareLinkUploader.upload(
                    file,
                    configuration: configuration,
                    secret: ShareLinkKeychain.secret(for: configuration.accessKeyID)
                )
                testState = .succeeded(url)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Extras

struct ExtrasSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var extras = ExtrasPreferences.shared
    @Bindable private var preferences = Preferences.shared
    @State private var idleError: String?

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Reply button on mirrored notifications", isOn: $extras.notificationRepliesEnabled)
                Text("Shown when the banner on screen offers Reply, such as Messages. It opens that banner's own reply field, so the app still sends the message. Needs notification mirroring in Media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !preferences.mirrorsSystemNotificationBanners {
                    SettingsWarningRow(message: "Notification mirroring is off.")
                }
            }

            Section("Calls") {
                Toggle("Mute and camera buttons on calls", isOn: $extras.meetingControlsEnabled)
                Text("Zoom, Teams, Slack and Discord get their own shortcut, so the meeting shows you as muted. Other apps, browsers included, mute the Mac's microphone for every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                Toggle("Caps Lock in the notch", isOn: $extras.showsCapsLock)
                Toggle("Keyboard language changes", isOn: $extras.showsInputSource)
                Text("A short burst when Caps Lock turns on or off, or when you switch input source. Language bursts appear only with more than one keyboard layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !preferences.multipleActivitiesEnabled {
                    SettingsWarningRow(message: "Turn on multiple activities in Live Activities to see these.")
                }
            }
            .onChange(of: extras.showsCapsLock) { _, _ in coordinator.refreshUtilities() }
            .onChange(of: extras.showsInputSource) { _, _ in coordinator.refreshUtilities() }

            Section("Downloads") {
                Toggle("Browser downloads as a live activity", isOn: $extras.showsDownloads)
                Text("Safari, Chrome and other browsers report progress for files saving to Downloads. Quick downloads under a second never appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: extras.showsDownloads) { _, _ in coordinator.refreshUtilities() }

            Section("Displays") {
                Toggle("Brightness keys control external displays", isOn: $extras.controlsExternalDisplays)
                Text("The keys adjust the display under the pointer. Monitors that accept DDC change their own backlight; others are dimmed in software. Sliders for every display are under More → Displays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if extras.controlsExternalDisplays, !preferences.suppressesSystemOSD {
                    SettingsWarningRow(message: "Brightness keys reach NotchShot only while it replaces the macOS volume and brightness overlay.")
                }
            }
            .onChange(of: extras.controlsExternalDisplays) { _, _ in coordinator.refreshUtilities() }

            Section("More Menu") {
                Toggle("Running Apps", isOn: $extras.showsAppSwitcher)
                LabeledContent("Pinned shortcuts") {
                    HStack {
                        Text(extras.pinnedShortcuts.isEmpty ? "None" : extras.pinnedShortcuts.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button("Choose…") { coordinator.openProductivity(tool: .shortcuts) }
                    }
                }
                Text("Pinned shortcuts run from the capture menu's More list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Today") {
                Toggle("Workday progress", isOn: $extras.showsDayProgress)
                Picker("Starts", selection: $extras.dayStartHour) {
                    ForEach(0 ..< 23, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                .disabled(!extras.showsDayProgress)
                Picker("Ends", selection: $extras.dayEndHour) {
                    ForEach((extras.dayStartHour + 1) ... 24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                .disabled(!extras.showsDayProgress)
                Toggle("Eye-break reminders", isOn: $extras.eyeBreaksEnabled)
                Stepper("Every \(extras.eyeBreakIntervalMinutes) minutes of use", value: $extras.eyeBreakIntervalMinutes, in: 5 ... 120, step: 5)
                    .disabled(!extras.eyeBreaksEnabled)
                Toggle("Screen time per app", isOn: $extras.screenTimeEnabled)
                Text("Screen time samples the frontmost app every 30 seconds while you're active and stays on this Mac for two weeks. See it under More → Today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: extras.eyeBreaksEnabled) { _, _ in coordinator.wellbeing.refresh() }
            .onChange(of: extras.screenTimeEnabled) { _, _ in coordinator.wellbeing.refresh() }
            .onChange(of: extras.dayStartHour) { _, start in
                if extras.dayEndHour <= start { extras.dayEndHour = start + 1 }
            }

            Section("Developer") {
                Toggle("Review queue", isOn: $extras.reviewQueueEnabled)
                Text("Lists pull requests waiting for your review, through the GitHub CLI (gh) you're signed in to. NotchShot never stores a token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if extras.reviewQueueEnabled, ReviewQueueService.executable == nil {
                    SettingsWarningRow(message: "The GitHub CLI isn't installed. Install it with Homebrew: brew install gh")
                }
            }

            Section("Lock Screen") {
                Toggle("Charging card while plugged in", isOn: $extras.showsChargingWhileLocked)
                if !preferences.showsActivityStackWhileLocked {
                    SettingsWarningRow(message: "Turn on the Lock Screen activity stack in Live Activities to see it.")
                }
            }

            Section("Idle Notch") {
                LabeledContent("Hover animation") {
                    HStack(spacing: 10) {
                        if let url = IdleAnimationStore.currentURL {
                            IdleAnimationView(url: url)
                                .frame(width: 28, height: 28)
                            Button("Remove") { IdleAnimationStore.remove() }
                        }
                        Button("Choose…", action: chooseIdleAnimation)
                    }
                }
                Text("A GIF or picture beside Capture when you hover the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let idleError {
                    SettingsWarningRow(message: idleError)
                }
            }
        }
        .settingsWorkbenchFormStyle()
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 24 { return "Midnight" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func chooseIdleAnimation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = IdleAnimationStore.allowedTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GIF or image for the idle notch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try IdleAnimationStore.install(from: url)
            idleError = nil
        } catch {
            idleError = error.localizedDescription
        }
    }
}

// MARK: - Clipboard import

/// "Import from Maccy / Alfred" for the Clipboard section.
struct ClipboardImportRow: View {
    @Bindable var coordinator: AppCoordinator
    @State private var message: String?
    @State private var isImporting = false

    var body: some View {
        LabeledContent("Import history") {
            Menu(isImporting ? "Importing…" : "Import From") {
                ForEach(ClipboardImportSource.allCases) { source in
                    Button(source.title) { importHistory(from: source) }
                }
            }
            .fixedSize()
            .disabled(isImporting)
        }
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importHistory(from source: ClipboardImportSource) {
        let panel = NSOpenPanel()
        panel.directoryURL = source.defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = source.defaultURL.lastPathComponent
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose \(source.title)'s clipboard database (\(source.defaultURL.lastPathComponent))"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let clippings = try await Task.detached(priority: .userInitiated) {
                    try ClipboardImporter.read(source, from: url)
                }.value
                let added = ClipboardImporter.importClippings(clippings, into: coordinator.clipboard, sourceName: source.title)
                message = clippings.isEmpty
                    ? "No text clippings were found."
                    : "Imported \(added) of \(clippings.count) text clippings from \(source.title)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
