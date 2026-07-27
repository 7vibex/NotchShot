import Foundation

/// Turns macOS's own screenshot shortcuts off so NotchShot can use them.
///
/// ⇧⌘4 and ⇧⌘5 belong to the system, not to any app: they are symbolic
/// hotkeys, dispatched by the window server before an app-registered hotkey
/// ever sees the key press. Registering the same combination while the system
/// still owns it silently loses. So the system one is switched off first, via
/// CGSSetSymbolicHotKeyEnabled — resolved at runtime from SkyLight, the same
/// way brightness is read, with nothing linked or patched.
///
/// This changes a system setting, so every claimed key is persisted before it
/// is disabled and restored eagerly when the preference is switched off or the
/// app quits. On the next launch, only claims left by this app are recovered;
/// shortcuts the user had already disabled are never silently turned back on.
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

    private typealias CGSSetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias CGSIsEnabled = @convention(c) (Int32) -> Bool

    private let setEnabled: ((Int32, Bool) -> Int32)?
    private let isEnabled: ((Int32) -> Bool)?
    private let defaults: UserDefaults
    private let claimsKey = "notchshot.systemScreenshotHotKeyClaims.v1"
    /// Keys this app switched off, persisted so a crash cannot erase ownership.
    private var claimed: Set<SymbolicHotKey>

    /// Taking ownership safely requires both mutation and an ownership check.
    public var isAvailable: Bool { setEnabled != nil && isEnabled != nil }

    public init() {
        defaults = .standard
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        if let handle, let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") {
            let function = unsafeBitCast(symbol, to: CGSSetEnabled.self)
            setEnabled = { function($0, $1) }
        } else {
            setEnabled = nil
        }
        if let handle, let symbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") {
            let function = unsafeBitCast(symbol, to: CGSIsEnabled.self)
            isEnabled = { function($0) }
        } else {
            isEnabled = nil
        }
        claimed = Self.loadClaims(from: defaults, key: claimsKey)
    }

    /// Test seam for the ownership and crash-recovery rules. Production always
    /// resolves the two SkyLight functions above at runtime.
    init(
        defaults: UserDefaults,
        setEnabled: ((Int32, Bool) -> Int32)?,
        isEnabled: ((Int32) -> Bool)?
    ) {
        self.defaults = defaults
        self.setEnabled = setEnabled
        self.isEnabled = isEnabled
        claimed = Self.loadClaims(from: defaults, key: claimsKey)
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
        for key in claimed.subtracting(keys) {
            restore(key)
        }
        for key in keys where !claimed.contains(key) {
            // A disabled shortcut may be an intentional user preference. If
            // macOS does not currently own it, NotchShot has nothing to take
            // and, crucially, nothing it is entitled to restore later.
            guard systemOwns(key) else {
                Log.app.notice("Leaving user-disabled shortcut \(key.title) unchanged")
                continue
            }

            // Persist ownership before changing the system. A crash in the
            // tiny gap after the CGS call can then be repaired next launch.
            claimed.insert(key)
            persistClaims()
            guard setEnabled?(Int32(key.rawValue), false) == 0 else {
                claimed.remove(key)
                persistClaims()
                Log.app.notice("Could not release \(key.title) from macOS")
                continue
            }
            Log.app.notice("\(key.title) reassigned to NotchShot")
        }
    }

    /// Called at launch, when the preference is switched off, and on quit. The
    /// persisted set contains only shortcuts NotchShot proved were enabled
    /// before it took them.
    public func restoreAll() {
        guard setEnabled != nil else { return }
        for key in claimed {
            restore(key)
        }
    }

    private func restore(_ key: SymbolicHotKey) {
        guard claimed.contains(key) else { return }
        if systemOwns(key) {
            claimed.remove(key)
            persistClaims()
            return
        }
        guard setEnabled?(Int32(key.rawValue), true) == 0 else {
            Log.app.error("Could not return \(key.title) to macOS")
            return
        }
        claimed.remove(key)
        persistClaims()
    }

    private func persistClaims() {
        defaults.set(claimed.map(\.rawValue).sorted(), forKey: claimsKey)
    }

    private static func loadClaims(
        from defaults: UserDefaults,
        key: String
    ) -> Set<SymbolicHotKey> {
        let values = defaults.array(forKey: key) as? [Int] ?? []
        return Set(values.compactMap(SymbolicHotKey.init(rawValue:)))
    }
}
