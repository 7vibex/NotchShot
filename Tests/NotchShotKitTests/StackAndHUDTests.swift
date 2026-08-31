import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Capture stack layout")
struct StackLayoutTests {

    private let uniform = [
        CGSize(width: 800, height: 600),
        CGSize(width: 800, height: 600),
        CGSize(width: 800, height: 600),
    ]

    @Test("A long image stacks captures top to bottom")
    func longImage() {
        let options = StackExportOptions(style: .longImage, spacing: 20, margin: 30)
        let (canvas, frames) = StackRenderer.layout(sizes: uniform, options: options)

        #expect(canvas.width == CGFloat(860))
        #expect(canvas.height == CGFloat(1900))
        #expect(frames.count == 3)
        // Each capture sits below the previous one, all at the same x.
        #expect(frames[0].minY < frames[1].minY)
        #expect(frames[1].minY < frames[2].minY)
        #expect(Set(frames.map(\.minX)) == [30])
    }

    @Test("Mixed widths are normalised to a common width")
    func normalisesWidth() {
        let sizes = [CGSize(width: 400, height: 300), CGSize(width: 800, height: 400)]
        let (_, frames) = StackRenderer.layout(
            sizes: sizes,
            options: StackExportOptions(style: .longImage, spacing: 0, margin: 0)
        )
        #expect(frames[0].width == 800)
        #expect(frames[1].width == 800)
        // Aspect ratio is preserved while scaling up.
        #expect(frames[0].height == 600)
    }

    @Test("A filmstrip lays captures out side by side")
    func filmstrip() {
        let options = StackExportOptions(style: .filmstrip, spacing: 10, margin: 20)
        let (canvas, frames) = StackRenderer.layout(sizes: uniform, options: options)

        #expect(canvas.height == CGFloat(640))
        #expect(canvas.width == CGFloat(2460))
        #expect(frames[0].minX < frames[1].minX)
        #expect(Set(frames.map(\.minY)) == [20])
    }

    @Test("A storyboard forms a roughly square grid")
    func storyboard() {
        let sizes = Array(repeating: CGSize(width: 100, height: 100), count: 4)
        let (_, frames) = StackRenderer.layout(
            sizes: sizes,
            options: StackExportOptions(style: .storyboard, spacing: 10, margin: 10)
        )
        #expect(frames.count == 4)
        // 2×2: two distinct rows and two distinct columns.
        #expect(Set(frames.map(\.minY)).count == 2)
        #expect(Set(frames.map(\.minX)).count == 2)
    }

    @Test("Storyboard cells aspect-fit, so mixed shapes aren't distorted")
    func storyboardAspectFit() {
        let sizes = [CGSize(width: 200, height: 100), CGSize(width: 100, height: 200)]
        let (_, frames) = StackRenderer.layout(
            sizes: sizes,
            options: StackExportOptions(style: .storyboard, spacing: 0, margin: 0)
        )
        for (frame, size) in zip(frames, sizes) {
            let originalRatio = size.width / size.height
            let framedRatio = frame.width / frame.height
            #expect(abs(originalRatio - framedRatio) < 0.001)
        }
    }

    @Test("A single capture still produces a valid sheet")
    func singleItem() {
        let (canvas, frames) = StackRenderer.layout(
            sizes: [CGSize(width: 500, height: 400)],
            options: StackExportOptions(style: .longImage, spacing: 24, margin: 20)
        )
        #expect(frames.count == 1)
        // Spacing must not be added after the last item.
        #expect(canvas.height == CGFloat(440))
    }

    @Test("An empty stack lays out to nothing rather than crashing")
    func emptyStack() {
        let (canvas, frames) = StackRenderer.layout(sizes: [], options: StackExportOptions())
        #expect(canvas == .zero)
        #expect(frames.isEmpty)
    }

