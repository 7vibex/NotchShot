import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A `Sendable` snapshot of one capturable window, so window picking never has
/// to pass `SCWindow` across an actor boundary.
public struct WindowInfo: Sendable, Identifiable, Equatable {
    public let id: CGWindowID
    /// Global CG-space (top-left origin) frame, in points.
    public let frame: CGRect
    public let title: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let layer: Int
    public let isOnScreen: Bool
    public let isActive: Bool

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return applicationName ?? "Window"
    }
}

public struct DisplayInfo: Sendable, Identifiable, Equatable {
    public let id: CGDirectDisplayID
    /// Global CG-space (top-left origin) frame, in points.
    public let frame: CGRect
    public let scale: CGFloat
}

/// Everything currently capturable, in `Sendable` form.
public struct ShareableSnapshot: Sendable {
    public var displays: [DisplayInfo]
    public var windows: [WindowInfo]

    /// Windows worth offering to the user: normal layer, on screen, not
    /// hairline-thin, and not one of ours.
    public func selectableWindows(excluding excluded: Set<CGWindowID>) -> [WindowInfo] {
        windows.filter { window in
            window.isOnScreen
                && window.layer == 0
                && window.frame.width > 40
                && window.frame.height > 40
                && !excluded.contains(window.id)
                && window.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    /// Topmost selectable window under a global CG-space point. ScreenCaptureKit
    /// returns windows front-to-back, so the first hit wins.
    public func window(at point: CGPoint, excluding excluded: Set<CGWindowID>) -> WindowInfo? {
        selectableWindows(excluding: excluded).first { $0.frame.contains(point) }
    }

    public func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    public func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }
}

/// Fetches and caches `SCShareableContent`.
///
/// The fetch is not cheap and blocks briefly, so selection overlays grab one
/// snapshot up front rather than querying per mouse-move.
public actor ShareableContentProvider {
    public static let shared = ShareableContentProvider()

    private var cached: ShareableSnapshot?
    private var cachedAt: Date?
    private let cacheLifetime: TimeInterval = 0.75

    public init() {}

    public func invalidate() {
        cached = nil
        cachedAt = nil
    }

    public func snapshot(forceRefresh: Bool = false) async throws -> ShareableSnapshot {
        if !forceRefresh,
           let cached,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cached
        }

        let content = try await fetchRawShareableContent()

        let scales = await MainActor.run { () -> [CGDirectDisplayID: CGFloat] in
            var map: [CGDirectDisplayID: CGFloat] = [:]
            for screen in NSScreen.screens {
                if let id = ScreenLookup.displayID(for: screen) {
                    map[id] = screen.backingScaleFactor
                }
            }
            return map
        }

        let displays = content.displays.map { display in
            DisplayInfo(
                id: display.displayID,
                frame: display.frame,
                scale: scales[display.displayID] ?? 2
            )
        }

        let frontmostBundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }

        let windows = content.windows.map { window in
            WindowInfo(
                id: window.windowID,
                frame: window.frame,
                title: window.title,
                applicationName: window.owningApplication?.applicationName,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                isActive: window.owningApplication?.bundleIdentifier == frontmostBundleID
            )
        }

        let snapshot = ShareableSnapshot(displays: displays, windows: windows)
        cached = snapshot
        cachedAt = Date()
        return snapshot
    }

}

enum ShareableContentRetryPolicy {
    static let maximumAttempts = 2

    static func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maximumAttempts
    }
}

/// Fetches the raw ScreenCaptureKit objects a capture or recording needs.
///
/// Deliberately `nonisolated` and free-standing: `SCShareableContent` is not
/// `Sendable`, and a freshly-created value returned from a nonisolated async
/// function stays in the caller's isolation region, so it can be used inside an
/// actor without an unsafe escape hatch.
func fetchRawShareableContent() async throws -> SCShareableContent {
    do {
        for attempt in 1 ... ShareableContentRetryPolicy.maximumAttempts {
            if attempt > 1 {
                // replayd can briefly publish an empty inventory after wake or
                // a display-mode change. One fresh request repairs the transient
                // case without creating a capture loop or masking a stuck service.
                try await Task.sleep(for: .milliseconds(300))
            }

            // Use one inventory policy for the picker, screenshots, and recording.
            // On macOS 26 the older filtered query can be empty for accessory apps
            // even when the complete public inventory contains usable displays.
            var content = try await SCShareableContent.current
            if !content.displays.isEmpty { return content }

            Log.capture.notice(
                "ScreenCaptureKit returned no displays for the full inventory; retrying the filtered query"
            )
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            if !content.displays.isEmpty { return content }

            if ShareableContentRetryPolicy.shouldRetry(afterAttempt: attempt) {
                Log.capture.notice("ScreenCaptureKit inventory is still empty; making one fresh request")
            }
        }
        throw NotchShotError.noShareableContent
    } catch {
        if error is CancellationError { throw error }
        Log.capture.error("SCShareableContent failed: \(error.localizedDescription)")
        if !CGPreflightScreenCaptureAccess() {
            throw NotchShotError.screenRecordingPermissionDenied
        }
        if let notchShotError = error as? NotchShotError {
            throw notchShotError
        }
        throw NotchShotError.noShareableContent
    }
}
