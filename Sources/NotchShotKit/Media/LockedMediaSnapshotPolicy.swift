import Foundation

/// Keeps the last confirmed track stable across the secure-session boundary.
///
/// Media bridges can temporarily lose access to their source while loginwindow
/// owns the display. Treating that transient empty result as "playback ended"
/// removes the very panel the user opted into. A real non-empty update is still
/// accepted while locked, and all updates become authoritative after unlock.
enum LockedMediaSnapshotPolicy {
    static func acceptedUpdate(
        current: MediaSnapshot,
        proposed: MediaSnapshot,
        sessionIsActive: Bool
    ) -> MediaSnapshot? {
        if sessionIsActive || proposed.hasContent || !current.hasContent {
            return proposed
        }
        return nil
    }

    static func shouldClearAfterStreamEnds(sessionIsActive: Bool) -> Bool {
        sessionIsActive
    }
}
