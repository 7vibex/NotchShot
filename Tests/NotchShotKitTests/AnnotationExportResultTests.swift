import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NotchShotKit

@Suite("Annotation export results")
@MainActor
struct AnnotationExportResultTests {
    @Test("Saved dimensions and pixels include crop, rotation, background and opaque redaction",
          arguments: RotationAngle.allCases)
    func composedExport(rotation: RotationAngle) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestImage.make(width: 160, height: 100) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            // A source marker centred at (60, 40) in top-left coordinates.
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 52, y: 52, width: 16, height: 16))
        }
        var style = AnnotationStyle(colorHex: "#000000")
        style.opacity = 0.3
        let document = AnnotationDocument(
            sourcePixelSize: CGSize(width: 160, height: 100),
            sourceScale: 1,
            cropRect: CGRect(x: 20, y: 10, width: 120, height: 80),
            rotation: rotation,
            elements: [AnnotationElement.rect(
                kind: .blackout,
                from: CGPoint(x: 100, y: 55),
                to: CGPoint(x: 120, y: 75),
                style: style
            )],
            background: BackgroundConfiguration(
                fill: .solid(hex: "#222222"),
                padding: 12,
                balancesAutomatically: false,
                drawsInnerBorder: false
            )
        )
        let controller = AnnotationDocumentController(source: source, document: document)
        let target = directory.appendingPathComponent("composed.png")
        let result = try controller.exportImageResult(to: target, format: .png)
        let decoded = try decode(result.url)

        // Independent expected positions after cropping, clockwise rotation,
        // and 12 pixels of padding; do not derive these with the renderer.
        let expectedSize: CGSize
        let marker: (x: Int, y: Int)
        let redaction: (x: Int, y: Int)
        switch rotation {
        case .none:
            expectedSize = CGSize(width: 144, height: 104)
            marker = (52, 42)
            redaction = (102, 67)
        case .ninety:
            expectedSize = CGSize(width: 104, height: 144)
            marker = (62, 52)
            redaction = (37, 102)
        case .oneEighty:
            expectedSize = CGSize(width: 144, height: 104)
            marker = (92, 62)
            redaction = (42, 37)
        case .twoSeventy:
            expectedSize = CGSize(width: 104, height: 144)
            marker = (42, 92)
            redaction = (67, 42)
        }
        #expect(result.url == target)
        #expect(result.pixelSize == expectedSize)
        #expect(CGSize(width: decoded.width, height: decoded.height) == expectedSize)
        let markerPixel = TestImage.pixel(decoded, x: marker.x, y: marker.y)
        #expect(markerPixel.r > 240 && markerPixel.g < 20 && markerPixel.b < 20)
        let hiddenPixel = TestImage.pixel(decoded, x: redaction.x, y: redaction.y)
        #expect(hiddenPixel.r == 0 && hiddenPixel.g == 0 && hiddenPixel.b == 0)
        let backgroundPixel = TestImage.pixel(decoded, x: 3, y: 3)
        #expect(abs(Int(backgroundPixel.r) - 34) <= 2)
        #expect(abs(Int(backgroundPixel.g) - 34) <= 2)
        #expect(abs(Int(backgroundPixel.b) - 34) <= 2)
        let originalPixel = TestImage.pixel(source, x: 110, y: 65)
        #expect(originalPixel.r == 255 && originalPixel.g == 255 && originalPixel.b == 255)
    }

    @Test("Saved pixelation destroys source detail")
    func savedPixelation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestImage.make(width: 100, height: 100) { context in
            for x in 0 ..< 100 {
                for y in 0 ..< 100 {
                    context.setFillColor(red: CGFloat(x) / 100, green: CGFloat(y) / 100, blue: 0.25, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let document = AnnotationDocument(
            sourcePixelSize: CGSize(width: 100, height: 100),
            sourceScale: 1,
            elements: [AnnotationElement.rect(
                kind: .pixelate,
                from: .zero,
                to: CGPoint(x: 100, y: 100),
                style: AnnotationStyle(pixelBlockSize: 20)
            )]
        )
        let controller = AnnotationDocumentController(source: source, document: document)
        let result = try controller.exportImageResult(to: directory.appendingPathComponent("redacted.png"), format: .png)
        let decoded = try decode(result.url)
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(result.pixelSize == CGSize(width: decoded.width, height: decoded.height))
        #expect(TestImage.distinctColors(source, in: region, step: 2).count > 500)
        #expect(TestImage.distinctColors(decoded, in: region, step: 2).count <= 30)
    }

    @Test("An unwritable destination throws without changing existing contents")
    func failedWrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A nonempty directory is a deterministic invalid image destination,
        // independent of the account's permissions or umask.
        let target = directory.appendingPathComponent("occupied.png", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("keep.txt")
        let contents = Data("existing contents".utf8)
        try contents.write(to: sentinel)
        let controller = makePlainController()
        #expect(throws: (any Error).self) {
            try controller.exportImageResult(to: target, format: .png)
        }
        #expect(try Data(contentsOf: sentinel) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["keep.txt"])
    }

    @Test("The existing URL export API still writes the image")
    func existingURLWrapper() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("legacy.png")
        let result = try makePlainController().exportImage(to: target, format: .png)
        let decoded = try decode(result)
        #expect(result == target)
        #expect(decoded.width == 32 && decoded.height == 24)
        let pixel = TestImage.pixel(decoded, x: 16, y: 12)
        #expect(pixel.r == 0 && pixel.g == 255 && pixel.b == 0)
    }

    @Test("Every requested image format returns dimensions matching the decoded file",
          arguments: ImageFormat.allCases)
    func formatDimensions(format: ImageFormat) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("image.\(format.rawValue)")
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 128, height: 96, green: 255),
            document: AnnotationDocument(
                sourcePixelSize: CGSize(width: 128, height: 96),
                sourceScale: 2,
                cropRect: CGRect(x: 16, y: 16, width: 96, height: 64),
                rotation: .ninety
            )
        )
        let result = try controller.exportImageResult(to: target, format: format)
        let decoded = try decode(result.url)
        #expect(result.url == target)
        #expect(result.pixelSize == CGSize(width: 64, height: 96))
        #expect(result.pixelSize == CGSize(width: decoded.width, height: decoded.height))
        let pixel = TestImage.pixel(decoded, x: 32, y: 48)
        // JPEG and HEIC may quantize the source; the format's existing PNG
        // fallback is also permitted by ImageExport's public contract.
        #expect(pixel.r < 25 && pixel.g > 230 && pixel.b < 25)
    }

    private func makePlainController() -> AnnotationDocumentController {
        AnnotationDocumentController(
            source: TestImage.solid(width: 32, height: 24, green: 255),
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 32, height: 24), sourceScale: 1)
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-export-result-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
