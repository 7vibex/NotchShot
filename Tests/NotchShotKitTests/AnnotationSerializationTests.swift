import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Annotation undo transactions")
@MainActor
struct AnnotationUndoTransactionTests {
    @Test("A text editing session creates one undo step")
    func textEditingCoalesces() {
        let source = TestImage.solid(width: 100, height: 100)
        let controller = AnnotationDocumentController(
            source: source,
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 100))
        )
        var element = AnnotationElement(
            kind: .text,
            points: [CGPoint(x: 10, y: 10)],
            style: AnnotationStyle(),
            text: ""
        )
        controller.add(element)
        let beforeEditing = controller.undoStepCount

        controller.beginCoalescing()
        for index in 0 ..< 100 {
            element.text = "Draft \(index)"
            controller.update(element)
        }
        controller.endCoalescing()

        #expect(controller.undoStepCount == beforeEditing + 1)
        controller.undo()
        #expect(controller.selectedElement == nil)
        #expect(controller.document.elements.first?.text == "")
        controller.redo()
        #expect(controller.document.elements.first?.text == "Draft 99")
    }

    @Test("A continuous background slider gesture creates one undo step")
    func backgroundSliderCoalesces() {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 100, height: 100),
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 100))
        )
        let before = controller.undoStepCount
        controller.beginCoalescing()
        for value in 1 ... 100 {
            var background = controller.document.background
            background.padding = Double(value)
            controller.applyBackground(background)
        }
        controller.endCoalescing()

        #expect(controller.undoStepCount == before + 1)
        controller.undo()
        #expect(controller.document.background.padding == 0)
    }

    @Test("The editor reuses its base image until composition changes")
    func basePreviewCaching() throws {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 100, height: 80),
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 80))
        )
        let first = try #require(controller.basePreviewImage())

        controller.add(AnnotationElement(
            kind: .arrow,
            points: [CGPoint(x: 5, y: 5), CGPoint(x: 40, y: 30)],
            style: AnnotationStyle()
        ))
        let afterAnnotation = try #require(controller.basePreviewImage())
        #expect(first === afterAnnotation)

        controller.rotateRight()
        let afterRotation = try #require(controller.basePreviewImage())
        #expect(first !== afterRotation)
    }
}

@Suite("Annotation serialisation")
struct AnnotationSerializationTests {

    @Test("Editable project privacy warning defaults to cancel")
    func editableProjectPrivacyWarningDefaultsToCancel() {
        #expect(EditableProjectPrivacyAlertPolicy.buttonTitles.first == "Cancel")
        #expect(!EditableProjectPrivacyAlertPolicy.allowsSave(for: .alertFirstButtonReturn))
        #expect(EditableProjectPrivacyAlertPolicy.allowsSave(for: .alertSecondButtonReturn))
    }

