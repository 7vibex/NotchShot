import AppKit
import Foundation
import Observation

public enum ImageFormat: String, Sendable, Codable, CaseIterable, Identifiable {
    case png
    case jpeg
    case heic

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

public enum ShelfDuration: Int, Sendable, Codable, CaseIterable, Identifiable {
    case seconds5 = 5
    case seconds10 = 10
    case seconds30 = 30
    case minutes2 = 120
    case never = -1

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .seconds5: "5 seconds"
        case .seconds10: "10 seconds"
        case .seconds30: "30 seconds"
        case .minutes2: "2 minutes"
        case .never: "Until dismissed"
        }
    }
    public var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

public enum ShelfPresentationStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case detail
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .detail: "Detail"
        case .grid: "Grid"
        }
    }

    public var symbolName: String {
        switch self {
        case .detail: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

public enum UpdateChannel: String, Sendable, Codable, CaseIterable, Identifiable {
    case stable
    case beta

    public var id: String { rawValue }
    public var title: String { self == .stable ? "Stable" : "Beta" }
}

public enum NotchDisplayPlacement: String, Sendable, Codable, CaseIterable, Identifiable {
    case builtInDisplayOnly
    case allDisplays

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtInDisplayOnly: "Built-in MacBook display only"
        case .allDisplays: "All connected displays"
        }
    }

    public func includesDisplay(isBuiltIn: Bool) -> Bool {
        self == .allDisplays || isBuiltIn
    }
}

