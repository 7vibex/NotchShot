import AppKit
import AudioToolbox
import CoreMedia
import Darwin
import Foundation
import Testing
import UserNotifications
@testable import NotchShotKit

@Suite("History retention")
struct HistoryRetentionTests {

    private func entry(ageDays: Double, text: String? = nil, name: String = "shot.png") -> HistoryEntry {
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100),
            createdAt: Date().addingTimeInterval(-ageDays * 86_400),
            sourceApplicationName: "Safari"
        )
        return HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: text)
    }

    @Test("Entries older than the window are removed")
    func expiry() {
        let entries = [entry(ageDays: 1), entry(ageDays: 29), entry(ageDays: 31), entry(ageDays: 400)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 30,
            now: Date(),
            fileExists: { _ in true }
        )
        #expect(result.kept.count == 2)
        #expect(result.removed.count == 2)
    }

    @Test("A retention of zero keeps everything forever")
    func keepForever() {
        let entries = [entry(ageDays: 1), entry(ageDays: 4000)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 0,
            now: Date(),
            fileExists: { _ in true }
        )
        #expect(result.removed.isEmpty)
        #expect(result.kept.count == 2)
    }

    @Test("A row whose file has vanished is dropped regardless of age")
    func missingFileDropped() {
        let asset = CaptureAsset(
            url: AppPaths.captures.appendingPathComponent("missing.png"),
            kind: .screenshot,
            pixelSize: .zero,
            createdAt: Date().addingTimeInterval(-0.1 * 86_400),
            ownership: .managedTemporary
        )
        let entries = [HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 30,
            now: Date(),
            fileExists: { _ in false }
        )
        #expect(result.kept.isEmpty)
        #expect(result.removed.count == 1)
    }

    @Test("A recent unavailable user document remains retryable")
    func unavailableUserDocumentKept() {
        let entries = [entry(ageDays: 0.1)]
        let result = HistoryRepository.partitionByRetention(
            entries,
            retentionDays: 30,
            now: Date(),
            fileExists: { _ in false }
        )
        #expect(result.kept.count == 1)
        #expect(result.removed.isEmpty)
    }

    @Test("Retention deletes only hidden managed captures")
    func retentionRespectsOwnership() {
        let managed = CaptureAsset(
            url: AppPaths.captures.appendingPathComponent("managed.png"),
            kind: .screenshot,
            pixelSize: .zero,
            ownership: .managedTemporary
        )
        let document = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/user-document.png"),
            kind: .screenshot,
            pixelSize: .zero,
            ownership: .userDocument
        )

        #expect(HistoryRepository.retentionDeletesFiles)
        #expect(HistoryRepository.retentionDeletesManagedFiles(
            for: HistoryEntry(asset: managed, thumbnailFilename: nil, indexedText: nil)
        ))
        #expect(!HistoryRepository.retentionDeletesManagedFiles(
            for: HistoryEntry(asset: document, thumbnailFilename: nil, indexedText: nil)
        ))
    }

    @Test("An entry exactly at the boundary is kept")
    func boundaryInclusive() {
        let now = Date()
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/a.png"),
            kind: .screenshot,
            pixelSize: .zero,
            createdAt: now.addingTimeInterval(-30 * 86_400)
        )
        let result = HistoryRepository.partitionByRetention(
            [HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)],
            retentionDays: 30,
            now: now,
            fileExists: { _ in true }
        )
        #expect(result.kept.count == 1)
    }

    @Test("Search matches filenames and app names")
    func searchBasics() {
        let entry = entry(ageDays: 1, name: "Invoice.png")
        #expect(entry.matches("invoice"))
        #expect(entry.matches("safari"))
        #expect(entry.matches("Screenshot"))
        #expect(!entry.matches("nonexistent"))
    }

    @Test("Recognised text is searchable only when it was indexed")
    func searchRespectsIndexingOptIn() {
        let indexed = entry(ageDays: 1, text: "confidential balance sheet")
        #expect(indexed.matches("balance"))

        // Nil indexedText models the opt-in being off at capture time.
        let notIndexed = entry(ageDays: 1, text: nil)
        #expect(!notIndexed.matches("balance"))
    }

    @Test("Library organization is sanitized, searchable, and persisted")
    @MainActor
    func libraryOrganizationRoundTrip() throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let repository = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/library-entry.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100)
        )
        repository.record(asset: asset, image: nil)
        repository.updateLibraryMetadata(
            id: asset.id,
            tags: [" launch ", "launch", "team\nreview"],
            collectionName: " Product Demos ",
            isFavorite: true
        )
        try repository.save()

        let reloaded = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
        let entry = try #require(reloaded.entry(id: asset.id))
        #expect(entry.libraryTags == ["launch", "team review"])
        #expect(entry.collectionName == "Product Demos")
        #expect(entry.favorite)
        #expect(reloaded.search("product demos").map(\.id) == [asset.id])
        #expect(reloaded.search("launch").map(\.id) == [asset.id])
    }

    @Test("An empty query matches everything")
    func emptyQuery() {
        #expect(entry(ageDays: 1).matches(""))
    }

    @Test("History preserves exact generated-caption ownership")
    func captionOwnershipRoundTrip() throws {
        let captionURL = URL(fileURLWithPath: "/tmp/recording.srt")
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/recording.mp4"),
            kind: .recording,
            pixelSize: CGSize(width: 1_920, height: 1_080),
            duration: 30,
            captionURL: captionURL
        )
        let original = HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)
        let decoded = try JSONDecoder().decode(
            HistoryEntry.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.captionPath == captionURL.path)
        #expect(decoded.asset.captionURL == captionURL)
    }

    @Test("History round-trips primary-file provenance")
    func provenanceRoundTrip() throws {
        let asset = CaptureAsset(
            url: AppPaths.captures.appendingPathComponent("private.png"),
            kind: .screenshot,
            pixelSize: .zero,
            ownership: .managedTemporary
        )
        let original = HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)
        let decoded = try JSONDecoder().decode(
            HistoryEntry.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded.asset.ownership == .managedTemporary)
    }

    @Test("Deletion includes managed projects but preserves external projects")
    func projectDeletionOwnership() {
        let caption = URL(fileURLWithPath: "/tmp/captions.srt")
        let managedProject = AppPaths.projects.appendingPathComponent("private.notchshot")
        let externalProject = URL(fileURLWithPath: "/tmp/user.notchshot")

        #expect(HistoryRepository.deletableSidecars(
            primaryURL: URL(fileURLWithPath: "/tmp/captions.mp4"),
            captionURL: caption,
            projectURL: managedProject
        ) == [caption, managedProject])
        #expect(HistoryRepository.deletableSidecars(
            primaryURL: URL(fileURLWithPath: "/tmp/captions.mp4"),
            captionURL: caption,
            projectURL: externalProject
        ) == [caption])
    }

    @Test("Moving a missing primary to Trash fails instead of deleting its retry row")
    func missingPrimaryTrashFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-missing-\(UUID().uuidString).png")
        #expect(throws: CocoaError.self) {
            try HistoryRepository.trashCaptureAndCaption(at: missing)
        }
    }

    /// Retiring a row whose capture the user already deleted in Finder has
    /// nothing left to fail at. Treating it as a failure stranded the row
    /// forever: every retry hit the same missing file.
    @Test("Retiring a row tolerates a primary already deleted outside the app")
    func missingPrimaryIsRetirableWhenTolerated() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-missing-\(UUID().uuidString).png")
        try HistoryRepository.trashCaptureAndCaption(
            at: missing,
            toleratingMissingPrimary: true
        )
    }

    @Test("Clearing history and files drops rows whose capture is already gone")
    @MainActor
    func clearAllRetiresAlreadyMissingCaptures() throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let repository = HistoryRepository(storeURL: store)

        let historyWasEnabled = Preferences.shared.historyEnabled
        Preferences.shared.historyEnabled = true
        defer { Preferences.shared.historyEnabled = historyWasEnabled }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-gone-\(UUID().uuidString).png")
        repository.record(
            asset: CaptureAsset(
                url: missing,
                kind: .screenshot,
                pixelSize: CGSize(width: 10, height: 10),
                ownership: .userDocument
            ),
            image: nil
        )
        #expect(repository.entries.count == 1)

        let failed = repository.clearAll(includingFiles: true)
        #expect(failed.isEmpty)
        #expect(repository.entries.isEmpty)
    }

    @Test("Retention removes a managed project beside a preserved user document")
    func retentionRemovesManagedProjectOnly() {
        let primary = URL(fileURLWithPath: "/tmp/user-capture.png")
        let managedProject = AppPaths.projects.appendingPathComponent("private.notchshot")
        let asset = CaptureAsset(
            url: primary,
            kind: .screenshot,
            pixelSize: .zero,
            projectURL: managedProject,
            ownership: .userDocument
        )
        let entry = HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)

        #expect(HistoryRepository.managedArtifactsForRetention(for: entry) == [managedProject])
    }

    @Test("Untracked cleanup stays inside managed storage and preserves known files")
    func untrackedManagedCleanupScope() {
        let knownURL = AppPaths.captures.appendingPathComponent("known.png")
        let orphanURL = AppPaths.recordings.appendingPathComponent("orphan.mp4")
        let outsideURL = URL(fileURLWithPath: "/tmp/user.png")
        let known = HistoryEntry(
            asset: CaptureAsset(
                url: knownURL,
                kind: .screenshot,
                pixelSize: .zero,
                ownership: .managedTemporary
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )

        #expect(HistoryRepository.untrackedManagedArtifacts(
            candidates: [knownURL, orphanURL, outsideURL],
            entries: [known]
        ) == [orphanURL])
    }

    @Test("Duplicate primary paths coalesce without losing sidecar ownership")
    func duplicatePrimaryPathsCoalesce() {
        let primary = URL(fileURLWithPath: "/tmp/shared-export.png")
        let project = AppPaths.projects.appendingPathComponent("shared.notchshot")
        let newer = HistoryEntry(
            asset: CaptureAsset(
                url: primary,
                kind: .screenshot,
                pixelSize: .zero,
                createdAt: Date()
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )
        let older = HistoryEntry(
            asset: CaptureAsset(
                url: primary,
                kind: .screenshot,
                pixelSize: .zero,
                createdAt: Date().addingTimeInterval(-10),
                projectURL: project
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )

        let result = HistoryRepository.coalesceDuplicatePrimaryPaths([newer, older])
        #expect(result.entries.count == 1)
        #expect(result.duplicates.map(\.id) == [older.id])
        #expect(result.entries.first?.projectPath == project.path)
    }

    @Test("Persisted traversal thumbnails and foreign sidecars are quarantined from the model")
    @MainActor
    func unsafePersistedPathsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.json")
        let primary = directory.appendingPathComponent("recording.mp4")
        var entry = HistoryEntry(
            asset: CaptureAsset(
                url: primary,
                kind: .recording,
                pixelSize: CGSize(width: 100, height: 100),
                ownership: .userDocument
            ),
            thumbnailFilename: "../../victim.png",
            indexedText: nil
        )
        entry.captionPath = directory.appendingPathComponent("foreign.srt").path
        entry.projectPath = directory.appendingPathComponent("foreign.notchshot").path
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: store)

        let repository = HistoryRepository(storeURL: store)
        let loaded = try #require(repository.entries.first)
        #expect(loaded.thumbnailURL == nil)
        #expect(loaded.captionPath == nil)
        #expect(loaded.projectPath == nil)
        #expect(loaded.asset.captionURL == nil)
    }

    @Test("Thumbnail validation accepts only the exact generated filename")
    func thumbnailFilenameValidationIsExact() throws {
        let id = UUID(uuidString: "A92A8258-9378-4AA0-B212-2C08810A124E")!
        let filename = "\(id.uuidString).png"
        let valid = try #require(HistoryRepository.validatedThumbnailURL(
            filename: filename,
            id: id
        ))
        #expect(valid.lastPathComponent == filename)
        #expect(valid.deletingLastPathComponent() == AppPaths.thumbnails)

        for rejected in [
            "../\(filename)",
            "folder/\(filename)",
            "\(filename)/child",
            filename.lowercased(),
            "\(id.uuidString).jpg",
        ] {
            #expect(HistoryRepository.validatedThumbnailURL(filename: rejected, id: id) == nil)
        }
    }

    @Test("Oversized history is rejected before it is read")
    @MainActor
    func oversizedHistoryRejectedBeforeRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.json")
        FileManager.default.createFile(atPath: store.path, contents: nil)
        let handle = try FileHandle(forWritingTo: store)
        try handle.truncate(atOffset: UInt64(HistoryRepository.maximumStoreBytes + 1))
        try handle.close()

        let repository = HistoryRepository(storeURL: store)
        #expect(repository.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history.json.corrupt-") }
        #expect(quarantined.count == 1)
    }
}

