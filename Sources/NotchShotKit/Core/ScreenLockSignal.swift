import CoreGraphics
import Foundation

/// The screen lock is distinct from an AppKit user-session switch.
///
/// `NSWorkspace.sessionDidResignActiveNotification` is documented for Fast
/// User Switching and doesn't fire for Control-Command-Q. loginwindow posts
/// these distributed notifications when the secure Lock Screen is raised and
/// lowered, which lets NotchShot stop interactive UI and request a
/// system-owned notification without trying to draw over password controls.
enum ScreenLockSignal {
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    static func sessionIsActive(for notificationName: Notification.Name) -> Bool? {
        switch notificationName {
        case lockedNotification: false
        case unlockedNotification: true
        default: nil
        }
    }

    struct State: Equatable {
        var sessionIsActive: Bool
        var screenIsLocked: Bool
    }

    /// The state right now. A launch on a locked Mac happens after both
    /// notifications went out, so without this every observer would run as
    /// unlocked until the next lock.
    static func current() -> State {
        state(from: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// No session dictionary means no window-server session to ask about;
    /// that keeps the old assumption, active and unlocked.
    static func state(from session: [String: Any]?) -> State {
        guard let session else { return State(sessionIsActive: true, screenIsLocked: false) }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session[kCGSessionOnConsoleKey] as? Bool ?? true
        return State(sessionIsActive: onConsole && !locked, screenIsLocked: locked)
    }
}
