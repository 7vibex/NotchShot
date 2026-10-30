import AppKit
@preconcurrency import CoreGraphics

private let systemDefinedCGEventType = CGEventType(
    rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)
)!

enum SystemMediaKeyAction: Sendable, Equatable {
    case volumeUp(fine: Bool)
    case volumeDown(fine: Bool)
    case mute
    case brightnessUp(fine: Bool)
    case brightnessDown(fine: Bool)

    static func action(
        keyType: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> SystemMediaKeyAction? {
        let fine = modifierFlags.contains(.shift) && modifierFlags.contains(.option)
        return switch keyType {
        case Int(NX_KEYTYPE_SOUND_UP): .volumeUp(fine: fine)
        case Int(NX_KEYTYPE_SOUND_DOWN): .volumeDown(fine: fine)
        case Int(NX_KEYTYPE_MUTE): .mute
        case Int(NX_KEYTYPE_BRIGHTNESS_UP): .brightnessUp(fine: fine)
        case Int(NX_KEYTYPE_BRIGHTNESS_DOWN): .brightnessDown(fine: fine)
        default: nil
        }
    }

    /// Presses from empty to full; Option-Shift moves a quarter of one.
    static let coarseSteps = 16

    static func adjustedLevel(current: Double, increasing: Bool, fine: Bool) -> Double {
        let step = 1.0 / Double(fine ? coarseSteps * 4 : coarseSteps)
        return min(max(current + (increasing ? step : -step), 0), 1)
    }
}

/// On macOS 26.5, volume and brightness OSD moved into Control Center, so
/// pausing OSDUIHelper no longer removes the duplicate system banner. This tap
/// consumes only the five hardware keys NotchShot can apply itself. A key whose
/// write fails still reaches macOS.
///
/// The tap lives on a thread of its own. WindowServer holds every covered event
/// until a filtering tap answers, and switches the tap off when the answer is
/// late; macOS then handles the key and draws its banner beside the notch. On
/// the main run loop the answer waited behind everything else queued there:
/// `CGGetEventTapList` showed 0.7 to 1 s per key on Oct 30, and once 17.6 s.
/// Now the tap thread answers at once and the main actor applies the key after.
@MainActor
final class SystemMediaKeyInterceptor {
    var onKeyDown: ((SystemMediaKeyAction) -> Bool)?

    /// `nonisolated(unsafe)` so `deinit`, which cannot be main-actor isolated,
    /// can still reach it: the tap thread keeps a dropped tap alive, swallowing
    /// keys, until it is stopped. Every mutation below happens on the main
    /// actor; the deinit is the one other reader, and by then nothing else
    /// holds a reference.
    private nonisolated(unsafe) var tap: MediaKeyTap?

    deinit {
        // Normal teardown goes through `stop()`; this is the backstop for any
        // path that drops the interceptor without it.
        tap?.stop()
    }

    var isRunning: Bool { tap != nil }

    func start(requestAccess: Bool) -> Bool {
        if isRunning { return true }

        var hasAccess = CGPreflightListenEventAccess()
        if !hasAccess, requestAccess {
            hasAccess = CGRequestListenEventAccess()
        }
        guard hasAccess else {
            Log.app.notice("Input Monitoring is required to replace the macOS 26.5 system banner")
            return false
        }

        // Input Monitoring is what lets a tap *see* events. This tap is created
        // with `.defaultTap`, which additionally lets it swallow them, and on
        // some macOS builds that capability is gated on the post-event grant
        // instead. It is not required here — asking for it would disable a
        // configuration that currently works — but when it is missing and the
        // tap then goes quiet, this line is the difference between a diagnosable
        // permission problem and a feature that looks simply broken.
        let canReplay = CGPreflightPostEventAccess()
        if !canReplay {
            Log.app.notice(
                "Post-event access is not granted; if media keys are not consumed, grant Accessibility as well as Input Monitoring"
            )
        }

        // Without post-event access a swallowed key can't be handed back to
        // macOS, so the tap thread must wait for the main actor's answer as
        // before; with it, the answer is immediate and a failure is replayed.
        let answer: MediaKeyTap.Answer = canReplay
            ? .immediately { [weak self] action, keyDown in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.onKeyDown?(action) != true else { return }
                        keyDown.replayToSystem()
                    }
                }
            }
            : .afterMainActor { [weak self] action in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.onKeyDown?(action) == true }
                }
            }
        guard let tap = MediaKeyTap(answer: answer) else {
            Log.app.notice("Could not install the system media-key interception tap")
            return false
        }
        self.tap = tap
        return true
    }

    func stop() {
        tap?.stop()
        tap = nil
    }
}