    @Test("Every frame stays inside the canvas")
    func framesFitCanvas() {
        let sizes = [
            CGSize(width: 1200, height: 800),
            CGSize(width: 640, height: 480),
            CGSize(width: 300, height: 900),
            CGSize(width: 1000, height: 200),
        ]
        for style in StackExportStyle.allCases {
            let options = StackExportOptions(style: style, spacing: 16, margin: 24)
            let (canvas, frames) = StackRenderer.layout(sizes: sizes, options: options)
            for frame in frames {
                #expect(frame.minX >= -0.001)
                #expect(frame.minY >= -0.001)
                #expect(frame.maxX <= canvas.width + 0.001)
                #expect(frame.maxY <= canvas.height + 0.001)
            }
        }
    }

    @Test("Rendering a stack produces a sheet of the laid-out size")
    func renderProducesSheet() throws {
        let images = [
            TestImage.solid(width: 60, height: 40, red: 255),
            TestImage.solid(width: 60, height: 40, green: 255),
        ]
        let options = StackExportOptions(style: .longImage, spacing: 10, margin: 10)
        let sheet = try StackRenderer.render(images: images, options: options)
        let (canvas, _) = StackRenderer.layout(
            sizes: images.map { CGSize(width: $0.width, height: $0.height) },
            options: options
        )
        #expect(sheet.width == Int(canvas.width))
        #expect(sheet.height == Int(canvas.height))
    }

    @Test("A stack canvas beyond the allocation budget is rejected")
    func oversizedCanvasRejected() {
        #expect(throws: NotchShotError.self) {
            try StackRenderer.render(
                images: [TestImage.solid(width: 1, height: 1)],
                options: StackExportOptions(style: .longImage, spacing: 0, margin: 50_000)
            )
        }
    }

    @Test("Public render rejects empty and non-finite input without trapping")
    func invalidRenderInputRejected() {
        #expect(throws: NotchShotError.self) {
            try StackRenderer.render(images: [], options: StackExportOptions())
        }
        #expect(throws: NotchShotError.self) {
            try StackRenderer.render(
                images: [TestImage.solid(width: 1, height: 1)],
                options: StackExportOptions(spacing: .nan, margin: .infinity)
            )
        }
    }

    @Test("The first capture is drawn at the top of a long image")
    func drawOrder() throws {
        let images = [
            TestImage.solid(width: 40, height: 40, red: 255),
            TestImage.solid(width: 40, height: 40, blue: 255),
        ]
        let sheet = try StackRenderer.render(
            images: images,
            options: StackExportOptions(style: .longImage, spacing: 0, margin: 0)
        )
        // Top-left region is the first (red) image, bottom is the second (blue).
        let top = TestImage.pixel(sheet, x: 20, y: 10)
        let bottom = TestImage.pixel(sheet, x: 20, y: 70)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
    }

    @Test("A PDF is written with one page per capture")
    func pdfExport() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let images = (0 ..< 3).map { _ in TestImage.solid(width: 100, height: 80, green: 180) }
        let url = directory.appendingPathComponent("stack.pdf")
        try StackRenderer.writePDF(images: images, options: StackExportOptions(style: .pdf), to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let document = try #require(CGPDFDocument(url as CFURL))
        #expect(document.numberOfPages == 3)
    }

    @Test("A rejected PDF export preserves an existing destination")
    func rejectedPDFPreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.pdf")
        let original = Data("original document".utf8)
        try original.write(to: url)

        #expect(throws: NotchShotError.self) {
            try StackRenderer.writePDF(
                images: [TestImage.solid(width: 10, height: 10)],
                options: StackExportOptions(style: .pdf, spacing: 0, margin: .nan),
                to: url
            )
        }
        #expect(try Data(contentsOf: url) == original)
    }
}

@Suite("Capture stack behaviour")
@MainActor
struct CaptureStackTests {

