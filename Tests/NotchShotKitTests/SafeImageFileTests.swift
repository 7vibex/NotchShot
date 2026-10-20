import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Safe image loading")
struct SafeImageFileTests {
    private func makeFixture() throws -> (directory: URL, image: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-safe-image-\(UUID().uuidString)", isDirectory: true)
        let imageURL = directory.appendingPathComponent("fixture.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try ImageExport.write(
            TestImage.solid(width: 4, height: 3, red: 20, green: 80, blue: 140),
            to: imageURL,
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        return (directory, imageURL)
    }

    @Test("A bounded regular image decodes at its declared dimensions")
    func boundedRegularImage() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let decoded = SafeImageFile.cgImage(
            at: fixture.image,
            limits: .init(maximumBytes: 1_000_000, maximumDimension: 100, maximumPixels: 10_000)
        )
        #expect(decoded?.width == 4)
        #expect(decoded?.height == 3)
    }

    @Test("A symbolic link is rejected even when its target is a valid image")
    func symbolicLinkRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let link = fixture.directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.image)

        #expect(SafeImageFile.cgImage(at: link, limits: .external) == nil)
    }

    @Test("Byte, dimension, and pixel limits are enforced before decode")
    func limitsEnforced() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let byteCount = try fixture.image.resourceValues(forKeys: [.fileSizeKey]).fileSize!

        #expect(SafeImageFile.cgImage(
            at: fixture.image,
            limits: .init(maximumBytes: byteCount - 1, maximumDimension: 100, maximumPixels: 10_000)
        ) == nil)
        #expect(SafeImageFile.cgImage(
            at: fixture.image,
            limits: .init(maximumBytes: byteCount, maximumDimension: 3, maximumPixels: 10_000)
        ) == nil)
        #expect(SafeImageFile.cgImage(
            at: fixture.image,
            limits: .init(maximumBytes: byteCount, maximumDimension: 100, maximumPixels: 11)
        ) == nil)
    }

    @Test("An external image must still match the inode the user selected")
    func externalIdentityIsPinned() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let identity = try #require(SafeAssetFile.identity(
            at: fixture.image,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ))
        let asset = CaptureAsset(
            url: fixture.image,
            kind: .screenshot,
            pixelSize: CGSize(width: 4, height: 3),
            ownership: .externalReference,
            externalFileIdentity: identity
        )
        #expect(SafeImageFile.cgImage(for: asset) != nil)

        let replacement = fixture.directory.appendingPathComponent("replacement.png")
        _ = try ImageExport.write(
            TestImage.solid(width: 5, height: 3, red: 200),
            to: replacement,
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        try FileManager.default.removeItem(at: fixture.image)
        try FileManager.default.moveItem(at: replacement, to: fixture.image)

        #expect(SafeImageFile.cgImage(for: asset) == nil)
    }

    @Test("Decoding immediately yields the same pixels, translucent or opaque")
    func decodeImmediatelyKeepsPixels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-immediate-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for translucent in [true, false] {
            // Every column a different colour, every row a different alpha.
            let drawn = TestImage.make(width: 64, height: 48) { context in
                for x in 0 ..< 64 {
                    for y in 0 ..< 48 {
                        context.setFillColor(
                            red: CGFloat(x) / 63,
                            green: CGFloat(63 - x) / 63,
                            blue: CGFloat(y) / 47,
                            alpha: translucent ? CGFloat(y) / 47 : 1
                        )
                        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            let url = directory.appendingPathComponent("fixture-\(translucent).png")
            _ = try ImageExport.write(drawn, to: url, format: .png, quality: 1, dpiScale: 1)

            let lazy = try #require(SafeImageFile.cgImage(at: url, limits: .generated))
            let decoded = try #require(SafeImageFile.cgImage(
                at: url,
                limits: .generated,
                decodeImmediately: true
            ))

            #expect(decoded.width == lazy.width && decoded.height == lazy.height)
            #expect(decoded.alphaInfo == lazy.alphaInfo)
            #expect(Self.composited(decoded) == Self.composited(lazy))
        }
    }

    @Test("Decoding immediately still enforces every limit")
    func decodeImmediatelyEnforcesLimits() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let byteCount = try fixture.image.resourceValues(forKeys: [.fileSizeKey]).fileSize!

        for limits in [
            SafeImageFile.Limits(maximumBytes: byteCount - 1, maximumDimension: 100, maximumPixels: 10_000),
            SafeImageFile.Limits(maximumBytes: byteCount, maximumDimension: 3, maximumPixels: 10_000),
            SafeImageFile.Limits(maximumBytes: byteCount, maximumDimension: 100, maximumPixels: 11),
        ] {
            #expect(SafeImageFile.cgImage(at: fixture.image, limits: limits, decodeImmediately: true) == nil)
        }
        let accepted = SafeImageFile.cgImage(
            at: fixture.image,
            limits: .init(maximumBytes: byteCount, maximumDimension: 4, maximumPixels: 12),
            decodeImmediately: true
        )
        #expect(accepted?.width == 4)
        #expect(accepted?.height == 3)
    }

    /// What either image looks like drawn over nothing: premultiplied sRGB.
    private static func composited(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
