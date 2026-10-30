import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NotchShotKit

/// History rows decode thumbnails to their drawn size and keep them for the
/// window. The decode must still cover the 52 × 36 pt row at 2x, and a file
/// rewritten in place must be decoded again.
@Suite("History thumbnail cache")
struct HistoryThumbnailCacheTests {
    @Test("The decoded size covers the row at 2x and never exceeds the image", arguments: [
        (512, 346), (512, 300), (512, 512), (300, 512), (2000, 100), (100, 2000), (104, 72), (60, 40),
    ])
    func fillingSizeCoversTheRow(width: Int, height: Int) {
        let longEdge = max(width, height)
        let pixels = HistoryThumbnailCache.fillingPixelSize(width: width, height: height)
        #expect(pixels <= longEdge)
        let scaledWidth = Double(width) * Double(pixels) / Double(longEdge)
        let scaledHeight = Double(height) * Double(pixels) / Double(longEdge)
        // An image smaller than the row can't cover it; it must stay full size.
        if width < 104 || height < 72 {
            #expect(pixels == longEdge)
        } else {
            // Both edges at least the row's pixels, so the fill never upscales.
            #expect(scaledWidth.rounded(.down) >= 104 && scaledHeight.rounded(.down) >= 72)
        }
    }

    @Test("A stored thumbnail decodes to its row size, far below full size")
    func rowImageIsSmall() throws {
        let data = try Self.png(width: 512, height: 346, shade: 0.2)
        let image = try #require(HistoryThumbnailCache.rowImage(from: data))
        #expect(image.width >= 104 && image.height >= 72)
        #expect(image.width < 140 && image.height < 100)
    }

    @Test("A file is decoded once, and again after it is rewritten in place")
    func cacheFollowsTheFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("thumbnail.png")
        try Self.png(width: 512, height: 346, shade: 0.2).write(to: url)

        let cache = HistoryThumbnailCache()
        var decodes = 0
        let decode: (Data) -> CGImage? = { decodes += 1; return HistoryThumbnailCache.rowImage(from: $0) }

        #expect(cache.image(at: url, decode: decode) != nil)
        #expect(cache.image(at: url, decode: decode) != nil)
        #expect(decodes == 1)

        // Same name, same dimensions, different pixels: the old image must go.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Self.png(width: 512, height: 346, shade: 0.8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: attributes[.modificationDate] as Any], ofItemAtPath: url.path
        )
        #expect(cache.image(at: url, decode: decode) != nil)
        #expect(decodes == 2)

        try FileManager.default.removeItem(at: url)
        #expect(cache.image(at: url, decode: decode) == nil)
        #expect(decodes == 2)
    }

    private static func png(width: Int, height: Int, shade: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
