import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

/// A whole-display frame in ScreenCaptureKit's own format (BGRA, premultiplied
/// first, sRGB) where every pixel's bytes encode its coordinates, so a cut that
/// lands one pixel off cannot pass.
private enum CoordinateFrame {
    static func make(display: CGRect, scale: CGFloat) -> CapturedImage {
        let width = Int(display.width * scale)
        let height = Int(display.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(x % 256) // B
                bytes[index + 1] = UInt8(y % 256) // G
                bytes[index + 2] = UInt8((x / 256 + (y / 256) * 16) % 256) // R
                bytes[index + 3] = 255
            }
        }
        let context = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )!
        }
        return CapturedImage(cgImage: context.makeImage()!, scale: scale, sourceRect: display)
    }

    /// (B, G, R) of one pixel, read from the image's own bytes.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let index = y * image.bytesPerRow + x * 4
        return [data[index], data[index + 1], data[index + 2]]
    }
}

@Suite("Cutting a selection from its freeze frame")
struct CaptureFreezeCutTests {
    @Test("A cut on a Retina display lands on the exact pixels of the rect")
    func retinaCutIsExact() throws {
        // A secondary display to the right of a 1470 pt primary.
        let display = CGRect(x: 1470, y: 0, width: 200, height: 150)
        let frame = CoordinateFrame.make(display: display, scale: 2)
        let rect = CGRect(x: 1500, y: 10, width: 50, height: 20)

        let cut = try #require(CaptureService.cut(rect, from: frame))

        #expect(cut.cgImage.width == 100)
        #expect(cut.cgImage.height == 40)
        #expect(cut.scale == 2)
        #expect(cut.sourceRect == rect)
        // Local origin (30, 10) pt is pixel (60, 20).
        #expect(CoordinateFrame.pixel(cut.cgImage, x: 0, y: 0) == [60, 20, 0])
        #expect(CoordinateFrame.pixel(cut.cgImage, x: 99, y: 39) == [159, 59, 0])
    }

    @Test("Every pixel of a 1x cut matches the frame it came from")
    func oneXCutMatchesSource() throws {
        let display = CGRect(x: -1920, y: 0, width: 400, height: 300)
        let frame = CoordinateFrame.make(display: display, scale: 1)
        let rect = CGRect(x: -1900, y: 33, width: 301, height: 199)

        let cut = try #require(CaptureService.cut(rect, from: frame))

        #expect(cut.cgImage.width == 301)
        #expect(cut.cgImage.height == 199)
        for y in stride(from: 0, to: 199, by: 7) {
            for x in stride(from: 0, to: 301, by: 11) {
                #expect(CoordinateFrame.pixel(cut.cgImage, x: x, y: y)
                    == CoordinateFrame.pixel(frame.cgImage, x: x + 20, y: y + 33))
            }
        }
    }

    @Test("The cut owns its pixels instead of pinning the whole display buffer")
    func cutIsStandalone() throws {
        let display = CGRect(x: 0, y: 0, width: 600, height: 400)
        let frame = CoordinateFrame.make(display: display, scale: 2)
        let cut = try #require(CaptureService.cut(CGRect(x: 10, y: 10, width: 40, height: 30), from: frame))

        let parentBytes = CFDataGetLength(frame.cgImage.dataProvider!.data!)
        let cutBytes = CFDataGetLength(cut.cgImage.dataProvider!.data!)
        #expect(cutBytes <= cut.cgImage.bytesPerRow * cut.cgImage.height)
        #expect(cutBytes * 50 < parentBytes)
    }

    @Test("A rect over the display's edge is clamped as a live capture would be")
    func clampsLikeCaptureArea() throws {
        let display = CGRect(x: 0, y: 0, width: 300, height: 200)
        let frame = CoordinateFrame.make(display: display, scale: 2)
        let cut = try #require(CaptureService.cut(CGRect(x: 250, y: 150, width: 100, height: 100), from: frame))

        #expect(cut.sourceRect == CGRect(x: 250, y: 150, width: 50, height: 50))
        #expect(cut.cgImage.width == 100)
        #expect(cut.cgImage.height == 100)
    }

    @Test("Anything the frame can't supply exactly falls back to a live capture")
    func unusableFramesFallBack() {
        let display = CGRect(x: 0, y: 0, width: 300, height: 200)
        let frame = CoordinateFrame.make(display: display, scale: 2)

        // Entirely on another display.
        #expect(CaptureService.cut(CGRect(x: 400, y: 10, width: 50, height: 50), from: frame) == nil)

        // A frame that is not the whole display at its scale (a crop, or a
        // display mode ScreenCaptureKit sized differently).
        let partial = CapturedImage(cgImage: frame.cgImage, scale: 2, sourceRect: CGRect(x: 0, y: 0, width: 320, height: 200))
        #expect(CaptureService.cut(CGRect(x: 10, y: 10, width: 50, height: 50), from: partial) == nil)
    }
}

@Suite("Frozen selection policy")
struct FrozenSelectionPolicyTests {
    @Test("Only an immediate area or text capture over a visible freeze uses it")
    func policy() {
        func uses(
            _ intent: CaptureIntent,
            timer: CaptureTimer = .none,
            cursor: Bool = false,
            shown: Bool = true
        ) -> Bool {
            FrozenSelectionPolicy.usesFreezeFrame(
                intent: intent,
                timer: timer,
                includesCursor: cursor,
                freezeWasShown: shown
            )
        }
        #expect(uses(.area))
        #expect(uses(.ocr))
        // A countdown means "what is on screen when it ends".
        #expect(!uses(.area, timer: .three))
        // The freeze frame has no cursor in it.
        #expect(!uses(.area, cursor: true))
        // The user was looking at the live screen.
        #expect(!uses(.area, shown: false))
        #expect(!uses(.scrolling))
        #expect(!uses(.window))
    }
}

@Suite("Applying a selection to a capture request")
struct CaptureRequestSelectionTests {
    @Test("A drag in window mode captures that area instead of failing")
    func windowModeDragBecomesArea() {
        var request = CaptureRequest(intent: .window)
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)

        let applied = request.apply(.area(rect, 7))
        #expect(applied)
        #expect(request.intent == .area)
        #expect(request.rect == rect)
        #expect(request.displayID == 7)
        #expect(request.windowID == nil)
    }

    @Test("A clicked window and the other modes keep their intent")
    func otherSelections() {
        let window = WindowInfo(
            id: 42,
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            title: "Doc",
            applicationName: "App",
            bundleIdentifier: "com.example.app",
            layer: 0,
            isOnScreen: true,
            isActive: true
        )
        var picked = CaptureRequest(intent: .window)
        let pickedApplied = picked.apply(.window(window))
        #expect(pickedApplied)
        #expect(picked.intent == .window)
        #expect(picked.windowID == 42)

        var text = CaptureRequest(intent: .ocr)
        let textApplied = text.apply(.area(CGRect(x: 0, y: 0, width: 50, height: 50), 1))
        #expect(textApplied)
        #expect(text.intent == .ocr)

        var cancelled = CaptureRequest(intent: .area)
        let cancelledApplied = cancelled.apply(.cancelled)
        #expect(!cancelledApplied)
    }
}
