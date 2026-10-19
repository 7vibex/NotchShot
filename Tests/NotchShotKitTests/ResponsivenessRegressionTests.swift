import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@MainActor
private final class MeetingFixture {
    var foreground: pid_t? = 9
    var clock: TimeInterval = 0
    var acceptsActivation = true
    var activatesImmediately = true
    var pending: pid_t?
    var posts: [pid_t] = []
    var postFocus: [pid_t?] = []
    var activationLog: [pid_t] = []
    var acceptsPost = true
    var afterPause: (() throws -> Void)?

    var hooks: MeetingShortcutDispatcher.Hooks {
        MeetingShortcutDispatcher.Hooks(
            frontmostPID: { self.foreground },
            isRunning: { [1, 2, 9].contains($0) },
            activate: { pid in
                self.activationLog.append(pid)
                guard self.acceptsActivation else { return false }
                if self.activatesImmediately || pid == 9 { self.foreground = pid }
                else { self.pending = pid }
                return true
            },
            post: { _, pid in
                guard self.acceptsPost else { return false }
                self.posts.append(pid)
                self.postFocus.append(self.foreground)
                return true
            },
            pause: { _ in
                self.clock += 0.02
                await Task.yield()
                try self.afterPause?()
            },
            now: { self.clock }
        )
    }
}

@Suite("Call shortcut routing", .serialized)
@MainActor
struct MeetingShortcutRegressionTests {
    private let combo = MeetingControls.KeyCombo.command(0)

    @Test("Failed and timed-out activation never posts keys")
    func activationFailure() async {
        let fixture = MeetingFixture()
        fixture.acceptsActivation = false
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1) == false)
        #expect(fixture.posts.isEmpty)
        fixture.acceptsActivation = true
        fixture.activatesImmediately = false
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1) == false)
        #expect(fixture.posts.isEmpty)
        #expect(fixture.foreground == 9)
    }

    @Test("Delayed activation waits for the target and restores prior focus")
    func delayedActivation() async {
        let fixture = MeetingFixture()
        fixture.activatesImmediately = false
        fixture.afterPause = {
            if fixture.clock >= 0.06, let pending = fixture.pending { fixture.foreground = pending }
        }
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1))
        #expect(fixture.posts == [1])
        #expect(fixture.postFocus == [1])
        #expect(fixture.foreground == 9)
    }

    @Test("Canceled activation and failed posting release focus without sending keys")
    func failedDeliveryRestoresFocus() async {
        let fixture = MeetingFixture()
        fixture.activatesImmediately = false
        fixture.afterPause = { fixture.foreground = 1; throw CancellationError() }
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1) == false)
        #expect(fixture.foreground == 9 && fixture.posts.isEmpty)
        fixture.afterPause = nil
        fixture.activatesImmediately = true
        fixture.acceptsPost = false
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1) == false)
        #expect(fixture.foreground == 9 && fixture.posts.isEmpty)
    }

    @Test("Delivery preserves a later user focus change")
    func userFocusWins() async {
        let fixture = MeetingFixture()
        fixture.afterPause = { fixture.foreground = 2 }
        #expect(await MeetingShortcutDispatcher(hooks: fixture.hooks).send(combo, to: 1))
        #expect(fixture.foreground == 2)
        #expect(fixture.activationLog == [1])
    }

    @Test("Concurrent requests serialize their entire focus handoff")
    func serialization() async {
        let fixture = MeetingFixture()
        let dispatcher = MeetingShortcutDispatcher(hooks: fixture.hooks)
        async let first = dispatcher.send(combo, to: 1)
        async let second = dispatcher.send(combo, to: 2)
        let results = await (first, second)
        #expect(results.0 && results.1)
        #expect(Set(fixture.posts) == Set([1, 2]))
        #expect(fixture.posts.map { Optional($0) } == fixture.postFocus)
        #expect(fixture.foreground == 9)
    }

    @Test("Cancellation before delivery does not activate or post")
    func cancelledRequest() async {
        let fixture = MeetingFixture()
        let dispatcher = MeetingShortcutDispatcher(hooks: fixture.hooks)
        let request = Task { await dispatcher.send(combo, to: 1) }
        request.cancel()
        #expect(await request.value == false)
        #expect(fixture.activationLog.isEmpty && fixture.posts.isEmpty)
    }
}

