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
}

@Suite("System level HUD")
struct SystemLevelTests {

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
}
