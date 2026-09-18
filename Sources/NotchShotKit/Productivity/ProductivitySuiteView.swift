@preconcurrency import AVFoundation
import AppKit
import SwiftUI

public struct ProductivitySuiteView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var router = ProductivityCenterRouter.shared

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationSplitView {
            List(ProductivityTool.allCases, selection: $router.selectedTool) { tool in
                Label(tool.title, systemImage: tool.symbolName)
                    .tag(tool)
            }
            .navigationTitle("Productivity")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            Group {
                switch router.selectedTool {
                case .notifications: ProductivityNotificationCenterView(coordinator: coordinator)
                case .notes: NotesToolView()
                case .schedule: ScheduleToolView(coordinator: coordinator)
                case .lyrics: LyricsToolView(coordinator: coordinator)
                case .weather: WeatherToolView()
                case .systemStats: SystemStatsToolView()
                case .terminal: TerminalToolView()
                case .launcher: LauncherToolView()
                case .localSend: LocalSendToolView()
                case .windowSnap: WindowSnapToolView(coordinator: coordinator)
                case .camera: CameraToolView()
                }
            }
            .navigationTitle(router.selectedTool.title)
            .notchShotContentSwap(id: router.selectedTool)
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 560, idealHeight: 640)
    }
}

private struct NotesToolView: View {
    @Bindable private var store = ProductivityNoteStore.shared
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Local Notes").font(.headline)
                    Spacer()
                    Button {
                        selectedID = store.create().id
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                }
                if store.notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Notes stay in NotchShot’s local Application Support folder.")
                    )
                } else {
                    List(store.notes, selection: $selectedID) { note in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.title).lineLimit(1)
                            Text(note.updatedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(note.id)
                    }
                }
                if let error = store.lastError {
                    InlineErrorMessage(message: error)
                }
            }
            .padding()
            .frame(minWidth: 250, idealWidth: 290)
            .frame(maxHeight: .infinity, alignment: .top)

            if let note = selectedNote {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: noteBinding(note, keyPath: \ProductivityNote.title))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                    TextEditor(text: noteBinding(note, keyPath: \ProductivityNote.body))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Note body")
                    HStack {
                        Text("Saved locally")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            store.delete(id: note.id)
                            selectedID = store.notes.first?.id
                        }
                    }
                }
                .padding()
                .frame(minWidth: 400)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("Select a Note", systemImage: "note.text")
                    .frame(minWidth: 400)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { selectedID = selectedID ?? store.notes.first?.id }
    }

    private var selectedNote: ProductivityNote? {
        guard let selectedID else { return nil }
        return store.notes.first { $0.id == selectedID }
    }

    private func noteBinding(
        _ note: ProductivityNote,
        keyPath: WritableKeyPath<ProductivityNote, String>
    ) -> Binding<String> {
        Binding(
            get: { store.notes.first(where: { $0.id == note.id })?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var current = store.notes.first(where: { $0.id == note.id }) else { return }
                current[keyPath: keyPath] = value
                store.update(current)
            }
        )
    }
}

