import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Capture recipes")
struct CaptureRecipeTests {
    @Test("Interactive recipes copy first and never open a save panel")
    func recipesAreClipboardFirst() {
        #expect(CaptureRecipe.all.allSatisfy { $0.destination == .clipboardOnly })
    }

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

@Suite("Capture preview routing")
@MainActor
struct CapturePreviewRoutingTests {
    @Test("Clicking an image shelf item opens its preview route")
    func imageRoutesToPreview() {
        let coordinator = AppCoordinator()
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/notchshot-preview.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 640, height: 480)
        )
        let item = ShelfItem(asset: asset, thumbnail: nil, image: nil)
        var openedID: UUID?
        coordinator.onOpenCapturePreview = { openedID = $0.id }

        coordinator.openPreview(for: item)

        #expect(openedID == item.id)
    }

    @Test("Non-image shelf items do not open the image preview")
    func recordingDoesNotRouteToImagePreview() {
        let coordinator = AppCoordinator()
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/notchshot-preview.mp4"),
            kind: .recording,
            pixelSize: .zero
        )
        let item = ShelfItem(asset: asset, thumbnail: nil, image: nil)
        var didOpen = false
        coordinator.onOpenCapturePreview = { _ in didOpen = true }

        coordinator.openPreview(for: item)

        #expect(!didOpen)
    }
}

@Suite("Privacy suggestions")
struct PrivacySuggestionTests {
    @Test("Privacy review does not claim sharing is ready before scanning finishes")
    func presentationTitleTracksReviewState() {
        #expect(PrivacyReviewPresentation.title(
            isReviewing: true,
            errorMessage: nil,
            findingCount: 0
        ) == "Checking Privacy")
        #expect(PrivacyReviewPresentation.title(
            isReviewing: false,
            errorMessage: "Vision failed",
            findingCount: 0
        ) == "Review Incomplete")
        #expect(PrivacyReviewPresentation.title(
            isReviewing: false,
            errorMessage: nil,
            findingCount: 0
        ) == "Share Ready")
        #expect(PrivacyReviewPresentation.title(
            isReviewing: false,
            errorMessage: nil,
            findingCount: 2
        ) == "Review Private Details")
    }

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

    @Test("Payment cards require a valid checksum and IP octets stay in range")
    func additionalSensitivePatternsAreValidated() {
        #expect(PrivacyReviewService.containsPaymentCard("Card 4242 4242 4242 4242"))
        #expect(!PrivacyReviewService.containsPaymentCard("Reference 1234 5678 9012 3456"))
        #expect(PrivacyReviewService.containsIPAddress("Server 192.168.1.42"))
        #expect(!PrivacyReviewService.containsIPAddress("Version 999.1.2.3"))
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

    /// The vectorised comparison walks sixteen bytes at a time and finishes the
    /// remainder one byte at a time. Sizes whose pixel count is not a multiple
    /// of four exercise that remainder, which is where a hand-written SIMD loop
    /// goes wrong.
    @Test("The vectorised difference matches a scalar reference at every threshold")
    func vectorisedDifferenceMatchesScalarReference() {
        func scalarReference(
            _ planes: ImageComparisonRenderer.DifferencePlanes,
            threshold: UInt8
        ) -> [UInt8] {
            var expected = [UInt8](repeating: 255, count: planes.bytesPerRow * planes.height)
            for offset in stride(from: 0, to: expected.count, by: 4) {
                for channel in 0 ..< 3 {
                    let delta = UInt8(
                        abs(Int(planes.left[offset + channel]) - Int(planes.right[offset + channel]))
                    )
                    expected[offset + channel] = delta >= threshold ? delta : 0
                }
            }
            return expected
        }

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextByte() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }

        // 3x3 and 5x7 both leave a partial 16-byte block; 8x4 divides evenly.
        for (width, height) in [(3, 3), (5, 7), (8, 4), (17, 2)] {
            let count = width * height * 4
            let planes = ImageComparisonRenderer.DifferencePlanes(
                left: (0 ..< count).map { _ in nextByte() },
                right: (0 ..< count).map { _ in nextByte() },
                width: width,
                height: height
            )
            for threshold in [UInt8(0), 1, 40, 128, 255] {
                let actual = ImageComparisonRenderer.absoluteDifference(
                    planes: planes,
                    threshold: threshold
                )
                #expect(
                    actual == scalarReference(planes, threshold: threshold),
                    "mismatch at \(width)x\(height) threshold \(threshold)"
                )
            }
        }
    }

    @Test("Alpha stays opaque so the difference is not silently transparent")
    func differenceKeepsAlphaOpaque() {
        let planes = ImageComparisonRenderer.DifferencePlanes(
            left: [UInt8](repeating: 10, count: 5 * 3 * 4),
            right: [UInt8](repeating: 200, count: 5 * 3 * 4),
            width: 5,
            height: 3
        )
        let output = ImageComparisonRenderer.absoluteDifference(planes: planes, threshold: 0)
        for offset in stride(from: 3, to: output.count, by: 4) {
            #expect(output[offset] == 255)
        }
    }

    @Test("Reusing decoded planes gives the same image as decoding each time")
    func cachedPlanesMatchFreshDecode() throws {
        let before = TestImage.solid(width: 24, height: 18, red: 30, green: 90, blue: 150)
        let after = TestImage.solid(width: 24, height: 18, red: 180, green: 20, blue: 40)
        let planes = try ImageComparisonRenderer.differencePlanes(before: before, after: after)

        for threshold in [UInt8(0), 60, 200] {
            let fromPlanes = try ImageComparisonRenderer.difference(
                planes: planes,
                threshold: threshold
            )
            let fromImages = try ImageComparisonRenderer.difference(
                before: before,
                after: after,
                threshold: threshold
            )
            let cached = TestImage.pixel(fromPlanes, x: 12, y: 9)
            let fresh = TestImage.pixel(fromImages, x: 12, y: 9)
            #expect(cached.r == fresh.r)
            #expect(cached.g == fresh.g)
            #expect(cached.b == fresh.b)
        }
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

@Suite("Finder shelf service")
@MainActor
struct FinderShelfServiceTests {
    @Test("Finder can park an arbitrary regular file without moving it")
    func stagesRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Project notes.txt")
        try Data("Local notes".utf8).write(to: source)

        let coordinator = AppCoordinator()
        coordinator.acceptFilesFromFinderService([source])

        let item = try #require(coordinator.shelfItems.first)
        #expect(item.asset.url == source)
        #expect(item.asset.kind == .document)
        #expect(item.asset.ownership == .externalReference)
        #expect(item.asset.dimensionsDescription == "Document")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(coordinator.activity == .result)
    }

    @Test("The bundle advertises the file shelf service")
    func serviceDeclaration() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Resources/Info.plist"))
        let root = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let services = try #require(root["NSServices"] as? [[String: Any]])
        let service = try #require(services.first)
        #expect(service["NSMessage"] as? String == "addFilesToShelf")
        #expect(service["NSSendFileTypes"] as? [String] == ["public.data"])
        #expect(service["NSSendTypes"] as? [String] == ["public.file-url"])
    }
}

@Suite("Recording presentation")
struct RecordingPresentationTests {
    @Test("Keystroke overlay reveals shortcuts but never ordinary typing")
    func keystrokePrivacy() throws {
        let plain = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        let shortcut = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(RecordingPresentationOverlayController.safeDescription(for: plain) == nil)
        #expect(RecordingPresentationOverlayController.safeDescription(for: shortcut) == "⌘P")
    }

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