    private func asset(_ name: String) -> CaptureAsset {
        CaptureAsset(
            url: URL(fileURLWithPath: "/tmp/\(name).png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100)
        )
    }

    @Test("Items keep the order they were added")
    func ordering() {
        let stack = CaptureStack()
        stack.add(asset("a"))
        stack.add(asset("b"))
        stack.add(asset("c"))
        #expect(stack.items.map { $0.asset.url.lastPathComponent } == ["a.png", "b.png", "c.png"])
    }

    @Test("An item can be moved earlier or later")
    func reordering() {
        let stack = CaptureStack()
        stack.add(asset("a"))
        stack.add(asset("b"))
        let second = stack.items[1].id

        stack.moveItem(id: second, by: -1)
        #expect(stack.items.map { $0.asset.url.lastPathComponent } == ["b.png", "a.png"])

        stack.moveItem(id: second, by: 1)
        #expect(stack.items.map { $0.asset.url.lastPathComponent } == ["a.png", "b.png"])
    }

    @Test("Moving past either end is a no-op, not a crash")
    func reorderingBounds() {
        let stack = CaptureStack()
        stack.add(asset("a"))
        stack.add(asset("b"))
        let first = stack.items[0].id
        stack.moveItem(id: first, by: -1)
        #expect(stack.items.map { $0.asset.url.lastPathComponent } == ["a.png", "b.png"])
    }

    @Test("The stack refuses to grow past its cap")
    func capacity() {
        let stack = CaptureStack()
        for index in 0 ..< (CaptureStack.maximumItems + 5) {
            stack.add(asset("shot\(index)"))
        }
        #expect(stack.count == CaptureStack.maximumItems)
    }

    @Test("Clearing empties the stack and stops collecting")
    func clearing() {
        let stack = CaptureStack()
        stack.isCollecting = true
        stack.add(asset("a"))
        stack.clear()
        #expect(stack.isEmpty)
        #expect(!stack.isCollecting)
    }

    @Test("Export fails instead of silently omitting an unreadable item")
    func unreadableItemFailsExport() {
        let stack = CaptureStack()
        stack.add(asset("missing-stack-item-\(UUID().uuidString)"))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-stack-output-\(UUID().uuidString).png")
        #expect(throws: NotchShotError.self) {
            try stack.export(to: output, options: StackExportOptions())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Saved capture sessions round-trip through an injected store")
    func savedSessionsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-stack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("sessions.json")
        let stack = CaptureStack(sessionsURL: store)
        stack.add(asset("saved"))

        let session = try #require(try stack.saveSession(named: "Release flow"))
        let reloaded = CaptureStack(sessionsURL: store)
        #expect(reloaded.savedSessions == [session])
        #expect(stack.lastPersistenceError == nil)
    }

    @Test("A failed session save leaves observable state unchanged")
    func failedSessionSaveDoesNotLie() {
        let stack = CaptureStack(
            sessionsURL: URL(fileURLWithPath: "/dev/null/CaptureSessions.json")
        )
        stack.add(asset("unsaved"))

        #expect(throws: (any Error).self) {
            _ = try stack.saveSession(named: "Cannot persist")
        }
        #expect(stack.savedSessions.isEmpty)
        #expect(stack.lastPersistenceError != nil)
    }

    @Test("A failed session delete preserves the durable row")
    func failedSessionDeleteKeepsRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-stack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("sessions.json")
        let stack = CaptureStack(sessionsURL: store)
        stack.add(asset("saved"))
        let session = try #require(try stack.saveSession(named: "Keep me"))

        try FileManager.default.removeItem(at: store)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try stack.deleteSession(id: session.id)
        }
        #expect(stack.savedSessions == [session])
        #expect(stack.lastPersistenceError != nil)
    }
}

@Suite("Comparison memory budget")
struct ComparisonMemoryBudgetTests {
    @Test("Comparison pixel limits reject multi-buffer memory spikes")
    func limits() {
        #expect(ImageComparisonRenderer.isWithinOperationBudget(width: 5_000, height: 5_000))
        #expect(!ImageComparisonRenderer.isWithinOperationBudget(width: 5_001, height: 5_000))
        #expect(!ImageComparisonRenderer.isWithinOperationBudget(width: 0, height: 5_000))
    }
}

@Suite("System level HUD")
struct SystemLevelTests {

