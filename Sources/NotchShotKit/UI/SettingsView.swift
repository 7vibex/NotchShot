import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI

public struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var preferences = Preferences.shared
    @State private var selection: SettingsSection? = .general
    @State private var searchText = ""

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SettingsSidebarSearchField(text: $searchText)
                SettingsSidebarIdentity()

                List(selection: $selection) {
                    ForEach(SettingsSidebarGroup.allCases) { group in
                        let sections = filteredSections.filter { $0.sidebarGroup == group }
                        if !sections.isEmpty {
                            Section(group.title) {
                                ForEach(sections) { section in
                                    SettingsSidebarLabel(
                                        section: section,
                                        isSelected: selection == section
                                    )
                                    .tag(section)
                                    .accessibilityLabel(section.title)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(SettingsWorkbenchStyle.sidebarBackground)
            .navigationSplitViewColumnWidth(
                min: SettingsWindowMetrics.sidebarMinimumWidth,
                ideal: SettingsWindowMetrics.sidebarIdealWidth,
                max: SettingsWindowMetrics.sidebarMaximumWidth
            )
            .onChange(of: searchText) { _, _ in
                guard selection.map(filteredSections.contains) != true else { return }
                selection = filteredSections.first
            }
        } detail: {
            ZStack {
                SettingsWorkbenchStyle.detailBackground
                    .ignoresSafeArea()

                if let selection {
                    VStack(spacing: 0) {
                        SettingsPaneHeader(section: selection)
                        settingsPane(for: selection)
                    }
                    .notchShotContentSwap(id: selection)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .notchShotContentSwap(id: "empty-\(searchText)")
                }
            }
            .navigationTitle(selection?.title ?? "Settings")
        }
        .tint(SettingsWorkbenchStyle.accent)
        .frame(
            minWidth: SettingsWindowMetrics.minimumWidth,
            idealWidth: SettingsWindowMetrics.defaultSize.width,
            minHeight: SettingsWindowMetrics.minimumHeight,
            idealHeight: SettingsWindowMetrics.defaultSize.height
        )
    }

    @ViewBuilder
    private func settingsPane(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettings(coordinator: coordinator, preferences: preferences)
        case .capture:
            CaptureSettings(preferences: preferences)
        case .presets:
            RecipeSettings()
        case .recording:
            RecordingSettings(preferences: preferences)
        case .dictation:
            DictationSettings(coordinator: coordinator, preferences: preferences)
        case .appearance:
            NotchSettings(coordinator: coordinator, preferences: preferences)
        case .integrations:
            MediaSettings(coordinator: coordinator, preferences: preferences)
        case .context:
            ContextModuleSettings(coordinator: coordinator, preferences: preferences)
        case .privacy:
            PrivacySettings(coordinator: coordinator, preferences: preferences)
        case .shortcuts:
            ShortcutSettings()
        }
    }

    private var filteredSections: [SettingsSection] {
        SettingsSearchPolicy.matchingSections(
            query: searchText,
            sections: SettingsSection.allCases,
            id: \SettingsSection.rawValue,
            title: \SettingsSection.title,
            keywords: \SettingsSection.searchKeywords
        )
    }
}

enum SettingsWindowMetrics {
    static let defaultSize = CGSize(width: 980, height: 700)
    static let minimumWidth: CGFloat = 900
    static let minimumHeight: CGFloat = 620
    static let sidebarMinimumWidth: CGFloat = 250
    static let sidebarIdealWidth: CGFloat = 268
    static let sidebarMaximumWidth: CGFloat = 294
}

fileprivate enum SettingsSidebarGroup: String, CaseIterable, Identifiable {
    case workspace
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .system: "System"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case presets
    case recording
    case dictation
    case appearance
    case integrations
    case context
    case privacy
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture & Export"
        case .presets: "Presets"
        case .recording: "Recording"
        case .dictation: "Dictation"
        case .appearance: "Appearance & Displays"
        case .integrations: "Integrations"
        case .context: "Context Modules"
        case .privacy: "Privacy"
        case .shortcuts: "Shortcuts & Automation"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .presets: "Presets"
        case .recording: "Record"
        case .dictation: "Dictation"
        case .appearance: "Display"
        case .integrations: "Media"
        case .context: "Context"
        case .privacy: "Privacy"
        case .shortcuts: "Hotkeys"
        }
    }

    fileprivate var sidebarGroup: SettingsSidebarGroup {
        switch self {
        case .general, .capture, .presets, .recording, .dictation, .appearance:
            .workspace
        case .integrations, .context, .privacy, .shortcuts:
            .system
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .presets: "wand.and.stars"
        case .recording: "record.circle"
        case .dictation: "mic"
        case .appearance: "macbook"
        case .integrations: "puzzlepiece.extension"
        case .context: "rectangle.topthird.inset.filled"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        }
    }

    var symbolTint: Color {
        switch self {
        case .general: .gray
        case .capture: .blue
        case .presets: .purple
        case .recording: .red
        case .dictation: .blue
        case .appearance: .indigo
        case .integrations: .orange
        case .context: .teal
        case .privacy: .green
        case .shortcuts: .gray
        }
    }

    var summary: String {
        switch self {
        case .general:
            "Startup, storage, updates, and the everyday defaults for NotchShot."
        case .capture:
            "Choose how screenshots are selected, saved, copied, and surfaced."
        case .presets:
            "Build reusable capture recipes for the workflows you repeat most."
        case .recording:
            "Tune video quality, audio, captions, pointer effects, and export."
        case .dictation:
            "Configure private voice input, language, cleanup, and insertion."
        case .appearance:
            "Shape how the notch, displays, system HUD, and floating basket behave."
        case .integrations:
            "Control trusted media bridges and Now Playing fallbacks."
        case .context:
            "Bring focused calendar, timer, agent, and voice-note context to the notch."
        case .privacy:
            "Review permissions, local history, clipboard access, and retention."
        case .shortcuts:
            "Set global hotkeys and automation entry points for fast capture."
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            ["launch", "login", "dock", "storage", "folder", "updates", "version"]
        case .capture:
            ["screenshot", "image", "export", "format", "jpeg", "heic", "shelf", "quick actions", "cursor"]
        case .presets:
            ["recipe", "github", "app store", "documentation", "social", "bug report"]
        case .recording:
            ["video", "screen", "microphone", "audio", "captions", "frame rate", "resolution", "cursor", "click"]
        case .dictation:
            ["voice", "speech", "transcription", "push to talk", "language", "insert", "filler words"]
        case .appearance:
            ["notch", "display", "hover", "brightness", "volume", "hud", "basket", "jiggle", "liquid glass"]
        case .integrations:
            ["music", "spotify", "now playing", "airplay", "audio route", "adapter", "automation", "notification center", "lock screen", "activity stack", "reply"]
        case .context:
            ["calendar", "reminders", "planner", "pomodoro", "focus timer", "voice notes", "agents", "ai activity", "charging"]
        case .privacy:
            ["permissions", "clipboard", "history", "ocr", "screen recording", "microphone", "accessibility", "retention"]
        case .shortcuts:
            ["hotkey", "keyboard", "automation", "url", "finder services", "alfred", "raycast"]
        }
    }
}