    private func sampleDocument() -> AnnotationDocument {
        var document = AnnotationDocument(
            sourcePixelSize: CGSize(width: 1200, height: 800),
            sourceScale: 2,
            cropRect: CGRect(x: 10, y: 20, width: 600, height: 400),
            rotation: .ninety,
            background: BackgroundPreset.preset(id: "sunset")!.configuration
        )
        document.add(AnnotationElement(
            kind: .arrow,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 180)],
            style: AnnotationStyle(colorHex: "#FF3B30", lineWidth: 6)
        ))
        document.add(AnnotationElement(
            kind: .text,
            points: [CGPoint(x: 300, y: 220)],
            style: AnnotationStyle(fontSize: 32),
            text: "Look here"
        ))
        document.add(AnnotationElement(
            kind: .pencil,
            points: (0 ..< 40).map { CGPoint(x: Double($0) * 3, y: sin(Double($0)) * 20 + 100) },
            style: AnnotationStyle(lineWidth: 3)
        ))
        document.add(AnnotationElement(
            kind: .pixelate,
            points: [CGPoint(x: 400, y: 300), CGPoint(x: 520, y: 360)],
            style: AnnotationStyle(pixelBlockSize: 18)
        ))
        return document
    }

    @Test("A document round-trips through JSON unchanged")
    func jsonRoundTrip() throws {
        let original = sampleDocument()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnnotationDocument.self, from: data)

        #expect(decoded.sourcePixelSize == original.sourcePixelSize)
        #expect(decoded.cropRect == original.cropRect)
        #expect(decoded.rotation == original.rotation)
        #expect(decoded.elements.count == original.elements.count)
        #expect(decoded.background == original.background)
        for (lhs, rhs) in zip(decoded.sortedElements, original.sortedElements) {
            #expect(lhs.kind == rhs.kind)
            #expect(lhs.points == rhs.points)
            #expect(lhs.style == rhs.style)
            #expect(lhs.text == rhs.text)
        }
    }

    @Test("A project package writes and reads back")
    func packageRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 120, height: 90, red: 200, green: 30, blue: 60)
        var document = sampleDocument()
        document.sourcePixelSize = CGSize(width: 120, height: 90)
        document.cropRect = nil
        document.rotation = .none

        let url = directory.appendingPathComponent("Sample.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let contents = try NotchShotPackage.read(from: url)
        #expect(contents.document.elements.count == document.elements.count)
        #expect(contents.source.width == 120)
        #expect(contents.source.height == 90)
        #expect(contents.info.formatVersion == 1)
    }

    @Test("A package contains the original, a preview, and the document")
    func packageContents() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 60, height: 40, green: 255)
        let document = AnnotationDocument(sourcePixelSize: CGSize(width: 60, height: 40), sourceScale: 1)
        let url = directory.appendingPathComponent("Bits.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(names.contains("Info.json"))
        #expect(names.contains("document.json"))
        #expect(names.contains("background.json"))
        #expect(names.contains("source.png"))
        #expect(names.contains("preview.png"))
    }

    @Test("A newer format version is refused rather than misread")
    func rejectsNewerFormat() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 20, height: 20)
        let document = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let url = directory.appendingPathComponent("Future.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)

        // Rewrite Info.json claiming a future format.
        let info = """
        {"formatVersion":99,"applicationVersion":"9.0",\
        "createdAt":"2030-01-01T00:00:00Z","modifiedAt":"2030-01-01T00:00:00Z"}
        """
        try info.data(using: .utf8)!.write(to: url.appendingPathComponent("Info.json"))

        #expect(throws: NotchShotError.self) {
            _ = try NotchShotPackage.read(from: url)
        }
    }

    @Test("Imported projects reject absolute background paths")
    func rejectsAbsoluteBackgroundPath() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 20, height: 20)
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let url = directory.appendingPathComponent("Unsafe.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)
        document.background.fill = .image(path: "/tmp/notchshot-private-image.png")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url.appendingPathComponent("document.json"))

        #expect(throws: NotchShotError.self) {
            _ = try NotchShotPackage.read(from: url)
        }
    }

    @Test("Imported projects reject extreme finite render geometry")
    func rejectsExtremeRenderGeometry() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 20, height: 20)
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let url = directory.appendingPathComponent("Huge.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)

        document.background.padding = 1_000_000
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url.appendingPathComponent("document.json"))

        #expect(throws: NotchShotError.self) {
            _ = try NotchShotPackage.read(from: url)
        }
    }

    @Test("Imported source metadata must match the decoded image")
    func rejectsMismatchedSourceMetadata() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 20, height: 20)
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let url = directory.appendingPathComponent("Mismatch.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)

        document.sourcePixelSize = CGSize(width: 10_000, height: 20)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url.appendingPathComponent("document.json"))

        #expect(throws: NotchShotError.self) {
            _ = try NotchShotPackage.read(from: url)
        }
    }

    @Test("Imported projects reject traversal from their Assets directory")
    func rejectsBackgroundTraversal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = TestImage.solid(width: 20, height: 20)
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let url = directory.appendingPathComponent("Traversal.notchshot")
        _ = try NotchShotPackage.write(document: document, source: source, to: url)
        document.background.fill = .image(path: "Assets/../source.png")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url.appendingPathComponent("document.json"))

        #expect(throws: NotchShotError.self) {
            _ = try NotchShotPackage.read(from: url)
        }
    }

    @Test("Step counters number themselves in sequence")
    func counterNumbering() {
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 100))
        #expect(document.nextCounterValue == 1)
        document.add(AnnotationElement(
            kind: .counter,
            points: [.zero],
            style: AnnotationStyle(),
            counterValue: document.nextCounterValue
        ))
        #expect(document.nextCounterValue == 2)
        document.add(AnnotationElement(
            kind: .counter,
            points: [.zero],
            style: AnnotationStyle(),
            counterValue: document.nextCounterValue
        ))
        #expect(document.nextCounterValue == 3)
    }

    @Test("Hit testing picks the topmost element")
    func hitTesting() {
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 500, height: 500))
        document.add(AnnotationElement.rect(
            kind: .rectangle,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 200, y: 200)
        ))
        let topID = UUID()
        document.add(AnnotationElement(
            id: topID,
            kind: .ellipse,
            points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)],
            style: AnnotationStyle()
        ))
        #expect(document.element(at: CGPoint(x: 100, y: 100))?.id == topID)
    }

    @Test("Hex colours parse in every supported form")
    func hexColours() {
        #expect(NSColor(hex: "#FF0000")?.hexString == "#FF0000")
        #expect(NSColor(hex: "F00")?.hexString == "#FF0000")
        #expect(NSColor(hex: "#00FF00FF")?.hexString == "#00FF00")
        #expect(NSColor(hex: "nonsense") == nil)
    }

    @Test("Rotation cycles through the four quarter turns")
    func rotationCycle() {
        var angle = RotationAngle.none
        angle = angle.rotatedRight()
        #expect(angle == .ninety)
        angle = angle.rotatedRight()
        #expect(angle == .oneEighty)
        angle = angle.rotatedLeft()
        #expect(angle == .ninety)
        #expect(RotationAngle.ninety.swapsAxes)
        #expect(!RotationAngle.oneEighty.swapsAxes)
    }
}

