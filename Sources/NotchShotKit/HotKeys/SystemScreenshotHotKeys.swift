import Foundation

/// Turns macOS's own screenshot shortcuts off so NotchShot can use them.
///
/// ⇧⌘4 and ⇧⌘5 belong to the system, not to any app: they are *symbolic
/// hotkeys*, dispatched by the window server before an app-registered hotkey
/// ever sees the key press. Registering the same combination while the system
/// still owns it silently loses. So the system one is switched off first, via
/// `CGSSetSymbolicHotKeyEnabled` — resolved at runtime from SkyLight, the same
/// way brightness is read, with nothing linked or patched.
///
/// This changes a system setting, so it is reversible and reversed eagerly:
/// switching the preference off, or quitting, restores every shortcut this took.
/// `restoreAll` also runs at launch, so a crash costs one relaunch rather than a
/// trip to System Settings to get ⇧⌘4 back.
@MainActor
public final class SystemScreenshotHotKeys {
    public static let shared = SystemScreenshotHotKeys()

    /// The identifiers macOS uses for its screenshot shortcuts.
    public enum SymbolicHotKey: Int, CaseIterable, Sendable {
        /// ⇧⌘3 — whole screen to a file.
        case fullScreenToFile = 28
        /// ⌃⇧⌘3 — whole screen to the clipboard.
        case fullScreenToClipboard = 29
        /// ⇧⌘4 — selected area to a file.
        case areaToFile = 30
        /// ⌃⇧⌘4 — selected area to the clipboard.
        case areaToClipboard = 31
        /// ⇧⌘5 — the screenshot and recording panel.
        case screenshotPanel = 184

        var title: String {
            switch self {
            case .fullScreenToFile: "⇧⌘3"
            case .fullScreenToClipboard: "⌃⇧⌘3"
            case .areaToFile: "⇧⌘4"
            case .areaToClipboard: "⌃⇧⌘4"
            case .screenshotPanel: "⇧⌘5"
            }
        }
    }

    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    private let setEnabled: SetEnabled?
    private let isEnabled: IsEnabled?
    /// Keys this app switched off, so only those get switched back on.
    private var disabled: Set<SymbolicHotKey> = []

    public var isAvailable: Bool { setEnabled != nil }

    public init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        if let handle, let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") {
            setEnabled = unsafeBitCast(symbol, to: SetEnabled.self)
        } else {
            setEnabled = nil
        }
        if let handle, let symbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") {
            isEnabled = unsafeBitCast(symbol, to: IsEnabled.self)
        } else {
            isEnabled = nil
        }
    }

    /// Whether macOS currently owns this shortcut.
    public func systemOwns(_ key: SymbolicHotKey) -> Bool {
        isEnabled?(Int32(key.rawValue)) ?? false
    }

    /// Hands the listed shortcuts to NotchShot and gives back any it previously
    /// took that are no longer wanted.
    public func takeOver(_ keys: Set<SymbolicHotKey>) {
        guard isAvailable else {
            Log.app.notice("Cannot reassign system screenshot shortcuts on this system")
            return
        }
        for key in disabled.subtracting(keys) {
            restore(key)
        }
        for key in keys where !disabled.contains(key) {
            guard setEnabled?(Int32(key.rawValue), false) == 0 else {
                Log.app.notice("Could not release \(key.title) from macOS")
                continue
            }
            disabled.insert(key)
            Log.app.notice("\(key.title) reassigned to NotchShot")
        }
    }

    /// Gives every shortcut back to macOS.
    ///
    /// Called when the preference is switched off and again on quit. It also
    /// runs at launch against *all* known keys, not just the ones this instance
    /// disabled, because a crash leaves no record of what was taken.
    public func restoreAll(includingUnknown: Bool = false) {
        guard isAvailable else { return }
        for key in includingUnknown ? Set(SymbolicHotKey.allCases) : disabled {
            restore(key)
        }
        disabled.removeAll()
    }

    private func restore(_ key: SymbolicHotKey) {
        guard setEnabled?(Int32(key.rawValue), true) == 0 else {
            Log.app.error("Could not return \(key.title) to macOS")
            return
        }
        disabled.remove(key)
    }
}
