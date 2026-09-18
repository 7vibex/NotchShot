import Foundation
import Testing
@testable import NotchShotKit

/// A generated caption follows the exact recording it was generated for. A
/// same-stem `.srt` that merely exists at the destination is never adopted,
/// moved, overwritten, or deleted.
@Suite("History caption relocation")
@MainActor
struct HistoryCaptionRelocationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-caption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository(in directory: URL) -> HistoryRepository {
        HistoryRepository(
            storeURL: directory.appendingPathComponent("history.json"),
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
    }

    @discardableResult
    private func makeRecording(
        named basename: String,
        in directory: URL,
        caption: String? = nil
    ) throws -> CaptureAsset {
        let primary = directory.appendingPathComponent("\(basename).mp4")
        try Data("video-\(basename)".utf8).write(to: primary)
        var captionURL: URL?
        if let caption {
            let url = directory.appendingPathComponent("\(basename).srt")
            try Data(caption.utf8).write(to: url)
            captionURL = url
        }
        return CaptureAsset(
            url: primary,
            kind: .recording,
            pixelSize: .zero,
            captionURL: captionURL
        )
    }

    @Test("Renaming moves the owned caption to the correct sibling")
    func renameMovesOwnedCaption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeRecording(named: "A", in: directory, caption: "caption for A")
        let repository = makeRepository(in: directory)
        repository.record(asset: asset, image: nil)
        try repository.save()

        let relocation = try ShelfFileOperations.rename(asset, to: "B")
        try repository.updateLocation(
            for: asset.id,
            to: relocation.url,
            relocatedCaptionURL: relocation.captionURL,
            relocatedCaptionIdentity: relocation.captionIdentity
        )

        let renamedPrimary = directory.appendingPathComponent("B.mp4")
        let renamedCaption = directory.appendingPathComponent("B.srt")
        #expect(FileManager.default.fileExists(atPath: renamedPrimary.path))
        #expect(FileManager.default.fileExists(atPath: renamedCaption.path))
        #expect(try Data(contentsOf: renamedCaption) == Data("caption for A".utf8))
        // The old caption is not left orphaned beside a missing recording.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("A.srt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("A.mp4").path
        ))

        let entry = try #require(repository.entry(id: asset.id))
        #expect(entry.fileURL == renamedPrimary)
        #expect(entry.captionPath == renamedCaption.path)
        #expect(entry.captionFileIdentity == SafeAssetFile.identity(
            at: renamedCaption,
            maximumBytes: SafeAssetFile.maximumOwnedBytes
        ))
    }

    @Test("An unrelated destination subtitle is never adopted or touched")
    func unrelatedDestinationCaptionIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeRecording(named: "A", in: directory, caption: "caption for A")
        let unrelated = directory.appendingPathComponent("B.srt")
        try Data("someone else's subtitle".utf8).write(to: unrelated)
        let repository = makeRepository(in: directory)
        repository.record(asset: asset, image: nil)
        try repository.save()

        #expect(throws: ShelfFileOperations.OperationError.destinationExists("B.srt")) {
            try ShelfFileOperations.rename(asset, to: "B")
        }

        #expect(try Data(contentsOf: unrelated) == Data("someone else's subtitle".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("A.srt"))
            == Data("caption for A".utf8))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("A.mp4").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("B.mp4").path
        ))
        #expect(repository.entry(id: asset.id)?.captionPath
            == directory.appendingPathComponent("A.srt").path)
        #expect(repository.entry(id: asset.id)?.fileURL
            == directory.appendingPathComponent("A.mp4"))
    }

    @Test("Moving to another folder carries the caption along")
    func moveCarriesCaption() throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let asset = try makeRecording(named: "A", in: source, caption: "move me")
        let repository = makeRepository(in: source)
        repository.record(asset: asset, image: nil)
        try repository.save()

        let relocation = try ShelfFileOperations.move(asset, toFolder: destination)
        try repository.updateLocation(
            for: asset.id,
            to: relocation.url,
            relocatedCaptionURL: relocation.captionURL,
            relocatedCaptionIdentity: relocation.captionIdentity
        )

        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("A.mp4").path
        ))
        #expect(try Data(contentsOf: destination.appendingPathComponent("A.srt"))
            == Data("move me".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: source.appendingPathComponent("A.srt").path
        ))
        #expect(repository.entry(id: asset.id)?.captionPath
            == destination.appendingPathComponent("A.srt").path)
    }

    @Test("A legacy caption without an identity cannot be relocated")
    func legacyCaptionFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("A.mp4")
        let caption = directory.appendingPathComponent("A.srt")
        try Data("video".utf8).write(to: primary)
        try Data("legacy caption".utf8).write(to: caption)
        let legacy = CaptureAsset(
            url: primary,
            kind: .recording,
            pixelSize: .zero,
            captionURL: caption,
            captureMissingFileIdentities: false
        )
        let repository = makeRepository(in: directory)
        repository.record(asset: legacy, image: nil)
        try repository.save()

        #expect(throws: ShelfFileOperations.OperationError.self) {
            try ShelfFileOperations.rename(legacy, to: "B")
        }

        // Nothing moved, and nothing at the destination was adopted.
        #expect(FileManager.default.fileExists(atPath: primary.path))
        #expect(try Data(contentsOf: caption) == Data("legacy caption".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("B.mp4").path
        ))
        #expect(repository.entry(id: legacy.id)?.captionPath == caption.path)
    }

    @Test("Deleting the relocated recording removes only its verified caption")
    func deleteRelocatedRemovesOnlyOwnedCaption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeRecording(named: "A", in: directory, caption: "owned caption")
        let bystander = directory.appendingPathComponent("Bystander.srt")
        try Data("unrelated".utf8).write(to: bystander)
        let repository = makeRepository(in: directory)
        repository.record(asset: asset, image: nil)
        try repository.save()

        let relocation = try ShelfFileOperations.rename(asset, to: "B")
        try repository.updateLocation(
            for: asset.id,
            to: relocation.url,
            relocatedCaptionURL: relocation.captionURL,
            relocatedCaptionIdentity: relocation.captionIdentity
        )
        try repository.delete(id: asset.id, includingFile: true)
        try repository.save()

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("B.mp4").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("B.srt").path
        ))
        #expect(FileManager.default.fileExists(atPath: bystander.path))
        #expect(repository.entry(id: asset.id) == nil)
    }
}
