import Foundation
import Testing
@testable import NotchShotKit

@Suite("Capture recipes")
struct CaptureRecipeTests {
    @Test("Every named workflow has a unique recipe")
    func namedRecipes() {
        let ids = Set(CaptureRecipe.all.map(\.id))
        #expect(ids.count == CaptureRecipe.all.count)
        #expect(ids.isSuperset(of: [
            "github-issue", "app-store", "documentation", "social-post", "bug-report",
        ]))
    }

    @Test("The App Store recipe produces the declared Mac screenshot size")
    func appStoreSize() throws {
        let recipe = try #require(CaptureRecipe.all.first { $0.id == "app-store" })
        let input = CapturedImage(
            cgImage: TestImage.solid(width: 320, height: 180, blue: 190),
            scale: 1,
            sourceRect: CGRect(x: 0, y: 0, width: 320, height: 180)
        )

        let output = try CaptureRecipeRenderer.render(input, recipe: recipe)
        #expect(output.cgImage.width == 2_880)
        #expect(output.cgImage.height == 1_800)
    }
}

@Suite("Privacy suggestions")
struct PrivacySuggestionTests {
    @Test("Known token formats are suggested without storing the value")
    func tokenDetection() {
        #expect(PrivacyReviewService.containsAccessToken("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"))
        #expect(PrivacyReviewService.containsAccessToken("ghp_123456789012345678901234567890"))
        #expect(!PrivacyReviewService.containsAccessToken("Use a bearer token here"))
    }

    @Test("Explicit account identifiers are detected conservatively")
    func accountDetection() {
        #expect(PrivacyReviewService.containsAccountIdentifier("Account ID: USER_84920"))
        #expect(PrivacyReviewService.containsAccountIdentifier("@example_account"))
        #expect(!PrivacyReviewService.containsAccountIdentifier("Account settings"))
    }
}

@Suite("Visual comparison")
struct VisualComparisonTests {
    @Test("Different image sizes are normalized to the before image")
    func normalizedSize() throws {
        let before = TestImage.solid(width: 120, height: 80, red: 200)
        let after = TestImage.solid(width: 60, height: 120, green: 200)
        let pair = try ImageComparisonRenderer.normalizedPair(before: before, after: after)
        #expect(pair.0.width == 120)
        #expect(pair.0.height == 80)
        #expect(pair.1.width == 120)
        #expect(pair.1.height == 80)
    }

    @Test("Identical images produce a black difference overlay")
    func identicalDifference() throws {
        let source = TestImage.solid(width: 40, height: 30, red: 50, green: 120, blue: 220)
        let difference = try ImageComparisonRenderer.difference(before: source, after: source)
        let pixel = TestImage.pixel(difference, x: 20, y: 15)
        #expect(pixel.r < 3)
        #expect(pixel.g < 3)
        #expect(pixel.b < 3)
    }
}

@Suite("Bug report privacy")
@MainActor
struct BugReportPackageTests {
    @Test("Default package includes the capture but no silent diagnostics")
    func defaultPackage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("capture.png")
        let encoded = try ImageExport.encode(
            TestImage.solid(width: 32, height: 24, green: 180),
            format: .png,
            quality: 1,
            dpiScale: 1
        )
        try encoded.data.write(to: captureURL)

        let asset = CaptureAsset(
            url: captureURL,
            kind: .screenshot,
            pixelSize: CGSize(width: 32, height: 24),
            sourceApplication: "com.example.private",
            sourceApplicationName: "Private App"
        )
        let packageURL = directory.appendingPathComponent("report.notchbug", isDirectory: true)
        try BugReportPackager.write(asset: asset, options: BugReportOptions(), to: packageURL)

        let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("Manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BugReportManifest.self, from: manifestData)
        #expect(manifest.sourceApplicationName == nil)
        #expect(manifest.sourceApplicationBundleID == nil)
        #expect(manifest.operatingSystem == nil)
        #expect(manifest.displays == nil)
        #expect(manifest.captureKind == nil)
        #expect(!manifest.includesEditableProject)

        let report = try String(contentsOf: packageURL.appendingPathComponent("Report.md"), encoding: .utf8)
        #expect(report.contains("No logs, device serial numbers, account data, or unrelated files"))
        #expect(!report.contains("Private App"))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("Capture.png").path))
    }
}

@Suite("Recording captions")
struct CaptionTests {
    @Test("Caption cues serialize as standard SRT timestamps")
    func srtFormatting() {
        let transcript = RecordingTranscript(
            text: "First Second",
            cues: [
                CaptionCue(start: 0.25, duration: 1.5, text: "First"),
                CaptionCue(start: 3_661.004, duration: 2, text: "Second"),
            ]
        )
        #expect(transcript.srt.contains("00:00:00,250 --> 00:00:01,750"))
        #expect(transcript.srt.contains("01:01:01,004 --> 01:01:03,004"))
    }
}

@Suite("Recording presentation")
struct RecordingPresentationTests {
    @Test("Background framing keeps content inside the selected output size")
    func backgroundFrame() {
        let configuration = RecordingConfiguration(
            target: .display(1),
            framesWithBackground: true
        )
        let output = CGSize(width: 1_920, height: 1_080)
        let rect = configuration.destinationRect(
            for: CGSize(width: 1_600, height: 1_000),
            outputPixelSize: output
        )
        #expect(rect.minX > 0)
        #expect(rect.minY > 0)
        #expect(rect.maxX < output.width)
        #expect(rect.maxY < output.height)
        #expect(abs(rect.width / rect.height - 1.6) < 0.01)
    }

    @Test("Background framing is a no-op until explicitly enabled")
    func backgroundFrameOff() {
        let configuration = RecordingConfiguration(target: .display(1))
        let output = CGSize(width: 1_920, height: 1_080)
        #expect(configuration.destinationRect(
            for: CGSize(width: 1_600, height: 1_000),
            outputPixelSize: output
        ) == CGRect(origin: .zero, size: output))
    }
}