@Suite("Capture processing", .serialized)
@MainActor
struct CaptureProcessingRegressionTests {
    @Test("The worker preserves recipe pixels, scale, and source geometry")
    func fidelity() async throws {
        let image = CapturedImage(
            cgImage: TestImage.page(width: 128, height: 96, offset: 0), scale: 2,
            sourceRect: CGRect(x: 30, y: 45, width: 64, height: 48)
        )
        for recipe in [CaptureRecipe.all[0], CaptureRecipe.all[1], CaptureRecipe.all[4]] {
            let expected = try CaptureRecipeRenderer.render(image, recipe: recipe)
            let actual = try await CaptureRecipeRenderer.prepare(image, recipe: recipe, format: .png, quality: 1)
            #expect(actual.scale == image.scale && actual.sourceRect == image.sourceRect)
            #expect(actual.pixelSize == expected.pixelSize)
            #expect(try ImageExport.encode(actual.cgImage, format: .png, quality: 1, dpiScale: 2).data
                == ImageExport.encode(expected.cgImage, format: .png, quality: 1, dpiScale: 2).data)
        }
    }

    @Test("Byte-limited recipes retain their actual encoder budget")
    func byteLimit() async throws {
        let image = CapturedImage(cgImage: TestImage.page(width: 512, height: 256, offset: 0), scale: 2, sourceRect: .zero)
        var recipe = CaptureRecipe.all[0]
        recipe.targetMaximumBytes = 2_000
        let actual = try await CaptureRecipeRenderer.prepare(image, recipe: recipe, format: .png, quality: 1)
        #expect(try ImageExport.encode(actual.cgImage, format: .png, quality: 1, dpiScale: 2).data.count <= 2_000)
        #expect(actual.cgImage.width <= image.cgImage.width)
    }

    @Test("A canceled capture does not run queued bitmap work")
    func cancelled() async throws {
        let image = CapturedImage(cgImage: TestImage.solid(width: 16, height: 16), scale: 1, sourceRect: .zero)
        let request = Task { try await CaptureRecipeRenderer.prepare(image, recipe: CaptureRecipe.all[1], format: .png, quality: 1) }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
    }
}

@Suite("Smart export contracts", .serialized)
@MainActor
struct SmartExportRegressionTests {
    @Test("The real export worker uses preset quality")
    func presetQuality() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = TestImage.page(width: 256, height: 256, offset: 0)
        let captured = CapturedImage(cgImage: image, scale: 2, sourceRect: .zero)
        let asset = CaptureAsset(url: directory.appendingPathComponent("source.png"), kind: .screenshot, pixelSize: captured.pixelSize)
        for preset in [SmartExportPreset.messages, .email, .smallFile] {
            let plan = SmartExportService.plan(for: asset, image: image, preset: preset)
            let url = directory.appendingPathComponent("\(preset.rawValue).jpg")
            let result = SmartExportSession.renderAndWrite(source: captured, plan: plan, dpiScale: 2, to: url)
            if case .failure(let message) = result { Issue.record("Export failed: \(message)") }
            let expected = try ImageExport.encode(image, format: plan.format, quality: plan.quality, dpiScale: 2).data
            #expect(try Data(contentsOf: url) == expected)
        }
    }

    @Test("Original dimensions supports long scrolling images without another canvas")
    func longOriginal() throws {
        let image = TestImage.solid(width: 32, height: 18_000)
        let actual = try SmartExportService.render(image, to: CGSize(width: 32, height: 18_000))
        #expect(actual === image)
        #expect(actual.height == 18_000)
        #expect(throws: NotchShotError.self) { try SmartExportService.render(image, to: CGSize(width: 33, height: 18_000)) }
    }
}
