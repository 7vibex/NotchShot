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

    static func adjustedLevel(current: Double, increasing: Bool, fine: Bool) -> Double {
        let step = fine ? 1.0 / 64.0 : 1.0 / 16.0
        return min(max(current + (increasing ? step : -step), 0), 1)
    }
}

/// On macOS 26.5, volume and brightness OSD moved into Control Center, so
/// pausing OSDUIHelper no longer removes the duplicate system banner. This tap
/// consumes only the five hardware keys NotchShot can apply itself. Any failed
/// write passes through to macOS unchanged.
@MainActor
final class SystemMediaKeyInterceptor {
    var onKeyDown: ((SystemMediaKeyAction) -> Bool)?

    /// `nonisolated(unsafe)` so `deinit`, which cannot be main-actor isolated,
    /// can still reach it. Every mutation below happens on the main actor; the
    /// deinit is the one other reader, and by then nothing else holds a
    /// reference.
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var consumedKeyTypes: Set<Int> = []

    deinit {
        // The run loop retains the source, which retains the port, so a tap
        // outlives its interceptor unless it is invalidated — and its callback
        // reaches back through an unretained pointer to this object. Normal
        // teardown goes through `stop()`; this is the backstop for any path
        // that drops the interceptor without it.
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    var isRunning: Bool { eventTap != nil }

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
        if !CGPreflightPostEventAccess() {
            Log.app.notice(
                "Post-event access is not granted; if media keys are not consumed, grant Accessibility as well as Input Monitoring"
            )
        }

        let mask = CGEventMask(1) << systemDefinedCGEventType.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: systemMediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.notice("Could not install the system media-key interception tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        consumedKeyTypes.removeAll()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func reenableAfterSystemDisable() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    fileprivate func handle(
        keyType: Int,
        keyState: Int,
        modifierFlagsRawValue: UInt
    ) -> Bool {
        if keyState == 0xA,
           let action = SystemMediaKeyAction.action(
               keyType: keyType,
               modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
           ),
           onKeyDown?(action) == true {
            consumedKeyTypes.insert(keyType)
            return true
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
    let interceptor = Unmanaged<SystemMediaKeyInterceptor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { interceptor.reenableAfterSystemDisable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == systemDefinedCGEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
        return Unmanaged.passUnretained(event)
    }
    let keyType = (nsEvent.data1 & 0xFFFF_0000) >> 16
    let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
    let modifierFlags = nsEvent.modifierFlags.rawValue
    let shouldConsume = MainActor.assumeIsolated {
        interceptor.handle(
            keyType: keyType,
            keyState: keyState,
            modifierFlagsRawValue: modifierFlags
        )
    }
    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}