private enum SettingsWorkbenchStyle {
    static let accent = Color.accentColor
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let detailBackground = Color(nsColor: .underPageBackgroundColor)
    static let groupedSurface = Color(nsColor: .controlBackgroundColor)
    static let keyline = Color(nsColor: .separatorColor).opacity(0.7)
}

private struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .accessibilityLabel("Search settings")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsWorkbenchStyle.keyline, lineWidth: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct SettingsSidebarIdentity: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(SettingsWorkbenchStyle.accent.gradient)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("NotchShot")
                    .font(.system(size: 15, weight: .semibold))
                Text("Local-first capture")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSidebarLabel: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(section.symbolTint.gradient)
                }

            Text(section.sidebarTitle)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

private struct SettingsPaneHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(section.symbolTint.gradient)
                Image(systemName: section.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 68, height: 68)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            .accessibilityHidden(true)

            Text(section.title)
                .font(.system(size: 27, weight: .bold))

            Text(section.summary)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 620)

            Label("Stored on this Mac", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SettingsWorkbenchStyle.groupedSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(SettingsWorkbenchStyle.keyline, lineWidth: 0.75)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title). \(section.summary) Settings are stored on this Mac")
    }
}

private extension View {
    func settingsWorkbenchFormStyle() -> some View {
        formStyle(.grouped)
            .font(.system(size: 13))
            .controlSize(.regular)
            .environment(\.defaultMinListRowHeight, 38)
            .scrollContentBackground(.hidden)
            .background(SettingsWorkbenchStyle.detailBackground)
    }
}

