import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

/// Regressions from the November 2026 review of the capture pipeline, editor,
/// comparison and inspector. None of these touch real files, the general
/// clipboard, or any window.
@Suite("Capture, editor and inspector regressions")
@MainActor
struct AuditNov2026FX3Tests {

    private func element(
        _ kind: AnnotationKind,
        from start: CGPoint,
        to end: CGPoint
    ) -> AnnotationElement {
        AnnotationElement(
            kind: kind,
            points: [start, end],
            style: .default(for: kind, baseColorHex: "#000000", lineWidth: 2)
        )
    }

    private func makeDocument(width: Int, height: Int) -> AnnotationDocument {
        AnnotationDocument(
            sourcePixelSize: CGSize(width: width, height: height),
            sourceScale: 1
        )
    }

    // MARK: Redaction

    @Test("A pixelate stacked over a blackout cannot bring the hidden pixels back")
    func blackoutWinsOverPixelate() throws {
        let source = TestImage.solid(width: 80, height: 80, red: 255)
        var document = makeDocument(width: 80, height: 80)
        document.add(element(.blackout, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60)))
        document.add(element(.pixelate, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60)))

        let output = try AnnotationRenderer.render(document: document, source: source)

        #expect(TestImage.pixel(output, x: 30, y: 30).r == 0)
        // Outside the redaction the source is untouched.
        #expect(TestImage.pixel(output, x: 70, y: 70).r == 255)
    }

    // MARK: Framing

    @Test("A forced ratio on a tall capture refuses to ask for gigabytes")
    func oversizedFramingThrows() {
        let tall = TestImage.solid(width: 2, height: 30_000)
        let framing = BackgroundConfiguration(fill: .solid(hex: "#000000"), aspectRatio: 16.0 / 9.0)
        #expect(throws: NotchShotError.self) {
            try AnnotationRenderer.composeBackground(framing, content: tall, scale: 1)
        }
    }

    @Test("A capture already past the budget can still take modest padding")
    func canvasBudgetScalesWithContent() {
        let content = CGSize(width: 11_000, height: 12_000)
        #expect(AnnotationRenderer.canvasFits(CGSize(width: 11_200, height: 12_200), content: content))
        #expect(!AnnotationRenderer.canvasFits(CGSize(width: 30_000, height: 12_000), content: content))
        #expect(!AnnotationRenderer.canvasFits(CGSize(width: 70_000, height: 10), content: content))
        #expect(!AnnotationRenderer.canvasFits(CGSize(width: CGFloat.infinity, height: 10), content: content))
    }

    // MARK: Seams

    @Test("Stitch seam warnings stay out of the exported file")
    func seamsAreNotBurnedIntoExports() throws {
        let source = TestImage.solid(width: 100, height: 100, red: 255, green: 255, blue: 255)
        var document = makeDocument(width: 100, height: 100)
        // Something to draw, so the annotation pass actually runs.
        document.add(element(.rectangle, from: CGPoint(x: 90, y: 90), to: CGPoint(x: 99, y: 99)))
        let controller = AnnotationDocumentController(source: source, document: document)
        controller.seams = [StitchSeam(y: 50, axis: .vertical, confidence: 0.1, addedRows: 40)]

        let output = try controller.renderFlattened()

        let pixel = TestImage.pixel(output, x: 4, y: 50)
        #expect(pixel.r == 255 && pixel.g == 255 && pixel.b == 255)
    }

    // MARK: Undo

    @Test("Undo during a gesture undoes the gesture and keeps the older steps")
    func undoDuringGesture() throws {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 40, height: 40),
            document: makeDocument(width: 40, height: 40)
        )
        let added = element(.rectangle, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 10, y: 10))
        controller.add(added)
        #expect(controller.undoStepCount == 1)

        controller.beginCoalescing()
        controller.update(added.moved(by: CGSize(width: 5, height: 5)))
        #expect(controller.canUndo)
        controller.undo()

        #expect(controller.document.elements.first?.points == added.points)
        #expect(controller.undoStepCount == 1)

        // The gesture is still open, and ending it with no change adds nothing.
        controller.endCoalescing()
        #expect(controller.undoStepCount == 1)
        controller.undo()
        #expect(controller.document.elements.isEmpty)
    }

    @Test("A gesture that changes nothing leaves redo alone")
    func noOpGestureKeepsRedo() {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 40, height: 40),
            document: makeDocument(width: 40, height: 40)
        )
        controller.add(element(.rectangle, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 10, y: 10)))
        controller.undo()
        #expect(controller.canRedo)

        controller.beginCoalescing()
        controller.endCoalescing()

        #expect(controller.canRedo)
        #expect(controller.undoStepCount == 0)
    }

    @Test("A gesture that changes something is one undo step and clears redo")
    func gestureIsOneStep() {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 40, height: 40),
            document: makeDocument(width: 40, height: 40)
        )
        let added = element(.rectangle, from: CGPoint(x: 1, y: 1), to: CGPoint(x: 10, y: 10))
        controller.add(added)
        controller.add(element(.ellipse, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 30, y: 30)))
        controller.undo()
        #expect(controller.canRedo)

        controller.beginCoalescing()
        controller.update(added.moved(by: CGSize(width: 1, height: 0)))
        controller.update(added.moved(by: CGSize(width: 2, height: 0)))
        #expect(!controller.canRedo)
        controller.endCoalescing()

        #expect(controller.undoStepCount == 2)
        #expect(!controller.canRedo)
    }

    // MARK: Text bounds

    @Test("Text is hit and outlined where it draws, right and down from its anchor")
    func textBoundsFollowTheText() {
        var text = element(.text, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100))
        text.points = [CGPoint(x: 100, y: 100)]
        let empty = text.boundingRect
        #expect(empty.minX == 100 && empty.minY == 100)
        #expect(empty.width > 0 && empty.height > 0)

        text.text = String(repeating: "A long annotation ", count: 8)
        #expect(text.boundingRect.width > empty.width)
        #expect(text.contains(CGPoint(x: text.boundingRect.maxX - 2, y: text.boundingRect.midY)))
    }

    // MARK: Stitching

    private func footerFrame(offset: Int) -> CGImage {
        let page = TestImage.page(width: 60, height: 240, offset: offset)
        return TestImage.make(width: 60, height: 240) { context in
            context.draw(page, in: CGRect(x: 0, y: 0, width: 60, height: 240))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 24))
        }
    }

    @Test("A fixed footer lands once at the end, not in the middle of the page")
    func footerAtEnd() throws {
        let output = try ScrollingStitcher.stitch(frames: [0, 40, 80].map(footerFrame(offset:)))
        let image = output.image
        #expect(image.height == 240 + 40 + 40)

        let isFooter = { (row: Int) in
            let pixel = TestImage.pixel(image, x: 5, y: row)
            return pixel.r > 200 && pixel.g < 60 && pixel.b < 60
        }
        // Where the first frame's footer used to be drawn, the page carries on.
        #expect(!isFooter(216))
        #expect(!isFooter(239))
        #expect(isFooter(image.height - 1))
        #expect(isFooter(image.height - 24))
        #expect(!isFooter(image.height - 25))

        let reference = TestImage.page(width: 60, height: 320, offset: 0)
        for row in [216, 239, 250, 295] {
            let expected = TestImage.pixel(reference, x: 5, y: row)
            let actual = TestImage.pixel(image, x: 5, y: row)
            #expect(abs(Int(expected.r) - Int(actual.r)) <= 2, "row \(row)")
        }
    }

    /// A page whose rows are all different except for one blank run.
    private func gappedFrame(offset: Int, height: Int, gap: Range<Int>) -> GrayBuffer? {
        let image = TestImage.make(width: 40, height: height) { context in
            for row in 0 ..< height {
                let pageRow = row + offset
                let value = gap.contains(pageRow)
                    ? 128
                    : 20 + (((pageRow + 1) &* 2_654_435_761) >> 8) % 200
                context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
                context.fill(CGRect(x: 0, y: height - row - 1, width: 40, height: 1))
            }
        }
        return GrayBuffer(image: image, columnStride: 4)
    }

    @Test("A blank bottom band aligns on the content above it")
    func blankBandAlignsOnContent() throws {
        let gap = 150 ..< 330
        let first = try #require(gappedFrame(offset: 0, height: 300, gap: gap))
        let second = try #require(gappedFrame(offset: 60, height: 300, gap: gap))

        let match = try #require(ScrollingStitcher.bestMatch(
            previous: first,
            next: second,
            sticky: ScrollingStitcher.StickyBands(top: 0, bottom: 0),
            settings: StitchSettings()
        ))

        #expect(match.addedRows == 60)
        #expect(match.sourceTop == 240)
        #expect(match.confidence >= StitchSettings.warningConfidence)
    }

    @Test("A join made only of blank rows is flagged as a guess")
    func allBlankJoinIsSuspect() throws {
        let image = TestImage.solid(width: 40, height: 300, red: 128, green: 128, blue: 128)
        let longer = TestImage.solid(width: 40, height: 360, red: 128, green: 128, blue: 128)
        let first = try #require(GrayBuffer(image: image, columnStride: 4))
        let second = try #require(GrayBuffer(image: longer, columnStride: 4))

        let match = try #require(ScrollingStitcher.bestMatch(
            previous: first,
            next: second,
            sticky: ScrollingStitcher.StickyBands(top: 0, bottom: 0),
            settings: StitchSettings()
        ))

        #expect(match.confidence < StitchSettings.warningConfidence)
    }

    // MARK: Loupe

    @Test("Near a screen edge the loupe leaves the missing pixels black, unstretched")
    func loupeKeepsPixelsSquare() throws {
        let sample = try #require(SelectionOverlayView.loupeSample(
            sampleRect: CGRect(x: -3, y: -3, width: 15, height: 15),
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            frame: CGRect(x: 200, y: 200, width: 120, height: 120),
            magnification: 8
        ))
        #expect(sample.crop == CGRect(x: 0, y: 0, width: 12, height: 12))
        // Three missing columns on the left, three missing rows on top.
        #expect(sample.destination == CGRect(x: 224, y: 200, width: 96, height: 96))

        #expect(SelectionOverlayView.loupeSample(
            sampleRect: CGRect(x: -50, y: -50, width: 15, height: 15),
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            frame: CGRect(x: 200, y: 200, width: 120, height: 120),
            magnification: 8
        ) == nil)
    }

    // MARK: Inspector

    @Test("A translucent pixel reports its real colour, not the premultiplied one")
    func samplingUnpremultiplies() throws {
        let image = TestImage.make(width: 4, height: 4) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/notchshot-inspector-\(UUID().uuidString).png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 4, height: 4)
        )
        let session = ImageInspectionSession(
            asset: asset,
            image: CapturedImage(cgImage: image, scale: 1, sourceRect: .zero)
        )

        session.updateHover(at: CGPoint(x: 1, y: 1))

        let color = try #require(session.hoverSample?.color)
        #expect(color.red > 0.95)
        #expect(color.green < 0.05)
    }

    // MARK: Stack

    @Test("Finishing an export keeps captures added while it ran")
    func exportKeepsNewerItems() {
        let stack = CaptureStack()
        func asset(_ name: String) -> CaptureAsset {
            CaptureAsset(
                url: URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString).png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 100, height: 100)
            )
        }
        stack.add(asset("exported"))
        let exported = Set(stack.items.map(\.id))
        stack.isCollecting = true
        stack.add(asset("newer"))

        stack.removeExported(ids: exported)

        #expect(stack.items.count == 1)
        #expect(stack.isCollecting)

        stack.removeExported(ids: Set(stack.items.map(\.id)))
        #expect(stack.isEmpty)
        #expect(!stack.isCollecting)
    }

    // MARK: Comparison

    @Test("A same-size pair compares without being refitted")
    func samePairDifference() throws {
        let before = TestImage.solid(width: 4, height: 4, red: 200)
        let after = TestImage.solid(width: 4, height: 4, red: 50)

        let planes = try ImageComparisonRenderer.differencePlanes(before: before, after: after)
        let difference = try ImageComparisonRenderer.difference(planes: planes, threshold: 0)

        #expect(planes.width == 4 && planes.height == 4)
        let pixel = TestImage.pixel(difference, x: 1, y: 1)
        #expect(abs(Int(pixel.r) - 150) <= 3)
    }
}