private struct ScheduleToolView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var plannerText = ""
    @State private var kind: PlannerItemKind = .event
    @State private var message: String?
    @State private var notificationTitle = "NotchShot reminder"
    @State private var notificationBody = "Scheduled from NotchShot Productivity Center"
    @State private var notificationPriority: ProductivityNotificationPriority = .standard
    @State private var notificationMinutes = 10
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("Calendar & Reminders") {
                Picker("Create", selection: $kind) {
                    ForEach(PlannerItemKind.allCases) { item in Text(item.title).tag(item) }
                }
                TextField("Example: Design review tomorrow at 3pm for 45 minutes", text: $plannerText)
                Button("Review and Add") { addPlannerItem() }
                    .disabled(plannerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if notificationsDenied {
                    Button("Open Notification Settings…") {
                        coordinator.openNotificationSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section("Pomodoro") {
                HStack {
                    ForEach([5, 15, 25, 45], id: \.self) { minutes in
                        Button("\(minutes)m") { coordinator.startFocusTimer(minutes: minutes) }
                    }
                }
                Text("The running timer appears as a live notch activity. Completion is local and does not claim Apple Clock synchronization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App-owned Notification") {
                TextField("Notification title", text: $notificationTitle)
                TextField("Message", text: $notificationBody, axis: .vertical)
                    .lineLimit(2 ... 4)
                Picker("Priority", selection: $notificationPriority) {
                    ForEach(ProductivityNotificationPriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }
                Stepper("In \(notificationMinutes) minutes", value: $notificationMinutes, in: 1 ... 1_440)
                Button("Schedule Notification") { scheduleNotification() }
                Button("Open Notification Center") {
                    coordinator.openProductivity(tool: .notifications)
                }
                Text("NotchShot can schedule and act on its own notifications. macOS exposes no API for another app’s history or reply channel; the optional Accessibility mirror in Settings shows only visibly presented banners and can hand a recognized source back to its app for reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .notchShotFormStyle()
    }

    private func addPlannerItem() {
        guard var draft = NaturalLanguagePlanner.parse(plannerText) else {
            message = "Add a title and date, such as ‘Standup tomorrow at 9am’."
            return
        }
        draft.kind = kind
        Task {
            do {
                try await PlannerEntryService.shared.save(draft)
                message = draft.kind == .event ? "Calendar event added." : "Reminder added."
                plannerText = ""
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func scheduleNotification() {
        Task {
            do {
                guard try await ProductivityNotificationCenter.shared.requestAuthorization() else {
                    notificationsDenied = true
                    message = "Notifications were not allowed."
                    return
                }
                try await ProductivityNotificationCenter.shared.schedule(
                    title: notificationTitle,
                    body: notificationBody,
                    priority: notificationPriority,
                    at: Date().addingTimeInterval(TimeInterval(notificationMinutes * 60))
                )
                notificationsDenied = false
                message = "Notification scheduled."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct LyricsToolView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var store = LyricsStore.shared
    @State private var text = ""
    @State private var message: String?

    private var trackKey: String? {
        LyricsStore.key(
            artist: coordinator.media.snapshot.artist,
            title: coordinator.media.snapshot.title
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = coordinator.media.snapshot.title {
                Text(title).font(.title2.weight(.semibold))
                Text(coordinator.media.snapshot.artist ?? "Unknown artist")
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Lyrics for current track")
                HStack {
                    Button("Save Local Lyrics") { save() }
                    Button("Import Text File…") { importLyrics() }
                    Spacer()
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Lyrics are user-supplied and stored locally. Apple Music and Spotify do not provide a public cross-app lyrics API that NotchShot can faithfully use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "music.note",
                    description: Text("Start Music or Spotify, then return here to attach local lyrics.")
                )
            }
        }
        .padding()
        .onAppear(perform: load)
        .onChange(of: trackKey) { _, _ in load() }
    }

    private func load() {
        text = trackKey.map(store.lyrics(for:)) ?? ""
        message = nil
    }

    private func save() {
        guard let trackKey else { return }
        do {
            try store.setLyrics(text, for: trackKey)
            message = "Saved locally"
        } catch {
            message = error.localizedDescription
        }
    }

    private func importLyrics() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 300_000 else {
                message = "That lyrics file is too large."
                return
            }
            text = String(decoding: data, as: UTF8.self)
            save()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct WeatherToolView: View {
    @AppStorage("productivity.weather.latitude") private var latitude = ""
    @AppStorage("productivity.weather.longitude") private var longitude = ""
    @State private var reading: WeatherReading?
    @State private var message: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            Section("Location") {
                TextField("Latitude", text: $latitude)
                TextField("Longitude", text: $longitude)
                Button(isLoading ? "Refreshing…" : "Refresh Weather") { refresh() }
                    .disabled(isLoading)
                Text("Coordinates are stored locally. They are sent only to Open-Meteo when you press Refresh; NotchShot does not request Location permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reading {
                Section("Current Conditions") {
                    LabeledContent("Conditions", value: reading.summary)
                    LabeledContent("Temperature", value: reading.temperatureCelsius.formatted(.number.precision(.fractionLength(1))) + " °C")
                    LabeledContent("Feels like", value: reading.apparentTemperatureCelsius.formatted(.number.precision(.fractionLength(1))) + " °C")
                    LabeledContent("Wind", value: reading.windKilometersPerHour.formatted(.number.precision(.fractionLength(0))) + " km/h")
                }
            }
            if let message { Section { InlineErrorMessage(message: message) } }
        }
        .notchShotFormStyle()
    }

    private func refresh() {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else {
            message = WeatherServiceError.invalidCoordinate.localizedDescription
            return
        }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                reading = try await WeatherService.shared.fetch(latitude: lat, longitude: lon)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct SystemStatsToolView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let stats = SystemStatsSnapshot.capture()
            Form {
                Section("System") {
                    LabeledContent("CPU cores", value: "\(stats.logicalProcessors)")
                    LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(stats.physicalMemoryBytes), countStyle: .memory))
                    LabeledContent("Uptime", value: Duration.seconds(stats.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                    LabeledContent("Thermal state", value: stats.thermalState)
                    LabeledContent("Low Power Mode", value: stats.lowPowerModeEnabled ? "On" : "Off")
                }
                Section("Load Average") {
                    LabeledContent("1 minute", value: stats.loadAverage1Minute.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("5 minutes", value: stats.loadAverage5Minutes.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("15 minutes", value: stats.loadAverage15Minutes.formatted(.number.precision(.fractionLength(2))))
                }
            }
            .notchShotFormStyle()
        }
    }
}

private struct TerminalToolView: View {
    @State private var command = ""
    @State private var output = "Run a command to see its output here."
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Terminal").font(.title3.weight(.semibold))
            HStack {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button(isRunning ? "Running…" : "Run", action: run)
                    .disabled(isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            Text("Commands run only after you press Run, in your home folder, with a 30-second timeout and a 256 KB output limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func run() {
        let requestedCommand = command
        isRunning = true
        output = "Running…"
        Task {
            defer { isRunning = false }
            do {
                let result = try await TerminalRunner.run(requestedCommand)
                let suffix = result.timedOut
                    ? "\n\n[Timed out]"
                    : "\n\n[Exit \(result.exitCode)]"
                output = result.output + (result.wasTruncated ? "\n[Output truncated]" : "") + suffix
            } catch {
                output = error.localizedDescription
            }
        }
    }
}

private struct LauncherToolView: View {
    @State private var query = ""
    @State private var applications: [ApplicationDescriptor] = []
    @State private var isLoading = true

    private var filtered: [ApplicationDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
            if isLoading {
                ProgressView("Indexing installed applications…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { application in
                    Button {
                        ApplicationCatalog.open(application)
                    } label: {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(application.name)
                                if let bundleIdentifier = application.bundleIdentifier {
                                    Text(bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(application.name)")
                }
            }
        }
        .padding()
        .task {
            let discovered = await Task.detached { ApplicationCatalog.discover() }.value
            applications = discovered
            isLoading = false
        }
    }
}

private struct LocalSendToolView: View {
    @Bindable private var router = ProductivityCenterRouter.shared
    @State private var host = ""
    @State private var port = "53317"
    @State private var usesHTTPS = true
    @State private var selectedFiles: [URL] = []
    @State private var progress: LocalSendProgress?
    @State private var message: String?
    @State private var pendingFingerprint: String?
    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Receiver") {
                TextField("Private IP or .local host", text: $host)
                TextField("Port", text: $port)
                Toggle("Use HTTPS", isOn: $usesHTTPS)
                if !usesHTTPS {
                    Text("HTTP sends file contents without transport encryption. Use it only with a receiver you trust on a private network.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("NotchShot accepts only private-network addresses and uses LocalSend’s v2 prepare/upload contract. It does not relay files through a server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Files") {
                Button("Choose Files…", action: chooseFiles)
                ForEach(selectedFiles, id: \.path) { url in
                    LabeledContent(url.lastPathComponent) {
                        Button("Remove") { selectedFiles.removeAll { $0 == url } }
                    }
                }
                if selectedFiles.isEmpty {
                    Text("No files selected").foregroundStyle(.secondary)
                }
            }

            Section("Transfer") {
                if let progress {
                    ProgressView(value: progress.fraction) {
                        Text(progress.currentFilename ?? "Finishing…")
                    } currentValueLabel: {
                        Text("\(progress.completedFiles) of \(progress.totalFiles)")
                    }
                }
                let controls = LocalSendControlState(
                    pendingFingerprint: pendingFingerprint,
                    isSending: isSending,
                    hasSelection: !selectedFiles.isEmpty
                )
                if controls.showsTrustButton, let pendingFingerprint {
                    Text("Receiver certificate SHA-256")
                        .font(.caption.weight(.semibold))
                    Text(pendingFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("I Verified It — Trust and Send") {
                        send(trustedFingerprint: pendingFingerprint)
                    }
                    .disabled(!controls.trustEnabled)
                } else {
                    Button(isSending ? "Sending…" : "Send with LocalSend") {
                        send(trustedFingerprint: nil)
                    }
                    .disabled(!controls.sendEnabled)
                }
                // Cancel is a property of the in-flight task, not of which
                // branch above is showing. The trusted retry is still a real
                // send, so it needs the same escape hatch as the first one.
                if controls.showsCancelButton {
                    Button("Cancel Transfer", role: .cancel) { sendTask?.cancel() }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .notchShotFormStyle()
        .onAppear {
            guard !router.pendingLocalSendFiles.isEmpty else { return }
            selectedFiles = router.pendingLocalSendFiles
            router.pendingLocalSendFiles = []
        }
        .onChange(of: router.pendingLocalSendFiles) { _, files in
            // Routing files to LocalSend while the tool is already visible must
            // replace the selection too; `onAppear` alone only fires once.
            guard !files.isEmpty else { return }
            selectedFiles = Array(files.prefix(100))
            router.pendingLocalSendFiles = []
            pendingFingerprint = nil
            message = files.count > 100
                ? "LocalSend sends the first 100 files per transfer."
                : nil
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        selectedFiles = Array(urls.prefix(100))
        pendingFingerprint = nil
        message = urls.count > 100
            ? "LocalSend sends the first 100 files per transfer."
            : nil
    }

    private func send(trustedFingerprint: String?) {
        guard let portNumber = Int(port) else {
            message = LocalSendError.invalidPeer.localizedDescription
            return
        }
        let peer = LocalSendPeer(
            alias: host,
            host: host,
            port: portNumber,
            usesHTTPS: usesHTTPS,
            trustedCertificateSHA256: trustedFingerprint
        )
        isSending = true
        message = nil
        progress = nil
        let files = selectedFiles
        let totalBytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        // The island's transfer activity reports the same measured progress
        // and cancels this exact task.
        let store = TransferActivityStore.shared
        var transferID: UUID?
        let task = Task {
            defer { isSending = false }
            do {
                try await LocalSendClient.shared.send(files: files, to: peer) { update in
                    await MainActor.run {
                        guard let transferID else { return }
                        // The client's total is the receiver's accepted count,
                        // which may be smaller than the selection. Record it
                        // before progress so completion cannot promote the
                        // requested files to delivered files.
                        store.updateAcceptedFiles(
                            transferID,
                            acceptedFiles: update.totalFiles
                        )
                        store.update(
                            transferID,
                            completedFiles: update.completedFiles,
                            currentFilename: update.currentFilename,
                            bytesTransferred: update.bytesSent,
                            totalBytes: update.totalBytes
                        )
                        // Mirror the store's ordered publication rather than the
                        // raw callback: a delayed callback for an earlier file
                        // can then neither regress nor overwrite newer UI state.
                        if let snapshot = store.transfers.first(where: { $0.id == transferID }) {
                            progress = LocalSendProgress(
                                completedFiles: snapshot.completedFiles,
                                totalFiles: snapshot.effectiveFileCount,
                                currentFilename: snapshot.currentFilename,
                                bytesSent: snapshot.bytesTransferred,
                                totalBytes: snapshot.totalBytes
                            )
                        }
                    }
                }
                pendingFingerprint = nil
                message = "Transfer completed."
                if let transferID { store.finish(transferID) }
            } catch LocalSendError.certificateNeedsApproval(let fingerprint) {
                pendingFingerprint = fingerprint
                message = "Compare the fingerprint with the receiving device before trusting it."
                if let transferID { store.dismiss(transferID) }
            } catch is CancellationError {
                message = "Transfer cancelled."
                if let transferID { store.markCancelled(transferID) }
            } catch let error as URLError where error.code == .cancelled {
                message = "Transfer cancelled."
                if let transferID { store.markCancelled(transferID) }
            } catch {
                message = error.localizedDescription
                if let transferID { store.finish(transferID, error: error.localizedDescription) }
            }
        }
        sendTask = task
        transferID = store.begin(
            service: .localSend,
            peerName: host,
            fileCount: files.count,
            totalBytes: totalBytes > 0 ? totalBytes : nil,
            cancel: { task.cancel() }
        )
    }
}

private struct WindowSnapToolView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var message: String?

    var body: some View {
        Form {
            Section("Snap the Frontmost Window") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach(WindowSnapPosition.allCases) { position in
                        Button {
                            snap(position)
                        } label: {
                            Label(position.title, systemImage: position.symbolName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("Window Snap uses the public macOS Accessibility API and acts only after you choose a layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mouse Locator") {
                Button("Highlight Pointer") { PointerLocatorService.shared.show() }
                Text("Draws a temporary, click-through ring around the current pointer. It does not alter pointer acceleration or install an event tap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).font(.caption).foregroundStyle(.secondary) } }
        }
        .notchShotFormStyle()
    }

    private func snap(_ position: WindowSnapPosition) {
        do {
            try WindowSnapService.snapFrontmost(to: position)
            message = "Moved the frontmost window to \(position.title.lowercased())."
        } catch {
            message = error.localizedDescription
            coordinator.present(error: error)
        }
    }
}

private struct CameraToolView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presenter Camera").font(.title3.weight(.semibold))
            CameraPreviewView()
                .frame(minHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
            Text("The camera starts only while this view is open. Screen-recording composition remains a separate step so a failed camera cannot corrupt a recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewHostView, context: Context) {}

    static func dismantleNSView(_ nsView: CameraPreviewHostView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.notchshot.camera-preview")
        private let session = AVCaptureSession()
        nonisolated private let stateLock = NSLock()
        nonisolated(unsafe) private var stopped = true

        nonisolated private var isStopped: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stopped
        }

        func start(view: CameraPreviewHostView) {
            stateLock.lock()
            stopped = false
            stateLock.unlock()
            view.previewLayer.session = session
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else { return }
                    Task { @MainActor [weak self] in
                        self?.configureAndStart()
                    }
                }
            default:
                view.showPermissionMessage()
            }
        }

        private func configureAndStart() {
            queue.async { [weak self, session] in
                // A TCC grant can arrive after the view was dismantled; the
                // session must not start with no preview and no owner.
                guard let self, !self.isStopped else { return }
                guard !session.isRunning else { return }
                session.beginConfiguration()
                session.sessionPreset = .high
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      session.canAddInput(input) else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(input)
                session.commitConfiguration()
                session.startRunning()
            }
        }

        func stop() {
            stateLock.lock()
            stopped = true
            stateLock.unlock()
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }
    }
}

private final class CameraPreviewHostView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func showPermissionMessage() {
        let label = NSTextField(labelWithString: "Allow Camera access in System Settings → Privacy & Security → Camera.")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }
}
