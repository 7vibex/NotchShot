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

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB

        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, scale: scale, sourceRect: display.frame)
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

        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.includeChildWindows = true
        configuration.ignoreShadowsSingleWindow = false
        configuration.colorSpaceName = CGColorSpace.sRGB

        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, scale: scale, sourceRect: window.frame)
    }

    /// Full-screen grab used to freeze the display behind a selection overlay.
    /// Deliberately excludes nothing but our own windows so what the user sees
    /// frozen matches what was on screen.
    public func captureFreezeFrame(
        displayID: CGDirectDisplayID,
        excludedWindows: Set<CGWindowID>
    ) async throws -> CapturedImage {
        try await captureDisplay(displayID, excludedWindows: excludedWindows, showsCursor: false)
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