    @Test("System media keys map to narrow replacement actions")
    func mediaKeyMapping() {
        #expect(SystemMediaKeyAction.action(
            keyType: Int(NX_KEYTYPE_SOUND_UP),
            modifierFlags: []
        ) == .volumeUp(fine: false))
        #expect(SystemMediaKeyAction.action(
            keyType: Int(NX_KEYTYPE_BRIGHTNESS_DOWN),
            modifierFlags: [.shift, .option]
        ) == .brightnessDown(fine: true))
        #expect(SystemMediaKeyAction.action(keyType: 999, modifierFlags: []) == nil)
    }

    @Test("System media-key levels use standard and fine increments with clamping")
    func mediaKeySteps() {
        #expect(SystemMediaKeyAction.adjustedLevel(
            current: 0.5,
            increasing: true,
            fine: false
        ) == 0.5625)
        #expect(SystemMediaKeyAction.adjustedLevel(
            current: 0.5,
            increasing: false,
            fine: true
        ) == 0.484375)
        #expect(SystemMediaKeyAction.adjustedLevel(
            current: 0.99,
            increasing: true,
            fine: false
        ) == 1)
    }

    @Test("The volume symbol reflects how loud it is")
    func volumeSymbols() {
        #expect(SystemLevelKind.volume.symbolName(for: 0.0, isMuted: false) == "speaker.slash.fill")
        #expect(SystemLevelKind.volume.symbolName(for: 0.2, isMuted: false) == "speaker.wave.1.fill")
        #expect(SystemLevelKind.volume.symbolName(for: 0.5, isMuted: false) == "speaker.wave.2.fill")
        #expect(SystemLevelKind.volume.symbolName(for: 0.9, isMuted: false) == "speaker.wave.3.fill")
    }

    @Test("Muting overrides the level entirely")
    func mutedSymbol() {
        #expect(SystemLevelKind.volume.symbolName(for: 1.0, isMuted: true) == "speaker.slash.fill")
    }

    @Test("Brightness has a dim and a bright symbol")
    func brightnessSymbols() {
        #expect(SystemLevelKind.brightness.symbolName(for: 0.2, isMuted: false) == "sun.min.fill")
        #expect(SystemLevelKind.brightness.symbolName(for: 0.8, isMuted: false) == "sun.max.fill")
    }

    @Test("A level change shows above media but below a deliberate expansion")
    func priority() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.systemLevel = SystemLevel(kind: .volume, value: 0.5, isMuted: false)
        #expect(arbiter.resolve() == .systemLevel(SystemLevel(kind: .volume, value: 0.5, isMuted: false)))

        arbiter.userExpanded = true
        #expect(arbiter.resolve() == .expanded)
    }

    @Test("A level change never interrupts a capture or a recording")
    func neverInterruptsCapture() {
        var arbiter = ActivityArbiter()
        arbiter.systemLevel = SystemLevel(kind: .brightness, value: 0.3, isMuted: false)

        arbiter.isRecording = true
        #expect(arbiter.resolve() == .recording)

        arbiter.isRecording = false
        arbiter.hasResult = true
        #expect(arbiter.resolve() == .result)

        arbiter.hasResult = false
        arbiter.selection = .area
        #expect(arbiter.resolve() == .selecting(.area))
    }

    @Test("The HUD island stays within the panel bounds")
    func layoutFits() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let layout = NotchLayout.layout(
            for: .systemLevel(SystemLevel(kind: .volume, value: 0.5, isMuted: false)),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.size.width <= NotchLayout.maximumSize.width)
        #expect(layout.size.height <= NotchLayout.maximumSize.height)
        // Wider than the cutout, so the change is actually visible.
        #expect(layout.size.width > metrics.notchSize.width)
        // Feedback uses only the two wings beside the camera. It must not
        // create a separate rounded bubble below the physical notch.
        #expect(layout.size.height == metrics.notchSize.height)
        #expect(layout.contentTopInset == 0)
    }

    @Test("A stacked shelf is taller than a plain one, and both still fit")
    func shelfWithStack() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let plain = NotchLayout.layout(
            for: .result, metrics: metrics, isPeeking: false, resultCount: 5, hasStack: false
        )
        let stacked = NotchLayout.layout(
            for: .result, metrics: metrics, isPeeking: false, resultCount: 5, hasStack: true
        )
        #expect(stacked.size.height > plain.size.height)
        #expect(stacked.size.height <= NotchLayout.maximumSize.height)
        #expect(stacked.size.width <= NotchLayout.maximumSize.width)
    }

    @Test("The shelf is exactly as tall as the rows it draws")
    func shelfHeightFollowsItsContent() {
        // Detail adds a pager as soon as there is a second capture to page to.
        // A single fixed height clipped that row behind the island's own edge.
        let oneDetail = NotchLayout.shelfContentHeight(
            style: .detail, itemCount: 1, hasStack: false
        )
        let twoDetail = NotchLayout.shelfContentHeight(
            style: .detail, itemCount: 2, hasStack: false
        )
        #expect(twoDetail > oneDetail)

        // Grid has neither the thumbnail block nor the pager, so it must not
        // reserve their height and leave empty island under the buttons.
        let twoGrid = NotchLayout.shelfContentHeight(
            style: .grid, itemCount: 2, hasStack: false
        )
        #expect(twoGrid < twoDetail)
        #expect(NotchLayout.shelfContentHeight(style: .grid, itemCount: 5, hasStack: false)
            == twoGrid)

        // The stack strip is a real row in both layouts.
        #expect(NotchLayout.shelfContentHeight(style: .grid, itemCount: 2, hasStack: true)
            > twoGrid)
        #expect(NotchLayout.shelfContentHeight(style: .detail, itemCount: 2, hasStack: true)
            > twoDetail)
    }

    @Test("The tallest shelf still fits the island")
    func tallestShelfFits() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let layout = NotchLayout.layout(
            for: .result,
            metrics: metrics,
            isPeeking: false,
            resultCount: 5,
            hasStack: true,
            shelfStyle: .detail
        )
        // Nothing is clipped: the island carries the full content plus the
        // band the physical cutout occupies.
        #expect(layout.size.height
            == NotchLayout.shelfContentHeight(style: .detail, itemCount: 5, hasStack: true) + 37)
        #expect(layout.size.height <= NotchLayout.maximumSize.height)
    }
}

