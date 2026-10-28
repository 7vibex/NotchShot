import Foundation
import IOKit.pwr_mgt
import Observation

/// How long the Mac is kept awake, as the menu offers it.
public enum KeepAwakeChoice: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case oneHour
    case untilTurnedOff
    /// Only while an AI agent reports that it is working. The display may
    /// sleep; the Mac doesn't, so a long run isn't cut off by idle sleep.
    case whileAgentsWork

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fifteenMinutes: "For 15 Minutes"
        case .oneHour: "For 1 Hour"
        case .untilTurnedOff: "Until Turned Off"
        case .whileAgentsWork: "While Agents Work"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .untilTurnedOff, .whileAgentsWork: nil
        }
    }
}

/// What Keep Awake is doing, reduced to what the power assertion needs.
public enum KeepAwakeMode: Equatable, Sendable {
    case off
    case until(Date)
    case indefinitely
    case whileAgentsWork

    /// The IOKit assertion this mode holds right now, or nil for none.
    /// Timed and indefinite modes keep the display on, as the `caffeinate -d`
    /// people reach for does. The agent mode only keeps the Mac itself awake,
    /// and only while an agent is working.
    static func assertionType(for mode: KeepAwakeMode, agentsWorking: Bool, now: Date) -> String? {
        switch mode {
        case .off: nil
        case .until(let end): end > now ? kIOPMAssertPreventUserIdleDisplaySleep : nil
        case .indefinitely: kIOPMAssertPreventUserIdleDisplaySleep
        case .whileAgentsWork: agentsWorking ? kIOPMAssertPreventUserIdleSystemSleep : nil
        }
    }
}

/// Keeps the Mac from idle-sleeping, from the menu bar's Keep Awake switch.
///
/// One power assertion at a time, released the moment the mode ends. Nothing
/// is persisted: a relaunch always starts with the Mac free to sleep.
@MainActor
@Observable
public final class KeepAwakeController {
    public static let shared = KeepAwakeController()

    public private(set) var mode: KeepAwakeMode = .off
    public private(set) var isHoldingAssertion = false
    public var isOn: Bool { mode != .off }

    /// Told about every change, so the notch can redraw its status glyph.
    @ObservationIgnored var onChange: (() -> Void)?
    /// A timed mode ran out on its own.
    @ObservationIgnored var onExpire: (() -> Void)?

    @ObservationIgnored private var assertionID = IOPMAssertionID(0)
    @ObservationIgnored private var assertionType: String?
    @ObservationIgnored private var agentsWorking = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init() {}

    public func turnOn(_ choice: KeepAwakeChoice, now: Date = Date()) {
        switch choice {
        case .whileAgentsWork: mode = .whileAgentsWork
        case .untilTurnedOff: mode = .indefinitely
        case .fifteenMinutes, .oneHour:
            mode = .until(now.addingTimeInterval(choice.duration ?? 0))
        }
        scheduleExpiry()
        apply()
    }

    public func turnOff() {
        guard mode != .off else { return }
        mode = .off
        expiryTask?.cancel()
        expiryTask = nil
        apply()
    }

    /// Fed from the agent activity sources; only the agent mode reads it.
    func setAgentsWorking(_ working: Bool) {
        guard working != agentsWorking else { return }
        agentsWorking = working
        if mode == .whileAgentsWork { apply() }
    }

    /// Time left on a timed mode, for the menu's caption.
    public func remaining(now: Date = Date()) -> TimeInterval? {
        guard case .until(let end) = mode else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard case .until(let end) = mode else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.mode == .until(end) else { return }
            self.mode = .off
            self.apply()
            self.onExpire?()
        }
    }

    private func apply() {
        let wanted = KeepAwakeMode.assertionType(for: mode, agentsWorking: agentsWorking, now: Date())
        if wanted != assertionType {
            release()
            if let wanted {
                var id = IOPMAssertionID(0)
                let status = IOPMAssertionCreateWithName(
                    wanted as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "NotchShot Keep Awake" as CFString,
                    &id
                )
                if status == kIOReturnSuccess {
                    assertionID = id
                    assertionType = wanted
                } else {
                    Log.app.error("Keep Awake couldn't hold a power assertion (\(status))")
                }
            }
        }
        let holding = assertionType != nil
        if holding != isHoldingAssertion { isHoldingAssertion = holding }
        onChange?()
    }

    private func release() {
        guard assertionType != nil else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        assertionType = nil
    }
}
