import AppKit
import Intents
import Observation
import Security

/// Whether a Focus burst should fire for a pair of readings. Only a real
/// transition between two known states counts: the first reading after launch,
/// or an unreadable status, is never announced.
enum FocusTransitionPolicy {
    static func transition(previous: Bool?, current: Bool?) -> Bool? {
        guard let previous, let current, previous != current else { return nil }
        return current
    }
}

/// Focus on/off, through the only public API macOS offers.
///
/// `INFocusStatusCenter` reports a single Boolean, requires the user's
/// authorization, and is only available to apps signed with the Communication
/// Notifications capability. It posts no change notification and never
/// exposes which Focus is active. So this monitor:
/// - stays `.unavailable` (and does nothing) in builds without the entitlement,
/// - re-reads on workspace events that commonly accompany a Focus change
///   (wake, Space change, app activation) plus a slow backstop while enabled,
/// - reports on/off only — never a Focus name it cannot know.
@MainActor
@Observable
public final class FocusStatusMonitor {
    public enum Availability: Equatable, Sendable {
        /// This build is not entitled to read Focus status.
        case unavailable
        case notDetermined
        case denied
        case authorized
    }

    public static let shared = FocusStatusMonitor()
    static let entitlement = "com.apple.developer.usernotifications.communication"
    static let backstopInterval: TimeInterval = 30

    public private(set) var availability: Availability = .unavailable
    public private(set) var isFocused: Bool?
    /// Fires with the new state on a real transition only.
    public var onTransition: ((Bool) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backstop: Timer?
    @ObservationIgnored private var isRunning = false

    public init() {
        availability = Self.readAvailability()
    }

    public func start() {
        availability = Self.readAvailability()
        guard availability == .authorized, !isRunning else { return }
        isRunning = true
        isFocused = Self.readFocused()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let timer = Timer(timeInterval: Self.backstopInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        backstop = timer
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        backstop?.invalidate()
        backstop = nil
        isFocused = nil
    }

    /// Asks for Focus status access. A no-op in unentitled builds.
    public func requestAuthorization(completion: (@MainActor (Availability) -> Void)? = nil) {
        guard Self.hasEntitlement else {
            availability = .unavailable
            completion?(.unavailable)
            return
        }
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            Task { @MainActor in
                let availability = Self.readAvailability()
                self?.availability = availability
                completion?(availability)
            }
        }
    }

    func refresh() {
        guard isRunning else { return }
        let current = Self.readFocused()
        if let changed = FocusTransitionPolicy.transition(previous: isFocused, current: current) {
            onTransition?(changed)
        }
        if current != nil { isFocused = current }
    }

    // MARK: System reads

    static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }

    private static func readAvailability() -> Availability {
        guard hasEntitlement else { return .unavailable }
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func readFocused() -> Bool? {
        guard hasEntitlement,
              INFocusStatusCenter.default.authorizationStatus == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }
}