/// Pure matching logic so Settings search can be regression-tested without
/// constructing a SwiftUI navigation hierarchy.
public enum SettingsSearchPolicy {
    public static func matchingSections<Section>(
        query: String,
        sections: [Section],
        id: KeyPath<Section, String>,
        title: KeyPath<Section, String>,
        keywords: KeyPath<Section, [String]>
    ) -> [Section] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return sections }
        return sections.filter { section in
            let haystack = ([
                section[keyPath: id],
                section[keyPath: title],
            ] + section[keyPath: keywords])
                .joined(separator: " ")
                .lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }
}

// MARK: - Context modules

private struct ContextModuleSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences
    @Bindable private var calendar = CalendarGlanceService.shared
    @State private var plannerText = ""
    @State private var plannerKind: PlannerItemKind = .event
    @State private var plannerDraft: PlannerDraft?
    @State private var plannerMessage: String?
    @State private var pendingHookIntegration: AIHookIntegration?
    @State private var hookMessage: String?
    @State private var customTimerMinutes = 25
    @State private var timerLabel = "Focus"
    @Bindable private var focusTimer = FocusTimerCoordinator.shared

    var body: some View {
        Form {
            Section("AI activity") {
                Toggle("Show Claude, Codex, and Cursor activity", isOn: Binding(
                    get: { preferences.aiActivityEnabled },
                    set: { value in
                        preferences.aiActivityEnabled = value
                        coordinator.refreshContextPreferences()
                    }
                ))
                Toggle("Show active AI work over music", isOn: Binding(
                    get: { preferences.showsAIActivityOverMedia },
                    set: { value in
                        preferences.showsAIActivityOverMedia = value
                        coordinator.refreshContextPreferences()
                    }
                ))
                .disabled(!preferences.aiActivityEnabled)
                HStack {
                    ForEach(AISource.allCases, id: \.rawValue) { source in
                        Toggle(source.title, isOn: Binding(
                            get: { preferences.enabledAISources.contains(source) },
                            set: { enabled in
                                preferences.setAISource(source, enabled: enabled)
                                coordinator.refreshContextPreferences()
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .disabled(!preferences.aiActivityEnabled)
                HStack {
                    Button("Reveal Status Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.aiActivity])
                    }
                    Button("Copy Reporter Path") { copyAIReporterPath() }
                }
                HStack {
                    Text("Connect hooks")
                        .foregroundStyle(.secondary)
                    ForEach(AIHookIntegration.allCases) { integration in
                        Button(integration.title) { pendingHookIntegration = integration }
                    }
                }
                if let hookMessage {
                    Text(hookMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("The bundled reporter accepts explicit local hook events. NotchShot does not scrape AI windows, read transcripts, or send this activity over the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar glance") {
                Toggle("Show upcoming calendar events", isOn: Binding(
                    get: { preferences.calendarGlanceEnabled },
                    set: { enabled in setCalendarEnabled(enabled) }
                ))
                LabeledContent("Calendar access", value: calendar.accessState.title)
                if calendar.accessState == .denied || calendar.accessState == .restricted {
                    Button("Open Calendar Privacy Settings") {
                        guard let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                        ) else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
                Group {
                    Toggle("Show event titles", isOn: Binding(
                        get: { preferences.showsCalendarEventTitles },
                        set: { value in
                            preferences.showsCalendarEventTitles = value
                            calendar.refresh()
                        }
                    ))
                    Toggle("Show imminent events over music", isOn: Binding(
                        get: { preferences.showsImminentEventsOverMedia },
                        set: { value in
                            preferences.showsImminentEventsOverMedia = value
                            calendar.refresh()
                        }
                    ))
                    if !calendar.calendars.isEmpty {
                        DisclosureGroup("Selected calendars") {
                            ForEach(calendar.calendars) { descriptor in
                                Toggle(descriptor.title, isOn: Binding(
                                    get: {
                                        CalendarSelectionPolicy.isSelected(
                                            descriptor.id,
                                            current: preferences.selectedCalendarIdentifiers,
                                            hasCustomSelection: preferences.hasCustomCalendarSelection
                                        )
                                    },
                                    set: { calendar.setCalendarSelected(descriptor.id, selected: $0) }
                                ))
                            }
                            if preferences.hasCustomCalendarSelection {
                                Button("Follow All Calendars") { calendar.selectAllCalendars() }
                            }
                            if preferences.hasCustomCalendarSelection,
                               preferences.selectedCalendarIdentifiers.isEmpty {
                                Text("No calendars selected, so the glance stays empty.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("Hide titles by calendar") {
                            ForEach(calendar.calendars) { descriptor in
                                Toggle(descriptor.title, isOn: Binding(
                                    get: { preferences.hiddenTitleCalendarIdentifiers.contains(descriptor.id) },
                                    set: { calendar.setCalendarTitleHidden(descriptor.id, hidden: $0) }
                                ))
                            }
                        }
                    }
                }
                .disabled(!preferences.calendarGlanceEnabled || calendar.accessState != .granted)
                Text("Event titles stay in memory and never enter capture History, diagnostics, or network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timer, Calendar & Reminders") {
                HStack {
                    ForEach([5, 15, 25, 45], id: \.self) { minutes in
                        Button("\(minutes)m") {
                            coordinator.startFocusTimer(minutes: minutes)
                        }
                    }
                    Spacer()
                    Button("Reveal Voice Notes") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.voiceNotes])
                    }
                    Button("Record Voice Note") { coordinator.startVoiceNote() }
                }
                HStack {
                    TextField("Timer label", text: $timerLabel)
                    Stepper("\(customTimerMinutes) minutes", value: $customTimerMinutes, in: 1...720)
                        .frame(width: 170)
                    Button("Start") {
                        coordinator.startFocusTimer(minutes: customTimerMinutes, label: timerLabel)
                    }
                    Button("Start & Add Reminder") {
                        startTimerWithReminder()
                    }
                }
                if !focusTimer.recent.isEmpty {
                    DisclosureGroup("Recent completed timers") {
                        ForEach(focusTimer.recent.prefix(5), id: \.id) { timer in
                            LabeledContent(timer.label, value: FocusTimerPolicy.formatted(timer.duration))
                        }
                    }
                }
                TextField("Team sync tomorrow at 3pm for 45 minutes", text: $plannerText)
                    .onChange(of: plannerText) { _, _ in
                        plannerDraft = nil
                        plannerMessage = nil
                    }
                Picker("Create", selection: $plannerKind) {
                    ForEach(PlannerItemKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Preview") {
                        plannerDraft = NaturalLanguagePlanner.parse(
                            plannerText,
                            preferredKind: plannerKind
                        )
                        if plannerDraft == nil { plannerMessage = "Add a title and a day/time." }
                    }
                    if let draft = plannerDraft {
                        Text("\(draft.title) · \(draft.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Add") { savePlannerDraft(draft) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let plannerMessage {
                    Text(plannerMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Nothing is written until you preview and press Add. Calendar and Reminders permissions are requested separately by macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status feedback") {
                Toggle("Show charging and battery transitions", isOn: Binding(
                    get: { preferences.powerStatusEnabled },
                    set: { value in
                        preferences.powerStatusEnabled = value
                        coordinator.refreshContextPreferences()
                    }
                ))
                Toggle("Show connected audio-route changes", isOn: Binding(
                    get: { preferences.audioRouteStatusEnabled },
                    set: { value in
                        preferences.audioRouteStatusEnabled = value
                        coordinator.refreshContextPreferences()
                    }
                ))
                Text("Audio feedback uses the public Core Audio output route only. It never guesses accessory battery level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Document summaries") {
                Text("Drop a supported document onto the notch or choose Summarize Document from the menu-bar app. Reading begins only after confirmation and stays on this Mac.")
                    .foregroundStyle(.secondary)
                Button("Choose Document…") { chooseDocument() }
            }
        }
        .settingsWorkbenchFormStyle()
        .onAppear {
            if preferences.calendarGlanceEnabled { calendar.start() }
        }
        .alert(item: $pendingHookIntegration) { integration in
            Alert(
                title: Text("Connect \(integration.title)?"),
                message: Text("NotchShot will merge local lifecycle hooks into \(AIHookInstaller.shared.configurationURL(for: integration).path), preserve unrelated settings, and create a backup before changing an existing file."),
                primaryButton: .default(Text("Connect")) { installHooks(for: integration) },
                secondaryButton: .cancel()
            )
        }
    }

    private func copyAIReporterPath() {
        guard let executable = Bundle.main.executableURL else { return }
        let path = executable.deletingLastPathComponent()
            .appendingPathComponent("notchshot-ai", isDirectory: false).path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func installHooks(for integration: AIHookIntegration) {
        guard let executable = Bundle.main.executableURL else {
            hookMessage = AIHookInstallerError.invalidReporter.localizedDescription
            return
        }
        let reporter = executable.deletingLastPathComponent().appendingPathComponent("notchshot-ai")
        do {
            hookMessage = try AIHookInstaller.shared.install(integration, reporterURL: reporter).message
        } catch {
            hookMessage = error.localizedDescription
        }
    }

    private func setCalendarEnabled(_ enabled: Bool) {
        if !enabled {
            preferences.calendarGlanceEnabled = false
            coordinator.refreshContextPreferences()
            return
        }
        Task {
            let granted: Bool
            if calendar.accessState == .granted {
                granted = true
            } else {
                granted = await calendar.requestAccess()
            }
            preferences.calendarGlanceEnabled = granted
            coordinator.refreshContextPreferences()
        }
    }

    private func savePlannerDraft(_ draft: PlannerDraft) {
        Task {
            do {
                try await PlannerEntryService.shared.save(draft)
                plannerMessage = PlannerEntryService.shared.statusMessage
                plannerText = ""
                plannerDraft = nil
                calendar.refresh()
            } catch {
                plannerMessage = error.localizedDescription
            }
        }
    }

    private func startTimerWithReminder() {
        coordinator.startFocusTimer(minutes: customTimerMinutes, label: timerLabel)
        let draft = PlannerDraft(
            kind: .reminder,
            title: "\(timerLabel) timer finished",
            date: Date().addingTimeInterval(TimeInterval(customTimerMinutes * 60))
        )
        Task {
            do {
                try await PlannerEntryService.shared.save(draft)
                plannerMessage = "Timer started and its completion reminder was added."
            } catch {
                plannerMessage = "Timer started, but the reminder was not added: \(error.localizedDescription)"
            }
        }
    }

    private func chooseDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a document to summarize locally."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.summarizeDocument(at: url)
    }
}

// MARK: - Recipes

private struct RecipeSettings: View {
    @Bindable private var store = CaptureRecipeStore.shared

    var body: some View {
        Form {
            Section("Active recipe") {
                Picker("Recipe", selection: $store.activeRecipeID) {
                    ForEach(store.recipes) { recipe in
                        Text(recipe.name).tag(recipe.id)
                    }
                }
                HStack {
                    Button("Duplicate") { store.duplicate(store.activeRecipe) }
                    if store.activeRecipeID.hasPrefix("custom-") {
                        Button("Delete", role: .destructive) {
                            store.deleteCustomRecipe(id: store.activeRecipeID)
                        }
                    }
                }
            }

            Section(store.activeRecipe.name) {
                if store.activeRecipeID.hasPrefix("custom-") {
                    TextField("Name", text: recipeBinding(\.name))
                    TextField("Description", text: recipeBinding(\.detail))
                    TextField("Filename template", text: recipeBinding(\.filenameTemplate))
                    Picker("Destination", selection: recipeBinding(\.destination)) {
                        ForEach(RecipeDestination.allCases, id: \.self) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    Picker("After capture", selection: recipeBinding(\.annotationMode)) {
                        ForEach(RecipeAnnotationMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Resize output", isOn: outputResizeBinding)
                    if store.activeRecipe.outputPixelSize != nil {
                        LabeledContent("Output size") {
                            HStack(spacing: 6) {
                                TextField(
                                    "Width",
                                    value: recipeDimensionBinding(.width),
                                    format: .number.precision(.fractionLength(0))
                                )
                                .frame(width: 78)
                                Text("×").foregroundStyle(.secondary)
                                TextField(
                                    "Height",
                                    value: recipeDimensionBinding(.height),
                                    format: .number.precision(.fractionLength(0))
                                )
                                .frame(width: 78)
                            }
                        }
                    }
                    Picker("Background", selection: backgroundPresetBinding) {
                        if BackgroundPreset.all.contains(where: { $0.configuration == store.activeRecipe.background }) == false {
                            Text("Custom").tag("custom")
                        }
                        ForEach(BackgroundPreset.all) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                    }
                    Picker("Format", selection: recipeBinding(\.imageFormat)) {
                        Text("Capture setting").tag(Optional<ImageFormat>.none)
                        ForEach(ImageFormat.allCases) { format in
                            Text(format.title).tag(Optional(format))
                        }
                    }
                } else {
                    Text(store.activeRecipe.detail)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Size", value: store.activeRecipe.sizeDescription)
                LabeledContent(
                    "Background",
                    value: store.activeRecipe.background.isEnabled ? "Framed" : "None"
                )
                LabeledContent("Annotations", value: store.activeRecipe.annotationMode.title)
                LabeledContent("Filename", value: store.activeRecipe.filenameTemplate)
                LabeledContent("Destination", value: store.activeRecipe.destination.title)
                LabeledContent(
                    "Format",
                    value: store.activeRecipe.imageFormat?.title ?? "Capture setting"
                )
            }

            Section {
                Text("Recipes are capture-focused: they change output, framing, follow-up review, naming, and destination without adding unrelated notch widgets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
    }

    private func recipeBinding<Value>(_ keyPath: WritableKeyPath<CaptureRecipe, Value>) -> Binding<Value> {
        Binding(
            get: { store.activeRecipe[keyPath: keyPath] },
            set: { value in
                var recipe = store.activeRecipe
                recipe[keyPath: keyPath] = value
                store.update(recipe)
            }
        )
    }

    private enum RecipeDimension {
        case width
        case height
    }

    private var outputResizeBinding: Binding<Bool> {
        Binding(
            get: { store.activeRecipe.outputPixelSize != nil },
            set: { enabled in
                var recipe = store.activeRecipe
                recipe.outputPixelSize = enabled ? (recipe.outputPixelSize ?? CGSize(width: 1_920, height: 1_080)) : nil
                store.update(recipe)
            }
        )
    }

    private func recipeDimensionBinding(_ dimension: RecipeDimension) -> Binding<Double> {
        Binding(
            get: {
                let size = store.activeRecipe.outputPixelSize ?? CGSize(width: 1_920, height: 1_080)
                return Double(dimension == .width ? size.width : size.height)
            },
            set: { value in
                var recipe = store.activeRecipe
                var size = recipe.outputPixelSize ?? CGSize(width: 1_920, height: 1_080)
                let clamped = CGFloat(min(max(value.rounded(), 1), 32_768))
                if dimension == .width {
                    size.width = clamped
                } else {
                    size.height = clamped
                }
                recipe.outputPixelSize = size
                store.update(recipe)
            }
        )
    }

    private var backgroundPresetBinding: Binding<String> {
        Binding(
            get: {
                BackgroundPreset.all.first(where: {
                    $0.configuration == store.activeRecipe.background
                })?.id ?? "custom"
            },
            set: { id in
                guard let preset = BackgroundPreset.preset(id: id) else { return }
                var recipe = store.activeRecipe
                recipe.background = preset.configuration
                store.update(recipe)
            }
        )
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
                Text("These four actions stay visible on every result. Actions that do not apply to the selected file are replaced temporarily; everything else remains under More.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsWorkbenchFormStyle()
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
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
            }

            Section("Presentation") {
                Toggle("Frame the recording on a dark background", isOn: $preferences.recordingFramesWithBackground)
                Text("Adds a clean matte around the capture while keeping the selected output resolution.")
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

private struct DictationSettings: View {
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

// MARK: - Notch

private struct NotchSettings: View {
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
                Toggle("Show cover and wave while Mac is locked", isOn: Binding(
                    get: { preferences.showsMediaWhileLocked },
                    set: { newValue in
                        preferences.showsMediaWhileLocked = newValue
                        coordinator.windowController?.refreshLockedPresentation()
                    }
                ))
                .disabled(!preferences.mediaIntegrationEnabled)
                Text("Experimental and off by default. The locked view is display-only: no title, controls, captures, history, settings, or pointer interaction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show activity stack while Mac is locked", isOn: Binding(
                    get: { preferences.showsActivityStackWhileLocked },
                    set: { newValue in
                        preferences.showsActivityStackWhileLocked = newValue
                        coordinator.windowController?.refreshLockedPresentation()
                    }
                ))
                Text("Separate privacy opt-in. Shows current track details, Focus state, and the latest NotchShot-owned alert in a display-only card stack. Replies and controls remain disabled until unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Toggle("Clear history when NotchShot quits", isOn: $preferences.clipboardClearsOnQuit)
                    .disabled(!preferences.clipboardEnabled)
                Text("Pinned items are cleared too. The current system clipboard is left untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Never recorded") {
                    Text("\(preferences.clipboardExcludedBundleIDs.count) apps")
                        .foregroundStyle(.secondary)
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

private struct ShortcutSettings: View {
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
