import CoreGraphics
import SwiftUI
import Testing
@testable import NotchShotKit

/// Reply labels can be 80 characters, wider than the row the island leaves
/// for them.
@Suite("Agent reply chips")
struct AgentReplyChipLayoutTests {
    @MainActor
    @Test func longChipTruncatesInsideItsRow() throws {
        let rowWidth = 200
        let flow = AgentChipFlow(spacing: 6) {
            Self.chip(String(repeating: "A long option label ", count: 4))
            Self.chip("Short")
        }
        .frame(width: CGFloat(rowWidth), alignment: .leading)
        // Room beside the row, where an overflowing chip would show.
        .frame(width: CGFloat(rowWidth + 100), alignment: .leading)
        .background(Color.black)

        let renderer = ImageRenderer(content: flow)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = try #require(Self.brightness(of: image))
        let firstRow = 14

        // The long chip still spans the row, so the check below is not vacuous.
        #expect(pixels[firstRow * image.width + rowWidth - 4] > 200)
        let outside = (0 ..< image.height).flatMap { y in
            (rowWidth + 1 ..< image.width).map { pixels[y * image.width + $0] }
        }
        #expect(outside.allSatisfy { $0 < 40 })
    }

    private static func chip(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white)
    }

    /// One red-channel byte per pixel, top row first.
    private static func brightness(of image: CGImage) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
    }
}
