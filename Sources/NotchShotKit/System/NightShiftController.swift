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

/// The calls into CoreBrightness and SkyLight, none of which belongs on main.
/// Loading the two frameworks and the first appearance call together took
/// about 150 ms, and each later read is a call to a daemon. Reads run off main
/// and changes on it, and nothing says `CBBlueLightClient` can take both at
/// once, so every call goes through `queue`. The work there never needs main,
/// so a change on main waits at most for the read in front of it.
private final class NightShiftBackend: @unchecked Sendable {
    /// Created off main at launch by `NightShiftController.preload()`.
    static let shared = NightShiftBackend()

    struct Reading: Sendable {
        var status: NightShiftStatus?
        var strength: Double?
        var isDarkModeAvailable: Bool
        var isDarkMode: Bool
    }

    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetStrength = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias GetAppearance = @convention(c) () -> Bool
    private typealias SetAppearance = @convention(c) (Bool) -> Void

    private let queue = DispatchQueue(label: "com.notchshot.night-shift", qos: .userInitiated)
    private let client: NSObject?
    private let getAppearance: GetAppearance?
    private let setAppearance: SetAppearance?
    /// The read made while loading, so the first open of the menu has its rows
    /// without calling anything: the panel is measured once, as it opens.
    private(set) var firstReading = Reading(status: nil, strength: nil, isDarkModeAvailable: false, isDarkMode: false)

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
        firstReading = read()
    }

    func read() -> Reading {
        queue.sync {
            Reading(
                status: readStatus(),
                strength: readStrength(),
                isDarkModeAvailable: getAppearance != nil && setAppearance != nil,
                isDarkMode: getAppearance?() ?? false
            )
        }
    }

    var hasNightShift: Bool { client != nil }

    func setEnabled(_ on: Bool) -> Bool {
        let selector = NSSelectorFromString("setEnabled:")
        guard let client else { return false }
        let set = unsafeBitCast(client.method(for: selector), to: SetEnabled.self)
        return queue.sync { set(client, selector, on) }
    }

    func setStrength(_ value: Double, commit: Bool) -> Bool {
        let selector = NSSelectorFromString("setStrength:commit:")
        guard let client else { return false }
        let set = unsafeBitCast(client.method(for: selector), to: SetStrength.self)
        return queue.sync { set(client, selector, Float(value), commit) }
    }

    /// The appearance after the change, or nil if there is no way to change it.
    func setDarkMode(_ dark: Bool) -> Bool? {
        guard let setAppearance else { return nil }
        return queue.sync {
            setAppearance(dark)
            return getAppearance?() ?? dark
        }
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

    @ObservationIgnored private let backend = NightShiftBackend.shared
    /// Bumped by every read and every change, so a read that was already under
    /// way can't put back what the user just changed.
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var pendingStrength: Double?
    /// What Night Shift really uses during a drag, for the bar to return to if
    /// the drag's last value is refused.
    @ObservationIgnored private var appliedDragStrength: Double?
    @ObservationIgnored private var strengthFlush: Task<Void, Never>?

    /// Loads the frameworks ahead of the first menu open. If that open still
    /// beats it, the menu waits for the load, as it always did.
    public nonisolated static func preload() {
        Task.detached(priority: .utility) { _ = NightShiftBackend.shared }
    }

    private init() {
        apply(backend.firstReading)
    }

    /// Re-reads both, for when the menu opens: either can change from
    /// Control Center, System Settings or the schedule.
    public func refresh() {
        readGeneration += 1
        let generation = readGeneration
        let backend = self.backend
        Task.detached(priority: .userInitiated) { [weak self] in
            let reading = backend.read()
            await self?.deliver(reading, generation: generation)
        }
    }

    private func deliver(_ reading: NightShiftBackend.Reading, generation: Int) {
        guard generation == readGeneration else { return }
        apply(reading)
    }

    private func apply(_ reading: NightShiftBackend.Reading) {
        if let status = reading.status {
            isAvailable = status.isAvailable
            isOn = status.isEnabled
        } else {
            isAvailable = false
            isOn = false
        }
        if let value = reading.strength { strength = value }
        isDarkModeAvailable = reading.isDarkModeAvailable
        isDarkMode = reading.isDarkMode
    }

    public func setOn(_ on: Bool) {
        guard backend.hasNightShift, isAvailable else { return }
        readGeneration += 1
        if backend.setEnabled(on) { isOn = on }
    }

    /// - Parameter isFinal: false while a slider is dragged; the bar follows
    ///   every pointer event, Night Shift gets one value a frame, and only the
    ///   last is saved as the user's warmth.
    public func setStrength(_ value: Double, isFinal: Bool) {
        guard backend.hasNightShift, isAvailable else { return }
        readGeneration += 1
        let clamped = min(max(value, 0), 1)
        // Warmth only shows while Night Shift is on, the way the slider in
        // System Settings previews it.
        if !isOn { setOn(true) }
        guard isFinal else {
            if appliedDragStrength == nil { appliedDragStrength = strength }
            strength = clamped
            pendingStrength = clamped
            if strengthFlush == nil {
                strengthFlush = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(16))
                    self?.flushStrength()
                }
            }
            return
        }
        pendingStrength = nil
        let strengthBeforeDrag = appliedDragStrength
        appliedDragStrength = nil
        if backend.setStrength(clamped, commit: true) {
            strength = clamped
        } else if let strengthBeforeDrag {
            strength = strengthBeforeDrag
        }
    }

    /// Commits a drag whose last event never came because the menu closed under it.
    public func finishDrag() {
        guard appliedDragStrength != nil else { return }
        setStrength(strength, isFinal: true)
    }

    private func flushStrength() {
        strengthFlush = nil
        guard let pendingStrength else { return }
        self.pendingStrength = nil
        if backend.setStrength(pendingStrength, commit: false) { appliedDragStrength = pendingStrength }
    }

    public func setDarkMode(_ dark: Bool) {
        guard let result = backend.setDarkMode(dark) else { return }
        readGeneration += 1
        isDarkMode = result
    }
}