@Suite("Brightness change classification")
struct BrightnessChangeClassifierTests {
    @Test("Brightness publication requires a recent key event")
    func brightnessKeyIntentWindow() {
        var gate = BrightnessKeyIntentGate()
        #expect(!gate.allowsPublication(at: 10))
        gate.noteKeyEvent(at: 10)
        #expect(gate.allowsPublication(at: 10.2))
        #expect(!gate.allowsPublication(at: 11))
        gate.reset()
        #expect(!gate.allowsPublication(at: 10.3))
    }


    /// Drives a sequence of readings at the monitor's real 5 Hz sample rate.
    private func run(
        _ values: [Double],
        from start: Double,
        interval: TimeInterval = 0.2
    ) -> [Double] {
        var classifier = BrightnessChangeClassifier()
        classifier.reset(to: start)
        var reported: [Double] = []
        for (index, value) in values.enumerated() {
            let time = TimeInterval(index + 1) * interval
            if case .report(let level) = classifier.classify(value, at: time) {
                reported.append(level)
            }
        }
        return reported
    }

    /// Measured on an adapting display: about 0.006 per sample, off-grid, and it
    /// keeps going. None of it should reach the notch.
    @Test("An auto-brightness ramp is never reported")
    func ambientRampIsSilent() {
        var value = 0.3649
        let ramp = (0 ..< 40).map { _ -> Double in
            value += 0.006
            return value
        }
        #expect(run(ramp, from: 0.3649).isEmpty)
    }

    /// Readings taken off a real adapting display, resampled to the monitor's
    /// 200 ms interval. This is the exact case that used to flash the HUD
    /// continuously: every step clears the old 0.004 gate.
    @Test("A measured ramp off real hardware is never reported")
    func measuredRampIsSilent() {
        let measured = [0.364872724, 0.369790286, 0.374707818, 0.379625350, 0.384542882]
        for (index, value) in measured.dropFirst().enumerated() {
            #expect(abs(value - measured[index]) > 0.004)
        }
        #expect(run(measured, from: 0.364872724).isEmpty)
    }

