import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Background framing")
struct BackgroundFramingTests {

    @Test("A window bar is laid out directly above the capture")
    func windowBarLayout() {
        let background = BackgroundConfiguration(
            fill: .solid(hex: "#000000"),
            padding: 20,
            windowChrome: .dark
        )
        let layout = background.layout(for: CGSize(width: 400, height: 300), scale: 2)
        let bar = BackgroundWindowChrome.barHeight * 2

        #expect(layout.canvas == CGSize(width: 400 + 80, height: 300 + 80 + bar))
        #expect(layout.content == CGRect(x: 40, y: 40 + bar, width: 400, height: 300))
    }

    @Test("A window bar alone counts as framing")
    func windowBarEnablesBackground() {
        #expect(!BackgroundConfiguration.none.isEnabled)
        #expect(BackgroundConfiguration(windowChrome: .light).isEnabled)
    }

    @Test("Editor clipping covers the bar as well as the capture")
    func editorFrameIncludesBar() {
        let document = AnnotationDocument(
            sourcePixelSize: CGSize(width: 400, height: 300),
            sourceScale: 1,
            background: BackgroundConfiguration(padding: 10, cornerRadius: 8, windowChrome: .light)
        )
        let geometry = AnnotationEditorGeometry(
            document: document,
            containerSize: CGSize(width: 2_000, height: 2_000)
        )

        #expect(geometry.frameViewRect.maxY == geometry.contentViewRect.maxY)
        #expect(geometry.frameViewRect.minX == geometry.contentViewRect.minX)
        #expect(abs(geometry.contentViewRect.minY - geometry.frameViewRect.minY - 28) < 0.001)
    }

    @Test("Projects saved before window bars existed still open")
    func legacyBackgroundDecodes() throws {
        let legacy = BackgroundConfiguration(fill: .solid(hex: "#123456"), padding: 30, cornerRadius: 9)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "windowChrome")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BackgroundConfiguration.self, from: data)
        #expect(decoded == legacy)
        #expect(decoded.windowChrome == nil)
    }

    @Test("Painted backdrops and window bars survive a save")
    func artworkRoundTrips() throws {
        for artwork in BackgroundArtwork.allCases {
            let original = BackgroundConfiguration(
                fill: .artwork(artwork),
                padding: 40,
                windowChrome: .dark
            )
            let decoded = try JSONDecoder().decode(
                BackgroundConfiguration.self,
                from: JSONEncoder().encode(original)
            )
            #expect(decoded == original)
        }
    }

    @Test("Every preset has its own identifier")
    func presetIdentifiersAreUnique() {
        let ids = BackgroundPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for artwork in BackgroundArtwork.allCases {
            #expect(BackgroundPreset.preset(id: artwork.rawValue)?.configuration.fill == .artwork(artwork))
        }
    }

    @Test("Painted backdrops are opaque and identical on every export")
    func artworkIsDeterministic() throws {
        let source = TestImage.solid(width: 120, height: 80, red: 255, green: 255, blue: 255)
        for artwork in BackgroundArtwork.allCases {
            let background = BackgroundConfiguration(fill: .artwork(artwork), padding: 24, windowChrome: .light)
            let first = try AnnotationRenderer.composeBackground(background, content: source, scale: 2)
            let second = try AnnotationRenderer.composeBackground(background, content: source, scale: 2)

            let firstBytes = try #require(first.dataProvider?.data) as Data
            let secondBytes = try #require(second.dataProvider?.data) as Data
            #expect(firstBytes == secondBytes, "\(artwork) changed between renders")

            // The corner pixel is pure backdrop; it must not be transparent.
            let alphaOffset = 3 // BGRA, premultiplied-first little-endian
            #expect(firstBytes[alphaOffset] == 255, "\(artwork) left the canvas transparent")
        }
    }
}
