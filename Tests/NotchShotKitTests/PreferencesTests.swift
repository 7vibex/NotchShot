import Foundation
import Testing
@testable import NotchShotKit

@Suite("Preferences")
@MainActor
struct PreferencesTests {

    /// An isolated defaults domain so these never touch the real settings.
    private func makePreferences() -> Preferences {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return Preferences(defaults: defaults)
    }

    private var referenceDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 9
        components.hour = 14
        components.minute = 5
        components.second = 30
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("The default template expands date and time")
    func defaultTemplate() {
        let preferences = makePreferences()
        let name = preferences.expandFilename(date: referenceDate)
        #expect(name == "NotchShot 2026-03-09 at 14.05.30")
    }

    @Test("The app token uses the captured application's name")
    func appToken() {
        let preferences = makePreferences()
        preferences.filenameTemplate = "{app} — {date}"
        #expect(preferences.expandFilename(date: referenceDate, appName: "Xcode") == "Xcode — 2026-03-09")
    }

    @Test("The app token falls back when no app is known")
    func appTokenFallback() {
        let preferences = makePreferences()
        preferences.filenameTemplate = "{app}"
        #expect(preferences.expandFilename(date: referenceDate) == "Screen")
    }

    @Test("Characters illegal in a filename are replaced")
    func illegalCharacters() {
        let preferences = makePreferences()
        preferences.filenameTemplate = "a/b:c"
        #expect(preferences.expandFilename(date: referenceDate) == "a-b.c")
    }

    @Test("An empty template still produces a usable name")
    func emptyTemplate() {
        let preferences = makePreferences()
        preferences.filenameTemplate = "   "
        #expect(preferences.expandFilename(date: referenceDate) == "NotchShot")
    }

    @Test("An unknown token is left visible rather than silently dropped")
    func unknownToken() {
        let preferences = makePreferences()
        preferences.filenameTemplate = "shot-{nope}"
        #expect(preferences.expandFilename(date: referenceDate) == "shot-{nope}")
    }

    @Test("Settings persist to their defaults domain")
    func persistence() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let first = Preferences(defaults: defaults)
        first.imageFormat = .heic
        first.historyRetentionDays = 7
        first.recordingFrameRate = 30
        first.indexesCaptureText = true

        let second = Preferences(defaults: defaults)
        #expect(second.imageFormat == .heic)
        #expect(second.historyRetentionDays == 7)
        #expect(second.recordingFrameRate == 30)
        #expect(second.indexesCaptureText)
    }

    @Test("Text indexing is off by default, since it stores screen contents")
    func textIndexingDefaultsOff() {
        #expect(!makePreferences().indexesCaptureText)
    }

    @Test("Private system integrations require opt-in on a new install")
    func privateIntegrationsDefaultOff() {
        let preferences = makePreferences()
        #expect(!preferences.suppressesSystemOSD)
        #expect(!preferences.usesSystemScreenshotShortcuts)
        #expect(!preferences.appleEventsFallbackEnabled)
    }

    @Test("A new install keeps OSD replacement off after first-run completion")
    func osdDefaultIsPersistedBeforeFirstRunChanges() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let first = Preferences(defaults: defaults)
        #expect(!first.suppressesSystemOSD)

        first.hasCompletedFirstRun = true
        let second = Preferences(defaults: defaults)
        #expect(!second.suppressesSystemOSD)
    }

    @Test("An upgraded install must explicitly opt into private OSD replacement")
    func legacyOSDDefaultDoesNotBecomeConsent() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "firstRun")

        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.suppressesSystemOSD)
    }

    @Test("Audio source flags follow the recording toggles")
    func audioSourceFlags() {
        let preferences = makePreferences()
        preferences.recordsSystemAudio = true
        preferences.recordsMicrophone = false
        #expect(preferences.recordingAudioSources == .system)

        preferences.recordsMicrophone = true
        #expect(preferences.recordingAudioSources.contains(.microphone))

        preferences.recordsSystemAudio = false
        preferences.recordsMicrophone = false
        #expect(preferences.recordingAudioSources.isEmpty)
    }

    @Test("Shelf durations map to intervals, with 'until dismissed' as nil")
    func shelfDurations() {
        #expect(ShelfDuration.seconds30.interval == 30)
        #expect(ShelfDuration.minutes2.interval == 120)
        #expect(ShelfDuration.never.interval == nil)
    }

    @Test("Unique naming avoids clobbering an existing file")
    func uniqueNaming() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AppPaths.uniqueURL(in: directory, name: "Shot", extension: "png")
        #expect(first.lastPathComponent == "Shot.png")
        try Data("x".utf8).write(to: first)

        let second = AppPaths.uniqueURL(in: directory, name: "Shot", extension: "png")
        #expect(second.lastPathComponent == "Shot 2.png")
        try Data("x".utf8).write(to: second)

        let third = AppPaths.uniqueURL(in: directory, name: "Shot", extension: "png")
        #expect(third.lastPathComponent == "Shot 3.png")
    }

    @Test("Recording names reserve their caption sidecar too")
    func companionNaming() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing captions".utf8).write(
            to: directory.appendingPathComponent("Recording.srt")
        )

        let result = AppPaths.uniqueURL(
            in: directory,
            name: "Recording",
            extension: "mp4",
            alsoAvoiding: ["srt"]
        )
        #expect(result.lastPathComponent == "Recording 2.mp4")
    }
}

@Suite("Capture assets")
struct CaptureAssetTests {

    @Test("Point size divides pixel size by the backing scale")
    func pointSize() {
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/a.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 2000, height: 1000),
            scale: 2
        )
        #expect(asset.pointSize == CGSize(width: 1000, height: 500))
        #expect(asset.dimensionsDescription == "2000 × 1000")
    }

    @Test("Image-only actions are hidden for recordings")
    func actionAvailability() {
        let recording = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/a.mp4"),
            kind: .recording,
            pixelSize: .zero
        )
        #expect(!ShareAction.annotate.isAvailable(for: recording))
        #expect(!ShareAction.ocr.isAvailable(for: recording))
        #expect(!ShareAction.pin.isAvailable(for: recording))
        #expect(ShareAction.copy.isAvailable(for: recording))
        #expect(ShareAction.airDrop.isAvailable(for: recording))
    }

    @Test("Only app-owned temporary files qualify for automatic removal")
    func automaticRemovalOwnership() {
        let managed = CaptureAsset(
            url: AppPaths.captures.appendingPathComponent("managed.png"),
            kind: .screenshot,
            pixelSize: .zero,
            ownership: .managedTemporary
        )
        var userDocument = managed
        userDocument.ownership = .userDocument
        var forgedManaged = managed
        forgedManaged.url = URL(fileURLWithPath: "/tmp/not-owned.png")

        #expect(managed.canBeAutomaticallyRemoved)
        #expect(!userDocument.canBeAutomaticallyRemoved)
        #expect(!forgedManaged.canBeAutomaticallyRemoved)
    }

    @Test("Intents that need an overlay are marked as such")
    func selectionIntents() {
        #expect(CaptureIntent.area.needsSelection)
        #expect(CaptureIntent.window.needsSelection)
        #expect(CaptureIntent.scrolling.needsSelection)
        #expect(CaptureIntent.ocr.needsSelection)
        #expect(!CaptureIntent.display.needsSelection)
        #expect(!CaptureIntent.previousArea.needsSelection)
    }
}
