import AVFoundation
import AppKit
import CoreImage
import Foundation

public struct RecordingPointerSample: Sendable, Equatable {
    public var time: TimeInterval
    /// Unit coordinates with a top-left origin.
    public var point: CGPoint
    /// False while the pointer is outside the recorded area. `point` is then
    /// pinned to the nearest edge, so nothing should be drawn there.
    public var isInsideTarget = true
}

public struct RecordingInteractionTimeline: Sendable, Equatable {
    public var duration: TimeInterval
    public var pointerSamples: [RecordingPointerSample]
    public var clickTimes: [TimeInterval]
    /// Exact click locations. Keeping these separate from the smoothed cursor
    /// path makes a zoom stay anchored after the pointer moves away.
    public var clickPoints: [RecordingPointerSample]

    public init(
        duration: TimeInterval = 0,
        pointerSamples: [RecordingPointerSample] = [],
        clickTimes: [TimeInterval] = [],
        clickPoints: [RecordingPointerSample] = []
    ) {
        self.duration = max(0, duration)
        self.pointerSamples = pointerSamples
        self.clickTimes = clickTimes
        self.clickPoints = clickPoints
    }

    public static func joined(_ segments: [RecordingInteractionTimeline]) -> RecordingInteractionTimeline {
        var offset: TimeInterval = 0
        var samples: [RecordingPointerSample] = []
        var clicks: [TimeInterval] = []
        var clickPoints: [RecordingPointerSample] = []
        for segment in segments {
            samples.append(contentsOf: segment.pointerSamples.map {
                RecordingPointerSample(time: $0.time + offset, point: $0.point, isInsideTarget: $0.isInsideTarget)
            })
            clicks.append(contentsOf: segment.clickTimes.map { $0 + offset })
            clickPoints.append(contentsOf: segment.clickPoints.map {
                RecordingPointerSample(time: $0.time + offset, point: $0.point)
            })
            offset += segment.duration
        }
        return RecordingInteractionTimeline(
            duration: offset,
            pointerSamples: samples,
            clickTimes: clicks,
            clickPoints: clickPoints
        )
    }

    public func smoothed(alpha: CGFloat = 0.22) -> RecordingInteractionTimeline {
        guard let first = pointerSamples.first else { return self }
        let alpha = min(max(alpha, 0.01), 1)
        var previous = first.point
        var output = [first]
        output.reserveCapacity(pointerSamples.count)
        for sample in pointerSamples.dropFirst() {
            previous = CGPoint(
                x: previous.x + (sample.point.x - previous.x) * alpha,
                y: previous.y + (sample.point.y - previous.y) * alpha
            )
            output.append(RecordingPointerSample(
                time: sample.time,
                point: previous,
                isInsideTarget: sample.isInsideTarget
            ))
        }
        return RecordingInteractionTimeline(
            duration: duration,
            pointerSamples: output,
            clickTimes: clickTimes,
            clickPoints: clickPoints
        )
    }

    public func point(at time: TimeInterval) -> CGPoint? {
        guard !pointerSamples.isEmpty else { return nil }
        let upper = pointerSamples.partitioningIndex { $0.time >= time }
        if upper == 0 { return pointerSamples[0].point }
        if upper >= pointerSamples.count { return pointerSamples[pointerSamples.count - 1].point }
        let before = pointerSamples[upper - 1]
        let after = pointerSamples[upper]
        let interval = max(after.time - before.time, 0.000_1)
        let progress = CGFloat(min(max((time - before.time) / interval, 0), 1))
        return CGPoint(
            x: before.point.x + (after.point.x - before.point.x) * progress,
            y: before.point.y + (after.point.y - before.point.y) * progress
        )
    }

    public func pointerIsInsideTarget(at time: TimeInterval) -> Bool {
        guard !pointerSamples.isEmpty else { return true }
        let upper = pointerSamples.partitioningIndex { $0.time > time }
        return pointerSamples[Swift.max(upper - 1, 0)].isInsideTarget
    }