/// Every user-facing setting, persisted in `UserDefaults`. Observation makes
/// SwiftUI views react without an explicit publisher.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: Capture

    public var imageFormat: ImageFormat = .png { didSet { write(imageFormat.rawValue, .imageFormat) } }
    public var jpegQuality: Double = 0.9 { didSet { write(jpegQuality, .jpegQuality) } }
    public var filenameTemplate: String = "NotchShot {date} at {time}" { didSet { write(filenameTemplate, .filenameTemplate) } }
    public var copyToClipboardAfterCapture = true { didSet { write(copyToClipboardAfterCapture, .copyToClipboard) } }
    public var saveToDiskAfterCapture = false { didSet { write(saveToDiskAfterCapture, .saveToDisk) } }
    public var showsShelfAfterCapture = true { didSet { write(showsShelfAfterCapture, .showsShelf) } }
    public var shelfDuration: ShelfDuration = .seconds30 { didSet { write(shelfDuration.rawValue, .shelfDuration) } }
    public var shelfPresentationStyle: ShelfPresentationStyle = .detail {
        didSet { write(shelfPresentationStyle.rawValue, .shelfPresentationStyle) }
    }
    public private(set) var shelfQuickActions = ShareAction.defaultShelfQuickActions {
        didSet { write(shelfQuickActions.map(\.rawValue), .shelfQuickActions) }
    }
    public var freezeScreenDuringSelection = true { didSet { write(freezeScreenDuringSelection, .freezeScreen) } }
    public var showsMagnifier = true { didSet { write(showsMagnifier, .showsMagnifier) } }
    public var playsCaptureSound = true { didSet { write(playsCaptureSound, .capturesSound) } }
    public var updateChannel: UpdateChannel = .stable { didSet { write(updateChannel.rawValue, .updateChannel) } }
    public var includesCursorInScreenshots = false { didSet { write(includesCursorInScreenshots, .includesCursor) } }

    /// Security-scoped bookmark for the user-chosen output folder.
    public var outputFolderBookmark: Data? { didSet { write(outputFolderBookmark, .outputFolderBookmark) } }

    // MARK: Recording

    public var recordingTargetMode: RecordingTargetMode = .area { didSet { write(recordingTargetMode.rawValue, .recordingTargetMode) } }
    public var recordingResolution: RecordingResolution = .native { didSet { write(recordingResolution.rawValue, .recordingResolution) } }
    public var recordingFrameRate = 60 { didSet { write(recordingFrameRate, .recordingFrameRate) } }
    public var recordsSystemAudio = true { didSet { write(recordsSystemAudio, .recordsSystemAudio) } }
    public var recordsMicrophone = false { didSet { write(recordsMicrophone, .recordsMicrophone) } }
    public var preferredMicrophoneID: String? { didSet { write(preferredMicrophoneID, .preferredMicrophone) } }
    public var recordingShowsCursor = true { didSet { write(recordingShowsCursor, .recordingShowsCursor) } }
    public var recordingHighlightsClicks = false { didSet { write(recordingHighlightsClicks, .recordingHighlightsClicks) } }
    public var recordingAutoZoomsOnClicks = false { didSet { write(recordingAutoZoomsOnClicks, .recordingAutoZoomsOnClicks) } }
    public var recordingFramesWithBackground = false { didSet { write(recordingFramesWithBackground, .recordingFramesWithBackground) } }
    public var recordingGeneratesCaptions = false { didSet { write(recordingGeneratesCaptions, .recordingGeneratesCaptions) } }

    // MARK: Dictation

    public var dictationEnabled = true { didSet { write(dictationEnabled, .dictationEnabled) } }
    public var dictationTriggerMode: DictationTriggerMode = .toggle { didSet { write(dictationTriggerMode.rawValue, .dictationTriggerMode) } }
    public var dictationLanguage = Locale.current.identifier { didSet { write(dictationLanguage, .dictationLanguage) } }
    public var dictationEngine: DictationEngineKind = .speechAnalyzer { didSet { write(dictationEngine.rawValue, .dictationEngine) } }
    public var dictationInsertMode: DictationInsertMode = .automatic { didSet { write(dictationInsertMode.rawValue, .dictationInsertMode) } }
    public var dictationPostProcessing: DictationPostProcessingMode = .clean { didSet { write(dictationPostProcessing.rawValue, .dictationPostProcessing) } }
    public var dictationAppendMode: DictationAppendMode = .space { didSet { write(dictationAppendMode.rawValue, .dictationAppendMode) } }
    public var dictationRemovesFillerWords = true { didSet { write(dictationRemovesFillerWords, .dictationRemovesFillerWords) } }
    public var dictationSpokenFormattingEnabled = true { didSet { write(dictationSpokenFormattingEnabled, .dictationSpokenFormatting) } }
    public var dictationMaximumDuration: TimeInterval = 120 { didSet { write(dictationMaximumDuration, .dictationMaximumDuration) } }
    public var dictationCustomWords: [String] = [] { didSet { write(dictationCustomWords, .dictationCustomWords) } }
    public var dictationDeterministicReplacements: [String: String] = [:] { didSet { write(dictationDeterministicReplacements, .dictationReplacements) } }
    public var dictationPreferredMicrophoneID: String? { didSet { write(dictationPreferredMicrophoneID, .dictationMicrophone) } }

    // MARK: History

    public var historyRetentionDays = 30 { didSet { write(historyRetentionDays, .historyRetentionDays) } }
    public var historyEnabled = true { didSet { write(historyEnabled, .historyEnabled) } }
    /// Opt-in: OCR text only enters the search index when this is on.
    public var indexesCaptureText = false { didSet { write(indexesCaptureText, .indexesCaptureText) } }

    // MARK: Clipboard

    /// Off by default, and deliberately so. A clipboard history is the most
    /// sensitive store this app could keep, and the rest of NotchShot's opt-ins
    /// — text indexing, Calendar Glance, the Apple Events fallback — set the
    /// precedent that a feature which retains content asks first.
    public var clipboardEnabled = false { didSet { write(clipboardEnabled, .clipboardEnabled) } }
    public var clipboardRetentionDays = 7 { didSet { write(clipboardRetentionDays, .clipboardRetentionDays) } }
    public var clipboardClearsOnQuit = false {
        didSet { write(clipboardClearsOnQuit, .clipboardClearsOnQuit) }
    }
    /// Apps whose clipboard traffic is never recorded. Seeded with the common
    /// password managers so the safe behaviour is the default one.
    public var clipboardExcludedBundleIDs = ClipboardMonitor.defaultExcludedBundleIDs {
        didSet { write(Array(clipboardExcludedBundleIDs).sorted(), .clipboardExcluded) }
    }

    // MARK: Notch

    public var notchEnabled = true { didSet { write(notchEnabled, .notchEnabled) } }
    public var notchDisplayPlacement: NotchDisplayPlacement = .builtInDisplayOnly {
        didSet { write(notchDisplayPlacement.rawValue, .notchDisplayPlacement) }
    }
    public var mirrorsPassiveContextOnAllDisplays = true {
        didSet { write(mirrorsPassiveContextOnAllDisplays, .mirrorPassiveContext) }
    }
    /// Hover reveals a compact peek; the full interface still needs a click.
    public var hoverPeekEnabled = true { didSet { write(hoverPeekEnabled, .hoverPeek) } }
    public var hoverPeekDelay: Double = 0.35 { didSet { write(hoverPeekDelay, .hoverPeekDelay) } }
    /// Mirror volume and brightness changes in the notch.
    public var systemLevelHUDEnabled = true { didSet { write(systemLevelHUDEnabled, .systemLevelHUD) } }
    /// Include brightness. Off leaves volume mirroring alone — useful when
    /// auto-brightness is on and the display adapts on its own all day.
    public var mirrorsBrightnessChanges = true { didSet { write(mirrorsBrightnessChanges, .mirrorsBrightness) } }
    /// Experimental direct-build option that pauses macOS's shared OSD helper.
    /// New installs must opt in after reading the warning in Settings.
    public var suppressesSystemOSD = false { didSet { write(suppressesSystemOSD, .suppressesSystemOSD) } }
    /// Take ⇧⌘4 and ⇧⌘5 from macOS and point them at NotchShot.
    public var usesSystemScreenshotShortcuts = false {
        didSet { write(usesSystemScreenshotShortcuts, .usesSystemShortcuts) }
    }
    public var mediaIntegrationEnabled = true { didSet { write(mediaIntegrationEnabled, .mediaEnabled) } }
    /// Privacy-sensitive opt-in. The lock-window presentation is media-only,
    /// compact, and non-interactive; capture results and metadata never use it.
    public var showsMediaWhileLocked = false { didSet { write(showsMediaWhileLocked, .mediaWhileLocked) } }
    /// More revealing lock-session presentation. Off by default and separate
    /// from compact media because it may show track metadata, Focus state, and
    /// the content of NotchShot-owned alerts.
    public var showsActivityStackWhileLocked = false {
        didSet { write(showsActivityStackWhileLocked, .activityStackWhileLocked) }
    }
    /// Privacy-sensitive and intentionally off by default. When enabled,
    /// visible other-app banners are read through Accessibility and shown only
    /// in memory while the user session is unlocked.
    public var mirrorsSystemNotificationBanners = false {
        didSet { write(mirrorsSystemNotificationBanners, .mirrorSystemNotifications) }
    }
    public var appleEventsFallbackEnabled = false { didSet { write(appleEventsFallbackEnabled, .appleEventsFallback) } }
    /// Path to the user-installed mediaremote-adapter bundle, if present.
    public var mediaRemoteAdapterPath: String? { didSet { write(mediaRemoteAdapterPath, .adapterPath) } }
    public var mediaRemoteAdapterIdentity: ExternalFileIdentity? {
        didSet {
            let data = mediaRemoteAdapterIdentity.flatMap { try? JSONEncoder().encode($0) }
            write(data, .adapterIdentity)
        }
    }

    // MARK: Context modules

    public var calendarGlanceEnabled = false { didSet { write(calendarGlanceEnabled, .calendarGlance) } }
    public var selectedCalendarIdentifiers: [String] = [] {
        didSet { write(selectedCalendarIdentifiers, .selectedCalendars) }
    }
    /// Distinguishes "the user has never chosen" from "the user chose none".
    /// Without it an empty selection is indistinguishable from the default
    /// every-calendar state, so deselecting the last calendar silently turns
    /// them all back on.
    public var hasCustomCalendarSelection = false {
        didSet { write(hasCustomCalendarSelection, .customCalendarSelection) }
    }
    public var hiddenTitleCalendarIdentifiers: [String] = [] {
        didSet { write(hiddenTitleCalendarIdentifiers, .hiddenTitleCalendars) }
    }
    public var showsCalendarEventTitles = true {
        didSet { write(showsCalendarEventTitles, .calendarTitles) }
    }
    public var showsImminentEventsOverMedia = false {
        didSet { write(showsImminentEventsOverMedia, .calendarOverMedia) }
    }
    public var powerStatusEnabled = true { didSet { write(powerStatusEnabled, .powerStatus) } }
    public var audioRouteStatusEnabled = false { didSet { write(audioRouteStatusEnabled, .audioRouteStatus) } }
    /// Reads only NotchShot's explicit local reporter files. It does not inspect
    /// other apps until the user chooses to connect one through a hook.
    public var aiActivityEnabled = true { didSet { write(aiActivityEnabled, .aiActivity) } }
    public var showsAIActivityOverMedia = true {
        didSet { write(showsAIActivityOverMedia, .aiActivityOverMedia) }
    }
    public var enabledAISourceRawValues = AISource.allCases.map(\.rawValue) {
        didSet { write(enabledAISourceRawValues, .enabledAISources) }
    }

    public var enabledAISources: Set<AISource> {
        Set(enabledAISourceRawValues.compactMap(AISource.init(rawValue:)))
    }

    public func setAISource(_ source: AISource, enabled: Bool) {
        var sources = enabledAISources
        if enabled { sources.insert(source) } else { sources.remove(source) }
        enabledAISourceRawValues = sources.map(\.rawValue).sorted()
    }

    // MARK: Editor

    public var defaultBackgroundPresetID: String = "none" { didSet { write(defaultBackgroundPresetID, .backgroundPreset) } }
    public var annotationColorHex: String = "#FF3B30" { didSet { write(annotationColorHex, .annotationColor) } }
    public var annotationLineWidth: Double = 4 { didSet { write(annotationLineWidth, .annotationLineWidth) } }

    // MARK: App

    public var launchesAtLogin = false { didSet { write(launchesAtLogin, .launchAtLogin) } }
    public var showsDockIcon = false { didSet { write(showsDockIcon, .showsDockIcon) } }
    public var hasCompletedFirstRun = false { didSet { write(hasCompletedFirstRun, .firstRun) } }
    /// A non-sensitive action token used only to resume the first capture after
    /// macOS requires a relaunch for Screen Recording permission.
    public var pendingFirstCaptureIntent: CaptureIntent? {
        didSet { write(pendingFirstCaptureIntent?.rawValue, .pendingFirstCaptureIntent) }
    }
    /// One-time migration from builds that could suspend OSDUIHelper without a
    /// crash watchdog. Kept separate from the user's replacement preference.
    public var hasRecoveredLegacySystemOSD = false {
        didSet { write(hasRecoveredLegacySystemOSD, .recoveredLegacySystemOSD) }
    }
    /// macOS build the adapter compatibility test last passed against.
    public var lastAdapterCheckBuild: String? { didSet { write(lastAdapterCheckBuild, .adapterCheckBuild) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Replaces or reorders one of the four immediate shelf actions. Choosing
    /// an action already in another slot swaps the two, so duplicate buttons
    /// can never crowd out an operation.
    public func setShelfQuickAction(_ action: ShareAction, at index: Int) {
        guard shelfQuickActions.indices.contains(index),
              ShareAction.customizableShelfCases.contains(action) else { return }
        if let existing = shelfQuickActions.firstIndex(of: action), existing != index {
            shelfQuickActions.swapAt(existing, index)
        } else {
            shelfQuickActions[index] = action
        }
        shelfQuickActions = ShareAction.sanitizedShelfQuickActions(shelfQuickActions)
    }

    // MARK: Derived

    /// Last successful bookmark resolution, keyed by the data it came from.
    ///
    /// Resolving a bookmark touches the file system, and `outputFolder` is read
    /// on every capture, every recording, and by every save panel — so the
    /// uncached spelling paid for a resolution per capture to answer the same
    /// question. Observation-ignored: the cache is derived state and must not
    /// invalidate a view when a read populates it.
    @ObservationIgnored private var resolvedOutputFolder: (bookmark: Data, url: URL)?

    /// True when the last resolution reported the bookmark as stale, so it can
    /// be rewritten at a moment that is allowed to mutate state.
    @ObservationIgnored private var outputFolderBookmarkIsStale = false

    /// Resolved output folder, falling back to ~/Desktop.
    public var outputFolder: URL {
        if let bookmark = outputFolderBookmark {
            if let cached = resolvedOutputFolder, cached.bookmark == bookmark {
                return cached.url
            }
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                resolvedOutputFolder = (bookmark, url)
                outputFolderBookmarkIsStale = stale
                return url
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Rewrites a bookmark macOS has reported as stale.
    ///
    /// The staleness flag used to be computed and dropped on the floor, so a
    /// folder that moved or was renamed kept resolving through an outdated
    /// bookmark for the life of the install. This is deliberately not done
    /// inside `outputFolder`: that is a getter, and rewriting an observed
    /// property from a read would invalidate views mid-update.
    public func refreshOutputFolderBookmarkIfStale() {
        _ = outputFolder
        guard outputFolderBookmarkIsStale,
              let url = resolvedOutputFolder?.url,
              let refreshed = try? url.bookmarkData(
                  options: [.withSecurityScope],
                  includingResourceValuesForKeys: nil,
                  relativeTo: nil
              ) else { return }
        outputFolderBookmarkIsStale = false
        resolvedOutputFolder = (refreshed, url)
        outputFolderBookmark = refreshed
        Log.app.notice("Refreshed a stale output-folder bookmark")
    }

    public func setOutputFolder(_ url: URL) {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        resolvedOutputFolder = bookmark.map { ($0, url) }
        outputFolderBookmarkIsStale = false
        outputFolderBookmark = bookmark
    }

    public var recordingAudioSources: RecordingAudioSources {
        var sources: RecordingAudioSources = []
        if recordsSystemAudio { sources.insert(.system) }
        if recordsMicrophone { sources.insert(.microphone) }
        return sources
    }

    /// Expands the filename template. Unknown tokens are left untouched so a
    /// typo produces a visible artefact rather than a silently empty name.
    public func expandFilename(
        template: String? = nil,
        date: Date = Date(),
        appName: String? = nil
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"

        var name = template ?? filenameTemplate
        name = name.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
        name = name.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
        name = name.replacingOccurrences(of: "{app}", with: appName ?? "Screen")
        name = name.replacingOccurrences(of: "{timestamp}", with: String(Int(date.timeIntervalSince1970)))
        // `/` and `:` are illegal in HFS/APFS display names.
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: ".")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "NotchShot" : trimmed
    }

    // MARK: Storage

    private enum Key: String {
        case imageFormat, jpegQuality, filenameTemplate, copyToClipboard, saveToDisk
        case showsShelf, shelfDuration, shelfPresentationStyle, shelfQuickActions
        case freezeScreen, showsMagnifier, capturesSound, includesCursor
        case outputFolderBookmark
        case recordingTargetMode, recordingResolution, recordingFrameRate
        case recordsSystemAudio, recordsMicrophone, preferredMicrophone
        case recordingShowsCursor, recordingHighlightsClicks, recordingAutoZoomsOnClicks
        case recordingFramesWithBackground
        case recordingGeneratesCaptions
        case dictationEnabled, dictationTriggerMode, dictationLanguage, dictationEngine
        case dictationInsertMode, dictationPostProcessing, dictationAppendMode
        case dictationRemovesFillerWords, dictationSpokenFormatting, dictationMaximumDuration
        case dictationCustomWords, dictationReplacements, dictationMicrophone
        case historyRetentionDays, historyEnabled, indexesCaptureText
        case clipboardEnabled, clipboardRetentionDays, clipboardClearsOnQuit, clipboardExcluded
        case notchEnabled, notchDisplayPlacement, islandOnExternal, mirrorPassiveContext, hoverPeek, hoverPeekDelay, systemLevelHUD
        case mirrorsBrightness, suppressesSystemOSD, usesSystemShortcuts
        case mediaEnabled, mediaWhileLocked, activityStackWhileLocked, mirrorSystemNotifications
        case appleEventsFallback, adapterPath, adapterIdentity
        case calendarGlance, selectedCalendars, hiddenTitleCalendars, calendarTitles, calendarOverMedia
        case customCalendarSelection
        case powerStatus, audioRouteStatus, aiActivity, aiActivityOverMedia, enabledAISources
        case backgroundPreset, annotationColor, annotationLineWidth
        case launchAtLogin, showsDockIcon, firstRun, pendingFirstCaptureIntent, updateChannel
        case recoveredLegacySystemOSD, adapterCheckBuild
    }

    private func write(_ value: Any?, _ key: Key) {
        guard !isLoading else { return }
        defaults.set(value, forKey: "notchshot.\(key.rawValue)")
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        func string(_ key: Key) -> String? { defaults.string(forKey: "notchshot.\(key.rawValue)") }
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: "notchshot.\(key.rawValue)") as? Bool ?? fallback
        }
        func int(_ key: Key, _ fallback: Int) -> Int {
            defaults.object(forKey: "notchshot.\(key.rawValue)") as? Int ?? fallback
        }
        func double(_ key: Key, _ fallback: Double) -> Double {
            defaults.object(forKey: "notchshot.\(key.rawValue)") as? Double ?? fallback
        }

        imageFormat = string(.imageFormat).flatMap(ImageFormat.init) ?? .png
        jpegQuality = double(.jpegQuality, 0.9)
        filenameTemplate = string(.filenameTemplate) ?? "NotchShot {date} at {time}"
        copyToClipboardAfterCapture = bool(.copyToClipboard, true)
        saveToDiskAfterCapture = bool(.saveToDisk, false)
        showsShelfAfterCapture = bool(.showsShelf, true)
        shelfDuration = ShelfDuration(rawValue: int(.shelfDuration, 30)) ?? .seconds30
        shelfPresentationStyle = string(.shelfPresentationStyle)
            .flatMap(ShelfPresentationStyle.init) ?? .detail
        let storedShelfActions = defaults.stringArray(
            forKey: "notchshot.\(Key.shelfQuickActions.rawValue)"
        )?.compactMap(ShareAction.init(rawValue:)) ?? []
        shelfQuickActions = ShareAction.sanitizedShelfQuickActions(storedShelfActions)
        freezeScreenDuringSelection = bool(.freezeScreen, true)
        showsMagnifier = bool(.showsMagnifier, true)
        playsCaptureSound = bool(.capturesSound, true)
        includesCursorInScreenshots = bool(.includesCursor, false)
        updateChannel = string(.updateChannel).flatMap(UpdateChannel.init) ?? .stable
        outputFolderBookmark = defaults.data(forKey: "notchshot.\(Key.outputFolderBookmark.rawValue)")

        recordingTargetMode = string(.recordingTargetMode).flatMap(RecordingTargetMode.init) ?? .area
        recordingResolution = string(.recordingResolution).flatMap(RecordingResolution.init) ?? .native
        recordingFrameRate = RecordingConfiguration.sanitizedFramesPerSecond(
            int(.recordingFrameRate, 60)
        )
        recordsSystemAudio = bool(.recordsSystemAudio, true)
        recordsMicrophone = bool(.recordsMicrophone, false)
        preferredMicrophoneID = string(.preferredMicrophone)
        recordingShowsCursor = bool(.recordingShowsCursor, true)
        recordingHighlightsClicks = bool(.recordingHighlightsClicks, false)
        recordingAutoZoomsOnClicks = bool(.recordingAutoZoomsOnClicks, false)
        recordingFramesWithBackground = bool(.recordingFramesWithBackground, false)
        recordingGeneratesCaptions = bool(.recordingGeneratesCaptions, false)

        dictationEnabled = bool(.dictationEnabled, true)
        dictationTriggerMode = string(.dictationTriggerMode).flatMap(DictationTriggerMode.init) ?? .toggle
        dictationLanguage = string(.dictationLanguage) ?? Locale.current.identifier
        dictationEngine = string(.dictationEngine).flatMap(DictationEngineKind.init) ?? .speechAnalyzer
        dictationInsertMode = string(.dictationInsertMode).flatMap(DictationInsertMode.init) ?? .automatic
        dictationPostProcessing = string(.dictationPostProcessing).flatMap(DictationPostProcessingMode.init) ?? .clean
        dictationAppendMode = string(.dictationAppendMode).flatMap(DictationAppendMode.init) ?? .space
        dictationRemovesFillerWords = bool(.dictationRemovesFillerWords, true)
        dictationSpokenFormattingEnabled = bool(.dictationSpokenFormatting, true)
        // Clamped, not trusted. This value arms the timer that stops a
        // dictation nobody is speaking into; a stored zero or negative — which
        // a hand-edited plist or a migrated key can produce — disabled that
        // safety stop entirely and left the microphone open indefinitely.
        dictationMaximumDuration = min(
            max(double(.dictationMaximumDuration, 120), 10),
            3_600
        )
        dictationCustomWords = defaults.stringArray(forKey: "notchshot.\(Key.dictationCustomWords.rawValue)") ?? []
        dictationDeterministicReplacements = defaults.dictionary(forKey: "notchshot.\(Key.dictationReplacements.rawValue)") as? [String: String] ?? [:]
        dictationPreferredMicrophoneID = string(.dictationMicrophone)

        historyRetentionDays = int(.historyRetentionDays, 30)
        historyEnabled = bool(.historyEnabled, true)
        indexesCaptureText = bool(.indexesCaptureText, false)
        clipboardEnabled = bool(.clipboardEnabled, false)
        clipboardRetentionDays = int(.clipboardRetentionDays, 7)
        clipboardClearsOnQuit = bool(.clipboardClearsOnQuit, false)
        if let stored = defaults.array(forKey: "notchshot.\(Key.clipboardExcluded.rawValue)") as? [String] {
            // A user who removed an app from the list must not have it put back
            // on the next launch, so an explicitly stored list wins outright.
            clipboardExcludedBundleIDs = Set(stored)
        } else {
            clipboardExcludedBundleIDs = ClipboardMonitor.defaultExcludedBundleIDs
        }

        notchEnabled = bool(.notchEnabled, true)
        if let storedPlacement = string(.notchDisplayPlacement).flatMap(NotchDisplayPlacement.init) {
            notchDisplayPlacement = storedPlacement
        } else if defaults.object(
            forKey: "notchshot.\(Key.islandOnExternal.rawValue)"
        ) is Bool {
            // Preserve the meaning of the earlier toggle for existing users.
            notchDisplayPlacement = bool(.islandOnExternal, false)
                ? .allDisplays
                : .builtInDisplayOnly
        } else {
            notchDisplayPlacement = .builtInDisplayOnly
        }
        mirrorsPassiveContextOnAllDisplays = bool(.mirrorPassiveContext, true)
        hoverPeekEnabled = bool(.hoverPeek, true)
        hoverPeekDelay = double(.hoverPeekDelay, 0.35)
        systemLevelHUDEnabled = bool(.systemLevelHUD, true)
        mirrorsBrightnessChanges = bool(.mirrorsBrightness, true)
        // Every install without an explicit choice fails open, including
        // upgrades from the earlier build that enabled this by default.
        // Persist the migration result immediately. If the key stayed absent,
        // first-run completion would make a fresh install look "existing" on
        // launch two and silently enable this experimental integration.
        let osdKey = "notchshot.\(Key.suppressesSystemOSD.rawValue)"
        if let stored = defaults.object(forKey: osdKey) as? Bool {
            suppressesSystemOSD = stored
        } else {
            // The old build enabled this private integration by default. A
            // completed first run is not informed consent to the new
            // direct-distribution warning, so every missing-key migration is
            // fail-open and requires an explicit opt-in.
            suppressesSystemOSD = false
            defaults.set(suppressesSystemOSD, forKey: osdKey)
        }
        usesSystemScreenshotShortcuts = bool(.usesSystemShortcuts, false)
        mediaIntegrationEnabled = bool(.mediaEnabled, true)
        showsMediaWhileLocked = bool(.mediaWhileLocked, false)
        showsActivityStackWhileLocked = bool(.activityStackWhileLocked, false)
        mirrorsSystemNotificationBanners = bool(.mirrorSystemNotifications, false)
        appleEventsFallbackEnabled = bool(.appleEventsFallback, false)
        mediaRemoteAdapterPath = string(.adapterPath)
        mediaRemoteAdapterIdentity = defaults.data(
            forKey: "notchshot.\(Key.adapterIdentity.rawValue)"
        ).flatMap { try? JSONDecoder().decode(ExternalFileIdentity.self, from: $0) }

        calendarGlanceEnabled = bool(.calendarGlance, false)
        selectedCalendarIdentifiers = defaults.stringArray(
            forKey: "notchshot.\(Key.selectedCalendars.rawValue)"
        ) ?? []
        // Installs that already narrowed their calendars keep that meaning on
        // upgrade; a stored non-empty list is itself a custom selection.
        hasCustomCalendarSelection = bool(
            .customCalendarSelection,
            !selectedCalendarIdentifiers.isEmpty
        )
        hiddenTitleCalendarIdentifiers = defaults.stringArray(
            forKey: "notchshot.\(Key.hiddenTitleCalendars.rawValue)"
        ) ?? []
        showsCalendarEventTitles = bool(.calendarTitles, true)
        showsImminentEventsOverMedia = bool(.calendarOverMedia, false)
        powerStatusEnabled = bool(.powerStatus, true)
        audioRouteStatusEnabled = bool(.audioRouteStatus, false)
        aiActivityEnabled = bool(.aiActivity, true)
        showsAIActivityOverMedia = bool(.aiActivityOverMedia, true)
        enabledAISourceRawValues = defaults.stringArray(
            forKey: "notchshot.\(Key.enabledAISources.rawValue)"
        ) ?? AISource.allCases.map(\.rawValue)

        defaultBackgroundPresetID = string(.backgroundPreset) ?? "none"
        annotationColorHex = string(.annotationColor) ?? "#FF3B30"
        annotationLineWidth = double(.annotationLineWidth, 4)

        launchesAtLogin = bool(.launchAtLogin, false)
        showsDockIcon = bool(.showsDockIcon, false)
        hasCompletedFirstRun = bool(.firstRun, false)
        pendingFirstCaptureIntent = string(.pendingFirstCaptureIntent).flatMap(CaptureIntent.init)
        hasRecoveredLegacySystemOSD = bool(.recoveredLegacySystemOSD, false)
        lastAdapterCheckBuild = string(.adapterCheckBuild)
    }
}

