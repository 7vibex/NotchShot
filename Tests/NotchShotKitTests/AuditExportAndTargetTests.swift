import AppKit
import ImageIO
import Testing
@testable import NotchShotKit

@Suite("Audit export and window target regression")
struct AuditExportAndTargetTests {
    @Test("Window Snap keeps the external target when Productivity Center takes focus")
    @MainActor
    func windowSnapTarget() {
        #expect(WindowSnapService.targetProcessIdentifier(frontmost: 10, remembered: 20, own: 10) == 20)
        #expect(WindowSnapService.targetProcessIdentifier(frontmost: 30, remembered: 20, own: 10) == 30)
        #expect(WindowSnapService.targetProcessIdentifier(frontmost: 10, remembered: nil, own: 10) == nil)
        #expect(WindowSnapService.targetProcessIdentifier(frontmost: nil, remembered: 10, own: 10) == nil)
    }

    @Test("Standard 1x publishes matching pixels, point size, scale and file DPI")
    @MainActor
    func standardExportMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.png")
        let source = TestImage.solid(width: 200, height: 100)
        _ = try ImageExport.write(source, to: originalURL, format: .png, quality: 1, dpiScale: 2)
        let asset = CaptureAsset(url: originalURL, kind: .screenshot, pixelSize: CGSize(width: 200, height: 100), scale: 2)
        let session = try SmartExportSession(asset: asset)
        session.preset = .standard1x
        session.export(to: root.appendingPathComponent("standard.png"))
        let deadline = ContinuousClock.now + .seconds(10)
        while session.isExporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isExporting)
        #expect(session.errorMessage == nil)
        let result = try #require(session.exportedAsset)
        #expect(result.pixelSize == CGSize(width: 100, height: 50))
        #expect(result.scale == 1)
        #expect(result.pointSize == result.pixelSize)
        let imageSource = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue == 72)
    }

    @Test("Unresampled original exports retain their source scale")
    func originalExportScale() {
        #expect(SmartExportSession.outputScale(preset: .original, matchesSource: true, sourceScale: 1) == 1)
        #expect(SmartExportSession.outputScale(preset: .original, matchesSource: true, sourceScale: 2) == 2)
        #expect(SmartExportSession.outputScale(preset: .messages, matchesSource: false, sourceScale: 2) == 2)
    }
}
