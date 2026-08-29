import CoreGraphics
import Testing
@testable import NotchShotKit

/// The security promise of the editor: a redaction in an *exported* image must
/// destroy the pixels, not cover them. These tests read the exported bitmap
/// back and assert the original content is unrecoverable.
@Suite("Redaction export")
struct RedactionExportTests {

    /// A 200×200 image whose left half is a fine gradient (the "secret") and
    /// whose right half is flat.
    private func secretImage() -> CGImage {
        TestImage.make(width: 200, height: 200) { context in
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            for x in 0 ..< 100 {
                for y in 0 ..< 100 {
                    context.setFillColor(
                        red: CGFloat(x) / 100,
                        green: CGFloat(y) / 100,
                        blue: 0.25,
                        alpha: 1
                    )
                    context.fill(CGRect(x: x, y: 200 - y - 1, width: 1, height: 1))
                }
            }
        }
    }

    private func document(with element: AnnotationElement) -> AnnotationDocument {
        AnnotationDocument(
            sourcePixelSize: CGSize(width: 200, height: 200),
            sourceScale: 1,
            elements: [element]
        )
    }

    @Test("Blackout leaves a uniformly black region in the export")
    func blackoutIsOpaque() throws {
        let source = secretImage()
        var style = AnnotationStyle(colorHex: "#000000")
        style.isFilled = true
        // Deliberately semi-transparent: a blackout must ignore opacity, or the
        // hidden content would still be readable under the overlay.
        style.opacity = 0.3

        let element = AnnotationElement.rect(
            kind: .blackout,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 90, y: 90),
            style: style
        )
        let exported = try AnnotationRenderer.render(
            document: document(with: element),
            source: source
        )

        let colors = TestImage.distinctColors(
            exported,
            in: CGRect(x: 20, y: 20, width: 60, height: 60),
            step: 4
        )
        #expect(colors == ["0,0,0"])
    }

    @Test("Pixelation destroys detail rather than blurring over it")
    func pixelationIsDestructive() throws {
        let source = secretImage()
        var style = AnnotationStyle()
        style.pixelBlockSize = 20

        let element = AnnotationElement.rect(
            kind: .pixelate,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100),
            style: style
        )
        let exported = try AnnotationRenderer.render(
            document: document(with: element),
            source: source
        )

        let originalColors = TestImage.distinctColors(
            source,
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            step: 2
        )
        let exportedColors = TestImage.distinctColors(
            exported,
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            step: 2
        )

        // A 100×100 gradient at 20px blocks can hold at most 25 colours.
        #expect(originalColors.count > 500)
        #expect(exportedColors.count <= 30)
    }

    /// The redaction canvas is flipped so element geometry reads in top-left
    /// space. That is right for `fill`, which is what a blackout uses, but it
    /// mirrors any *image* drawn into it — and pixelation draws one. The export
    /// therefore came out with its mosaic rows reversed relative to both the
    /// source and the editor preview.
    ///
    /// The colour-count tests above cannot see that: a mirrored mosaic has
    /// exactly the same colours as an upright one. This asserts on position.
    @Test("Pixelation keeps the orientation of what it replaced")
    func pixelationIsNotMirrored() throws {
        // Top half red, bottom half blue, so a vertical flip is unmistakable.
        let source = TestImage.make(width: 64, height: 64) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        #expect(TestImage.pixel(source, x: 32, y: 8).r > 200)
        #expect(TestImage.pixel(source, x: 32, y: 56).b > 200)

        var style = AnnotationStyle()
        style.pixelBlockSize = 16
        let element = AnnotationElement.rect(
            kind: .pixelate,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 64, y: 64),
            style: style
        )
        let exported = try AnnotationRenderer.render(
            document: AnnotationDocument(
                sourcePixelSize: CGSize(width: 64, height: 64),
                sourceScale: 1,
                elements: [element]
            ),
            source: source
        )

        // Still destructive — that is the other tests' job — but the red half
        // must remain the top half.
        let top = TestImage.pixel(exported, x: 32, y: 8)
        let bottom = TestImage.pixel(exported, x: 32, y: 56)
        #expect(top.r > top.b)
        #expect(bottom.b > bottom.r)
    }

    @Test("Pixel blocks are uniform, so no sub-block detail survives")
    func pixelBlocksAreFlat() throws {
        let source = secretImage()
        var style = AnnotationStyle()
        style.pixelBlockSize = 25

        let element = AnnotationElement.rect(
            kind: .pixelate,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100),
            style: style
        )
        let exported = try AnnotationRenderer.render(
            document: document(with: element),
            source: source
        )

        // Sample well inside one block; every pixel there must be identical.
        let colors = TestImage.distinctColors(
            exported,
            in: CGRect(x: 30, y: 30, width: 15, height: 15),
            step: 1
        )
        #expect(colors.count == 1)
    }

    @Test("Content outside the redaction is untouched")
    func outsideRegionSurvives() throws {
        let source = secretImage()
        let element = AnnotationElement.rect(
            kind: .blackout,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100),
            style: AnnotationStyle(colorHex: "#000000", isFilled: true)
        )
        let exported = try AnnotationRenderer.render(
            document: document(with: element),
            source: source
        )

        let original = TestImage.pixel(source, x: 150, y: 150)
        let after = TestImage.pixel(exported, x: 150, y: 150)
        #expect(original == after)
    }

    @Test("The preview keeps the original pixels so editing stays reversible")
    @MainActor
    func previewIsNonDestructive() throws {
        let source = secretImage()
        let element = AnnotationElement.rect(
            kind: .pixelate,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 100),
            style: AnnotationStyle()
        )
        let document = document(with: element)

        #expect(document.hasRedactions)
        let controller = AnnotationDocumentController(source: source, document: document)
        let preview = try controller.renderPreview()
        let flattened = try controller.renderFlattened()
        #expect(preview.width == source.width)
        #expect(flattened.width == source.width)
        #expect(TestImage.pixel(preview, x: 25, y: 25) != TestImage.pixel(flattened, x: 25, y: 25))

        let sourceColors = TestImage.distinctColors(
            source,
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            step: 4
        )
        #expect(sourceColors.count > 100) // source object itself is unmodified
    }

    @Test("A redaction survives a crop that keeps it in frame")
    func redactionWithCrop() throws {
        let source = secretImage()
        var document = document(with: AnnotationElement.rect(
            kind: .blackout,
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 80, y: 80),
            style: AnnotationStyle(colorHex: "#000000", isFilled: true)
        ))
        document.cropRect = CGRect(x: 10, y: 10, width: 100, height: 100)

        let exported = try AnnotationRenderer.render(document: document, source: source)
        #expect(exported.width == 100)
        #expect(exported.height == 100)

        // The blackout started at source (20,20), i.e. (10,10) after the crop.
        let inside = TestImage.pixel(exported, x: 40, y: 40)
        #expect(inside == (0, 0, 0))
    }

    @Test("A redaction partly off the canvas is clipped, not skipped")
    func redactionClippedToImage() throws {
        let source = secretImage()
        let element = AnnotationElement.rect(
            kind: .blackout,
            from: CGPoint(x: 150, y: 150),
            to: CGPoint(x: 400, y: 400),
            style: AnnotationStyle(colorHex: "#000000", isFilled: true)
        )
        let exported = try AnnotationRenderer.render(
            document: document(with: element),
            source: source
        )
        #expect(TestImage.pixel(exported, x: 180, y: 180) == (0, 0, 0))
        #expect(exported.width == 200)
    }
}
