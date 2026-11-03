import AppKit
import Foundation
import Observation

/// What `-[CBBlueLightClient getBlueLightStatus:]` writes, read from its C
/// layout: `active`, `enabled`, `sunSchedulePermitted` (one byte each), an
/// `int` mode, the from/to schedule (four `int`s), a 64-bit `disableFlags`,
/// then `available`.
struct NightShiftStatus: Equatable {
    static let byteCount = 40

    /// Warm right now, whether switched on by hand or by the schedule.
    var isEnabled: Bool
    /// 0 off, 1 sunset to sunrise, 2 custom hours.
    var mode: Int32
    var isAvailable: Bool

    init(isEnabled: Bool, mode: Int32, isAvailable: Bool) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.isAvailable = isAvailable
    }

    init?(bytes: [UInt8]) {
        guard bytes.count >= Self.byteCount else { return nil }
        isEnabled = bytes[1] != 0
        mode = bytes[4 ..< 8].reversed().reduce(0) { $0 << 8 | Int32($1) }
        isAvailable = bytes[32] != 0
    }
}

/// Night Shift and Dark Mode, for the menu-bar panel.
///
/// Neither has public API. Night Shift is CoreBrightness's
/// `CBBlueLightClient`, the object System Settings and Control Center use;
/// Dark Mode is SkyLight's appearance switch. Both are looked up at run time,
/// so a macOS that removes them hides the rows instead of crashing.
@MainActor
@Observable
public final class NightShiftController {
    public static let shared = NightShiftController()

    public private(set) var isAvailable = false
    public private(set) var isOn = false
    /// 0…1, the warmth slider in System Settings.
    public private(set) var strength = 0.5

    public private(set) var isDarkModeAvailable = false
    public private(set) var isDarkMode = false

    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetStrength = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias GetAppearance = @convention(c) () -> Bool
    private typealias SetAppearance = @convention(c) (Bool) -> Void

    @ObservationIgnored private let client: NSObject?
    @ObservationIgnored private let getAppearance: GetAppearance?
    @ObservationIgnored private let setAppearance: SetAppearance?

    private init() {
        if Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
           let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type,
           (type as AnyObject).responds(to: NSSelectorFromString("supportsBlueLightReduction")) {
            let client = type.init()
            let selectors = ["getBlueLightStatus:", "setEnabled:", "getStrength:", "setStrength:commit:"]
            self.client = selectors.allSatisfy { client.responds(to: NSSelectorFromString($0)) } ? client : nil
        } else {
            client = nil
        }
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        getAppearance = skyLight.flatMap { dlsym($0, "SLSGetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: GetAppearance.self) }
        setAppearance = skyLight.flatMap { dlsym($0, "SLSSetAppearanceThemeLegacy") }.map { unsafeBitCast($0, to: SetAppearance.self) }
        refresh()
    }

    /// Re-reads both, for when the menu opens: either can change from
    /// Control Center, System Settings or the schedule.
    public func refresh() {
        if let status = readStatus() {
            isAvailable = status.isAvailable
            isOn = status.isEnabled
        } else {
            isAvailable = false
            isOn = false
        }
        if let value = readStrength() { strength = value }
        isDarkModeAvailable = getAppearance != nil && setAppearance != nil
        isDarkMode = getAppearance?() ?? false
    }

    public func setOn(_ on: Bool) {
        let selector = NSSelectorFromString("setEnabled:")
        guard let client, isAvailable else { return }
        let set = unsafeBitCast(client.method(for: selector), to: SetEnabled.self)
        if set(client, selector, on) { isOn = on }
    }

    /// - Parameter isFinal: false while a slider is dragged; only the last
    ///   value is saved as the user's warmth.
    public func setStrength(_ value: Double, isFinal: Bool) {
        let selector = NSSelectorFromString("setStrength:commit:")
        guard let client, isAvailable else { return }
        let clamped = min(max(value, 0), 1)
        // Warmth only shows while Night Shift is on, the way the slider in
        // System Settings previews it.
        if !isOn { setOn(true) }
        let set = unsafeBitCast(client.method(for: selector), to: SetStrength.self)
        if set(client, selector, Float(clamped), isFinal) { strength = clamped }
    }

    public func setDarkMode(_ dark: Bool) {
        guard let setAppearance else { return }
        setAppearance(dark)
        isDarkMode = getAppearance?() ?? dark
    }

    private func readStatus() -> NightShiftStatus? {
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let client else { return nil }
        let get = unsafeBitCast(client.method(for: selector), to: GetStatus.self)
        // Room to spare, in case a later macOS grows the struct.
        var bytes = [UInt8](repeating: 0, count: 128)
        let ok = bytes.withUnsafeMutableBytes { get(client, selector, $0.baseAddress!) }
        return ok ? NightShiftStatus(bytes: bytes) : nil
    }

    private func readStrength() -> Double? {
        let selector = NSSelectorFromString("getStrength:")
        guard let client else { return nil }
        let get = unsafeBitCast(client.method(for: selector), to: GetStrength.self)
        var value: Float = 0
        return get(client, selector, &value) ? Double(min(max(value, 0), 1)) : nil
    }
}
