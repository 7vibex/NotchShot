import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import Foundation

/// Mute and camera for the call on the island.
///
/// Meeting apps don't publish their state, so there are two honest routes:
/// apps with a documented toggle shortcut get that shortcut (their own UI
/// shows the result, and other people see it too); everything else —
/// browsers included, where ⌘D might bookmark the page rather than mute
/// Meet — gets the system's input mute, which silences the microphone for
/// every app at once.
public enum MeetingControls {
    public struct KeyCombo: Equatable, Sendable {
        public var keyCode: CGKeyCode
        public var flags: CGEventFlags

        static func command(shift: Bool = false, _ keyCode: CGKeyCode) -> KeyCombo {
            KeyCombo(keyCode: keyCode, flags: shift ? [.maskCommand, .maskShift] : [.maskCommand])
        }
    }

    public struct AppProfile: Equatable, Sendable {
        public var name: String
        public var mute: KeyCombo
        public var camera: KeyCombo?
    }

    struct ControlPresentation: Equatable, Sendable {
        var label: String
        var help: String
    }

    /// Shortcut delivery cannot acknowledge the app's actual mute state.
    /// Describe the action without promising a state or direction.
    static func microphonePresentation(for bundleIdentifier: String) -> ControlPresentation {
        if let profile = profile(for: bundleIdentifier) {
            return ControlPresentation(
                label: "Toggle microphone in \(profile.name)",
                help: "Sends the mute shortcut. Check \(profile.name) for its current microphone state."
            )
        }
        return ControlPresentation(
            label: "Toggle system microphone mute",
            help: "Changes the default microphone's mute setting for every app."
        )
    }

    // ANSI virtual key codes.
    private static let keyA: CGKeyCode = 0
    private static let keyM: CGKeyCode = 46
    private static let keyO: CGKeyCode = 31
    private static let keyV: CGKeyCode = 9
    private static let space: CGKeyCode = 49

    /// Apps whose default toggle shortcuts are documented and stable.
    public static func profile(for bundleIdentifier: String) -> AppProfile? {
        switch bundleIdentifier {
        case "us.zoom.xos":
            AppProfile(name: "Zoom", mute: .command(shift: true, keyA), camera: .command(shift: true, keyV))
        case "com.microsoft.teams2", "com.microsoft.teams":
            AppProfile(name: "Teams", mute: .command(shift: true, keyM), camera: .command(shift: true, keyO))
        case "com.tinyspeck.slackmacgap":
            AppProfile(name: "Slack", mute: .command(shift: true, space), camera: nil)
        case "com.hnc.Discord":
            AppProfile(name: "Discord", mute: .command(shift: true, keyM), camera: nil)
        default:
            nil
        }
    }

    /// Sends a shortcut to an app the way the user would: bring it forward,
    /// press the keys, then hand focus back to whatever was in front.
    /// Requires Accessibility, which NotchShot already asks for to mirror
    /// notifications and drive the HUD.
    @MainActor
    public static func send(_ combo: KeyCombo, to bundleIdentifier: String) async -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        return await MeetingShortcutDispatcher.shared.send(combo, to: app.processIdentifier)
    }

    // MARK: System input mute

    /// Whether the default input device is muted, or nil when it has no mute
    /// control (many USB microphones don't).
    public static func isSystemInputMuted() -> Bool? {
        guard let device = defaultInputDevice() else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    public static func setSystemInputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }
}
