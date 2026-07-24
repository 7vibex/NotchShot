import AppKit
import CoreGraphics
import Foundation

/// Drives a manual vertical scrolling capture.
///
/// The user picks a region, then scrolls it themselves; a frame is grabbed each
/// time scrolling settles. Automating the scroll would need synthetic events
/// (and Accessibility permission) and breaks on any custom scroll view, so V1
/// stays manual and honest about it.
@MainActor
public final class ScrollingCaptureSession {

    public enum Event: Sendable {
        case frameCaptured(count: Int)
        case stitching(progress: Double)
        case finished(StitchOutput)
        case failedButFramesKept(reason: String, folder: URL)
        case cancelled
    }

    /// Guard rail: 120 frames of a 1200px-tall region is a ~50k pixel image,
    /// well past what anything downstream will happily open.
    public static let maximumFrames = 120

    public private(set) var frames: [CGImage] = []
    public private(set) var isRunning = false

    private let region: CGRect
    private let onEvent: (Event) -> Void
    private var scrollMonitors: [Any] = []
    private var settleWorkItem: DispatchWorkItem?
    private var isCapturingFrame = false
    private var hasPendingScroll = false

    public init(region: CGRect, onEvent: @escaping (Event) -> Void) {
        self.region = region
        self.onEvent = onEvent
    }

    // MARK: Lifecycle

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await captureFrame()
        installScrollMonitors()
    }

    /// Explicit "grab now", for content that doesn't emit scroll events.
    public func captureFrameManually() async {
        await captureFrame()
    }

    public func finish() async {
        guard isRunning else { return }
        teardown()

        // A scroll that hadn't settled yet still has useful content in it.
        if hasPendingScroll {
            await captureFrame()
        }

        let captured = frames
        guard captured.count > 1 else {
            onEvent(.failedButFramesKept(
                reason: "Only one frame was captured — nothing to stitch.",
                folder: (try? preserveFrames(captured)) ?? AppPaths.captures
            ))
            return
        }

        onEvent(.stitching(progress: 0))
        let box = FrameBox(frames: captured)
        let result: Result<StitchOutput, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let output = try ScrollingStitcher.stitch(frames: box.frames) { progress in
                    Task { @MainActor in
                        // Progress only; the session is already off the hot path.
                        _ = progress
                    }
                }
                return .success(output)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let output):
            onEvent(.finished(output))
        case .failure(let error):
            let reason = (error as? NotchShotError)?.errorDescription ?? error.localizedDescription
            do {
                let folder = try preserveFrames(captured)
                onEvent(.failedButFramesKept(reason: reason, folder: folder))
            } catch {
                onEvent(.failedButFramesKept(reason: reason, folder: AppPaths.captures))
            }
        }
    }

    public func cancel() {
        guard isRunning else { return }
        teardown()
        frames.removeAll()
        onEvent(.cancelled)
    }

    private func teardown() {
        isRunning = false
        settleWorkItem?.cancel()
        settleWorkItem = nil
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors.removeAll()
    }

    // MARK: Frame grabbing

    private func installScrollMonitors() {
        // Scroll-wheel monitoring needs no Accessibility grant, unlike keyboard
        // monitoring — one reason the flow is built around scrolling.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDidChange() }
        }) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scrollDidChange() }
            return event
        }) {
            scrollMonitors.append(local)
        }
    }

    private func scrollDidChange() {
        guard isRunning, frames.count < Self.maximumFrames else { return }
        hasPendingScroll = true
        settleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.captureFrame() }
            }
        }
        settleWorkItem = item
        // Long enough for momentum scrolling to stop, short enough to feel live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
    }

    private func captureFrame() async {
        guard !isCapturingFrame, frames.count < Self.maximumFrames else { return }
        isCapturingFrame = true
        defer { isCapturingFrame = false }

        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        do {
            let image = try await CaptureService.shared.captureArea(
                region,
                excludedWindows: excluded,
                showsCursor: false
            )
            frames.append(image.cgImage)
            hasPendingScroll = false
            onEvent(.frameCaptured(count: frames.count))
        } catch {
            Log.capture.error("Scrolling frame capture failed: \(error.localizedDescription)")
        }
    }

    /// When stitching fails the frames are still the user's work, so they get
    /// written out individually instead of thrown away.
    private func preserveFrames(_ frames: [CGImage]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = AppPaths.captures.appendingPathComponent(
            "Scrolling Frames \(formatter.string(from: Date()))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            let url = folder.appendingPathComponent(String(format: "frame-%03d.png", index + 1))
            _ = try? ImageExport.write(frame, to: url, format: .png, quality: 1, dpiScale: 2)
        }
        Log.capture.notice("Preserved \(frames.count) scrolling frames at \(folder.path)")
        return folder
    }
}

/// Carries `CGImage`s into a detached task. Immutable and read-only there.
private struct FrameBox: @unchecked Sendable {
    let frames: [CGImage]
}
