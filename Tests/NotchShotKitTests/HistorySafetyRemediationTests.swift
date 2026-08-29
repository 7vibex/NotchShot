import Foundation
import Testing

@testable import NotchShotKit

@Suite("History fail-closed remediation")
@MainActor
struct HistorySafetyRemediationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-history-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A corrupt index quarantines itself without deleting untracked captures")
    func corruptLoadSuppressesCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let orphan = managed.appendingPathComponent("must-survive.png")
        try Data("capture".utf8).write(to: orphan)
        let store = directory.appendingPathComponent("history.json")
        try Data("{not-json".utf8).write(to: store)

        let repository = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [managed],
            historyEnabled: true,
            indexesCaptureText: false
        )

        guard case let .failed(_, backupURL) = repository.loadOutcome else {
            Issue.record("Malformed History should enter recovery mode")
            return
        }
        #expect(backupURL != nil)
        #expect(backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(repository.removeUntrackedManagedFiles() == 0)
        #expect(repository.applyRetention() == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("A legacy row stays unverified when reconstructed")
    func legacyEntryDoesNotBlessReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.png")
        let legacy = HistoryEntry(
            asset: CaptureAsset(
                url: path,
                kind: .screenshot,
                pixelSize: .zero,
                ownership: .managedTemporary,
                captureMissingFileIdentities: false
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )
        try Data("replacement".utf8).write(to: path)

        #expect(legacy.externalFileIdentity == nil)
        #expect(legacy.asset.externalFileIdentity == nil)
    }

    @Test("A replaced caption aborts before the primary is moved")
    func sidecarReplacementIsAllOrNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("recording.mp4")
        let caption = directory.appendingPathComponent("recording.srt")
        try Data("video".utf8).write(to: primary)
        try Data("caption-one".utf8).write(to: caption)
        let primaryIdentity = try #require(SafeAssetFile.identity(
            at: primary,
            maximumBytes: SafeAssetFile.maximumOwnedBytes
        ))
        let captionIdentity = try #require(SafeAssetFile.identity(
            at: caption,
            maximumBytes: SafeAssetFile.maximumOwnedBytes
        ))
        try Data("caption replacement with a different identity".utf8)
            .write(to: caption, options: .atomic)

        #expect(throws: (any Error).self) {
            try HistoryRepository.trashCaptureAndCaption(
                at: primary,
                primaryIdentity: primaryIdentity,
                captionURL: caption,
                captionIdentity: captionIdentity
            )
        }
        #expect(FileManager.default.fileExists(atPath: primary.path))
        #expect(FileManager.default.fileExists(atPath: caption.path))
    }

    @Test("An existing legacy file cannot be deleted without an identity")
    func legacyDeletionFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("legacy.png")
        try Data("keep".utf8).write(to: primary)

        #expect(throws: (any Error).self) {
            try HistoryRepository.trashCaptureAndCaption(at: primary)
        }
        #expect(FileManager.default.fileExists(atPath: primary.path))
    }
}
