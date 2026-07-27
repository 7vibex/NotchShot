import Foundation
import Testing
@testable import NotchShotKit

@Suite("Safe raw file actions")
struct SafeAssetFileTests {
    @Test("A Finder file is copied only while its captured identity matches")
    func identityPinnedCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-safe-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let firstDestination = directory.appendingPathComponent("first.bin")
        try Data("original".utf8).write(to: source)
        let identity = try #require(SafeAssetFile.identity(
            at: source,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ))
        let asset = CaptureAsset(
            url: source,
            kind: .recording,
            pixelSize: .zero,
            ownership: .externalReference,
            externalFileIdentity: identity
        )

        try SafeAssetFile.copy(asset, to: firstDestination)
        #expect(try Data(contentsOf: firstDestination) == Data("original".utf8))

        try Data("replacement with a different size".utf8).write(to: source)
        #expect(!SafeAssetFile.isCurrentAndSafe(asset))
        #expect(throws: NotchShotError.self) {
            try SafeAssetFile.copy(asset, to: directory.appendingPathComponent("second.bin"))
        }
    }

    @Test("Symbolic links never receive a shelf file identity")
    func symbolicLinkRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-safe-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("link.bin")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(SafeAssetFile.identity(
            at: link,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ) == nil)
    }
}
