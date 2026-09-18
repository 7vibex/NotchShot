import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var preferences = Preferences.shared
    @ObservedObject private var updates = SecureUpdateController.shared
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
                    if updates.pendingUpdateVersion != nil {
                        SettingsSidebarUpdateRow {
                            updates.checkForUpdates(nil)
                        }
                    }
                    ForEach(filteredSections) { section in
                        SettingsSidebarLabel(
                            section: section,
                            isSelected: selection == section
                        )
                        .tag(section)
                        .accessibilityLabel(section.title)
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
        case .activities:
            ActivityIslandSettings(coordinator: coordinator, preferences: preferences)
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

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case presets
    case recording
    case dictation
    case appearance
    case activities
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
        case .activities: "Live Activities"
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
        case .activities: "Activities"
        case .integrations: "Media"
        case .context: "Context"
        case .privacy: "Privacy"
        case .shortcuts: "Hotkeys"
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
        case .activities: "capsule.on.rectangle"
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
        case .activities: .pink
        case .integrations: .orange
        case .context: .teal
        case .privacy: .green
        case .shortcuts: .gray
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
        case .activities:
            ["dynamic island", "multiple activities", "satellite", "swipe", "trackpad", "haptic", "focus", "transfer", "localsend", "airdrop", "live activity", "cli", "external", "alerts"]
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

enum SettingsWorkbenchStyle {
    static let accent = Color.accentColor
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let detailBackground = Color(nsColor: .underPageBackgroundColor)
    static let keyline = Color(nsColor: .separatorColor).opacity(0.7)
}

enum UserIdentity {
    static var fullName: String { NSFullUserName() }

    static var initials: String {
        let words = fullName.split(separator: " ")
        let letters = words.compactMap(\.first)
        if letters.count >= 2 {
            return String(letters.prefix(2)).uppercased()
        }
        return String(fullName.prefix(2)).uppercased()
    }
}

extension View {
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