/// Everything NotchShot writes lives under Application Support/NotchShot.
public enum AppPaths {
    /// Resolved once: the Application Support location cannot change under a
    /// running process, and `owns` consults this on every managed-file check,
    /// which the history load path performs once per stored row.
    private static let supportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NotchShot", isDirectory: true)
    }()

    public static var support: URL { supportURL }

    public static var captures: URL { support.appendingPathComponent("Captures", isDirectory: true) }
    public static var thumbnails: URL { support.appendingPathComponent("Thumbnails", isDirectory: true) }
    public static var projects: URL { support.appendingPathComponent("Projects", isDirectory: true) }
    public static var recordings: URL { support.appendingPathComponent("Recordings", isDirectory: true) }
    public static var voiceNotes: URL { support.appendingPathComponent("Voice Notes", isDirectory: true) }
    public static var inProgress: URL { support.appendingPathComponent("InProgress", isDirectory: true) }
    /// Partial recordings the user explicitly discarded when macOS could not
    /// move them to Trash. Keeping these outside `InProgress` prevents the
    /// crash-recovery flow from resurrecting a deliberate discard.
    public static var discardedRecordings: URL {
        support.appendingPathComponent("Discarded Recordings", isDirectory: true)
    }
    public static var clipboard: URL { support.appendingPathComponent("Clipboard", isDirectory: true) }
    public static var aiActivity: URL { support.appendingPathComponent("AI Activity", isDirectory: true) }
    public static var historyStore: URL { support.appendingPathComponent("history.json") }
    public static var clipboardStore: URL { support.appendingPathComponent("clipboard.json") }

    /// True only for files physically inside NotchShot's own Application
    /// Support tree. Resolving symlinks prevents a managed-looking pathname
    /// from redirecting reads, writes, or automatic cleanup outside the app's
    /// storage root.
    public static func owns(_ url: URL) -> Bool {
        owns(url, within: support)
    }

    nonisolated static func owns(_ url: URL, within supportRoot: URL) -> Bool {
        let lexicalRoot = supportRoot.standardizedFileURL.path
        let lexicalCandidate = url.standardizedFileURL.path

        // Fast path for the shape every managed file has: a path already
        // spelled inside the storage root. Symlink resolution can only move
        // such a path if one of the components below the root is itself a
        // symbolic link, so checking those directly — one `lstat` each, and
        // there are rarely more than two — decides the same question as
        // resolving the whole path twice. It is an exact substitute, not an
        // approximation: `SymlinkEscapeTests` fuzzes both against each other.
        //
        // Worth the extra branch because this is the answer `owns` gives for
        // thousands of rows in a row when history loads, and resolving a
        // five-component path through Foundation is most of what it cost.
        if let tail = pathComponentsBelow(root: lexicalRoot, of: lexicalCandidate),
           !containsSymbolicLink(root: lexicalRoot, tail: tail),
           !containsSymbolicLink(root: "/", tail: componentsOfAbsolutePath(lexicalRoot)) {
            return true
        }

        let resolvedRoot = resolvedURLPreservingMissingTail(supportRoot).path
        guard resolvedRoot == lexicalRoot else { return false }
        let candidate = resolvedURLPreservingMissingTail(url).path
        return candidate == resolvedRoot || candidate.hasPrefix(resolvedRoot + "/")
    }

    /// The components of `path` that sit below `root`, or nil when `path` is not
    /// lexically inside `root`. An empty array means the two are the same place.
    private nonisolated static func pathComponentsBelow(
        root: String,
        of path: String
    ) -> [String]? {
        if path == root { return [] }
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    private nonisolated static func componentsOfAbsolutePath(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// True when any prefix of `root` + `tail` is a symbolic link.
    ///
    /// Missing components are not symbolic links, which matches how
    /// `resolvedURLPreservingMissingTail` treats a path whose tail does not
    /// exist yet: it carries those components through unresolved.
    private nonisolated static func containsSymbolicLink(root: String, tail: [String]) -> Bool {
        var path = root == "/" ? "" : root
        for component in tail {
            path += "/" + component
            var info = stat()
            let failed = path.withCString { lstat($0, &info) != 0 }
            if failed { continue }
            if info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private nonisolated static func resolvedURLPreservingMissingTail(_ url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/" {
            if pathEntryExists(existingAncestor.path) { break }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// True when anything at all sits at `path` — a file, a directory, or a
    /// symbolic link, including one whose target is missing.
    ///
    /// This is the predicate the walk above needs, and `lstat` answers it in a
    /// single syscall. Expressing it as `fileExists(atPath:) || .isSymbolicLinkKey`
    /// instead — `stat` plus a bridged `URLResourceValues` bag per level — is
    /// what made `owns` cost about 160 µs, and `HistoryEntry.thumbnailURL`
    /// (which calls it against a path whose leaf is usually absent) about 1 ms.
    /// The two agree case for case: `lstat` succeeds exactly when the entry
    /// exists, and a dangling symlink is the one case `stat` alone misses.
    private nonisolated static func pathEntryExists(_ path: String) -> Bool {
        path.withCString { cString in
            var info = stat()
            return lstat(cString, &info) == 0
        }
    }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        var succeeded = true
        for url in [
            support,
            captures,
            thumbnails,
            projects,
            recordings,
            voiceNotes,
            inProgress,
            discardedRecordings,
            clipboard,
            aiActivity,
        ] {
            do {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true || (values != nil && values?.isDirectory != true) {
                    throw CocoaError(
                        .fileWriteInvalidFileName,
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                if url == aiActivity {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700],
                        ofItemAtPath: url.path
                    )
                }
                guard owns(url) else {
                    throw CocoaError(
                        .fileWriteNoPermission,
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
            } catch {
                succeeded = false
                Log.history.error(
                    "Managed storage is unavailable at \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return succeeded
    }

    /// Appends " 2", " 3", … until the name is free.
    public static func uniqueURL(
        in directory: URL,
        name: String,
        extension ext: String,
        alsoAvoiding companionExtensions: [String] = []
    ) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
        var counter = 2
        let allExtensions = [ext] + companionExtensions
        func hasCollision(_ primary: URL) -> Bool {
            let base = primary.deletingPathExtension()
            return allExtensions.contains { candidateExtension in
                fm.fileExists(atPath: base.appendingPathExtension(candidateExtension).path)
            }
        }
        while hasCollision(candidate) {
            candidate = directory
                .appendingPathComponent("\(name) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// Free space on the volume backing `url`, in bytes.
    ///
    /// A failed probe falls back to `statfs` rather than to `.max`. Reporting
    /// unlimited space silently disabled every capacity guard built on this —
    /// including the recording ladder that warns and then stops early — so the
    /// one condition those guards exist for was also the one that switched them
    /// off. `-1` is returned only if both probes fail, which callers compare
    /// against as "not enough" rather than "unlimited".
    public static func availableCapacity(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return -1 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