/// A swallowed key press, kept so a key NotchShot could not apply still
/// reaches macOS.
struct ConsumedMediaKey: @unchecked Sendable {
    /// Marks events NotchShot posts itself, so its own tap lets them through.
    static let replayMarker: Int64 = 0x4E53_4D4B

    let keyDown: CGEvent

    /// macOS gets the press back as a whole: the real key-up was swallowed
    /// along with the key-down, so a key-up is posted after it.
    func replayToSystem() {
        guard let keyUp = Self.keyUp(for: keyDown) else { return }
        for event in [keyDown, keyUp] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func keyUp(for keyDown: CGEvent) -> CGEvent? {
        guard let down = NSEvent(cgEvent: keyDown) else { return nil }
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: down.locationInWindow,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: (down.modifierFlags.rawValue & ~0xFF00) | 0xB00
            ),
            timestamp: down.timestamp,
            windowNumber: 0,
            context: nil,
            subtype: down.subtype.rawValue,
            data1: keyUpData1(forKeyDown: down.data1),
            data2: down.data2
        )?.cgEvent
    }

    /// `data1` is the key type in the high 16 bits, then the key state (0xA
    /// down, 0xB up) and a repeat bit. A key-up never repeats.
    static func keyUpData1(forKeyDown data1: Int) -> Int {
        (data1 & ~0xFFFF) | (0xB << 8)
    }
}

/// The event tap and the thread it runs on.
///
/// `@unchecked Sendable`: `port` is set once before the thread starts and then
/// only read, and `consumedKeyTypes` is touched only by the tap callback, which
/// always runs on the tap thread.
private final class MediaKeyTap: @unchecked Sendable {
    enum Answer {
        /// Swallow the key now; the main actor applies it later.
        case immediately(@Sendable (SystemMediaKeyAction, ConsumedMediaKey) -> Void)
        /// Wait for the main actor to say whether it applied the key.
        case afterMainActor(@Sendable (SystemMediaKeyAction) -> Bool)
    }

    let answer: Answer
    private(set) var port: CFMachPort?
    private var consumedKeyTypes: Set<Int> = []
    private let runLoopLock = NSLock()
    /// Guarded by `runLoopLock`.
    private var runLoop: CFRunLoop?
    private var isStopped = false

    init?(answer: Answer) {
        self.answer = answer
        let mask = CGEventMask(1) << systemDefinedCGEventType.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: systemMediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port

        // The thread's closure keeps `self` alive until its run loop ends, so
        // the unretained pointer the callback receives stays valid.
        let thread = Thread { [self] in run() }
        thread.name = "NotchShot.MediaKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        // Reached once the thread has ended, or if it never got its run loop
        // source; invalidating twice is harmless.
        if let port { CFMachPortInvalidate(port) }
    }

    private func run() {
        guard let port,
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        let current = CFRunLoopGetCurrent()
        runLoopLock.lock()
        if isStopped {
            runLoopLock.unlock()
            return
        }
        runLoop = current
        runLoopLock.unlock()
        CFRunLoopAddSource(current, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    /// Invalidating the port removes its source from the tap thread's run loop;
    /// stopping the run loop ends the thread even if something else was added.
    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        runLoopLock.lock()
        isStopped = true
        let runLoop = runLoop
        runLoopLock.unlock()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate func reenableAfterSystemDisable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    fileprivate func shouldConsume(_ event: CGEvent, keyType: Int, keyState: Int, modifierFlags: UInt) -> Bool {
        if keyState == 0xA,
           let action = SystemMediaKeyAction.action(
               keyType: keyType,
               modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags)
           ) {
            let consumed: Bool
            switch answer {
            case .immediately(let deliver):
                if let keyDown = event.copy() {
                    deliver(action, ConsumedMediaKey(keyDown: keyDown))
                    consumed = true
                } else {
                    consumed = false
                }
            case .afterMainActor(let decide):
                consumed = decide(action)
            }
            if consumed { consumedKeyTypes.insert(keyType) }
            return consumed
        }
        if keyState == 0xB, consumedKeyTypes.remove(keyType) != nil {
            return true
        }
        return false
    }
}

private func systemMediaKeyEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenableAfterSystemDisable()
        return Unmanaged.passUnretained(event)
    }
    guard type == systemDefinedCGEventType,
          event.getIntegerValueField(.eventSourceUserData) != ConsumedMediaKey.replayMarker,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
        return Unmanaged.passUnretained(event)
    }
    let keyType = (nsEvent.data1 & 0xFFFF_0000) >> 16
    let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
    let consume = tap.shouldConsume(
        event,
        keyType: keyType,
        keyState: keyState,
        modifierFlags: nsEvent.modifierFlags.rawValue
    )
    return consume ? nil : Unmanaged.passUnretained(event)
}
