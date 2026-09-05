import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Project save integrity")
struct ProjectRoundTripRegressionTests {
    @Test("Supported narrow scrolling captures preserve editable state",
          arguments: [16_384, 17_000, 32_769, 65_535])
    func tallProjectRoundTrip(height: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-tall-project-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestImage.solid(width: 16, height: height, red: 40, green: 80, blue: 120)
        var document = AnnotationDocument(sourcePixelSize: CGSize(width: 16, height: height), sourceScale: 1)
        document.add(AnnotationElement(kind: .rectangle,
                                       points: [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 10)],
                                       style: AnnotationStyle()))
        let project = directory.appendingPathComponent("Tall.notchshot")
        try NotchShotPackage.write(document: document, source: source, to: project)
        let reopened = try NotchShotPackage.read(from: project)
        #expect(reopened.source.width == 16)
        #expect(reopened.source.height == height)
        #expect(reopened.document.elements == document.elements)
        #expect(reopened.document.sourcePixelSize == document.sourcePixelSize)
    }

    @Test("Rejected saves leave the previous readable project intact",
          arguments: ["future version", "source geometry", "render budget", "JSON budget", "relative background"])
    func failedSavePreservesProject(reason: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-save-preserve-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestImage.solid(width: 20, height: 20)
        let original = AnnotationDocument(sourcePixelSize: CGSize(width: 20, height: 20), sourceScale: 1)
        let project = directory.appendingPathComponent("Existing.notchshot")
        try NotchShotPackage.write(document: original, source: source, to: project)
        let previousBytes = try Data(contentsOf: project.appendingPathComponent("document.json"))
        var invalid = original
        switch reason {
        case "future version": invalid.version = 2
        case "source geometry": invalid.sourcePixelSize.width = 21_000
        case "render budget":
            invalid.background = BackgroundConfiguration(fill: .solid(hex: "#FFFFFF"),
                                                          padding: 2_048, aspectRatio: 0.2)
        case "JSON budget":
            invalid.elements = (0 ..< 90).map { index in
                AnnotationElement(kind: .text, points: [.zero], style: AnnotationStyle(),
                                  text: String(repeating: "a", count: 90_000), order: index)
            }
        default: invalid.background.fill = .image(path: "Assets/../source.png")
        }
        #expect(throws: NotchShotError.self) {
            try NotchShotPackage.write(document: invalid, source: source, to: project)
        }
        #expect(try Data(contentsOf: project.appendingPathComponent("document.json")) == previousBytes)
        let reopened = try NotchShotPackage.read(from: project)
        #expect(reopened.document.sourcePixelSize == original.sourcePixelSize)
        #expect(reopened.document.elements.isEmpty)
    }
}
