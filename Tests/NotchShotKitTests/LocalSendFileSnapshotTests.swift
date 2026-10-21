import Foundation
import Testing
@testable import NotchShotKit

/// LocalSend authorizes a file when it is chosen, waits on the user and the
/// network, and uploads later. These tests pin that the bytes uploaded are the
/// bytes chosen: preparation copies the pinned inode into a private snapshot,
/// and the original pathname is never read again.
@Suite("LocalSend transfer snapshots")
struct LocalSendFileSnapshotTests {
    private func makeDirectory() throws -> URL {
        // Deliberately not the snapshot prefix: the cleanup assertion scans for
        // leftover snapshot directories, and the fixture must not look like one.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-snapshot-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Preparation snapshots the authorized bytes, not the pathname")
    func snapshotPinsAuthorizedBytes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.bin")
        try Data("authorized bytes".utf8).write(to: source)

        let client = LocalSendClient()
        let selection = try #require(LocalSendSelection(url: source))
        let prepared = try await client.prepareFiles([selection])
        defer { LocalSendClient.discardSnapshots(prepared) }
        let file = try #require(prepared.first)

        #expect(file.fileName == "original.bin")
        #expect(file.size == 16)
        #expect(try Data(contentsOf: file.snapshotURL) == Data("authorized bytes".utf8))

        // Replace the pathname with a different file and a different inode.
        try FileManager.default.removeItem(at: source)
        try Data("replacement bytes that were never authorized".utf8).write(to: source)

        // The snapshot still holds exactly the authorized bytes.
        #expect(try Data(contentsOf: file.snapshotURL) == Data("authorized bytes".utf8))
    }

    @Test("A copy refuses a pathname replaced after its identity was captured")
    func copyVerifiedRefusesReplacement() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        try Data("original".utf8).write(to: source)
        let identity = try #require(SafeAssetFile.identity(
            at: source,
            maximumBytes: 10_000
        ))
        let snapshot = directory.appendingPathComponent("snapshot.bin")

        try Data("replacement with a different identity".utf8)
            .write(to: source, options: .atomic)

        #expect(throws: NotchShotError.self) {
            try SafeAssetFile.copyVerified(
                from: source,
                expectedIdentity: identity,
                maximumBytes: 10_000,
                to: snapshot
            )
        }
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test("A file replaced after it was chosen is refused, not sent")
    func replacementAfterSelectionIsRefused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("chosen.bin")
        try Data("chosen bytes".utf8).write(to: source)
        let selection = try #require(LocalSendSelection(url: source))

        // The swap happens while the device picker is open.
        try Data("PRIVATE KEY".utf8).write(to: source, options: .atomic)

        let client = LocalSendClient()
        await #expect(throws: LocalSendError.self) {
            _ = try await client.prepareFiles([selection])
        }
    }

    @Test("A shelf file keeps the identity it had when it entered the shelf")
    func shelfSelectionUsesRecordedIdentity() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("shelved.txt")
        try Data("shelved".utf8).write(to: source)
        let recorded = try #require(SafeAssetFile.identity(at: source, maximumBytes: 10_000))
        let asset = CaptureAsset(
            url: source,
            kind: .text,
            pixelSize: .zero,
            ownership: .externalReference,
            externalFileIdentity: recorded
        )
        #expect(LocalSendSelection(asset: asset)?.identity == recorded)

        try Data("replaced on the shelf".utf8).write(to: source, options: .atomic)
        #expect(LocalSendSelection(asset: asset) == nil)
    }

    @Test("A symlink cannot be chosen")
    func symlinkIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.bin")
        try Data("target".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(LocalSendSelection(url: link) == nil)
    }

    @Test("A file over the 5 GB transfer limit cannot be chosen")
    func oversizedFileIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let huge = directory.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(LocalSendClient.maximumFileBytes) + 1)
        try handle.close()

        #expect(LocalSendSelection(url: huge) == nil)
    }

    @Test("Snapshots are removed on cleanup")
    func snapshotsAreDiscarded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.bin")
        try Data("bytes".utf8).write(to: source)

        let client = LocalSendClient()
        let prepared = try await client.prepareFiles([
            try #require(LocalSendSelection(url: source)),
        ])
        let snapshotDirectory = try #require(prepared.first).snapshotURL
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: snapshotDirectory.path))

        LocalSendClient.discardSnapshots(prepared)
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectory.path))
        // Discarding twice is harmless.
        LocalSendClient.discardSnapshots(prepared)
    }

    @Test("A later unsafe file cleans up the snapshots already made")
    func partialPreparationCleansUp() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "unique-\(UUID().uuidString).bin"
        let good = directory.appendingPathComponent(marker)
        try Data("good".utf8).write(to: good)
        let swapped = directory.appendingPathComponent("swapped-\(UUID().uuidString).bin")
        try Data("before".utf8).write(to: swapped)
        let selections = [
            try #require(LocalSendSelection(url: good)),
            try #require(LocalSendSelection(url: swapped)),
        ]
        try Data("after the selection".utf8).write(to: swapped, options: .atomic)

        let client = LocalSendClient()
        await #expect(throws: LocalSendError.self) {
            _ = try await client.prepareFiles(selections)
        }

        // No snapshot directory still holds the file that was prepared first.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { url in
            url.lastPathComponent.hasPrefix("notchshot-localsend-")
                && FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(marker).path
                )
        }
        #expect(leftovers.isEmpty)
    }
}
