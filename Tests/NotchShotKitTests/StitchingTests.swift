import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

private final class LockedValues<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct SendableFrames: @unchecked Sendable {
    let values: [CGImage]
}

@MainActor
private final class ControlledFrameProvider {
    private var continuation: CheckedContinuation<CGImage, any Error>?

    var isWaiting: Bool { continuation != nil }

    func capture() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilWaiting() async -> Bool {
        for _ in 0 ..< 2_000 {
            if isWaiting { return true }
            await Task.yield()
        }
        return isWaiting
    }

    func resume(returning image: CGImage) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: image)
    }
}

/// Scrolling capture is the feature most likely to produce a silently wrong
/// result, so the matcher is tested against synthetic frames where the correct
/// answer is known exactly.
@Suite("Scrolling stitcher")
struct StitchingTests {

    /// Builds frames as windows onto one tall "page", advancing by `step` rows.
    private func frames(
        count: Int,
        width: Int = 80,
        height: Int = 240,
        step: Int,
        stickyTop: Int = 0,
        stickyBottom: Int = 0
    ) -> [CGImage] {
        (0 ..< count).map { index in
            let offset = index * step
            let page = TestImage.page(width: width, height: height, offset: offset)
            guard stickyTop > 0 || stickyBottom > 0 else { return page }
            return TestImage.make(width: width, height: height) { context in
                context.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height))
                // A fixed header/footer identical in every frame.
                context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
                if stickyTop > 0 {
                    context.fill(CGRect(x: 0, y: height - stickyTop, width: width, height: stickyTop))
                }
                if stickyBottom > 0 {
                    context.fill(CGRect(x: 0, y: 0, width: width, height: stickyBottom))
                }
            }
        }
    }

    @Test("A single frame passes through untouched")
    func singleFrame() throws {
        let frame = TestImage.page(width: 40, height: 60, offset: 0)
        let output = try ScrollingStitcher.stitch(frames: [frame])
        #expect(output.image.width == 40)
        #expect(output.image.height == 60)
        #expect(output.seams.isEmpty)
    }

    @Test("Frames scrolled by a known amount produce the expected height")
    func knownScrollAmount() throws {
        let step = 40
        let height = 240
        let output = try ScrollingStitcher.stitch(frames: frames(count: 4, height: height, step: step))

        // First frame in full, then `step` new rows per subsequent frame.
        let expected = height + step * 3
        #expect(output.seams.count == 3)
        // Allow a pixel of slack: matching is integral but the template can
        // land one row either side on low-contrast content.
        #expect(abs(output.image.height - expected) <= 3)
    }

    @Test("Seams from clean frames report high confidence")
    func confidence() throws {
        let output = try ScrollingStitcher.stitch(frames: frames(count: 3, step: 50))
        for seam in output.seams {
            #expect(seam.confidence > StitchSettings.warningConfidence)
            #expect(!seam.isSuspect)
        }
    }

    @Test("A duplicate frame is dropped instead of doubling content")
    func duplicateFrameDropped() throws {
        var list = frames(count: 3, step: 45)
        list.insert(list[1], at: 2) // exact repeat
        let output = try ScrollingStitcher.stitch(frames: list)
        #expect(output.droppedFrameIndices.count >= 1)
        #expect(output.warnings.contains { $0.contains("didn't overlap") })
    }

    @Test("Frames with no overlap at all fail loudly")
    func noOverlapFails() {
        let a = TestImage.solid(width: 60, height: 200, red: 255)
        let b = TestImage.solid(width: 60, height: 200, blue: 255)
        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: [a, b])
        }
    }

    @Test("Mismatched frame widths are rejected")
    func mismatchedWidths() {
        let a = TestImage.page(width: 60, height: 120, offset: 0)
        let b = TestImage.page(width: 80, height: 120, offset: 20)
        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: [a, b])
        }
    }

    @Test("An empty frame list fails rather than returning an empty image")
    func noFrames() {
        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: [])
        }
    }

    @Test("A sticky header is detected and excluded from matching")
    func stickyHeaderDetected() throws {
        let list = frames(count: 3, height: 240, step: 40, stickyTop: 30)
        let buffers = list.compactMap { GrayBuffer(image: $0, columnStride: 4) }
        let sticky = ScrollingStitcher.detectStickyBands(buffers: buffers)
        #expect(sticky.top >= 25)

        let output = try ScrollingStitcher.stitch(frames: list)
        #expect(output.warnings.contains { $0.contains("fixed header") })
        #expect(output.seams.count == 2)
    }

    @Test("A sticky footer isn't repeated down the composite")
    func stickyFooterExcluded() throws {
        let list = frames(count: 3, height: 240, step: 40, stickyBottom: 24)
        let output = try ScrollingStitcher.stitch(frames: list)
        #expect(output.warnings.contains { $0.contains("fixed footer") })
        // Each frame contributes only its new rows, not the repeated footer.
        #expect(output.image.height < 240 + 2 * (40 + 24))
    }

    @Test("A frame that never scrolled contributes nothing")
    func zeroScrollRejected() {
        let frame = TestImage.page(width: 60, height: 200, offset: 0)
        let buffer = GrayBuffer(image: frame, columnStride: 4)!
        let match = ScrollingStitcher.bestMatch(
            previous: buffer,
            next: buffer,
            sticky: ScrollingStitcher.StickyBands(top: 0, bottom: 0),
            settings: StitchSettings()
        )
        // Identical frames match at the template's own position, leaving zero
        // new rows, which the caller treats as a duplicate.
        #expect(match == nil || match!.addedRows < StitchSettings().minimumAdvance)
    }

    @Test("Progress is monotonic and reaches completion")
    func progressReporting() throws {
        let observed = LockedValues<Double>()
        _ = try ScrollingStitcher.stitch(frames: frames(count: 4, step: 40)) { progress in
            observed.append(progress)
        }

        let values = observed.snapshot()
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.contains { $0 > 0 && $0 < 1 })
        #expect(zip(values, values.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
    }

    @Test("Frame dimensions are bounded before pixel conversion")
    func frameDimensionBudget() {
        var limits = StitchLimits()
        limits.maximumFrameDimension = 50
        let oversized = TestImage.page(width: 60, height: 40, offset: 0)

        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: [oversized], limits: limits)
        }
    }

    @Test("Aggregate decoded frame bytes are bounded")
    func decodedInputByteBudget() {
        var limits = StitchLimits()
        limits.maximumInputBytes = 2_000
        let list = frames(count: 2, width: 20, height: 20, step: 5)

        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: list, limits: limits)
        }
    }

    @Test("Composite growth is rejected before allocation")
    func compositePixelBudget() {
        var limits = StitchLimits()
        limits.maximumCompositePixels = 20_000
        let list = frames(count: 3, width: 80, height: 240, step: 40)

        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: list, limits: limits)
        }
    }

    @Test("Direct stitch callers cannot bypass the frame-count cap")
    func directFrameCountBudget() {
        var limits = StitchLimits()
        limits.maximumFrames = 2

        #expect(throws: NotchShotError.self) {
            _ = try ScrollingStitcher.stitch(frames: frames(count: 3, step: 40), limits: limits)
        }
    }

    @Test("Stitching cooperatively reports task cancellation")
    func cancellation() async {
        let list = SendableFrames(values: frames(count: 3, step: 40))
        let task = Task.detached {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try ScrollingStitcher.stitch(frames: list.values)
        }

        do {
            _ = try await task.value
            Issue.record("Expected stitching to throw CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Finish includes a capture already in flight and emits one terminal event")
    @MainActor
    func finishIncludesInFlightFrame() async {
        let list = frames(count: 2, step: 40)
        let provider = ControlledFrameProvider()
        var events: [ScrollingCaptureSession.Event] = []
        let session = ScrollingCaptureSession(
            region: CGRect(x: 0, y: 0, width: 80, height: 240),
            onEvent: { events.append($0) },
            limits: StitchLimits(),
            frameProvider: { try await provider.capture() }
        )

        let startTask = Task { await session.start() }
        #expect(await provider.waitUntilWaiting())
        provider.resume(returning: list[0])
        await startTask.value

        let captureTask = Task { await session.captureFrameManually() }
        #expect(await provider.waitUntilWaiting())
        let finishTask = Task { await session.finish() }
        while session.isRunning {
            await Task.yield()
        }
        provider.resume(returning: list[1])
        await captureTask.value
        await finishTask.value

        #expect(session.frames.count == 2)
        #expect(events.contains { event in
            if case .frameCaptured(count: 2) = event { return true }
            return false
        })
        #expect(terminalCount(in: events) == 1)
        #expect(events.contains { event in
            if case .finished = event { return true }
            return false
        })
    }

    @Test("Cancel suppresses a late in-flight frame and stale terminal results")
    @MainActor
    func cancelSuppressesInFlightResult() async {
        let list = frames(count: 2, step: 40)
        let provider = ControlledFrameProvider()
        var events: [ScrollingCaptureSession.Event] = []
        let session = ScrollingCaptureSession(
            region: CGRect(x: 0, y: 0, width: 80, height: 240),
            onEvent: { events.append($0) },
            limits: StitchLimits(),
            frameProvider: { try await provider.capture() }
        )

        let startTask = Task { await session.start() }
        #expect(await provider.waitUntilWaiting())
        provider.resume(returning: list[0])
        await startTask.value

        let captureTask = Task { await session.captureFrameManually() }
        #expect(await provider.waitUntilWaiting())
        session.cancel()
        provider.resume(returning: list[1])
        await captureTask.value
        await Task.yield()

        #expect(session.frames.isEmpty)
        #expect(terminalCount(in: events) == 1)
        #expect(events.contains { event in
            if case .cancelled = event { return true }
            return false
        })
        #expect(!events.contains { event in
            if case .frameCaptured(count: 2) = event { return true }
            return false
        })
    }

    private func terminalCount(in events: [ScrollingCaptureSession.Event]) -> Int {
        events.reduce(into: 0) { count, event in
            switch event {
            case .finished, .failedButFramesKept, .cancelled:
                count += 1
            case .frameCaptured, .stitching:
                break
            }
        }
    }

    @Test("The session caps how many frames a capture can accumulate")
    @MainActor
    func frameCap() {
        #expect(ScrollingCaptureSession.maximumFrames == 120)
    }
}