@Suite("Background composition")
struct BackgroundLayoutTests {

    @Test("Padding grows the canvas on every side")
    func padding() {
        let background = BackgroundConfiguration(fill: .solid(hex: "#FFFFFF"), padding: 20)
        let layout = background.layout(for: CGSize(width: 100, height: 80), scale: 1)
        #expect(layout.canvas == CGSize(width: 140, height: 120))
        #expect(layout.content == CGRect(x: 20, y: 20, width: 100, height: 80))
    }

    @Test("Padding is expressed in points, so Retina doubles it")
    func paddingRespectsScale() {
        let background = BackgroundConfiguration(fill: .solid(hex: "#FFFFFF"), padding: 20)
        let layout = background.layout(for: CGSize(width: 100, height: 80), scale: 2)
        #expect(layout.canvas == CGSize(width: 180, height: 160))
    }

    @Test("A forced aspect ratio grows the canvas and never crops")
    func aspectRatioGrows() {
        let background = BackgroundConfiguration(
            fill: .solid(hex: "#000000"),
            padding: 0,
            aspectRatio: 16.0 / 9.0,
            balancesAutomatically: false
        )
        let layout = background.layout(for: CGSize(width: 100, height: 100), scale: 1)
        #expect(layout.canvas.width == 178) // 100 * 16/9, rounded
        #expect(layout.canvas.height == 100)
        // The capture keeps every pixel.
        #expect(layout.content.size == CGSize(width: 100, height: 100))
    }

    @Test("A tall capture in a wide frame stays fully visible")
    func tallContentInWideFrame() {
        let background = BackgroundConfiguration(
            padding: 10,
            aspectRatio: 1.0,
            balancesAutomatically: false
        )
        let layout = background.layout(for: CGSize(width: 100, height: 400), scale: 1)
        #expect(layout.canvas.width == layout.canvas.height)
        #expect(layout.content.width == 100)
        #expect(layout.content.height == 400)
        #expect(layout.content.minX >= 0)
        #expect(layout.content.maxX <= layout.canvas.width)
    }

    @Test("Optical balancing lifts the capture slightly above centre")
    func opticalBalance() {
        let balanced = BackgroundConfiguration(
            padding: 0,
            aspectRatio: 1.0,
            balancesAutomatically: true
        )
        let plain = BackgroundConfiguration(
            padding: 0,
            aspectRatio: 1.0,
            balancesAutomatically: false
        )
        let content = CGSize(width: 400, height: 100)
        let balancedLayout = balanced.layout(for: content, scale: 1)
        let plainLayout = plain.layout(for: content, scale: 1)
        #expect(balancedLayout.content.origin.y < plainLayout.content.origin.y)
    }

    @Test("Alignment biases the capture without pushing it off the canvas")
    func alignmentClamps() {
        let background = BackgroundConfiguration(
            padding: 20,
            horizontalAlignment: 1,
            verticalAlignment: -1,
            balancesAutomatically: false
        )
        let layout = background.layout(for: CGSize(width: 100, height: 100), scale: 1)
        #expect(layout.content.minX >= 0)
        #expect(layout.content.maxX <= layout.canvas.width)
        #expect(layout.content.minY >= 0)
        #expect(layout.content.maxY <= layout.canvas.height)
    }

    @Test("A zero-size capture doesn't produce a degenerate canvas")
    func degenerateContent() {
        let layout = BackgroundConfiguration(padding: 10).layout(for: .zero, scale: 1)
        #expect(layout.canvas.width > 0)
        #expect(layout.canvas.height > 0)
    }

    @Test("The 'none' preset is treated as disabled")
    func noneIsDisabled() {
        #expect(!BackgroundConfiguration.none.isEnabled)
        #expect(BackgroundPreset.preset(id: "paper")!.configuration.isEnabled)
    }
}
