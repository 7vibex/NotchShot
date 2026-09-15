import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Context modules

struct ContextModuleSettings: View {
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
                Text("The bundled reporter accepts explicit local hook events. Claude sessions can show permission actions and an on-demand local conversation view. NotchShot does not scrape AI windows or send this activity over the network.")
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
                Toggle("Show when the internet connection drops", isOn: Binding(
                    get: { preferences.networkStatusEnabled },
                    set: { value in
                        preferences.networkStatusEnabled = value
                        coordinator.refreshContextPreferences()
                    }
                ))
                Text("Low-battery alerts show the public Low Power Mode state and open Battery Settings; NotchShot cannot switch that system mode itself. Audio feedback uses the public Core Audio output route only and never guesses accessory battery level. Connectivity uses the system's own routing verdict — no probe traffic leaves this Mac, and the network's name is never read or stored.")
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

struct RecipeSettings: View {
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
                    Toggle("Fit to a file-size limit", isOn: recipeTargetSizeEnabled)
                    if store.activeRecipe.targetMaximumBytes != nil {
                        Stepper(
                            "Maximum size: \(recipeTargetMegabytes) MB",
                            value: Binding(
                                get: { recipeTargetMegabytes },
                                set: { recipeTargetMegabytes = $0 }
                            ),
                            in: 1 ... 100
                        )
                    }
                    Toggle("Run OCR after capture", isOn: Binding(
                        get: { store.activeRecipe.runsOCR == true },
                        set: { recipeBinding(\.runsOCR).wrappedValue = $0 ? true : nil }
                    ))
                    TextField("Library tags, comma separated", text: Binding(
                        get: { (store.activeRecipe.libraryTags ?? []).joined(separator: ", ") },
                        set: { value in
                            recipeBinding(\.libraryTags).wrappedValue = value
                                .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        }
                    ))
                    TextField("Library collection", text: Binding(
                        get: { store.activeRecipe.collectionName ?? "" },
                        set: { recipeBinding(\.collectionName).wrappedValue = $0.isEmpty ? nil : $0 }
                    ))
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

    private var recipeTargetSizeEnabled: Binding<Bool> {
        Binding(
            get: { store.activeRecipe.targetMaximumBytes != nil },
            set: { enabled in
                var recipe = store.activeRecipe
                recipe.targetMaximumBytes = enabled ? (recipe.targetMaximumBytes ?? 5 * 1_024 * 1_024) : nil
                store.update(recipe)
            }
        )
    }

    private var recipeTargetMegabytes: Int {
        get { max(1, (store.activeRecipe.targetMaximumBytes ?? 1_024 * 1_024) / (1_024 * 1_024)) }
        nonmutating set {
            var recipe = store.activeRecipe
            recipe.targetMaximumBytes = newValue * 1_024 * 1_024
            store.update(recipe)
        }
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
