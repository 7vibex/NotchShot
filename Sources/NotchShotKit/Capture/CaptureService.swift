import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Takes the actual pixels.
///
/// Every path goes through ScreenCaptureKit — there is no `CGWindowListCreateImage`
/// fallback, because that API is deprecated on macOS 26 and returns blank
/// images without a TCC grant anyway.
public actor CaptureService {
    public static let shared = CaptureService()

    /// Remembered for `.previousArea`, in global CG space (points).
    private var lastAreaRect: CGRect?

    public init() {}

    public var previousAreaRect: CGRect? { lastAreaRect }

    public func rememberArea(_ rect: CGRect) {
        lastAreaRect = rect
    }

    // MARK: Entry point

    /// Performs a capture. `excludedWindows` should always include NotchShot's
    /// own panels — see `WindowExclusionRegistry`.
    public func capture(
        _ request: CaptureRequest,
        excludedWindows: Set<CGWindowID>
    ) async throws -> CapturedImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw NotchShotError.screenRecordingPermissionDenied
        }

        switch request.intent {
        case .display:
            guard let displayID = request.displayID else { throw NotchShotError.displayNotFound }
            return try await captureDisplay(
                displayID,
                excludedWindows: excludedWindows,
                showsCursor: request.includesCursor
            )

        case .window:
            guard let windowID = request.windowID else { throw NotchShotError.windowNotFound }
            return try await captureWindow(windowID, showsCursor: request.includesCursor)

        case .area, .ocr, .scrolling:
            guard let rect = request.rect else { throw NotchShotError.captureFailed("No area selected") }
            lastAreaRect = rect
            // The user drew this rect on a frozen frame: hand back exactly
            // those pixels. Asking ScreenCaptureKit again cost ~60 ms after
            // mouse-up and captured whatever the screen had moved on to.
            if let frozen = request.selectionFreezeFrame,
               let cut = Self.cut(rect, from: frozen) {
                return cut
            }
            return try await captureArea(
                rect,
                excludedWindows: excludedWindows,
                showsCursor: request.includesCursor
            )

        case .previousArea:
            guard let rect = lastAreaRect else {
                throw NotchShotError.captureFailed("No previous area to repeat")
            }
            return try await captureArea(
                rect,
                excludedWindows: excludedWindows,
                showsCursor: request.includesCursor
            )
        }
    }

    // MARK: Individual modes

    /// Captures a global CG-space rect, resolving which display it belongs to
    /// and converting into that display's local point space.
    public func captureArea(
        _ globalRect: CGRect,
        excludedWindows: Set<CGWindowID>,
        showsCursor: Bool
    ) async throws -> CapturedImage {
        let content = try await fetchRawShareableContent()

        // Pick the display holding most of the rect; a selection dragged across
        // a bezel still resolves to something sensible.
        guard let display = content.displays.max(by: { lhs, rhs in
            area(of: lhs.frame.intersection(globalRect)) < area(of: rhs.frame.intersection(globalRect))
        }), area(of: display.frame.intersection(globalRect)) > 0 else {
            throw NotchShotError.displayNotFound
        }

        guard let clamped = ScreenGeometry.clamp(globalRect, to: display.frame) else {
            throw NotchShotError.captureFailed("Selection is outside every display")
        }

        let scale = await scale(for: display.displayID)
        let localRect = ScreenGeometry.displayLocalRect(
            globalCGRect: clamped,
            displayCGBounds: display.frame
        )
        let pixelSize = ScreenGeometry.pixelSize(forPointRect: clamped, scale: scale)

        let excluded = content.windows.filter { excludedWindows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB

        let image = try await captureImage(filter: filter, configuration: configuration)

        // `sourceRect` is the fast path, but it is also the part of
        // ScreenCaptureKit most likely to disagree with us about scaling on an
        // unusual display mode. If what came back isn't the size we asked for,
        // fall back to grabbing the whole display and cropping — slower, but it
        // cannot return the wrong region.
        let expected = CGSize(width: CGFloat(Int(pixelSize.width)), height: CGFloat(Int(pixelSize.height)))
        let actual = CGSize(width: image.width, height: image.height)
        if abs(actual.width - expected.width) > 2 || abs(actual.height - expected.height) > 2 {
            Log.capture.notice("""
                sourceRect capture returned \(Int(actual.width))×\(Int(actual.height)), \
                expected \(Int(expected.width))×\(Int(expected.height)); cropping from full display
                """)
            if let cropped = try await captureAreaByCropping(
                clamped,
                display: display,
                scale: scale,
                excludedWindows: excludedWindows,
                showsCursor: showsCursor
            ) {
                return cropped
            }
        }

        return CapturedImage(cgImage: image, scale: scale, sourceRect: clamped)
    }

    /// Full-display grab cropped to `globalRect`. The reliable-but-wasteful
    /// path, used only when the direct one misbehaves.
    private func captureAreaByCropping(
        _ globalRect: CGRect,
        display: SCDisplay,
        scale: CGFloat,
        excludedWindows: Set<CGWindowID>,
        showsCursor: Bool
    ) async throws -> CapturedImage? {
        let full = try await captureDisplay(
            display.displayID,
            excludedWindows: excludedWindows,
            showsCursor: showsCursor
        )
        let local = ScreenGeometry.displayLocalRect(
            globalCGRect: globalRect,
            displayCGBounds: display.frame
        )
        let pixelRect = CGRect(
            x: local.origin.x * scale,
            y: local.origin.y * scale,
            width: local.width * scale,
            height: local.height * scale
        ).integral
        guard let cropped = full.cgImage.cropping(to: pixelRect) else { return nil }
        return CapturedImage(cgImage: cropped, scale: scale, sourceRect: globalRect)
    }

    public func captureDisplay(
        _ displayID: CGDirectDisplayID,
        excludedWindows: Set<CGWindowID>,
        showsCursor: Bool
    ) async throws -> CapturedImage {
        let content = try await fetchRawShareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NotchShotError.displayNotFound
        }

        let scale = await scale(for: displayID)
        let excluded = content.windows.filter { excludedWindows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = Self.displayConfiguration(for: display, scale: scale, showsCursor: showsCursor)

        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, scale: scale, sourceRect: display.frame)
    }

    /// Whole-display settings. Freeze frames must match `captureArea`'s
    /// pixel for pixel — same resolution, no scaling, same colour space — or
    /// a selection cut from one would differ from a live capture of it.
    private static func displayConfiguration(
        for display: SCDisplay,
        scale: CGFloat,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    /// Captures a single window including its shadow-free bounds, independent
    /// of what is stacked on top of it.
    public func captureWindow(
        _ windowID: CGWindowID,
        showsCursor: Bool
    ) async throws -> CapturedImage {
        let content = try await fetchRawShareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NotchShotError.windowNotFound
        }

        let scale = await scaleForWindow(frame: window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Width and height are left at their defaults on purpose. The shadow is
        // part of the output, so the image is larger than `window.frame`; sizing
        // it to the frame (as the stream configuration used to) squeezed window
        // plus shadow into the frame's pixels, which resampled the window to about
        // 91% and softened every glyph. At the default size the window lands 1:1.
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = showsCursor
        configuration.includeChildWindows = true
        configuration.ignoreShadows = false
        configuration.dynamicRange = .sdr

        let image = try await captureScreenshot(filter: filter, configuration: configuration)

        // The shadow's extent is not reported, so the source rect is widened
        // evenly around the frame. Close enough for metadata; no pixel math
        // depends on it.
        let extraWidth = max(0, CGFloat(image.width) / scale - window.frame.width)
        let extraHeight = max(0, CGFloat(image.height) / scale - window.frame.height)
        let sourceRect = window.frame.insetBy(dx: -extraWidth / 2, dy: -extraHeight / 2)
        return CapturedImage(cgImage: image, scale: scale, sourceRect: sourceRect)
    }

    /// Everything the selection overlay needs before it can appear. The
    /// freeze frames deliberately exclude nothing but our own windows, so
    /// what the user sees frozen matches what was on screen.
    public struct SelectionPrelude: Sendable {
        public var freezeFrames: [CGDirectDisplayID: CapturedImage] = [:]
        /// The window inventory the freeze frames were taken against.
        public var inventory: ShareableSnapshot?
    }

    /// Freeze frames for every display and the window list, from a single
    /// ScreenCaptureKit inventory.
    ///
    /// The overlay used to wait for one inventory fetch per display (each
    /// freeze frame went through `captureDisplay`) plus a forced refresh for
    /// the window list: four ~32 ms fetches on a three-display desk, ~230 ms
    /// from the shortcut to the overlay. One fetch shared by all of them is
    /// ~110 ms. The captures themselves stay sequential — ScreenCaptureKit
    /// serialises them, so running them concurrently measured no faster.
    public func prepareSelection(
        displays displayIDs: [CGDirectDisplayID],
        scales: [CGDirectDisplayID: CGFloat],
        frontmostBundleID: String?,
        excludedWindows: Set<CGWindowID>
    ) async -> SelectionPrelude {
        guard let content = try? await fetchRawShareableContent() else { return SelectionPrelude() }
        let excluded = content.windows.filter { excludedWindows.contains($0.windowID) }
        var prelude = SelectionPrelude()
        for displayID in displayIDs {
            guard !Task.isCancelled else { break }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let scale = scales[displayID] ?? 2
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let configuration = Self.displayConfiguration(for: display, scale: scale, showsCursor: false)
            if let image = try? await captureImage(filter: filter, configuration: configuration) {
                prelude.freezeFrames[displayID] = CapturedImage(cgImage: image, scale: scale, sourceRect: display.frame)
            }
        }
        prelude.inventory = ShareableSnapshot(
            content: content,
            scales: scales,
            frontmostBundleID: frontmostBundleID
        )
        return prelude
    }

    /// A global CG-space rect cut out of a whole-display frame, as its own
    /// bitmap. Nil when the frame can't supply exactly what `captureArea`
    /// would have — the caller then captures live.
    ///
    /// The pixels are copied out rather than left as a `cropping(to:)` view:
    /// a view keeps the entire display buffer alive (22 MB on a Retina
    /// panel) for as long as the shelf, history or an editor holds the
    /// capture. The copy is a same-format, 1:1, `.copy` draw, measured
    /// byte-identical to the crop, ~1–3 ms.
    nonisolated static func cut(_ globalRect: CGRect, from frame: CapturedImage) -> CapturedImage? {
        let scale = frame.scale
        let display = frame.sourceRect
        // The frame must be the whole display at its backing scale.
        guard scale > 0,
              CGFloat(frame.cgImage.width) == (display.width * scale).rounded(),
              CGFloat(frame.cgImage.height) == (display.height * scale).rounded(),
              let clamped = ScreenGeometry.clamp(globalRect, to: display) else { return nil }

        let local = ScreenGeometry.displayLocalRect(globalCGRect: clamped, displayCGBounds: display)
        let size = ScreenGeometry.pixelSize(forPointRect: clamped, scale: scale)
        let origin = CGPoint(x: local.minX * scale, y: local.minY * scale)
        // Only whole-pixel cuts are the same as a live capture; anything else
        // would need resampling.
        guard abs(origin.x - origin.x.rounded()) < 0.001,
              abs(origin.y - origin.y.rounded()) < 0.001,
              size.width >= 1, size.height >= 1 else { return nil }
        let pixelRect = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        guard CGRect(x: 0, y: 0, width: frame.cgImage.width, height: frame.cgImage.height).contains(pixelRect),
              let view = frame.cgImage.cropping(to: pixelRect),
              view.width == Int(size.width), view.height == Int(size.height),
              let space = view.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: view.width,
                  height: view.height,
                  bitsPerComponent: view.bitsPerComponent,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: view.bitmapInfo.rawValue
              ) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(view, in: CGRect(x: 0, y: 0, width: view.width, height: view.height))
        guard let copy = context.makeImage() else { return nil }
        return CapturedImage(cgImage: copy, scale: scale, sourceRect: clamped)
    }

    // MARK: Plumbing

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        guard configuration.width > 0, configuration.height > 0 else {
            throw NotchShotError.captureFailed("Empty capture region")
        }
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            if CaptureService.isPermissionError(error) {
                throw NotchShotError.screenRecordingPermissionDenied
            }
            throw NotchShotError.captureFailed(error.localizedDescription)
        }
    }

    private func captureScreenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration
    ) async throws -> CGImage {
        do {
            // `SCScreenshotOutput` isn't Sendable, so only the CGImage crosses
            // back, in the same box every other capture uses.
            let box = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CapturedImage?, Error>) in
                SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                ) { output, error in
                    if let output {
                        let image = output.sdrImage.map {
                            CapturedImage(cgImage: $0, scale: 1, sourceRect: .zero)
                        }
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? NotchShotError.captureFailed("No image returned"))
                    }
                }
            }
            guard let image = box?.cgImage, image.width > 0, image.height > 0 else {
                throw NotchShotError.captureFailed("Empty capture region")
            }
            return image
        } catch let error as NotchShotError {
            throw error
        } catch {
            if CaptureService.isPermissionError(error) {
                throw NotchShotError.screenRecordingPermissionDenied
            }
            throw NotchShotError.captureFailed(error.localizedDescription)
        }
    }

    private func scale(for displayID: CGDirectDisplayID) async -> CGFloat {
        await MainActor.run {
            ScreenLookup.screen(for: displayID)?.backingScaleFactor ?? 2
        }
    }

    /// A window's scale is that of the display it mostly sits on — capturing a
    /// window dragged onto a 1× external display at 2× would double its size.
    private func scaleForWindow(frame: CGRect) async -> CGFloat {
        await MainActor.run {
            ScreenLookup.screen(bestMatchingCGRect: frame)?.backingScaleFactor ?? 2
        }
    }

    private nonisolated func area(of rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    /// ScreenCaptureKit reports a revoked or never-granted TCC entitlement as
    /// `userDeclined`, which needs different remediation from a real failure.
    public nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return false }
        return nsError.code == -3801 // SCStreamErrorUserDeclined
    }
}