@Suite("Media snapshot")
struct MediaSnapshotTests {

    @Test("Playing media becomes a bounded system Lock Screen notification")
    func lockedMediaNotificationPayload() throws {
        let snapshot = MediaSnapshot(
            source: .mediaRemote,
            applicationName: "Music",
            title: "Song\nTitle",
            artist: String(repeating: "Artist", count: 40),
            isPlaying: true
        )
        let payload = try #require(LockedMediaNotificationPolicy.payload(
            snapshot: snapshot,
            screenIsLocked: true,
            enabled: true
        ))

        #expect(payload.title == "Song Title")
        #expect(payload.subtitle.count == LockedMediaNotificationPolicy.maximumFieldLength)
        #expect(payload.body == "Playing in Music")
    }

    @Test("Lock notifications never expose disabled, unlocked, paused, or empty media")
    func lockedMediaNotificationPrivacyGate() {
        let playing = MediaSnapshot(
            source: .mediaRemote,
            title: "Song",
            artist: "Artist",
            isPlaying: true
        )
        var paused = playing
        paused.isPlaying = false

        #expect(LockedMediaNotificationPolicy.payload(
            snapshot: playing,
            screenIsLocked: false,
            enabled: true
        ) == nil)
        #expect(LockedMediaNotificationPolicy.payload(
            snapshot: playing,
            screenIsLocked: true,
            enabled: false
        ) == nil)
        #expect(LockedMediaNotificationPolicy.payload(
            snapshot: playing,
            screenIsLocked: true,
            enabled: true,
            customPresentationIsAvailable: true
        ) == nil)
        #expect(LockedMediaNotificationPolicy.payload(
            snapshot: paused,
            screenIsLocked: true,
            enabled: true
        ) == nil)
        #expect(LockedMediaNotificationPolicy.payload(
            snapshot: .empty,
            screenIsLocked: true,
            enabled: true
        ) == nil)
    }

    @Test("An unsupported Lock Screen setting still delivers")
    func readinessTreatsUnsupportedAsAllowed() {
        // macOS reports `notSupported` for settings it does not model per app.
        // Reading that as "disabled" suppressed every post, so the feature
        // looked broken while System Settings showed nothing wrong.
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .authorized,
            lockScreen: .notSupported
        ) == .ready)
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .authorized,
            lockScreen: .enabled
        ) == .ready)
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .provisional,
            lockScreen: .enabled
        ) == .ready)
    }

    @Test("Every reason the song cannot reach the Lock Screen is reportable")
    func readinessNamesItsBlockers() {
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .notDetermined,
            lockScreen: .enabled
        ) == .notRequested)
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .denied,
            lockScreen: .enabled
        ) == .denied)
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .authorized,
            lockScreen: .disabled
        ) == .lockScreenDisabled)

        // Denial outranks the Lock Screen switch: fixing the switch would not
        // help, so the remedy must not point there.
        #expect(LockedMediaNotificationPolicy.readiness(
            authorization: .denied,
            lockScreen: .disabled
        ) == .denied)

        // Anything that is not ready has to tell the user where to go.
        for readiness in [
            LockedMediaNotificationReadiness.notRequested,
            .denied,
            .lockScreenDisabled
        ] {
            #expect(readiness.needsAttention)
            #expect(readiness.remedy != nil)
        }
        #expect(!LockedMediaNotificationReadiness.ready.needsAttention)
        #expect(!LockedMediaNotificationReadiness.unknown.needsAttention)
    }

    @Test("A transient empty bridge result cannot erase opted-in locked media")
    func lockedSnapshotRetention() {
        let playing = MediaSnapshot(
            source: .appleEvents,
            applicationName: "Music",
            title: "Song",
            artist: "Artist",
            isPlaying: true
        )

        #expect(LockedMediaSnapshotPolicy.acceptedUpdate(
            current: playing,
            proposed: .empty,
            sessionIsActive: false
        ) == nil)
        #expect(LockedMediaSnapshotPolicy.acceptedUpdate(
            current: playing,
            proposed: .empty,
            sessionIsActive: true
        ) == .empty)
        #expect(!LockedMediaSnapshotPolicy.shouldClearAfterStreamEnds(
            sessionIsActive: false
        ))
        #expect(LockedMediaSnapshotPolicy.shouldClearAfterStreamEnds(
            sessionIsActive: true
        ))
    }

    @Test("A real track change is still accepted while locked")
    func lockedSnapshotRefresh() {
        let first = MediaSnapshot(source: .mediaRemote, title: "First", artist: "Artist")
        let second = MediaSnapshot(source: .mediaRemote, title: "Second", artist: "Artist")

        #expect(LockedMediaSnapshotPolicy.acceptedUpdate(
            current: first,
            proposed: second,
            sessionIsActive: false
        ) == second)
    }

    @Test("Artwork accent preserves cover hue and lifts dark colours for the notch")
    @MainActor
    func artworkAccent() throws {
        let image = NSImage(size: CGSize(width: 20, height: 20))
        image.lockFocus()
        NSColor(srgbRed: 0.02, green: 0.08, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 20, height: 20)).fill()
        image.unlockFocus()

        let accent = try #require(ArtworkAccentColor.extract(from: image).usingColorSpace(.sRGB))
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        #expect(hue > 0.55 && hue < 0.75)
        #expect(saturation >= 0.55)
        #expect(brightness >= 0.68)
        #expect(ArtworkAccentColor.contrastAgainstBlack(accent) >= 4.5)
    }

    @Test("Artwork accent falls back to white for a neutral cover")
    @MainActor
    func neutralArtworkAccent() throws {
        let image = NSImage(size: CGSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()

        let accent = try #require(ArtworkAccentColor.extract(from: image).usingColorSpace(.sRGB))
        #expect(accent.redComponent == 1)
        #expect(accent.greenComponent == 1)
        #expect(accent.blueComponent == 1)
    }

    @Test("Position is interpolated forward while playing")
    func interpolationWhilePlaying() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 200,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-10),
            isPlaying: true
        )
        let position = snapshot.interpolatedPosition()
        #expect(position != nil)
        #expect(abs(position! - 40) < 0.5)
    }

    @Test("A paused track's position doesn't drift")
    func noInterpolationWhilePaused() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 200,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-60),
            isPlaying: false
        )
        #expect(snapshot.interpolatedPosition() == 30)
    }

    @Test("Interpolation is clamped to the track length")
    func interpolationClamped() {
        let snapshot = MediaSnapshot(
            title: "Track",
            duration: 40,
            position: 30,
            positionTimestamp: Date().addingTimeInterval(-600),
            isPlaying: true
        )
        #expect(snapshot.interpolatedPosition() == 40)
        #expect(snapshot.progress == 1)
    }

    @Test("A position tick is not treated as a track change")
    func dedupIgnoresPosition() {
        let base = MediaSnapshot(
            source: .mediaRemote,
            title: "Track",
            artist: "Artist",
            duration: 200,
            position: 10,
            isPlaying: true
        )
        var tick = base
        tick.position = 11
        tick.positionTimestamp = Date()
        #expect(base.isMateriallyEqual(to: tick))
    }

    @Test("A different track is a real change")
    func dedupDetectsTrackChange() {
        let a = MediaSnapshot(source: .mediaRemote, title: "One", artist: "Artist")
        var b = a
        b.title = "Two"
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Play/pause counts as a material change")
    func dedupDetectsPlayState() {
        let a = MediaSnapshot(source: .mediaRemote, title: "One", isPlaying: true)
        var b = a
        b.isPlaying = false
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Same-sized new artwork is still a material media change")
    func dedupDetectsArtworkContent() {
        let a = MediaSnapshot(
            source: .mediaRemote,
            title: "One",
            artworkData: Data([1, 2, 3])
        )
        var b = a
        b.artworkData = Data([3, 2, 1])
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("Visible app names and command availability refresh")
    func dedupDetectsControlsAndAppName() {
        let a = MediaSnapshot(
            source: .mediaRemote,
            applicationName: "Music",
            title: "One",
            supportedCommands: [.play]
        )
        var b = a
        b.applicationName = "Spotify"
        #expect(!a.isMateriallyEqual(to: b))
        b = a
        b.supportedCommands = [.pause, .nextTrack]
        #expect(!a.isMateriallyEqual(to: b))
    }

    @Test("An empty snapshot has nothing worth showing")
    func emptyHasNoContent() {
        #expect(!MediaSnapshot.empty.hasContent)
        #expect(MediaSnapshot(source: .mediaRemote, title: "x").hasContent)
        // Source `.none` means the backend is disabled, whatever it carries.
        #expect(!MediaSnapshot(source: .none, title: "x").hasContent)
    }

    @Test("Progress is zero when the duration is unknown")
    func progressWithoutDuration() {
        #expect(MediaSnapshot(title: "x", position: 30).progress == 0)
    }
}

@Suite("Apple Events media timeline")
struct AppleEventsMediaTimelineTests {

    @Test("Spotify duration is converted from milliseconds")
    func spotifyDurationConversion() throws {
        let separator = AppleEventsMediaSource.fieldSeparator
        let fields = try #require(AppleEventsMediaSource.parseSnapshotFields(
            ["Song", "Artist", "Album", "215000", "42", "playing"].joined(separator: separator),
            spotifyDurationIsMilliseconds: true
        ))

        #expect(fields.duration == 215)
        #expect(fields.position == 42)
        #expect(fields.isPlaying)
    }

    @Test("Newlines in metadata do not shift timeline fields")
    func metadataNewline() throws {
        let separator = AppleEventsMediaSource.fieldSeparator
        let fields = try #require(AppleEventsMediaSource.parseSnapshotFields(
            ["First line\nSecond line", "Artist", "Album", "180", "73", "paused"].joined(separator: separator),
            spotifyDurationIsMilliseconds: false
        ))

        #expect(fields.title == "First line\nSecond line")
        #expect(fields.duration == 180)
        #expect(fields.position == 73)
        #expect(!fields.isPlaying)
    }

    @Test("Invalid timeline numbers degrade to unknown")
    func malformedTimeline() throws {
        let separator = AppleEventsMediaSource.fieldSeparator
        let fields = try #require(AppleEventsMediaSource.parseSnapshotFields(
            ["Song", "Artist", "Album", "not-a-number", "-1", "playing"].joined(separator: separator),
            spotifyDurationIsMilliseconds: false
        ))

        #expect(fields.duration == nil)
        #expect(fields.position == nil)
    }
}

