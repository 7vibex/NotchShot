import AppKit
import CoreGraphics
import Foundation

public enum ScrollingCaptureMode: String, Sendable, CaseIterable, Identifiable {
    case manualVertical
    case automaticVertical
    case manualHorizontal
    case automaticHorizontal

    public var id: String { rawValue }
    public var axis: ScrollingAxis {
        switch self {
        case .manualVertical, .automaticVertical: .vertical
        case .manualHorizontal, .automaticHorizontal: .horizontal
        }
    }
    public var isAutomatic: Bool {
        self == .automaticVertical || self == .automaticHorizontal
    }
    public var title: String {
        switch self {
        case .manualVertical: "Manual Vertical"
        case .automaticVertical: "Automatic Vertical"
        case .manualHorizontal: "Manual Horizontal"
        case .automaticHorizontal: "Automatic Horizontal"
        }
    }
}

/// Drives manual or automatic scrolling capture on either axis.
@MainActor
public final class ScrollingCaptureSession {

    public enum Event: Sendable {
        case frameCaptured(count: Int)
        case stitching(progress: Double)
        case finished(StitchOutput)
        case failedButFramesKept(reason: String, folder: URL)
        case failed(reason: String)
        case cancelled
    }

    /// A count guard complements the decoded-byte and composite-pixel budgets
    /// enforced below and by `ScrollingStitcher`.
    public static let maximumFrames = 120

    public private(set) var frames: [CGImage] = []
    public private(set) var isRunning = false

    private let region: CGRect
    public let mode: ScrollingCaptureMode
    private let onEvent: (Event) -> Void
    private let limits: StitchLimits
    private let frameProvider: FrameProvider
    private var scrollMonitors: [Any] = []
    private var automaticTask: Task<Void, Never>?
    private var settleWorkItem: DispatchWorkItem?
    private var hasPendingScroll = false
    private var scrollRevision: UInt64 = 0
    private var captureTask: Task<Void, Never>?
    private var captureTaskID: UInt64 = 0
    private var stitchTask: Task<StitchOutput, Error>?
    private var stitchTaskID: UInt64 = 0
    private var generation: UInt64 = 0
    private var terminalGeneration: UInt64?
    private var isFinishing = false
    private var capturedPixels = 0
    private var capturedBytes = 0
    private var consecutiveCaptureFailures = 0
    private var consecutiveDuplicateFrames = 0
    private var lastFrameFingerprint: UInt64?
    private var lastStitchProgress = 0.0
    private var hasEmittedStitchProgress = false

    typealias FrameProvider = @MainActor @Sendable () async throws -> CGImage
    typealias FrameWriter = @Sendable (CGImage, URL) throws -> Void
    typealias ScrollDriver = @MainActor @Sendable (ScrollingAxis, CGRect) -> Bool

    private let recoveryRoot: URL
    private let frameWriter: FrameWriter
    private let scrollDriver: ScrollDriver

    public convenience init(
        region: CGRect,
        mode: ScrollingCaptureMode = .manualVertical,
        onEvent: @escaping (Event) -> Void
    ) {
        self.init(region: region, mode: mode, onEvent: onEvent, limits: StitchLimits()) {
            let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
            return try await CaptureService.shared.captureArea(
                region,
                excludedWindows: excluded,
                showsCursor: false
            ).cgImage
        }
    }

