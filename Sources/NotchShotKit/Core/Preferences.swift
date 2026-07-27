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
    public var saveToDiskAfterCapture = true { didSet { write(saveToDiskAfterCapture, .saveToDisk) } }
    public var showsShelfAfterCapture = true { didSet { write(showsShelfAfterCapture, .showsShelf) } }
    public var shelfDuration: ShelfDuration = .seconds30 { didSet { write(shelfDuration.rawValue, .shelfDuration) } }
    public var freezeScreenDuringSelection = true { didSet { write(freezeScreenDuringSelection, .freezeScreen) } }
    public var showsMagnifier = true { didSet { write(showsMagnifier, .showsMagnifier) } }
    public var playsCaptureSound = true { didSet { write(playsCaptureSound, .capturesSound) } }
    public var includesCursorInScreenshots = false { didSet { write(includesCursorInScreenshots, .includesCursor) } }

    /// Security-scoped bookmark for the user-chosen output folder.
    public var outputFolderBookmark: Data? { didSet { write(outputFolderBookmark, .outputFolderBookmark) } }

    // MARK: Recording

    public var recordingQuality: RecordingQuality = .balanced { didSet { write(recordingQuality.rawValue, .recordingQuality) } }
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

    // MARK: History

    public var historyRetentionDays = 30 { didSet { write(historyRetentionDays, .historyRetentionDays) } }
    public var historyEnabled = true { didSet { write(historyEnabled, .historyEnabled) } }
    /// Opt-in: OCR text only enters the search index when this is on.
    public var indexesCaptureText = false { didSet { write(indexesCaptureText, .indexesCaptureText) } }

    // MARK: Notch

    public var notchEnabled = true { didSet { write(notchEnabled, .notchEnabled) } }
    public var showsIslandOnExternalDisplays = true { didSet { write(showsIslandOnExternalDisplays, .islandOnExternal) } }
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
    public var appleEventsFallbackEnabled = false { didSet { write(appleEventsFallbackEnabled, .appleEventsFallback) } }
    /// Path to the user-installed mediaremote-adapter bundle, if present.
    public var mediaRemoteAdapterPath: String? { didSet { write(mediaRemoteAdapterPath, .adapterPath) } }

    // MARK: Editor

    public var defaultBackgroundPresetID: String = "none" { didSet { write(defaultBackgroundPresetID, .backgroundPreset) } }
    public var annotationColorHex: String = "#FF3B30" { didSet { write(annotationColorHex, .annotationColor) } }
    public var annotationLineWidth: Double = 4 { didSet { write(annotationLineWidth, .annotationLineWidth) } }

    // MARK: App

    public var launchesAtLogin = false { didSet { write(launchesAtLogin, .launchAtLogin) } }
    public var showsDockIcon = false { didSet { write(showsDockIcon, .showsDockIcon) } }
    public var hasCompletedFirstRun = false { didSet { write(hasCompletedFirstRun, .firstRun) } }
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

    // MARK: Derived

    /// Resolved output folder, falling back to ~/Desktop.
    public var outputFolder: URL {
        if let bookmark = outputFolderBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public func setOutputFolder(_ url: URL) {
        outputFolderBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
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
        case showsShelf, shelfDuration, freezeScreen, showsMagnifier, capturesSound, includesCursor
        case outputFolderBookmark
        case recordingQuality, recordingResolution, recordingFrameRate
        case recordsSystemAudio, recordsMicrophone, preferredMicrophone
        case recordingShowsCursor, recordingHighlightsClicks, recordingAutoZoomsOnClicks
        case recordingFramesWithBackground
        case recordingGeneratesCaptions
        case historyRetentionDays, historyEnabled, indexesCaptureText
        case notchEnabled, islandOnExternal, hoverPeek, hoverPeekDelay, systemLevelHUD
        case mirrorsBrightness, suppressesSystemOSD, usesSystemShortcuts
        case mediaEnabled, appleEventsFallback, adapterPath
        case backgroundPreset, annotationColor, annotationLineWidth
        case launchAtLogin, showsDockIcon, firstRun, recoveredLegacySystemOSD, adapterCheckBuild
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
        saveToDiskAfterCapture = bool(.saveToDisk, true)
        showsShelfAfterCapture = bool(.showsShelf, true)
        shelfDuration = ShelfDuration(rawValue: int(.shelfDuration, 30)) ?? .seconds30
        freezeScreenDuringSelection = bool(.freezeScreen, true)
        showsMagnifier = bool(.showsMagnifier, true)
        playsCaptureSound = bool(.capturesSound, true)
        includesCursorInScreenshots = bool(.includesCursor, false)
        outputFolderBookmark = defaults.data(forKey: "notchshot.\(Key.outputFolderBookmark.rawValue)")

        recordingQuality = string(.recordingQuality).flatMap(RecordingQuality.init) ?? .balanced
        recordingResolution = string(.recordingResolution).flatMap(RecordingResolution.init) ?? .native
        recordingFrameRate = int(.recordingFrameRate, 60)
        recordsSystemAudio = bool(.recordsSystemAudio, true)
        recordsMicrophone = bool(.recordsMicrophone, false)
        preferredMicrophoneID = string(.preferredMicrophone)
        recordingShowsCursor = bool(.recordingShowsCursor, true)
        recordingHighlightsClicks = bool(.recordingHighlightsClicks, false)
        recordingAutoZoomsOnClicks = bool(.recordingAutoZoomsOnClicks, false)
        recordingFramesWithBackground = bool(.recordingFramesWithBackground, false)
        recordingGeneratesCaptions = bool(.recordingGeneratesCaptions, false)

        historyRetentionDays = int(.historyRetentionDays, 30)
        historyEnabled = bool(.historyEnabled, true)
        indexesCaptureText = bool(.indexesCaptureText, false)

        notchEnabled = bool(.notchEnabled, true)
        showsIslandOnExternalDisplays = bool(.islandOnExternal, true)
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
        appleEventsFallbackEnabled = bool(.appleEventsFallback, false)
        mediaRemoteAdapterPath = string(.adapterPath)

        defaultBackgroundPresetID = string(.backgroundPreset) ?? "none"
        annotationColorHex = string(.annotationColor) ?? "#FF3B30"
        annotationLineWidth = double(.annotationLineWidth, 4)

        launchesAtLogin = bool(.launchAtLogin, false)
        showsDockIcon = bool(.showsDockIcon, false)
        hasCompletedFirstRun = bool(.firstRun, false)
        hasRecoveredLegacySystemOSD = bool(.recoveredLegacySystemOSD, false)
        lastAdapterCheckBuild = string(.adapterCheckBuild)
    }
}