@Suite("Adapter payload parsing")
struct AdapterPayloadTests {

    private func snapshot(_ json: String) -> MediaSnapshot? {
        AdapterPayload.snapshot(from: Data(json.utf8))
    }

    @Test("A standard payload is parsed")
    func standardPayload() throws {
        let result = try #require(snapshot("""
        {"title":"Song","artist":"Band","album":"Record","duration":210.5,
         "elapsedTime":42.0,"playing":true,"bundleIdentifier":"com.spotify.client"}
        """))
        #expect(result.title == "Song")
        #expect(result.artist == "Band")
        #expect(result.album == "Record")
        #expect(result.duration == 210.5)
        #expect(result.position == 42)
        #expect(result.isPlaying)
        #expect(result.source == .mediaRemote)
    }

    @Test("A payload wrapped in `payload` is unwrapped")
    func wrappedPayload() throws {
        let result = try #require(snapshot("""
        {"payload":{"title":"Song","artist":"Band","playing":false}}
        """))
        #expect(result.title == "Song")
        #expect(!result.isPlaying)
    }

    @Test("Alternate key spellings still parse, so a rename degrades gracefully")
    func alternateKeys() throws {
        let result = try #require(snapshot("""
        {"title":"Song","trackArtist":"Band","currentTime":12,"isPlaying":1,
         "bundleID":"com.apple.Music"}
        """))
        #expect(result.artist == "Band")
        #expect(result.position == 12)
        #expect(result.isPlaying)
    }

    @Test("Numbers arriving as strings are accepted")
    func stringNumbers() throws {
        let result = try #require(snapshot("""
        {"title":"Song","duration":"180","elapsedTime":"20"}
        """))
        #expect(result.duration == 180)
        #expect(result.position == 20)
    }

    @Test("Non-finite and negative playback numbers are discarded")
    func invalidNumbers() throws {
        let result = try #require(snapshot("""
        {"title":"Song","duration":"nan","elapsedTime":"-1"}
        """))
        #expect(result.duration == nil)
        #expect(result.position == nil)
        #expect(result.positionTimestamp == nil)
    }

    @Test("Content flags are read when stated and stay off when absent")
    func contentFlags() throws {
        let flagged = try #require(snapshot("""
        {"title":"Song","artist":"Band","isExplicitTrack":true,"lossless":1}
        """))
        #expect(flagged.isExplicit)
        #expect(flagged.isLossless)

        // Absent means "not stated". A badge claiming a track is clean, on a
        // source that never reports the flag, would be worse than no badge.
        let silent = try #require(snapshot(#"{"title":"Song","artist":"Band"}"#))
        #expect(!silent.isExplicit)
        #expect(!silent.isLossless)
    }

    @Test("A payload with no track means nothing is playing")
    func emptyPayload() throws {
        let result = try #require(snapshot(#"{"bundleIdentifier":"com.apple.Safari"}"#))
        #expect(!result.hasContent)
        #expect(result.title == nil)
    }

    @Test("Malformed JSON yields nil rather than throwing into the stream")
    func malformedJSON() {
        #expect(snapshot("not json at all") == nil)
        #expect(snapshot("") == nil)
    }

    @Test("Base64 artwork is decoded")
    func artwork() throws {
        let payload = Data("hello artwork".utf8).base64EncodedString()
        let result = try #require(snapshot(#"{"title":"Song","artworkData":"\#(payload)"}"#))
        #expect(result.artworkData == Data("hello artwork".utf8))
    }

    @Test("Unparseable artwork doesn't discard the rest of the metadata")
    func badArtwork() throws {
        let result = try #require(snapshot(#"{"title":"Song","artworkData":"!!!not base64!!!"}"#))
        #expect(result.title == "Song")
    }
}

@Suite("Adapter command process safety")
struct AdapterCommandProcessTests {
    @Test("The process-group runner is available to adapter launches")
    func runnerIsAvailable() {
        #expect(MediaRemoteAdapterSource.defaultRunnerURL != nil)
    }

    @Test("A successful command returns its bounded output")
    func successfulCommand() async {
        let data = await MediaRemoteAdapterSource.runOnce(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ready"]
        )
        #expect(data == Data("ready\n".utf8))
    }

    @Test("A hung command is terminated at the deadline")
    func commandTimeout() async {
        let started = ContinuousClock.now
        let data = await MediaRemoteAdapterSource.runOnce(
            executableURL: URL(fileURLWithPath: "/usr/bin/tail"),
            arguments: ["-f", "/dev/null"],
            timeout: 0.1
        )
        let elapsed = started.duration(to: .now)

        #expect(data == nil)
        // `tail -f /dev/null` never exits on its own, so any finite elapsed
        // time proves the deadline fired. The bound is deliberately far above
        // the ~0.2s this actually takes: a tighter one only measures how
        // loaded the machine is while the rest of the suite runs in parallel.
        #expect(elapsed < .seconds(5))
    }

    @Test("Unbounded command output is rejected")
    func commandOutputLimit() async {
        let data = await MediaRemoteAdapterSource.runOnce(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            timeout: 1,
            maximumOutputBytes: 1_024
        )
        #expect(data == nil)
    }


    @Test("Replacing an approved adapter inode requires reapproval")
    func replacementRequiresReapproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("adapter")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let identity = try #require(SafeAssetFile.identity(
            at: executable,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ))

        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let data = await MediaRemoteAdapterSource.runOnce(
            executableURL: executable,
            approvedIdentity: identity,
            arguments: ["must-not-run"]
        )
        #expect(data == nil)
    }

    @Test("A stubborn streaming adapter is killed before stop returns")
    func stubbornStreamingAdapterIsReaped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-stream-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("adapter")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\ntrap '' TERM\nsleep 1000 &\necho $! > \"$1\"\nwait\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let identity = try #require(SafeAssetFile.identity(
            at: executable,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ))
        let source = MediaRemoteAdapterSource(
            executableURL: executable,
            arguments: [childPIDFile.path],
            approvedIdentity: identity
        )
        let stream = await source.updates()
        for _ in 0 ..< 300 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processID = try #require(await source.runningProcessIdentifier)
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childProcessID = try #require(pid_t(childPIDText))
        defer { _ = kill(childProcessID, SIGKILL) }

        await source.stop()
        errno = 0
        #expect(kill(processID, 0) == -1)
        #expect(errno == ESRCH)
        errno = 0
        #expect(kill(childProcessID, 0) == -1)
        #expect(errno == ESRCH)
        _ = stream
    }
}

@Suite("Structured OCR")
struct DataDetectionTests {

    @Test("Tables preserve rows and columns as TSV")
    func tableTSV() {
        let table = RecognizedTable(rows: [
            ["Name", "Score"],
            ["Ada", "98"],
            ["Linus", "95"],
        ])
        #expect(table.tabSeparatedText == "Name\tScore\nAda\t98\nLinus\t95")
    }

    @Test("Markdown tables escape pipes and pad ragged rows")
    func tableMarkdown() {
        let table = RecognizedTable(rows: [
            ["Name", "Notes"],
            ["Ada", "Fast | precise"],
            ["Linus"],
        ])
        #expect(table.markdown == """
        | Name | Notes |
        | --- | --- |
        | Ada | Fast \\| precise |
        | Linus |  |
        """)
    }

    @Test("A structured OCR result chooses the requested clipboard format")
    func clipboardFormats() {
        let table = RecognizedTable(rows: [["A", "B"], ["1", "2"]])
        let result = OCRResult(
            regions: [],
            fullText: "A B 1 2",
            detectedItems: [],
            tables: [table],
            structuredText: table.tabSeparatedText,
            markdownText: table.markdown
        )
        #expect(result.clipboardText(format: .text) == table.tabSeparatedText)
        #expect(result.clipboardText(format: .tsv) == table.tabSeparatedText)
        #expect(result.clipboardText(format: .markdown) == table.markdown)
    }

    @Test("Detected items produce openable URLs")
    func actionURLs() {
        #expect(DetectedItem(kind: .email, value: "a@b.com").actionURL?.scheme == "mailto")
        #expect(DetectedItem(kind: .phone, value: "+1 555 0100").actionURL?.scheme == "tel")
        #expect(DetectedItem(kind: .link, value: "example.com").actionURL?.scheme == "https")
        #expect(DetectedItem(kind: .address, value: "1 Infinite Loop").actionURL == nil)
    }
}

@Suite("Recording configuration")
struct RecordingConfigurationTests {

    private func configuration(
        resolution: RecordingResolution,
        fps: Int = 60
    ) -> RecordingConfiguration {
        RecordingConfiguration(
            target: .display(1),
            resolution: resolution,
            framesPerSecond: fps
        )
    }

    @Test("Native resolution keeps the source pixels")
    func nativeResolution() {
        let size = configuration(resolution: .native)
            .outputPixelSize(for: CGSize(width: 3024, height: 1964))
        #expect(size == CGSize(width: 3024, height: 1964))
    }

    @Test("Downscaling preserves the aspect ratio")
    func downscale() {
        let size = configuration(resolution: .p1080)
            .outputPixelSize(for: CGSize(width: 3840, height: 2160))
        #expect(size == CGSize(width: 1920, height: 1080))
    }

    @Test("Output dimensions are always even, as H.264 requires")
    func evenDimensions() {
        for source in [CGSize(width: 1001, height: 733), CGSize(width: 3, height: 7)] {
            for resolution in RecordingResolution.allCases {
                let size = configuration(resolution: resolution).outputPixelSize(for: source)
                #expect(Int(size.width) % 2 == 0)
                #expect(Int(size.height) % 2 == 0)
            }
        }
    }

    @Test("A source smaller than the target isn't upscaled")
    func noUpscaling() {
        let size = configuration(resolution: .p2160)
            .outputPixelSize(for: CGSize(width: 640, height: 480))
        #expect(size == CGSize(width: 640, height: 480))
    }

    @Test("A zero-size source degrades to a valid minimum")
    func degenerateSource() {
        let size = configuration(resolution: .native).outputPixelSize(for: .zero)
        #expect(size.width >= 2)
        #expect(size.height >= 2)
    }

    @Test("Audio sources compose as flags")
    func audioSources() {
        var sources: RecordingAudioSources = []
        #expect(sources.isEmpty)
        sources.insert(.system)
        sources.insert(.microphone)
        #expect(sources.contains(.system))
        #expect(sources.contains(.microphone))
        sources.remove(.microphone)
        #expect(!sources.contains(.microphone))
    }

    @Test("Elapsed time formats with an hour component only when needed")
    func elapsedFormatting() {
        var status = RecordingStatus()
        status.elapsed = 65
        #expect(status.elapsedDescription == "01:05")
        status.elapsed = 3_725
        #expect(status.elapsedDescription == "1:02:05")
    }

    @Test("Audio meter attack, bounds, and decay are stable")
    func audioMeterEnvelope() {
        var meter = AudioLevelMeter()
        meter.push(rms: 1)
        let attacked = meter.level
        #expect(attacked > 0)
        #expect(attacked <= 1)
        meter.decay()
        #expect(meter.level < attacked)

        meter.push(rms: .infinity)
        #expect(meter.level >= 0)
        #expect(meter.level <= 1)
    }

    @Test("RMS reads every channel of a planar float sample buffer")
    func planarAudioRMS() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr)

        let values: [Float] = [0.5, 0.5, 0.5, 0.5, -0.5, -0.5, -0.5, -0.5]
        let byteCount = values.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr)
        let readyBlockBuffer = try #require(blockBuffer)
        let replaceStatus = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: readyBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        #expect(replaceStatus == noErr)

        let readyFormatDescription = try #require(formatDescription)
        var sampleBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: readyBlockBuffer,
            formatDescription: readyFormatDescription,
            sampleCount: 4,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)

        let readySampleBuffer = try #require(sampleBuffer)
        let rms = try #require(AudioLevelMeter.rootMeanSquare(of: readySampleBuffer))
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test("Recording status keeps a fixed history of real meter samples")
    func waveformHistory() {
        var status = RecordingStatus()
        status.isSystemAudioEnabled = true
        status.isMicrophoneEnabled = true

        for index in 0 ..< RecordingStatus.waveformSampleCount + 4 {
            status.appendMeterSnapshot(
                system: Float(index) / 10,
                microphone: Float(index) / 20
            )
        }

        #expect(status.systemWaveform.count == RecordingStatus.waveformSampleCount)
        #expect(status.microphoneWaveform.count == RecordingStatus.waveformSampleCount)
        #expect(status.systemWaveform.last == 1)
        #expect(status.microphoneWaveform.last == 1)
        #expect(status.systemWaveform.contains(where: { $0 > 0 }))
    }

    @Test("Disabled audio sources publish silence")
    func disabledWaveformIsSilent() {
        var status = RecordingStatus()
        status.appendMeterSnapshot(system: 0.9, microphone: 0.8)
        #expect(status.systemLevel == 0)
        #expect(status.microphoneLevel == 0)
        #expect(status.systemWaveform.allSatisfy { $0 == 0 })
        #expect(status.microphoneWaveform.allSatisfy { $0 == 0 })
    }
}

@Suite("Playing Next queue")
struct MediaQueueServiceTests {

    private func output(_ rows: [(String, String)]) -> String {
        rows
            .map { "\($0.0)\(MediaQueueService.fieldSeparator)\($0.1)" }
            .joined(separator: MediaQueueService.recordSeparator)
            + MediaQueueService.recordSeparator
    }

    @Test("Only Music can be asked for a queue")
    func supportedPlayers() {
        #expect(MediaQueueService.supportsQueue(bundleID: "com.apple.Music"))
        // Spotify's scripting dictionary exposes no queue, so the control must
        // not appear for it — an always-empty list is worse than none.
        #expect(!MediaQueueService.supportsQueue(bundleID: "com.spotify.client"))
        #expect(!MediaQueueService.supportsQueue(bundleID: nil))
    }

    @Test("Rows are parsed in order")
    func parsesRows() {
        let entries = MediaQueueService.parse(output([
            ("Blue Skies", "Revelation"),
            ("Stop Crying", "The Straikerz"),
        ]))
        #expect(entries.count == 2)
        #expect(entries[0].title == "Blue Skies")
        #expect(entries[1].artist == "The Straikerz")
    }

    @Test("The same track queued twice keeps distinct identities")
    func duplicateTracksStayDistinct() {
        let entries = MediaQueueService.parse(output([
            ("Blue Skies", "Revelation"),
            ("Blue Skies", "Revelation"),
        ]))
        #expect(entries.count == 2)
        // Two rows sharing an id makes SwiftUI drop one of them.
        #expect(entries[0].id != entries[1].id)
    }

    @Test("An empty or partial answer yields no rows rather than blank ones")
    func toleratesEmptyOutput() {
        #expect(MediaQueueService.parse("").isEmpty)
        #expect(MediaQueueService.parse("no separators here").isEmpty)
        // A record missing its artist field is incomplete, not a nameless track.
        #expect(MediaQueueService.parse("Title only\(MediaQueueService.recordSeparator)").isEmpty)
    }

    @Test("Whitespace-only titles are dropped")
    func dropsBlankTitles() {
        let entries = MediaQueueService.parse(output([("   ", "Band")]))
        #expect(entries.isEmpty)
    }

    @Test("A stopped player is distinguishable from a genuinely empty queue")
    func stoppedMarkerNeverReadsAsRows() {
        // The marker must differ from the empty script answer an error path
        // returns, so `upcoming` can map it to nil ("not playing") while ""
        // stays "answered, nothing queued".
        #expect(MediaQueueService.stoppedMarker != "")
        // And it must never survive parsing as rows, whatever a track is named.
        #expect(MediaQueueService.parse(MediaQueueService.stoppedMarker).isEmpty)
        #expect(MediaQueueService.parse(
            output([("Not the marker", "Artist")])
        ).count == 1)
    }
}

@Suite("Expanded player panels")
struct MediaPanelStateTests {

    @Test("A list opens one at a time and closes with the peek")
    @MainActor
    func panelsAreMutuallyExclusive() {
        let coordinator = AppCoordinator()
        coordinator.setPeeking(true)

        coordinator.setMediaPanel(.audioRoutes, rowCount: 3)
        #expect(coordinator.mediaPanel == .audioRoutes)
        #expect(coordinator.mediaPanelRowCount == 3)

        // Two stacked lists would push the island past the height at which it
        // still reads as part of the notch.
        coordinator.setMediaPanel(.playingNext, rowCount: 2)
        #expect(coordinator.mediaPanel == .playingNext)
        #expect(coordinator.mediaPanelRowCount == 2)

        // A list left open would otherwise reserve height in a collapsed
        // island, which reads as a stuck, empty gap under the player.
        coordinator.setPeeking(false)
        #expect(coordinator.mediaPanel == .none)
        #expect(coordinator.mediaPanelRowCount == 0)
    }

    @Test("An empty list still claims a row for its own message")
    @MainActor
    func emptyListKeepsOneRow() {
        let coordinator = AppCoordinator()
        coordinator.setPeeking(true)

        // Zero rows means closed; a list with nothing in it still has to show
        // why it is empty.
        coordinator.setMediaPanel(.playingNext, rowCount: 0)
        #expect(coordinator.mediaPanel == .none)

        coordinator.setMediaPanel(.playingNext, rowCount: 1)
        #expect(coordinator.mediaPanelRowCount == 1)
    }

    @Test("The island grows by exactly the rows a list will draw")
    func panelHeightMatchesItsRows() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        func height(rows: Int) -> CGFloat {
            NotchLayout.layout(
                for: .media,
                metrics: metrics,
                isPeeking: true,
                resultCount: 0,
                mediaPanelRows: rows
            ).size.height
        }

        let oneRow = height(rows: 1)
        let twoRows = height(rows: 2)
        #expect(
            twoRows - oneRow
                == NotchLayout.mediaPanelRowHeight + NotchLayout.mediaPanelRowSpacing
        )
    }
}

@Suite("Shuffle and repeat")
struct MediaPlaybackModeServiceTests {

    private func output(_ shuffle: String, _ repeatValue: String) -> String {
        "\(shuffle)\(MediaPlaybackModeService.fieldSeparator)\(repeatValue)"
    }

    @Test("Only the two scriptable players expose these controls")
    func supportedPlayers() {
        #expect(MediaPlaybackModeService.supportsModes(bundleID: "com.apple.Music"))
        #expect(MediaPlaybackModeService.supportsModes(bundleID: "com.spotify.client"))
        // A browser tab on the MediaRemote bridge reports nothing back, so the
        // buttons must not be offered for it.
        #expect(!MediaPlaybackModeService.supportsModes(bundleID: "com.apple.Safari"))
        #expect(!MediaPlaybackModeService.supportsModes(bundleID: nil))
    }

    @Test("Both players' vocabularies parse")
    func parsesBothDialects() throws {
        // Music answers off/one/all.
        let music = try #require(MediaPlaybackModeService.parse(output("true", "one")))
        #expect(music.isShuffling)
        #expect(music.repeatMode == .one)

        // Spotify answers with booleans.
        let spotify = try #require(MediaPlaybackModeService.parse(output("false", "true")))
        #expect(!spotify.isShuffling)
        #expect(spotify.repeatMode == .all)

        let off = try #require(MediaPlaybackModeService.parse(output("false", "off")))
        #expect(off.repeatMode == .off)
    }

    @Test("A partial or empty answer yields no state rather than a wrong one")
    func toleratesBadOutput() {
        #expect(MediaPlaybackModeService.parse("") == nil)
        #expect(MediaPlaybackModeService.parse("true") == nil)
    }

    @Test("Spotify's repeat cycle skips the position it cannot hold")
    func repeatCycleMatchesThePlayer() {
        // Music has three positions.
        #expect(MediaPlaybackModeService.next(after: .off, supportsSingleTrack: true) == .all)
        #expect(MediaPlaybackModeService.next(after: .all, supportsSingleTrack: true) == .one)
        #expect(MediaPlaybackModeService.next(after: .one, supportsSingleTrack: true) == .off)

        // Spotify has two: offering "repeat one" there would set a state the
        // player cannot hold, and the button would spring back on the next read.
        #expect(MediaPlaybackModeService.next(after: .off, supportsSingleTrack: false) == .all)
        #expect(MediaPlaybackModeService.next(after: .all, supportsSingleTrack: false) == .off)
    }

    @Test("Repeat reports whether it is on, for the control's tint")
    func repeatKnowsWhenItIsActive() {
        #expect(!MediaRepeatMode.off.isOn)
        #expect(MediaRepeatMode.all.isOn)
        #expect(MediaRepeatMode.one.isOn)
        #expect(MediaRepeatMode.one.symbolName == "repeat.1")
        #expect(MediaRepeatMode.all.symbolName == "repeat")
    }
}

@Suite("Push to talk")
struct DictationPushToTalkTests {

    @Test("A hold can begin from every state a session can end in")
    func holdStartsFromTerminalStates() {
        // The push-to-talk gate used to accept only `.idle`, so the first
        // dictation worked and every hold after it was dropped until the
        // finished state happened to reset.
        for state in [
            DictationState.idle,
            .completed,
            .cancelled,
            .copied,
            .failed("microphone unavailable"),
        ] {
            #expect(state.canStartNewSession, "\(state) should accept a new hold")
        }
    }

    @Test("A hold cannot begin on top of a session already running")
    func holdRefusesLiveStates() {
        for state in [
            DictationState.requestingMicrophone,
            .preparingModel(progress: 0.5),
            .listening,
            .finalizing,
            .inserting,
        ] {
            #expect(!state.canStartNewSession, "\(state) should not start a second session")
        }
    }

    @Test("The start gate and the toggle intent stay in agreement")
    func gateMatchesToggleIntent() {
        for state in [
            DictationState.idle,
            .completed,
            .cancelled,
            .copied,
            .failed("x"),
            .requestingMicrophone,
            .preparingModel(progress: 0),
            .listening,
            .finalizing,
            .inserting,
        ] {
            #expect(state.canStartNewSession == (state.toggleIntent == .start))
        }
    }
}

@Suite("Accessory battery")
struct BluetoothAccessoryBatteryTests {

    /// Shaped exactly like a real `system_profiler SPBluetoothDataType -json`
    /// answer on macOS 26, with the owner's name replaced.
    private let report = """
    {"SPBluetoothDataType":[{"device_connected":[
      {"Test AirPods Pro":{
        "device_address":"40:DA:5C:BA:0D:2F",
        "device_batteryLevelCase":"15%",
        "device_batteryLevelLeft":"100%",
        "device_batteryLevelRight":"95%",
        "device_minorType":"Headphones"}},
      {"Some Mouse":{"device_batteryLevel":"62%","device_minorType":"Mouse"}},
      {"Silent Speaker":{"device_minorType":"Speaker"}}
    ]}]}
    """

    @Test("Levels are read from the nested report")
    func parsesConnectedAccessories() throws {
        let parsed = BluetoothAccessoryBatteryService.parse(Data(report.utf8))
        let airpods = try #require(BluetoothAccessoryBatteryService.match(
            routeName: "Test AirPods Pro",
            in: parsed
        ))
        #expect(airpods.left == 100)
        #expect(airpods.right == 95)
        #expect(airpods.enclosure == 15)
        #expect(airpods.hasCase)
        // The number worth showing when only one fits is the one about to run out.
        #expect(airpods.lowestLevel == 15)
    }

    @Test("An accessory that reports nothing is not invented")
    func silentAccessoriesAreOmitted() {
        let parsed = BluetoothAccessoryBatteryService.parse(Data(report.utf8))
        #expect(BluetoothAccessoryBatteryService.match(
            routeName: "Silent Speaker",
            in: parsed
        ) == nil)
    }

    @Test("A single-level accessory still reports")
    func singleLevelAccessory() throws {
        let parsed = BluetoothAccessoryBatteryService.parse(Data(report.utf8))
        let mouse = try #require(BluetoothAccessoryBatteryService.match(
            routeName: "Some Mouse",
            in: parsed
        ))
        #expect(mouse.single == 62)
        #expect(!mouse.hasCase)
    }

    @Test("Route names match across punctuation and spelling differences")
    func matchesRouteNamesLoosely() {
        let parsed = BluetoothAccessoryBatteryService.parse(Data(report.utf8))
        // Core Audio and Bluetooth disagree about apostrophes and casing.
        #expect(BluetoothAccessoryBatteryService.match(
            routeName: "test airpods pro",
            in: parsed
        ) != nil)
        #expect(BluetoothAccessoryBatteryService.match(
            routeName: "MacBook Pro Speakers",
            in: parsed
        ) == nil)
    }

    @Test("A containment match prefers the most specific accessory")
    func longestNameWins() {
        let accessories = [
            BluetoothAccessoryBatteryService.normalized("AirPods"):
                AccessoryBattery(name: "AirPods", single: 50),
            BluetoothAccessoryBatteryService.normalized("Marius's AirPods Pro"):
                AccessoryBattery(name: "Marius's AirPods Pro", single: 80),
        ]
        // Core Audio appends a qualifier to the route name, so both entries
        // containment-match. The specific accessory must win over the generic
        // one — dictionary order must not decide.
        let matched = BluetoothAccessoryBatteryService.match(
            routeName: "Marius's AirPods Pro (2)",
            in: accessories
        )
        #expect(matched?.name == "Marius's AirPods Pro")
        #expect(matched?.single == 80)
    }

    @Test("Percentages survive their formatting, and nonsense is dropped")
    func parsesPercentStrings() {
        #expect(BluetoothAccessoryBatteryService.percent("15%") == 15)
        #expect(BluetoothAccessoryBatteryService.percent("100%") == 100)
        #expect(BluetoothAccessoryBatteryService.percent(42) == 42)
        #expect(BluetoothAccessoryBatteryService.percent("") == nil)
        #expect(BluetoothAccessoryBatteryService.percent("120%") == nil)
        #expect(BluetoothAccessoryBatteryService.percent(nil) == nil)
    }

    @Test("Artwork comes from Apple's own symbols, and never guesses a brand")
    func symbolMatchesTheModel() {
        #expect(AccessoryBattery(name: "Test AirPods Max", single: 80).symbolName == "airpodsmax")
        #expect(AccessoryBattery(name: "AirPods Pro", enclosure: 50).symbolName
            == "airpodspro.chargingcase.wireless.fill")
        // An unrecognised accessory stays generic rather than claiming to be
        // an Apple product.
        #expect(AccessoryBattery(name: "OPPO Enco Air4 Pro", single: 70).symbolName == "headphones")
    }
}