    /// The leak that survived the first version: a real ramp does not glide at a
    /// constant rate. When a sample dips under the noise floor the burst closes,
    /// and judging it on accumulated distance reported every few seconds of a
    /// long adaptation. Only a single fast sample may qualify.
    @Test("A stuttering auto-brightness ramp is never reported")
    func stutteringRampIsSilent() {
        var value = 0.30
        var samples: [Double] = []
        // Six seconds of drift that pauses every few samples, as the sensor does.
        for index in 0 ..< 30 {
            if index % 4 == 3 {
                samples.append(value)          // a beat with no movement
            } else {
                value += 0.006
                samples.append(value)
            }
        }
        // Accumulates far past a key press in total, yet no single step is fast.
        #expect(value - 0.30 > 0.12)
        #expect(run(samples, from: 0.30).isEmpty)
    }

    /// A settled display still wobbles slightly; that is not a change either.
    @Test("Sensor wobble is never reported")
    func wobbleIsSilent() {
        let jitter = [0.4202, 0.4195, 0.4207, 0.4191, 0.4206, 0.4198]
        #expect(run(jitter, from: 0.4200).isEmpty)
    }

    /// One tap of the brightness key: 1/16, landing on the keyboard grid.
    @Test("A single key press is reported immediately")
    func keyPressIsReported() {
        let reported = run([0.5 + 1.0 / 16, 0.5 + 1.0 / 16], from: 0.5)
        #expect(reported == [0.5625])
    }

    /// The finest step the keys produce, with ⇧⌥ held.
    @Test("A fine key press is reported")
    func fineKeyPressIsReported() {
        let target = 0.5 + BrightnessChangeClassifier.keyboardStep
        #expect(run([target, target], from: 0.5) == [target])
    }

    /// Holding the key ramps in grid steps; the HUD has to track it, not just
    /// flash once.
    @Test("A held key keeps reporting")
    func heldKeyKeepsReporting() {
        let steps = (1 ... 5).map { 0.4 + Double($0) * (1.0 / 16) }
        #expect(run(steps, from: 0.4).count == 5)
    }

    /// A Control Centre drag lands off-grid, so it is only recognised once the
    /// movement stops — the final value, not every intermediate one.
    @Test("A slider drag is reported once it comes to rest")
    func sliderDragReportsOnRest() {
        let drag = [0.513, 0.541, 0.572, 0.572, 0.572]
        let reported = run(drag, from: 0.5)
        #expect(reported == [0.572])
    }

    /// A ramp that fools the first sample must not hold the HUD open for the
    /// whole adaptation.
    @Test("A slow ramp that starts on-grid is abandoned")
    func slowRampIsAbandoned() {
        var value = 0.5
        // First step is a clean 1/16 onto the grid, then it crawls like a sensor.
        var samples = [0.5 + 1.0 / 16]
        value = samples[0]
        for _ in 0 ..< 20 {
            value += 0.006
            samples.append(value)
        }
        let reported = run(samples, from: 0.5)
        #expect(!reported.isEmpty)
        // Bounded by the 1.2 s ceiling rather than running the full ramp.
        #expect(reported.count < 8)
    }

    /// Waking a display reports a different value; that is not a user action.
    @Test("Resetting the baseline suppresses the next reading")
    func resetSuppressesNextReading() {
        var classifier = BrightnessChangeClassifier()
        classifier.reset(to: 0.5)
        classifier.reset(to: 0.2)
        #expect(classifier.classify(0.2, at: 1) == .ignore)
    }

    @Test("An ambient ramp accumulated during a sampling stall is ignored")
    func delayedAmbientSampleIsIgnored() {
        var classifier = BrightnessChangeClassifier()
        classifier.reset(to: 0.40)
        #expect(classifier.classify(0.406, at: 1.0) == .ignore)
        // This large off-grid jump represents several seconds of samples that
        // the main run loop could not deliver individually.
        #expect(classifier.classify(0.49, at: 2.0) == .ignore)
        #expect(classifier.classify(0.49, at: 2.2) == .ignore)
    }
}

