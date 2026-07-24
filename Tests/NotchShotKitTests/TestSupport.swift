import AppKit
import CoreGraphics
import Foundation
@testable import NotchShotKit

/// Bitmap helpers shared by the rendering tests.
enum TestImage {

    /// Solid-colour image.
    static func solid(
        width: Int,
        height: Int,
        red: UInt8 = 0,
        green: UInt8 = 0,
        blue: UInt8 = 0
    ) -> CGImage {
        make(width: width, height: height) { context in
            context.setFillColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A window onto a synthetic "page" whose every row has a distinct,
    /// deterministic brightness.
    ///
    /// Deliberately *non*-periodic: a repeating pattern has no unique
    /// alignment, so the stitcher's answer would be ambiguous by construction
    /// rather than because of a defect.
    ///
    /// `offset` is the page row shown at the top of the window, so two frames
    /// differing by N model a scroll of N pixels.
    static func page(width: Int, height: Int, offset: Int) -> CGImage {
        make(width: width, height: height) { context in
            for row in 0 ..< height {
                let intensity = CGFloat(rowValue(forPageRow: row + offset)) / 255
                context.setFillColor(gray: intensity, alpha: 1)
                // `row` is top-down; the context's coordinate space is bottom-up.
                context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
            }
        }
    }

    /// Deterministic hash so a page row looks the same in every frame that
    /// shows it, while neighbouring rows stay uncorrelated.
    private static func rowValue(forPageRow row: Int) -> UInt8 {
        var state = UInt64(bitPattern: Int64(row &+ 1)) &* 0x9E37_79B9_7F4A_7C15
        state ^= state >> 29
        state = state &* 0xBF58_476D_1CE4_E5B9
        state ^= state >> 32
        // Keep away from pure black and white so artefacts stay visible.
        return UInt8(20 + state % 216)
    }

    static func make(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    /// Reads one pixel as (r, g, b), with a **top-left** origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Shift the image so the requested pixel lands at the origin.
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x),
                y: -CGFloat(image.height - y - 1),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        // Little-endian premultiplied-first is B, G, R, A in memory.
        return (data[2], data[1], data[0])
    }

    /// Every distinct colour in a region, used to prove a redaction destroyed
    /// the detail that was there.
    static func distinctColors(
        _ image: CGImage,
        in rect: CGRect,
        step: Int = 1
    ) -> Set<String> {
        var colors = Set<String>()
        var y = Int(rect.minY)
        while y < Int(rect.maxY) {
            var x = Int(rect.minX)
            while x < Int(rect.maxX) {
                let pixel = pixel(image, x: x, y: y)
                colors.insert("\(pixel.r),\(pixel.g),\(pixel.b)")
                x += step
            }
            y += step
        }
        return colors
    }
}

extension AnnotationElement {
    static func rect(
        kind: AnnotationKind,
        from origin: CGPoint,
        to end: CGPoint,
        style: AnnotationStyle = AnnotationStyle()
    ) -> AnnotationElement {
        AnnotationElement(kind: kind, points: [origin, end], style: style)
    }
}
