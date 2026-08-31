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
}