@Suite("Grayscale buffer")
struct GrayBufferTests {

    @Test("Row 0 is the top of the image, matching the scroll maths")
    func rowOrientation() {
        // Top half white, bottom half black.
        let image = TestImage.make(width: 8, height: 8) { context in
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        }
        let buffer = GrayBuffer(image: image, columnStride: 1)!
        #expect(buffer.pixels[0] > 200)                       // top row is white
        #expect(buffer.pixels[7 * buffer.width] < 55)         // bottom row is black
    }

    @Test("Identical rows compare equal within tolerance")
    func rowMatching() {
        let image = TestImage.solid(width: 16, height: 4, red: 120, green: 120, blue: 120)
        let a = GrayBuffer(image: image, columnStride: 1)!
        let b = GrayBuffer(image: image, columnStride: 1)!
        #expect(a.rowsMatch(b, row: 0, tolerance: 2))
    }

    @Test("Different rows do not compare equal")
    func rowMismatch() {
        let a = GrayBuffer(image: TestImage.solid(width: 16, height: 4, red: 10), columnStride: 1)!
        let b = GrayBuffer(image: TestImage.solid(width: 16, height: 4, red: 240, green: 240, blue: 240), columnStride: 1)!
        #expect(!a.rowsMatch(b, row: 0, tolerance: 3))
    }

    @Test("An out-of-range band scores as no match rather than crashing")
    func outOfRangeMatch() {
        let buffer = GrayBuffer(image: TestImage.solid(width: 8, height: 8), columnStride: 1)!
        let score = buffer.meanAbsoluteDifference(
            templateTop: 6,
            templateHeight: 10,
            against: buffer,
            at: 0,
            earlyExit: .greatestFiniteMagnitude
        )
        #expect(score == .greatestFiniteMagnitude)
    }
}