/// Everything NotchShot writes lives under Application Support/NotchShot.
public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NotchShot", isDirectory: true)
    }

    public static var captures: URL { support.appendingPathComponent("Captures", isDirectory: true) }
    public static var thumbnails: URL { support.appendingPathComponent("Thumbnails", isDirectory: true) }
    public static var projects: URL { support.appendingPathComponent("Projects", isDirectory: true) }
    public static var recordings: URL { support.appendingPathComponent("Recordings", isDirectory: true) }
    public static var inProgress: URL { support.appendingPathComponent("InProgress", isDirectory: true) }
    /// Partial recordings the user explicitly discarded when macOS could not
    /// move them to Trash. Keeping these outside `InProgress` prevents the
    /// crash-recovery flow from resurrecting a deliberate discard.
    public static var discardedRecordings: URL {
        support.appendingPathComponent("Discarded Recordings", isDirectory: true)
    }
    public static var historyStore: URL { support.appendingPathComponent("history.json") }

    /// True only for files inside NotchShot's own Application Support tree.
    /// Standardising both paths prevents a sibling prefix such as
    /// "NotchShot-old" from being mistaken for owned storage.
    public static func owns(_ url: URL) -> Bool {
        let root = support.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    public static func ensureDirectories() {
        for url in [
            support,
            captures,
            thumbnails,
            projects,
            recordings,
            inProgress,
            discardedRecordings,
        ] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
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
    public static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}
