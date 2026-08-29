import AppKit
import Foundation
import Testing

@testable import NotchShotKit

/// Regressions for defects found by audit, each pinned to the specific wrong
/// behaviour rather than to the shape of the fix.
@Suite("Audit regressions")
struct AuditRegressionTests {

    // MARK: Bound before decode

    @Test("A pasteboard image is rejected on its header, before the pixels are decoded")
    func oversizedPasteboardImageIsRejectedUnread() throws {
        // A PNG header claiming 40k x 40k. Decoding it would cost several
        // gigabytes; the reader must refuse it from the header alone, which it
        // can only do if it never asks for the pixels.
        let declared = Self.pngHeader(width: 40_000, height: 40_000)
        #expect(SafeImageFile.cgImage(from: declared, limits: .external) == nil)
    }

    @Test("A pasteboard image inside the limits still decodes")
    func boundedPasteboardImageDecodes() throws {
        let data = try Self.pngData(width: 6, height: 4)
        let image = SafeImageFile.cgImage(from: data, limits: .external)
        #expect(image?.width == 6)
        #expect(image?.height == 4)
    }

    @Test("A pasteboard image over the byte cap is refused without being parsed")
    func oversizedBytesRefused() throws {
        let data = try Self.pngData(width: 6, height: 4)
        let tiny = SafeImageFile.Limits(
            maximumBytes: 4,
            maximumDimension: 16_384,
            maximumPixels: 50_000_000
        )
        #expect(SafeImageFile.cgImage(from: data, limits: tiny) == nil)
    }

    // MARK: Case-only rename

    @Test("A file can be renamed to a different case of its own name")
    func caseOnlyRenameIsAllowed() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("shot.png")
        _ = try ImageExport.write(
            TestImage.solid(width: 2, height: 2, red: 10, green: 10, blue: 10),
            to: source,
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        let asset = CaptureAsset(url: source, kind: .screenshot, pixelSize: .zero, scale: 1)
        let renamed = try ShelfFileOperations.rename(asset, to: "Shot")
        #expect(renamed.lastPathComponent == "Shot.png")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test("A rename onto a different existing file is still refused")
    func genuineCollisionStillRejected() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("one.png")
        let occupied = directory.appendingPathComponent("two.png")
        for url in [source, occupied] {
            _ = try ImageExport.write(
                TestImage.solid(width: 2, height: 2, red: 10, green: 10, blue: 10),
                to: url,
                format: .png,
                quality: 1,
                dpiScale: 1
            )
        }
        let asset = CaptureAsset(url: source, kind: .screenshot, pixelSize: .zero, scale: 1)
        #expect(throws: ShelfFileOperations.OperationError.self) {
            try ShelfFileOperations.rename(asset, to: "two")
        }
    }

    // MARK: Pin symlinks

    @Test("A pin URL naming a symlink is refused rather than silently followed")
    func symlinkPinIsRejected() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.png")
        _ = try ImageExport.write(
            TestImage.solid(width: 2, height: 2, red: 1, green: 2, blue: 3),
            to: target,
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: NotchShotURLRouterError.self) {
            _ = try NotchShotURLRouter.parse(
                URL(string: "notchshot://pin?file=\(link.path)")!
            )
        }
        // The direct path is unaffected.
        let direct = try NotchShotURLRouter.parse(
            URL(string: "notchshot://pin?file=\(target.path)")!
        )
        if case .pinFile(let url) = direct {
            #expect(url.lastPathComponent == "target.png")
        } else {
            Issue.record("Expected a pinFile command")
        }
    }

    // MARK: Document summary privacy

    @Test("HTML loses everything that could fetch from the network before import")
    func htmlRemoteReferencesAreStripped() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="https://tracker.example/a.css">
        <script src="https://tracker.example/b.js"></script>
        <style>
        body { background: url(https://tracker.example/c.png); }
        </style>
        </head><body>
        <p>Quarterly revenue rose.</p>
        <img src="https://tracker.example/pixel.gif?id=42">
        <img src="//tracker.example/protocol-relative.gif">
        <iframe src="https://tracker.example/frame">fallback</iframe>
        </body></html>
        """
        let cleaned = String(
            decoding: DocumentSummaryService.htmlWithoutRemoteReferences(Data(html.utf8)),
            as: UTF8.self
        )
        #expect(!cleaned.contains("tracker.example"))
        #expect(!cleaned.lowercased().contains("<img"))
        #expect(!cleaned.lowercased().contains("<script"))
        #expect(!cleaned.lowercased().contains("<iframe"))
        // The prose that is actually being summarized survives.
        #expect(cleaned.contains("Quarterly revenue rose."))
    }

    // MARK: Capacity probe

    @Test("A capacity probe on a real path reports a real number, never unlimited")
    func capacityProbeDoesNotReportUnlimited() {
        let capacity = AppPaths.availableCapacity(at: FileManager.default.temporaryDirectory)
        #expect(capacity > 0)
        #expect(capacity != .max)
    }

    @Test("An unreadable path fails closed instead of claiming infinite space")
    func capacityProbeFailsClosed() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/deeper")
        let capacity = AppPaths.availableCapacity(at: missing)
        // Whatever it reports, it must never be a value that passes a
        // `available > needed` guard for an arbitrary requirement.
        #expect(capacity < Int64.max)
    }

    // MARK: Helpers

    private static func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        _ = try ImageExport.write(
            TestImage.solid(width: width, height: height, red: 30, green: 60, blue: 90),
            to: url,
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        return try Data(contentsOf: url)
    }

    /// A syntactically valid PNG signature + IHDR declaring an enormous size,
    /// with no image data behind it. Enough for `CGImageSource` to report the
    /// dimensions, which is the only thing the guard under test should need.
    private static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var chunk = Data()
        chunk.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        chunk.append(contentsOf: withUnsafeBytes(of: width.bigEndian, Array.init))
        chunk.append(contentsOf: withUnsafeBytes(of: height.bigEndian, Array.init))
        chunk.append(contentsOf: [8, 6, 0, 0, 0]) // depth, colour, compression, filter, interlace
        data.append(contentsOf: withUnsafeBytes(of: UInt32(13).bigEndian, Array.init))
        data.append(chunk)
        data.append(contentsOf: withUnsafeBytes(of: crc32(chunk).bigEndian, Array.init))
        return data
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