@Suite("Screen Recording remediation")
@MainActor
struct ScreenRecordingRemediationTests {

    /// Drives the class with a scripted TCC state instead of the real one: a
    /// test process carries the terminal's Screen Recording status, which says
    /// nothing about the app's.
    private func center(
        granted: Bool,
        asked: Bool
    ) -> (center: PermissionCenter, requestCount: () -> Int) {
        let defaults = UserDefaults.standard
        defaults.set(asked, forKey: "notchshot.askedScreenRecording")
        let counter = Counter()
        let center = PermissionCenter(
            preflight: { granted },
            request: { counter.increment(); return granted }
        )
        return (center, { counter.value })
    }

    private final class Counter: @unchecked Sendable {
        private var count = 0
        func increment() { count += 1 }
        var value: Int { count }
    }

    /// The dead end this replaced: a stored "already asked" flag made every
    /// later launch report denied without ever asking macOS again, so an
    /// approval that did not land could not be recovered from inside the app.
    @Test("A request from an earlier launch still asks macOS again")
    func earlierRequestDoesNotBlockAsking() {
        let (subject, requestCount) = center(granted: false, asked: true)
        #expect(subject.requestScreenRecordingAccess() == false)
        #expect(requestCount() == 1)
        // Offers a way forward rather than the terminal denial it used to latch.
        #expect(subject.screenRecording == .restartRequired)
        #expect(subject.pendingRemediation == .screenRecording)
    }

    /// A second attempt inside one launch cannot produce another system prompt,
    /// so that one is allowed to report the denial.
    @Test("A second attempt in the same launch reports denied without re-asking")
    func secondAttemptInSameLaunchReportsDenied() {
        let (subject, requestCount) = center(granted: false, asked: false)
        _ = subject.requestScreenRecordingAccess()
        _ = subject.requestScreenRecordingAccess()
        #expect(requestCount() == 1)
        #expect(subject.screenRecording == .denied)
    }

    /// A live grant on a launch that never asked is simply usable.
    @Test("An existing grant is reported as granted")
    func existingGrantIsUsable() {
        let (subject, requestCount) = center(granted: true, asked: true)
        #expect(subject.requestScreenRecordingAccess())
        #expect(subject.screenRecording == .granted)
        #expect(subject.screenRecording.isUsable)
        #expect(requestCount() == 0)
        #expect(!subject.isScreenRecordingGrantStale)
    }

    /// `CGPreflightScreenCaptureAccess` is the source of truth for the current
    /// process. Once it turns true, a request made earlier in this launch must
    /// not keep the UI or capture flow stuck behind a false relaunch prompt.
    @Test("A live preflight grant overrides the same-launch pending state")
    func liveGrantOverridesPendingState() {
        var granted = false
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "notchshot.askedScreenRecording")
        let counter = Counter()
        let subject = PermissionCenter(
            preflight: { granted },
            request: { counter.increment(); return false }
        )

        #expect(!subject.requestScreenRecordingAccess())
        #expect(subject.screenRecording == .restartRequired)
        #expect(subject.pendingRemediation == .screenRecording)

        granted = true
        subject.refresh()

        #expect(subject.screenRecording == .granted)
        #expect(subject.screenRecording.isUsable)
        #expect(subject.pendingRemediation == nil)
        #expect(subject.requestScreenRecordingAccess())
        #expect(counter.value == 1)
    }

    /// The stale hint is the poll's decision, not the request's: a prompt the
    /// user is still answering must not be labelled a broken record.
    @Test("The stale-grant hint is not raised immediately")
    func staleHintIsNotImmediate() {
        let (subject, _) = center(granted: false, asked: true)
        _ = subject.requestScreenRecordingAccess()
        #expect(!subject.isScreenRecordingGrantStale)
    }
}