    /// Internal injection point used by deterministic lifecycle tests. The app
    /// always uses the public initializer above.
    init(
        region: CGRect,
        mode: ScrollingCaptureMode = .manualVertical,
        onEvent: @escaping (Event) -> Void,
        limits: StitchLimits,
        recoveryRoot: URL = AppPaths.captures,
        frameWriter: @escaping FrameWriter = { image, url in
            _ = try ImageExport.write(image, to: url, format: .png, quality: 1, dpiScale: 2)
        },
        scrollDriver: @escaping ScrollDriver = { axis, region in
            let primary = Int32(max(80, (axis == .vertical ? region.height : region.width) * 0.72))
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: axis == .vertical ? -primary : 0,
                wheel2: axis == .horizontal ? -primary : 0,
                wheel3: 0
            )
            event?.location = CGPoint(x: region.midX, y: region.midY)
            event?.post(tap: .cghidEventTap)
            return event != nil
        },
        frameProvider: @escaping FrameProvider
    ) {
        self.region = region
        self.mode = mode
        self.onEvent = onEvent
        self.limits = limits
        self.recoveryRoot = recoveryRoot
        self.frameWriter = frameWriter
        self.scrollDriver = scrollDriver
        self.frameProvider = frameProvider
    }

    // MARK: Lifecycle

    public func start() async {
        guard !isRunning, !isFinishing else { return }
        generation &+= 1
        terminalGeneration = nil
        frames.removeAll(keepingCapacity: true)
        capturedPixels = 0
        capturedBytes = 0
        consecutiveCaptureFailures = 0
        consecutiveDuplicateFrames = 0
        lastFrameFingerprint = nil
        hasPendingScroll = false
        scrollRevision = 0
        lastStitchProgress = 0
        hasEmittedStitchProgress = false
        isRunning = true
        let activeGeneration = generation
        await captureFrame(for: activeGeneration, whileFinishing: false)
        guard canEmit(for: activeGeneration), isRunning else { return }
        if mode.isAutomatic {
            startAutomaticScrolling(for: activeGeneration)
        } else {
            installScrollMonitors()
        }
    }

    /// Explicit "grab now", for content that doesn't emit scroll events.
    public func captureFrameManually() async {
        guard isRunning else { return }
        await captureFrame(for: generation, whileFinishing: false)
    }

    public func finish() async {
        guard isRunning else { return }
        let activeGeneration = generation
        isRunning = false
        isFinishing = true
        stopMonitoring()

        // ScreenCaptureKit does not guarantee immediate cooperative
        // cancellation. Await the already-started grab so a press of Return at
        // exactly the wrong moment cannot omit the last visible position.
        await awaitCurrentCapture()
        guard canEmit(for: activeGeneration), isFinishing else { return }

        // A scroll that hadn't settled yet still has useful content in it.
        if hasPendingScroll {
            await captureFrame(for: activeGeneration, whileFinishing: true)
        }
        guard canEmit(for: activeGeneration), isFinishing else { return }

        let captured = frames
        guard captured.count > 1 else {
            await failAndPreserveFrames(
                captured,
                reason: "Only one frame was captured — nothing to stitch.",
                generation: activeGeneration
            )
            return
        }

        emitStitchProgress(0, for: activeGeneration)
        let box = FrameBox(frames: captured)
        let stitchLimits = limits
        let stitchAxis = mode.axis
        let progressTarget = self
        stitchTaskID &+= 1
        let taskID = stitchTaskID
        let task = Task.detached(priority: .userInitiated) {
            try ScrollingStitcher.stitch(
                frames: box.frames,
                axis: stitchAxis,
                limits: stitchLimits
            ) { progress in
                Task { @MainActor in
                    progressTarget.emitStitchProgress(progress, for: activeGeneration)
                }
            }
        }
        stitchTask = task

        do {
            let output = try await task.value
            if stitchTaskID == taskID {
                stitchTask = nil
            }
            guard canEmit(for: activeGeneration), isFinishing else { return }
            emitStitchProgress(1, for: activeGeneration)
            emitTerminal(.finished(output), for: activeGeneration)
        } catch is CancellationError {
            if stitchTaskID == taskID {
                stitchTask = nil
            }
            // `cancel()` owns the sole terminal event for an intentional
            // cancellation. A superseded generation is likewise silent.
            guard canEmit(for: activeGeneration), isFinishing else { return }
            await failAndPreserveFrames(
                captured,
                reason: "Stitching was interrupted before it could finish.",
                generation: activeGeneration
            )
        } catch {
            if stitchTaskID == taskID {
                stitchTask = nil
            }
            guard canEmit(for: activeGeneration), isFinishing else { return }
            await failAndPreserveFrames(
                captured,
                reason: stitchFailureReason(error),
                generation: activeGeneration
            )
        }
    }

    public func cancel() {
        guard isRunning || isFinishing else { return }
        let activeGeneration = generation
        isRunning = false
        isFinishing = false
        stopMonitoring()
        captureTask?.cancel()
        stitchTask?.cancel()
        captureTask = nil
        stitchTask = nil
        captureTaskID &+= 1
        stitchTaskID &+= 1
        frames.removeAll()
        capturedPixels = 0
        capturedBytes = 0
        hasPendingScroll = false
        emitTerminal(.cancelled, for: activeGeneration)
    }

    private func failAndPreserveFrames(
        _ captured: [CGImage],
        reason: String,
        generation activeGeneration: UInt64
    ) async {
        guard canEmit(for: activeGeneration) else { return }
        isRunning = false
        isFinishing = false
        stopMonitoring()

        // Encoding is deliberately not done here. Each kept frame is a
        // full-resolution Retina PNG costing well over 200 ms to write, and this
        // runs on the main actor at exactly the moment the failure UI is meant
        // to appear — so a six-frame capture used to freeze the app for more
        // than a second while trying to tell the user it had not worked.
        let box = FrameBox(frames: captured)
        let writer = frameWriter
        let root = recoveryRoot
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> PreservationOutcome in
            do {
                return .kept(try Self.preserveFrames(box.frames, in: root, using: writer))
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        // Re-checked after the suspension: cancel() or a newer generation may
        // have claimed the terminal event while the frames were being written.
        guard canEmit(for: activeGeneration) else { return }
        switch outcome {
        case .kept(let folder):
            emitTerminal(
                .failedButFramesKept(reason: reason, folder: folder),
                for: activeGeneration
            )
        case .failed(let description):
            emitTerminal(
                .failed(
                    reason: "\(reason) The captured frames could not be preserved: \(description)"
                ),
                for: activeGeneration
            )
        }
    }

    /// `Error` is not `Sendable`, so the failure crosses the actor boundary as
    /// the message the caller would have shown anyway.
    private enum PreservationOutcome: Sendable {
        case kept(URL)
        case failed(String)
    }

    private func stitchFailureReason(_ error: Error) -> String {
        if let error = error as? NotchShotError {
            if case .stitchFailed(let reason) = error {
                return reason
            }
        }
        return error.localizedDescription
    }

    private func canEmit(for activeGeneration: UInt64) -> Bool {
        generation == activeGeneration && terminalGeneration != activeGeneration
    }

    private func emit(_ event: Event, for activeGeneration: UInt64) {
        guard canEmit(for: activeGeneration) else { return }
        onEvent(event)
    }

    private func emitTerminal(_ event: Event, for activeGeneration: UInt64) {
        guard canEmit(for: activeGeneration) else { return }
        terminalGeneration = activeGeneration
        isRunning = false
        isFinishing = false
        onEvent(event)
    }

    private func emitStitchProgress(_ progress: Double, for activeGeneration: UInt64) {
        guard canEmit(for: activeGeneration), isFinishing else { return }
        let clamped = min(max(progress, 0), 1)
        guard !hasEmittedStitchProgress || clamped > lastStitchProgress else { return }
        hasEmittedStitchProgress = true
        lastStitchProgress = clamped
        emit(.stitching(progress: clamped), for: activeGeneration)
    }

    private func stopMonitoring() {
        automaticTask?.cancel()
        automaticTask = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        for monitor in scrollMonitors { NSEvent.removeMonitor(monitor) }
        scrollMonitors.removeAll()
    }

    // MARK: Frame grabbing

    private func startAutomaticScrolling(for activeGeneration: UInt64) {
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            guard let self else { return }
            while self.canCapture(for: activeGeneration, whileFinishing: false) {
                do {
                    try await Task.sleep(for: .milliseconds(520))
                } catch {
                    return
                }
                guard self.scrollDriver(self.mode.axis, self.region) else {
                    await self.failAndPreserveFrames(
                        self.frames,
                        reason: "Automatic scrolling could not send a scroll event.",
                        generation: activeGeneration
                    )
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(360))
                } catch {
                    return
                }
                await self.captureFrame(for: activeGeneration, whileFinishing: false)
                guard self.canEmit(for: activeGeneration) else { return }
                if self.consecutiveDuplicateFrames >= 2
                    || self.frames.count >= min(Self.maximumFrames, self.limits.maximumFrames) {
                    self.automaticTask = nil
                    await self.finish()
                    return
                }
            }
        }
    }

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
        guard isRunning,
              frames.count < min(Self.maximumFrames, limits.maximumFrames) else { return }
        hasPendingScroll = true
        scrollRevision &+= 1
        let activeGeneration = generation
        settleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.captureFrame(for: activeGeneration, whileFinishing: false) }
            }
        }
        settleWorkItem = item
        // Long enough for momentum scrolling to stop, short enough to feel live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
    }

    private func captureFrame(for activeGeneration: UInt64, whileFinishing: Bool) async {
        guard canCapture(for: activeGeneration, whileFinishing: whileFinishing) else { return }
        if captureTask != nil {
            await awaitCurrentCapture()
            // A settled scroll that arrived during the previous grab still
            // needs its own frame. Concurrent manual requests, which do not
            // set this flag, continue to coalesce onto the in-flight task.
            guard hasPendingScroll,
                  canCapture(for: activeGeneration, whileFinishing: whileFinishing) else { return }
        }

        captureTaskID &+= 1
        let taskID = captureTaskID
        let revisionAtStart = scrollRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await self.frameProvider()
                try Task.checkCancellation()
                guard self.canCompleteCapture(for: activeGeneration) else { return }

                do {
                    let cost = try ScrollingStitcher.validateFrame(
                        image,
                        aggregatePixels: self.capturedPixels,
                        aggregateBytes: self.capturedBytes,
                        limits: self.limits
                    )
                    self.frames.append(image)
                    self.capturedPixels += cost.pixels
                    self.capturedBytes += cost.decodedBytes
                    self.consecutiveCaptureFailures = 0
                    let fingerprint = Self.fingerprint(image)
                    if self.mode.isAutomatic,
                       let previous = self.lastFrameFingerprint,
                       previous == fingerprint {
                        self.consecutiveDuplicateFrames += 1
                    } else {
                        self.consecutiveDuplicateFrames = 0
                    }
                    self.lastFrameFingerprint = fingerprint
                } catch {
                    await self.failAndPreserveFrames(
                        self.frames,
                        reason: self.stitchFailureReason(error),
                        generation: activeGeneration
                    )
                    return
                }

                if self.scrollRevision == revisionAtStart {
                    self.hasPendingScroll = false
                }
                self.emit(.frameCaptured(count: self.frames.count), for: activeGeneration)
            } catch is CancellationError {
                // `cancel()` emits the terminal event and invalidates this task.
            } catch {
                Log.capture.error("Scrolling frame capture failed: \(error.localizedDescription)")
                self.consecutiveCaptureFailures += 1
                if self.frames.isEmpty || self.consecutiveCaptureFailures >= 3 {
                    await self.failAndPreserveFrames(
                        self.frames,
                        reason: "Frame capture failed: \(error.localizedDescription)",
                        generation: activeGeneration
                    )
                }
            }
        }
        captureTask = task
        await task.value
        if captureTaskID == taskID {
            captureTask = nil
        }
    }

    private func canCapture(for activeGeneration: UInt64, whileFinishing: Bool) -> Bool {
        guard canEmit(for: activeGeneration),
              frames.count < min(Self.maximumFrames, limits.maximumFrames) else { return false }
        return isRunning || (whileFinishing && isFinishing)
    }

    private func canCompleteCapture(for activeGeneration: UInt64) -> Bool {
        guard canEmit(for: activeGeneration),
              frames.count < min(Self.maximumFrames, limits.maximumFrames) else { return false }
        return isRunning || isFinishing
    }

    private func awaitCurrentCapture() async {
        guard let task = captureTask else { return }
        let taskID = captureTaskID
        await task.value
        if captureTaskID == taskID {
            captureTask = nil
        }
    }

    private nonisolated static func fingerprint(_ image: CGImage) -> UInt64 {
        let dimension = 16
        var pixels = Array(repeating: UInt8.zero, count: dimension * dimension)
        guard let context = CGContext(
            data: &pixels,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        return pixels.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }

    /// When stitching fails the frames are still the user's work, so they get
    /// written out individually instead of thrown away.
    nonisolated private static func preserveFrames(
        _ frames: [CGImage],
        in recoveryRoot: URL,
        using frameWriter: FrameWriter
    ) throws -> URL {
        guard !frames.isEmpty else {
            throw NotchShotError.exportFailed("No scrolling frames were captured")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let identifier = UUID().uuidString
        let folder = recoveryRoot.appendingPathComponent(
            "Scrolling Frames \(formatter.string(from: Date())) \(identifier.prefix(8))",
            isDirectory: true
        )
        let staging = recoveryRoot.appendingPathComponent(
            ".scrolling-frames-\(identifier).partial",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: staging) }
        }
        for (index, frame) in frames.enumerated() {
            let url = staging.appendingPathComponent(String(format: "frame-%03d.png", index + 1))
            try frameWriter(frame, url)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw NotchShotError.exportFailed("A scrolling frame was not written completely")
            }
        }
        try FileManager.default.moveItem(at: staging, to: folder)
        committed = true
        Log.capture.notice("Preserved \(frames.count) scrolling frames at \(folder.path)")
        return folder
    }
}

/// Carries `CGImage`s into a detached task. Immutable and read-only there.
private struct FrameBox: @unchecked Sendable {
    let frames: [CGImage]
}
