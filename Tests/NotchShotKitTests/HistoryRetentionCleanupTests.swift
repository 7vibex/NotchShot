import Foundation
import Testing

@testable import NotchShotKit

/// Retention verifies each managed artifact before it removes it, and a row
/// whose artifact fails that check is kept for a later retry. These cover the
/// rows that failed on every launch even though nothing about their files had
/// changed, and the ones that must still fail closed.
@Suite("History retention cleanup")
struct HistoryRetentionCleanupTests {
    private struct Storage {
        var root: URL
        var captures: URL { root.appendingPathComponent("Captures", isDirectory: true) }
        var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
        var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
        var swept: [URL] { [captures, recordings] }
    }

    private func makeStorage() throws -> Storage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-retention-\(UUID().uuidString)", isDirectory: true)
            // `owns` compares against the resolved root; /var is a symlink.
            .resolvingSymlinksInPath()
        let storage = Storage(root: root)
        for directory in [storage.captures, storage.recordings, storage.projects] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return storage
    }

    private func managedEntry(at url: URL) -> HistoryEntry {
        HistoryEntry(
            asset: CaptureAsset(
                url: url,
                kind: .screenshot,
                pixelSize: .zero,
                ownership: .managedTemporary,
                captureMissingFileIdentities: false
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )
    }

    private func identity(at url: URL, allowsDirectory: Bool = false) throws -> ExternalFileIdentity {
        try #require(SafeAssetFile.fileSystemIdentity(
            at: url,
            maximumBytes: SafeAssetFile.maximumOwnedBytes,
            allowsDirectory: allowsDirectory
        ))
    }

    private func remove(_ entry: HistoryEntry, in storage: Storage) throws {
        try HistoryRepository.removeManagedArtifacts(
            for: entry,
            excluding: [],
            sweptDirectories: storage.swept,
            historyEnabled: true,
            supportRoot: storage.root
        )
    }

    @Test("A capture recorded before a restart is still removed")
    func deviceNumberChangeAfterRestart() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let capture = storage.captures.appendingPathComponent("before-restart.png")
        try Data("capture".utf8).write(to: capture)
        var entry = managedEntry(at: capture)
        // APFS hands a volume a new `st_dev` each time it mounts, so a row
        // written before a restart carries a device number that no longer
        // matches the same, untouched file.
        var recorded = try identity(at: capture)
        recorded.device &+= 1
        entry.externalFileIdentity = recorded

        try remove(entry, in: storage)

        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("A legacy capture with no identity is removed like an unowned capture")
    func legacyCaptureInSweptFolder() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let capture = storage.captures.appendingPathComponent("legacy.png")
        try Data("capture".utf8).write(to: capture)
        let entry = managedEntry(at: capture)
        #expect(entry.externalFileIdentity == nil)

        try remove(entry, in: storage)

        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("A legacy project with no identity still fails closed, and nothing is removed")
    func legacyProjectFailsClosed() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let capture = storage.captures.appendingPathComponent("redacted.png")
        try Data("capture".utf8).write(to: capture)
        let project = storage.projects.appendingPathComponent("unredacted.notchshot", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var entry = managedEntry(at: capture)
        entry.externalFileIdentity = try identity(at: capture)
        entry.projectPath = project.path

        #expect(throws: (any Error).self) { try remove(entry, in: storage) }
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("A project recorded before a restart is still removed")
    func projectAfterRestart() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let capture = storage.captures.appendingPathComponent("redacted.png")
        try Data("capture".utf8).write(to: capture)
        let project = storage.projects.appendingPathComponent("unredacted.notchshot", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var entry = managedEntry(at: capture)
        entry.externalFileIdentity = try identity(at: capture)
        var projectIdentity = try identity(at: project, allowsDirectory: true)
        projectIdentity.device &+= 1
        entry.projectPath = project.path
        entry.projectFileIdentity = projectIdentity

        try remove(entry, in: storage)

        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("A replaced capture still fails closed")
    func replacedCaptureFailsClosed() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let capture = storage.captures.appendingPathComponent("replaced.png")
        try Data("original".utf8).write(to: capture)
        var entry = managedEntry(at: capture)
        entry.externalFileIdentity = try identity(at: capture)
        try Data("a replacement with a different size".utf8).write(to: capture, options: .atomic)

        #expect(throws: (any Error).self) { try remove(entry, in: storage) }
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    @Test("A legacy file outside the swept folders still fails closed")
    func legacyOutsideSweptFoldersFailsClosed() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let other = storage.root.appendingPathComponent("Voice Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let note = other.appendingPathComponent("legacy.png")
        try Data("note".utf8).write(to: note)

        #expect(throws: (any Error).self) { try remove(managedEntry(at: note), in: storage) }
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    @Test("A legacy recording is kept while History is off, as the sweep keeps it")
    func legacyRecordingWithHistoryOff() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let recording = storage.recordings.appendingPathComponent("take.mp4")
        try Data("video".utf8).write(to: recording)

        #expect(throws: (any Error).self) {
            try HistoryRepository.removeManagedArtifacts(
                for: managedEntry(at: recording),
                excluding: [],
                sweptDirectories: storage.swept,
                historyEnabled: false,
                supportRoot: storage.root
            )
        }
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }
}
