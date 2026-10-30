import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import Observation

/// Locks the keyboard for a minute so it can be wiped without typing into
/// whatever is open. The mouse and trackpad keep working, so the lock can
/// always be ended early from the menu bar.
///
/// An event tap swallows key presses, modifier changes and the media keys.
/// Swallowing keys needs Accessibility, which NotchShot already asks for
/// elsewhere; without it nothing is locked and `start` throws.
@MainActor
@Observable
public final class KeyboardCleaningController {
    public static let shared = KeyboardCleaningController()

    /// Long enough to wipe a keyboard, short enough that a forgotten lock
    /// gives the keyboard back on its own.
    public static let duration: TimeInterval = 60

    public private(set) var endsAt: Date?
    public var isActive: Bool { endsAt != nil }

    @ObservationIgnored var onChange: (() -> Void)?

    /// See `SystemMediaKeyInterceptor.tap` for why this is unsafe.
    @ObservationIgnored private nonisolated(unsafe) var eventTap: EventTapThread?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    init() {}

    deinit {
        eventTap?.stop()
    }

    public enum StartError: LocalizedError {
        case needsAccessibility
        case tapUnavailable

        public var errorDescription: String? {
            switch self {
            case .needsAccessibility:
                "Locking the keyboard needs Accessibility. Turn NotchShot on in Privacy & Security, then try again."
            case .tapUnavailable:
                "macOS didn't let NotchShot lock the keyboard."
            }
        }
    }

    public func start(now: Date = Date()) throws {
        if isActive {
            schedule(end: now.addingTimeInterval(Self.duration))
            return
        }
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw StartError.needsAccessibility
        }
        let mask = KeyboardCleaningPolicy.swallowedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // On its own thread, so a busy main thread can't make WindowServer
        // switch the lock off mid-wipe and let key presses through.
        guard let tap = EventTapThread(
            name: "NotchShot.KeyboardCleaningTap",
            eventsOfInterest: mask,
            filter: { type, event in
                let subtype = type == KeyboardCleaningPolicy.systemDefined
                    ? NSEvent(cgEvent: event).map { Int($0.subtype.rawValue) }
                    : nil
                return KeyboardCleaningPolicy.swallows(type: type, systemDefinedSubtype: subtype)
            }
        ) else {
            throw StartError.tapUnavailable
        }
        eventTap = tap
        schedule(end: now.addingTimeInterval(Self.duration))
    }

    public func stop() {
        endTask?.cancel()
        endTask = nil
        eventTap?.stop()
        eventTap = nil
        guard endsAt != nil else { return }
        endsAt = nil
        onChange?()
    }

    public func remaining(now: Date = Date()) -> TimeInterval? {
        endsAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    private func schedule(end: Date) {
        endsAt = end
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        onChange?()
    }
}

/// Which events the lock swallows.
enum KeyboardCleaningPolicy {
    static let systemDefined = CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue))!

    static let swallowedTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, systemDefined]

    /// Every key event goes. Of the system-defined events only the media and
    /// brightness keys do: the same event type also carries mouse-button and
    /// power notifications, which must keep flowing.
    static func swallows(type: CGEventType, systemDefinedSubtype: Int?) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged: true
        case systemDefined: systemDefinedSubtype == Int(NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        default: false
        }
    }
}
