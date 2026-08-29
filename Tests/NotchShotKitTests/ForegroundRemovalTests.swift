import Foundation
import Testing

@testable import NotchShotKit

@Suite("Foreground removal")
struct ForegroundRemovalTests {
    @Test("The derived file is always a clearly named PNG")
    func suggestedFilenameIsTransparentFormat() {
        #expect(
            ForegroundRemovalService.suggestedFilename(
                for: URL(fileURLWithPath: "/tmp/Product Shot.heic")
            ) == "Product Shot Subject.png"
        )
        #expect(
            ForegroundRemovalService.suggestedFilename(
                for: URL(fileURLWithPath: "/tmp/.png")
            ) == "png Subject.png"
        )
    }

    @Test("Background removal is offered only for images")
    func actionAvailabilityMatchesTheVisionInputContract() {
        let image = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100)
        )
        let recording = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/movie.mp4"),
            kind: .recording,
            pixelSize: CGSize(width: 100, height: 100)
        )

        #expect(ShareAction.removeBackground.isAvailable(for: image))
        #expect(!ShareAction.removeBackground.isAvailable(for: recording))
    }
}
