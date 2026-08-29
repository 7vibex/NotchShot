import AppKit
import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Selection overlay accessibility")
@MainActor
struct SelectionOverlayTests {
    private func makeView() -> SelectionOverlayView {
        SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            displayID: 1,
            mode: .area,
            freezeFrame: nil,
            showsFreeze: false,
            showsMagnifier: false,
            windows: [],
            scale: 2
        )
    }

    @Test("Resize handles use the shared motor-accessibility target")
    func resizeHandleTarget() {
        #expect(SelectionOverlayView.resizeHandleHitSize >= 36)
    }

    @Test("The overlay exposes an accessible group and can create an initial selection")
    func createsAccessibleInitialSelection() {
        let view = makeView()
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .group)
        #expect(view.createCenteredSelection())
        #expect((view.accessibilityValue() as? String)?.contains("pixels") == true)
    }

    @Test("The accessibility confirm action completes the centered selection")
    func confirmsAccessibleSelection() {
        let view = makeView()
        var result: SelectionResult?
        view.onResult = { result = $0 }

        #expect(view.createCenteredSelection())
        #expect(view.accessibilityPerformConfirm())
        guard case .area(let rect, let displayID) = result else {
            Issue.record("Expected an area result")
            return
        }
        #expect(displayID == 1)
        #expect(rect.width == 600)
        #expect(rect.height == 400)
    }

    @Test("The accessibility cancel action returns cancellation")
    func cancelsAccessibly() {
        let view = makeView()
        var result: SelectionResult?
        view.onResult = { result = $0 }

        #expect(view.accessibilityPerformCancel())
        #expect(result == .cancelled)
    }

    @Test("A drawn corner handle resizes from its opposite corner")
    func cornerHandleResize() {
        let resized = SelectionOverlayView.resizedRect(
            CGRect(x: 100, y: 100, width: 300, height: 200),
            handle: .topRight,
            to: CGPoint(x: 500, y: 450),
            bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        #expect(resized == CGRect(x: 100, y: 100, width: 400, height: 350))
    }

    @Test("Corner resizing clamps to display bounds")
    func cornerHandleClamp() {
        let resized = SelectionOverlayView.resizedRect(
            CGRect(x: 100, y: 100, width: 300, height: 200),
            handle: .bottomLeft,
            to: CGPoint(x: -50, y: -80),
            bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        #expect(resized.minX == 0)
        #expect(resized.minY == 0)
        #expect(resized.maxX == 400)
        #expect(resized.maxY == 300)
    }
}

/// The backdrop avoids a full-screen translucent fill because Core Graphics
/// blends one about thirty times slower than it writes an opaque one. These
/// render the view for real and check the resulting pixels, because the whole
/// point of the faster route is that it must be indistinguishable.
@Suite("Selection overlay backdrop")
@MainActor
struct SelectionOverlayBackdropTests {
    private static let side = 400
    private static let scale: CGFloat = 2

    private func render(showsFreeze: Bool, selected: Bool) -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let freeze = CapturedImage(
            cgImage: TestImage.solid(
                width: Int(CGFloat(Self.side) * Self.scale),
                height: Int(CGFloat(Self.side) * Self.scale),
                red: 200,
                green: 200,
                blue: 200
            ),
            scale: Self.scale,
            sourceRect: bounds
        )
        let view = SelectionOverlayView(
            frame: bounds,
            screenFrame: bounds,
            displayID: 1,
            mode: .area,
            freezeFrame: showsFreeze ? freeze : nil,
            showsFreeze: showsFreeze,
            showsMagnifier: false,
            windows: [],
            scale: Self.scale
        )
        if selected { _ = view.createCenteredSelection() }

        let context = CGContext(
            data: nil,
            width: Self.side,
            height: Self.side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.clear(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    @Test("A frozen backdrop dims outside the selection and leaves it untouched inside")
    func frozenBackdropDimsOnlyOutside() {
        let image = render(showsFreeze: true, selected: true)

        // The centred selection covers the middle of the view.
        let inside = TestImage.pixel(image, x: Self.side / 2, y: Self.side / 2)
        #expect(inside.r == 200)
        #expect(inside.g == 200)
        #expect(inside.b == 200)

        // 200 composited under black at alpha 0.45 is 110.
        let outside = TestImage.pixel(image, x: 12, y: 12)
        #expect(abs(Int(outside.r) - 110) <= 1)
        #expect(abs(Int(outside.g) - 110) <= 1)
        #expect(abs(Int(outside.b) - 110) <= 1)
    }

    @Test("The selection keeps the original thin outline footprint")
    func selectionOutlineStaysThin() {
        let image = render(showsFreeze: true, selected: true)

        // The centred selection starts 100 points from each edge. Three points
        // outside and two points inside its top edge must already be backdrop
        // pixels; a layered 4–6 point keyline incorrectly paints over both.
        let justOutside = TestImage.pixel(image, x: Self.side / 2, y: 97)
        #expect(abs(Int(justOutside.r) - 110) <= 1)
        #expect(abs(Int(justOutside.g) - 110) <= 1)
        #expect(abs(Int(justOutside.b) - 110) <= 1)

        let justInside = TestImage.pixel(image, x: Self.side / 2, y: 102)
        #expect(justInside.r == 200)
        #expect(justInside.g == 200)
        #expect(justInside.b == 200)
    }

    @Test("With no selection the whole frozen backdrop is dimmed")
    func frozenBackdropDimsEverythingWithoutSelection() {
        let image = render(showsFreeze: true, selected: false)
        for point in [(12, 12), (Self.side / 2, Self.side / 2), (Self.side - 12, Self.side - 12)] {
            let pixel = TestImage.pixel(image, x: point.0, y: point.1)
            #expect(abs(Int(pixel.r) - 110) <= 1, "at \(point)")
        }
    }

    @Test("A live backdrop leaves the selection fully transparent")
    func liveBackdropPunchesThrough() {
        let image = render(showsFreeze: false, selected: true)
        // Premultiplied black at alpha 0.28 outside, nothing written inside, so
        // both read back as zero colour. Alpha is what distinguishes them.
        var pixels = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
        let context = CGContext(
            data: &pixels,
            width: Self.side,
            height: Self.side,
            bitsPerComponent: 8,
            bytesPerRow: Self.side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))

        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[(y * Self.side + x) * 4 + 3]
        }
        #expect(alpha(x: Self.side / 2, y: Self.side / 2) == 0)
        #expect(abs(Int(alpha(x: 12, y: 12)) - 71) <= 1) // 0.28 * 255
    }
}
