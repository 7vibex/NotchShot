import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Annotation editor geometry")
struct AnnotationEditorGeometryTests {

    @Test("Crop coordinates round-trip through every quarter turn")
    func cropCoordinatesRoundTrip() throws {
        let sourcePoint = CGPoint(x: 230, y: 175)

        for rotation in RotationAngle.allCases {
            let geometry = makeGeometry(rotation: rotation)
            let viewPoint = geometry.viewPoint(from: sourcePoint)
            let roundTrip = try #require(geometry.sourcePoint(from: viewPoint))

            expectEqual(roundTrip, sourcePoint)
        }
    }

    @Test("Ninety-degree rotation maps source corners to the rotated preview")
    func ninetyDegreeCornerMapping() {
        let geometry = makeGeometry(rotation: .ninety)
        let crop = geometry.visibleSourceRect

        expectEqual(
            geometry.viewPoint(from: CGPoint(x: crop.minX, y: crop.minY)),
            CGPoint(x: geometry.contentViewRect.maxX, y: geometry.contentViewRect.minY)
        )
        expectEqual(
            geometry.viewPoint(from: CGPoint(x: crop.maxX, y: crop.maxY)),
            CGPoint(x: geometry.contentViewRect.minX, y: geometry.contentViewRect.maxY)
        )
    }

    @Test("Two-hundred-seventy-degree rotation maps source corners to the rotated preview")
    func twoSeventyDegreeCornerMapping() {
        let geometry = makeGeometry(rotation: .twoSeventy)
        let crop = geometry.visibleSourceRect

        expectEqual(
            geometry.viewPoint(from: CGPoint(x: crop.minX, y: crop.minY)),
            CGPoint(x: geometry.contentViewRect.minX, y: geometry.contentViewRect.maxY)
        )
        expectEqual(
            geometry.viewPoint(from: CGPoint(x: crop.maxX, y: crop.maxY)),
            CGPoint(x: geometry.contentViewRect.maxX, y: geometry.contentViewRect.minY)
        )
    }

    @Test("Background framing keeps interaction inside the captured image")
    func backgroundFraming() throws {
        let background = BackgroundConfiguration(
            fill: .solid(hex: "#FFFFFF"),
            padding: 32,
            aspectRatio: 1,
            balancesAutomatically: false
        )
        let geometry = makeGeometry(rotation: .ninety, background: background)

        #expect(geometry.outputViewRect.width == geometry.outputViewRect.height)
        #expect(geometry.contentViewRect.minX > geometry.outputViewRect.minX)
        #expect(geometry.contentViewRect.minY > geometry.outputViewRect.minY)

        let backgroundPoint = CGPoint(
            x: geometry.outputViewRect.minX + 1,
            y: geometry.outputViewRect.minY + 1
        )
        #expect(geometry.sourcePoint(from: backgroundPoint) == nil)

        let clamped = try #require(geometry.sourcePoint(from: backgroundPoint, clamped: true))
        let crop = geometry.visibleSourceRect
        #expect(clamped.x >= crop.minX && clamped.x <= crop.maxX)
        #expect(clamped.y >= crop.minY && clamped.y <= crop.maxY)
    }

    @Test("Selection bounds rotate with their annotation")
    func selectionBoundsRotate() {
        let geometry = makeGeometry(rotation: .ninety)
        let sourceRect = CGRect(x: 180, y: 120, width: 80, height: 30)
        let viewRect = geometry.viewRect(from: sourceRect)
        let scale = geometry.contentViewRect.width / geometry.rotatedContentSize.width

        expectEqual(viewRect.width, sourceRect.height * scale)
        expectEqual(viewRect.height, sourceRect.width * scale)
    }

    @Test("Affine drawing transform matches point mapping")
    func affineTransformMatchesPointMapping() {
        let sourcePoint = CGPoint(x: 330, y: 245)

        for rotation in RotationAngle.allCases {
            let geometry = makeGeometry(rotation: rotation)
            expectEqual(
                sourcePoint.applying(geometry.sourceToViewTransform),
                geometry.viewPoint(from: sourcePoint)
            )
        }
    }

    @Test("Editor mapping matches flattened export with crop, rotation and background")
    func mappingMatchesExport() throws {
        let source = TestImage.solid(width: 160, height: 100, red: 255, green: 255, blue: 255)
        let markerCenter = CGPoint(x: 60, y: 40)
        let background = BackgroundConfiguration(
            fill: .solid(hex: "#222222"),
            padding: 12,
            aspectRatio: 1,
            horizontalAlignment: 0.5,
            verticalAlignment: -0.5,
            balancesAutomatically: false
        )

        for rotation in RotationAngle.allCases {
            var document = AnnotationDocument(
                sourcePixelSize: CGSize(width: 160, height: 100),
                sourceScale: 1,
                cropRect: CGRect(x: 20, y: 10, width: 120, height: 80),
                rotation: rotation,
                background: background
            )
            document.add(AnnotationElement.rect(
                kind: .rectangle,
                from: CGPoint(x: 52, y: 32),
                to: CGPoint(x: 68, y: 48),
                style: AnnotationStyle(
                    colorHex: "#FF0000",
                    lineWidth: 1,
                    isFilled: true,
                    cornerRadius: 0,
                    hasShadow: false
                )
            ))

            let exported = try AnnotationRenderer.render(document: document, source: source)
            let geometry = AnnotationEditorGeometry(
                document: document,
                containerSize: CGSize(width: exported.width + 48, height: exported.height + 48)
            )
            #expect(geometry.outputPixelSize == CGSize(width: exported.width, height: exported.height))
            let viewPoint = geometry.viewPoint(from: markerCenter)
            let outputPoint = CGPoint(
                x: viewPoint.x - geometry.outputViewRect.minX,
                y: viewPoint.y - geometry.outputViewRect.minY
            )
            let pixel = TestImage.pixel(
                exported,
                x: Int(outputPoint.x.rounded()),
                y: Int(outputPoint.y.rounded())
            )

            #expect(pixel.r > 240)
            #expect(pixel.g < 20)
            #expect(pixel.b < 20)
        }
    }

    private func makeGeometry(
        rotation: RotationAngle,
        background: BackgroundConfiguration = .none
    ) -> AnnotationEditorGeometry {
        let document = AnnotationDocument(
            sourcePixelSize: CGSize(width: 1_200, height: 800),
            sourceScale: 2,
            cropRect: CGRect(x: 100, y: 50, width: 600, height: 400),
            rotation: rotation,
            background: background
        )
        return AnnotationEditorGeometry(
            document: document,
            containerSize: CGSize(width: 720, height: 520)
        )
    }

    private func expectEqual(
        _ actual: CGPoint,
        _ expected: CGPoint,
        tolerance: CGFloat = 0.000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.x - expected.x) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(actual.y - expected.y) < tolerance, sourceLocation: sourceLocation)
    }

    private func expectEqual(
        _ actual: CGFloat,
        _ expected: CGFloat,
        tolerance: CGFloat = 0.000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < tolerance, sourceLocation: sourceLocation)
    }
}
