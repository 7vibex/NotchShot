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
        first.recordingTargetMode = .window
        first.recordingSmoothsCursor = true
        first.recordingShowsKeystrokes = true
        first.recordingPresenterCamera = true
        first.updateChannel = .beta
        first.indexesCaptureText = true
        first.indexesCapturesInSpotlight = true
        first.notchDisplayPlacement = .allDisplays
        first.clipboardClearsOnQuit = true
        first.shelfPresentationStyle = .grid
        first.setShelfQuickAction(.removeBackground, at: 2)

        let second = Preferences(defaults: defaults)
        #expect(second.imageFormat == .heic)
        #expect(second.historyRetentionDays == 7)
        #expect(second.recordingFrameRate == 30)
        #expect(second.recordingTargetMode == .window)
        #expect(second.recordingSmoothsCursor)
        #expect(second.recordingShowsKeystrokes)
        #expect(second.recordingPresenterCamera)
        #expect(second.updateChannel == .beta)
        #expect(second.indexesCaptureText)
        #expect(second.indexesCapturesInSpotlight)
        #expect(second.notchDisplayPlacement == .allDisplays)
        #expect(second.clipboardClearsOnQuit)
        #expect(second.shelfPresentationStyle == .grid)
        #expect(second.shelfQuickActions[2] == .removeBackground)
    }

    @Test("Shelf quick actions stay unique, safe, and ordered")
    func shelfQuickActionsAreSanitized() {
        let sanitized = ShareAction.sanitizedShelfQuickActions([
            .airDrop, .airDrop, .delete, .removeBackground,
        ])
        #expect(sanitized.count == ShareAction.shelfQuickActionSlots)
        // A customized order survives; the widened row is filled from the
        // defaults rather than resetting what the user already chose.
        #expect(sanitized.prefix(2) == [.airDrop, .removeBackground])
        #expect(Set(sanitized).count == ShareAction.shelfQuickActionSlots)
        #expect(!sanitized.contains(.delete))
        #expect(ShareAction.customizableShelfCases.contains(.open))

        let preferences = makePreferences()
        preferences.setShelfQuickAction(.share, at: 0)
        #expect(preferences.shelfQuickActions[0] == .share)
        #expect(preferences.shelfQuickActions[3] == .copy)
    }

    @Test("The shelf row leads with the actions a capture is usually made for")
    func shelfQuickActionDefaults() {
        let defaults = ShareAction.defaultShelfQuickActions
        #expect(defaults.count == ShareAction.shelfQuickActionSlots)
        // Pulling the text out of a screenshot and getting it onto another
        // device are the two reasons people open More most often.
        #expect(defaults.contains(.ocr))
        #expect(defaults.contains(.airDrop))
        // Every default has to be legal in a slot, and none may be destructive.
        for action in defaults {
            #expect(ShareAction.customizableShelfCases.contains(action))
        }
        #expect(!ShareAction.customizableShelfCases.contains(.delete))
        #expect(!ShareAction.customizableShelfCases.contains(.moveTo))
        #expect(!ShareAction.customizableShelfCases.contains(.rename))
    }

    @Test("The notch defaults to the built-in MacBook display")
    func notchDisplayPlacementDefaultsToBuiltIn() {
        let preferences = makePreferences()
        #expect(preferences.notchDisplayPlacement == .builtInDisplayOnly)
        #expect(preferences.notchDisplayPlacement.includesDisplay(isBuiltIn: true))
        #expect(!preferences.notchDisplayPlacement.includesDisplay(isBuiltIn: false))
        #expect(NotchDisplayPlacement.allDisplays.includesDisplay(isBuiltIn: false))
    }

    @Test("The old external-display toggle migrates without changing its meaning")
    func legacyNotchDisplayPlacementMigration() {
        for (legacyValue, expected) in [
            (false, NotchDisplayPlacement.builtInDisplayOnly),
            (true, NotchDisplayPlacement.allDisplays),
        ] {
            let suiteName = "notchshot.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(legacyValue, forKey: "notchshot.islandOnExternal")

            #expect(Preferences(defaults: defaults).notchDisplayPlacement == expected)
        }
    }

    @Test("Corrupted recording frame rates are reset to a supported value")
    func corruptFrameRateIsSanitized() {
        for value in [-1, 0, Int(Int32.max) + 1, Int.max] {
            let suiteName = "notchshot.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "notchshot.recordingFrameRate")

            let preferences = Preferences(defaults: defaults)
            #expect(preferences.recordingFrameRate == 60)
        }
    }

    @Test("Managed ownership rejects symlink escapes")
    func managedOwnershipRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let link = root.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = link.appendingPathComponent("victim.png")

        #expect(!AppPaths.owns(escaped, within: root))
        #expect(AppPaths.owns(root.appendingPathComponent("safe.png"), within: root))
    }

    @Test("Text indexing is off by default, since it stores screen contents")
    func textIndexingDefaultsOff() {
        let preferences = makePreferences()
        #expect(!preferences.indexesCaptureText)
        #expect(!preferences.indexesCapturesInSpotlight)
        #expect(!preferences.recordingSmoothsCursor)
        #expect(!preferences.recordingShowsKeystrokes)
        #expect(!preferences.recordingPresenterCamera)
    }

    @Test("Locked-session media is privacy opt-in and persists explicitly")
    func lockedMediaPreference() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        #expect(!first.showsMediaWhileLocked)
        #expect(!first.showsActivityStackWhileLocked)
        #expect(!first.mirrorsSystemNotificationBanners)
        first.showsMediaWhileLocked = true
        first.showsActivityStackWhileLocked = true
        first.mirrorsSystemNotificationBanners = true

        #expect(Preferences(defaults: defaults).showsMediaWhileLocked)
        #expect(Preferences(defaults: defaults).showsActivityStackWhileLocked)
        #expect(Preferences(defaults: defaults).mirrorsSystemNotificationBanners)
    }

    @Test("Context modules use privacy-safe defaults and persist explicit choices")
    func contextModulePreferences() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        #expect(!first.calendarGlanceEnabled)
        #expect(first.powerStatusEnabled)
        #expect(!first.audioRouteStatusEnabled)
        #expect(first.aiActivityEnabled)
        #expect(first.showsAIActivityOverMedia)
        #expect(first.enabledAISources == Set(AISource.allCases))
        #expect(first.mirrorsPassiveContextOnAllDisplays)
        first.calendarGlanceEnabled = true
        first.selectedCalendarIdentifiers = ["work"]
        first.hiddenTitleCalendarIdentifiers = ["private"]
        first.audioRouteStatusEnabled = true
        first.aiActivityEnabled = false
        first.showsAIActivityOverMedia = false
        first.setAISource(.cursor, enabled: false)
        first.mirrorsPassiveContextOnAllDisplays = false

        let second = Preferences(defaults: defaults)
        #expect(second.calendarGlanceEnabled)
        #expect(second.selectedCalendarIdentifiers == ["work"])
        #expect(second.hiddenTitleCalendarIdentifiers == ["private"])
        #expect(second.audioRouteStatusEnabled)
        #expect(!second.aiActivityEnabled)
        #expect(!second.showsAIActivityOverMedia)
        #expect(!second.enabledAISources.contains(.cursor))
        #expect(!second.mirrorsPassiveContextOnAllDisplays)
    }

    @Test("Private system integrations require opt-in on a new install")
    func privateIntegrationsDefaultOff() {
        let preferences = makePreferences()
        #expect(!preferences.suppressesSystemOSD)
        #expect(!preferences.usesSystemScreenshotShortcuts)
        #expect(!preferences.appleEventsFallbackEnabled)
    }

    @Test("Input Monitoring has direct Settings remediation")
    func inputMonitoringSettingsURL() {
        #expect(PermissionKind.inputMonitoring.title == "Input Monitoring")
        #expect(PermissionKind.inputMonitoring.settingsURL?.absoluteString.contains("Privacy_ListenEvent") == true)
    }

    @Test("Input Monitoring state refreshes when the app becomes active again")
    func inputMonitoringRefresh() {
        var granted = false
        let permissions = PermissionCenter(
            preflight: { true },
            request: { true },
            inputMonitoringPreflight: { granted }
        )
        #expect(!permissions.inputMonitoringGranted)

        granted = true
        permissions.refresh()
        #expect(permissions.inputMonitoringGranted)
    }

    @Test("An empty capture-service inventory explains the safe recovery")
    func emptyCaptureInventoryRecoveryMessage() {
        let message = NotchShotError.noShareableContent.errorDescription ?? ""
        #expect(message.contains("capture service"))
        #expect(message.contains("log out") || message.contains("restart"))
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

    @Test("A pending first capture survives only as a non-sensitive intent token")
    func pendingFirstCaptureRoundTrip() {
        let suiteName = "notchshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let first = Preferences(defaults: defaults)
        first.pendingFirstCaptureIntent = .area

        let second = Preferences(defaults: defaults)
        #expect(second.pendingFirstCaptureIntent == .area)
        second.pendingFirstCaptureIntent = nil
        #expect(Preferences(defaults: defaults).pendingFirstCaptureIntent == nil)
    }

    @Test("Stable updates exclude prerelease channels and Beta opts in explicitly")
    func updateChannelsAreExplicit() {
        #expect(SecureUpdateController.allowedChannels(for: .stable).isEmpty)
        #expect(SecureUpdateController.allowedChannels(for: .beta) == ["beta"])
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
        #expect(ShareAction.share.isAvailable(for: recording))

        let document = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/a.pdf"),
            kind: .document,
            pixelSize: .zero
        )
        #expect(!ShareAction.annotate.isAvailable(for: document))
        #expect(!ShareAction.ocr.isAvailable(for: document))
        #expect(!ShareAction.pin.isAvailable(for: document))
        #expect(ShareAction.reveal.isAvailable(for: document))
        #expect(document.dimensionsDescription == "PDF document")
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
