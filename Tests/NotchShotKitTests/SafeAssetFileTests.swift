import Foundation
import Darwin
import Testing
@testable import NotchShotKit

@Suite("Safe raw file actions")
struct SafeAssetFileTests {
    @Test("Nonregular inputs are rejected without waiting for a FIFO writer",
          arguments: ["read", "copy", "project"])
    func rejectsFIFOWithoutBlocking(operation: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-fifo-test-\(UUID()).notchshot", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("document.json")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        // A regression must fail rather than hang the test runner. Opening a
        // writer after two seconds releases a mistakenly blocking read-open;
        // O_NONBLOCK keeps this rescue itself bounded when no reader exists.
        let rescue = DispatchWorkItem {
            let descriptor = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: rescue)
        defer { rescue.cancel() }
        let started = ContinuousClock.now
        #expect(throws: NotchShotError.self) {
            switch operation {
            case "copy":
                let asset = CaptureAsset(url: fifo, kind: .document, pixelSize: .zero,
                                         captureMissingFileIdentities: false)
                try SafeAssetFile.copy(asset, to: directory.appendingPathComponent("copy.bin"))
            case "project":
                _ = try NotchShotPackage.read(from: directory)
            default:
                _ = try SafeAssetFile.readData(at: fifo, maximumBytes: 1_024)
            }
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

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