    public func zoom(at time: TimeInterval) -> CGFloat {
        guard let click = clickTimes.last(where: { $0 <= time }) else { return 1 }
        let elapsed = time - click
        switch elapsed {
        case ..<0: return 1
        case 0 ..< 0.22:
            return 1 + 0.35 * Self.smoothstep(CGFloat(elapsed / 0.22))
        case 0.22 ..< 0.92:
            return 1.35
        case 0.92 ..< 1.35:
            return 1.35 - 0.35 * Self.smoothstep(CGFloat((elapsed - 0.92) / 0.43))
        default:
            return 1
        }
    }

    public func focusPoint(at time: TimeInterval) -> CGPoint? {
        if zoom(at: time) > 1.001,
           let click = clickPoints.last(where: { $0.time <= time }) {
            return click.point
        }
        return point(at: time)
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

enum RecordingZoomGeometry {
    static let maximumZoom: CGFloat = 1.35

    /// Scales about `focus` and eases it toward the centre as the zoom grows, so
    /// the frame neither jumps at the start of a zoom nor shows empty space when
    /// the click is near an edge. At a zoom of 1 this is the identity.
    static func transform(focus: CGPoint, zoom: CGFloat, in extent: CGRect) -> CGAffineTransform {
        guard zoom > 1 else { return .identity }
        let progress = min((zoom - 1) / (maximumZoom - 1), 1)
        func placed(_ point: CGFloat, middle: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            let eased = point + (middle - point) * progress
            // Past these, an edge of the scaled frame would come inside `extent`.
            return min(max(eased, upper - zoom * (upper - point)), lower - zoom * (lower - point))
        }
        let x = placed(focus.x, middle: extent.midX, lower: extent.minX, upper: extent.maxX)
        let y = placed(focus.y, middle: extent.midY, lower: extent.minY, upper: extent.maxY)
        return CGAffineTransform(
            a: zoom, b: 0,
            c: 0, d: zoom,
            tx: x - zoom * focus.x,
            ty: y - zoom * focus.y
        )
    }
}

@MainActor
public final class RecordingInteractionRecorder {
    public static let shared = RecordingInteractionRecorder()

    private var timer: Timer?
    private var startedAt: Date?
    private var targetRect: CGRect?
    /// A window recording follows its window, so its rect goes stale.
    private var targetWindowID: CGWindowID?
    private var isRefreshingWindowBounds = false
    private var samples: [RecordingPointerSample] = []
    private var clicks: [TimeInterval] = []
    private var clickPoints: [RecordingPointerSample] = []
    private var wasPressed = false

    public func start(configuration: RecordingConfiguration) {
        _ = stop()
        guard configuration.smoothsCursor || configuration.autoZoomsOnClicks else { return }
        targetRect = Self.targetRect(for: configuration.target)
        guard targetRect != nil else { return }
        if case .window(let windowID) = configuration.target { targetWindowID = windowID }
        startedAt = Date()
        sample()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    public func stop() -> RecordingInteractionTimeline? {
        timer?.invalidate()
        timer = nil
        guard let startedAt else {
            reset()
            return nil
        }
        sample()
        let timeline = RecordingInteractionTimeline(
            duration: max(0, Date().timeIntervalSince(startedAt)),
            pointerSamples: samples,
            clickTimes: clicks,
            clickPoints: clickPoints
        )
        reset()
        return timeline
    }

    private func reset() {
        startedAt = nil
        targetRect = nil
        targetWindowID = nil
        samples.removeAll(keepingCapacity: true)
        clicks.removeAll(keepingCapacity: true)
        clickPoints.removeAll(keepingCapacity: true)
        wasPressed = false
    }

    private func sample() {
        guard let startedAt, let rect = targetRect, rect.width > 0, rect.height > 0 else { return }
        let location = NSEvent.mouseLocation
        let isInside = rect.contains(location)
        let point = CGPoint(
            x: min(max((location.x - rect.minX) / rect.width, 0), 1),
            y: min(max((rect.maxY - location.y) / rect.height, 0), 1)
        )
        let time = Date().timeIntervalSince(startedAt)
        samples.append(RecordingPointerSample(time: time, point: point, isInsideTarget: isInside))
        if samples.count % 30 == 0 { refreshWindowBoundsOffMain() }
        let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if pressed, !wasPressed, isInside {
            clicks.append(time)
            clickPoints.append(RecordingPointerSample(time: time, point: point))
        }
        wasPressed = pressed
    }

    /// About once a second, since samples run at 30 Hz. A window that has gone
    /// keeps its last known rect.
    private func refreshWindowBoundsOffMain() {
        guard let targetWindowID, !isRefreshingWindowBounds else { return }
        isRefreshingWindowBounds = true
        let session = startedAt
        Task.detached(priority: .utility) { [weak self] in
            let bounds = RecordingInteractionRecorder.windowBounds(targetWindowID)
            await self?.applyWindowBounds(bounds, session: session)
        }
    }

    private func applyWindowBounds(_ bounds: CGRect?, session: Date?) {
        isRefreshingWindowBounds = false
        guard let bounds, session == startedAt, startedAt != nil else { return }
        targetRect = ScreenGeometry.cocoaRect(fromCG: bounds, primaryFrame: ScreenLookup.primaryFrame)
    }

    private nonisolated static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let dictionary = list.first,
              let boundsValue = dictionary[kCGWindowBounds as String],
              let boundsDictionary = boundsValue as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    }

    private static func targetRect(for target: RecordingTarget) -> CGRect? {
        switch target {
        case .display(let displayID):
            return ScreenLookup.screen(for: displayID)?.frame
        case .area(let rect, _):
            return ScreenGeometry.cocoaRect(fromCG: rect, primaryFrame: ScreenLookup.primaryFrame)
        case .window(let windowID):
            guard let bounds = windowBounds(windowID) else { return nil }
            return ScreenGeometry.cocoaRect(fromCG: bounds, primaryFrame: ScreenLookup.primaryFrame)
        }
    }
}

public enum RecordingEffectsProcessor {
    public static func process(
        recordingURL: URL,
        timeline: RecordingInteractionTimeline,
        smoothsCursor: Bool,
        autoZoomsOnClicks: Bool
    ) async throws {
        guard smoothsCursor || (autoZoomsOnClicks && !timeline.clickTimes.isEmpty) else { return }
        let asset = AVURLAsset(url: recordingURL)
        _ = try await asset.load(.duration)
        _ = try await asset.loadTracks(withMediaType: .video)
        let effective = smoothsCursor ? timeline.smoothed() : timeline
        let cursor = smoothsCursor ? cursorImage() : nil
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { request in
            let extent = request.sourceImage.extent
            let seconds = request.compositionTime.seconds
            func position(_ unit: CGPoint?) -> CGPoint {
                let unit = unit ?? CGPoint(x: 0.5, y: 0.5)
                return CGPoint(
                    x: extent.minX + extent.width * unit.x,
                    y: extent.minY + extent.height * (1 - unit.y)
                )
            }
            let zoom = autoZoomsOnClicks ? effective.zoom(at: seconds) : 1
            let zoomTransform = zoom > 1.001
                ? RecordingZoomGeometry.transform(
                    focus: position(effective.focusPoint(at: seconds)),
                    zoom: zoom,
                    in: extent
                )
                : CGAffineTransform.identity
            var image = request.sourceImage
            if zoom > 1.001 {
                image = image.transformed(by: zoomTransform).cropped(to: extent)
            }
            if let cursor, effective.pointerIsInsideTarget(at: seconds) {
                let cursorScale = max(0.75, min(extent.width, extent.height) / 1_400)
                // The pointer itself, moved with the picture. It can leave the
                // click point while a zoom holds.
                let cursorPosition = position(effective.point(at: seconds)).applying(zoomTransform)
                let overlay = cursor
                    .transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
                    .transformed(by: CGAffineTransform(
                        translationX: cursorPosition.x - 3 * cursorScale,
                        y: cursorPosition.y - cursor.extent.height * cursorScale + 3 * cursorScale
                    ))
                image = overlay.composited(over: image)
            }
            return AVCIImageFilteringResult(resultImage: image)
        }

        let staging = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-effects-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NotchShotError.exportFailed("Could not create the recording-effects exporter")
        }
        exporter.videoComposition = composition
        try await exporter.export(to: staging, as: .mp4)
        let values = try staging.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw NotchShotError.exportFailed("Recording effects did not produce a complete video")
        }
        _ = try FileManager.default.replaceItemAt(recordingURL, withItemAt: staging)
    }

    private static func cursorImage() -> CIImage? {
        guard let tiff = NSCursor.arrow.image.tiffRepresentation else { return nil }
        return CIImage(data: tiff)
    }
}
