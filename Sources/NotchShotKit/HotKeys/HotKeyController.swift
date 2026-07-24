import AppKit
import Carbon.HIToolbox
import Foundation

public enum HotKeyAction: String, Sendable, CaseIterable, Identifiable, Codable {
    case captureArea
    case captureWindow
    case captureDisplay
    case capturePreviousArea
    case captureScrolling
    case captureText
    case startRecording
    case stopRecording
    case toggleNotch
    case restoreLastCapture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureDisplay: "Capture Full Screen"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureScrolling: "Scrolling Capture"
        case .captureText: "Capture Text (OCR)"
        case .startRecording: "Start Recording"
        case .stopRecording: "Stop Recording"
        case .toggleNotch: "Open the Notch"
        case .restoreLastCapture: "Restore Last Capture"
        }
    }

    /// Defaults chosen to sit beside macOS's own ⇧⌘3/4/5 without colliding.
    public var defaultBinding: HotKeyBinding? {
        switch self {
        case .captureArea: HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureWindow: HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureDisplay: HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .capturePreviousArea: HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureScrolling: HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureText: HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .startRecording: HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .stopRecording: HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .toggleNotch: HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .restoreLastCapture: nil
        }
    }
}

public struct HotKeyBinding: Codable, Sendable, Equatable, Hashable {
    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, …).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    public var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"; case kVK_ANSI_B: "B"; case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"; case kVK_ANSI_E: "E"; case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"; case kVK_ANSI_H: "H"; case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"; case kVK_ANSI_K: "K"; case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"; case kVK_ANSI_N: "N"; case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"; case kVK_ANSI_Q: "Q"; case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"; case kVK_ANSI_T: "T"; case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"; case kVK_ANSI_W: "W"; case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"; case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"; case kVK_ANSI_1: "1"; case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"; case kVK_ANSI_4: "4"; case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"; case kVK_ANSI_7: "7"; case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Escape: "⎋"; case kVK_Return: "↩"; case kVK_Space: "Space"
        case kVK_Tab: "⇥"; case kVK_Delete: "⌫"
        default: "Key \(keyCode)"
        }
    }
}

/// Registers global shortcuts through Carbon's hot-key API.
///
/// Carbon is used deliberately: `RegisterEventHotKey` needs no Accessibility
/// grant, while an `NSEvent` global key monitor does. For a capture tool that
/// already asks for Screen Recording, avoiding a second scary prompt matters.
@MainActor
public final class HotKeyController {
    public static let shared = HotKeyController()

    public private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    public var handler: ((HotKeyAction) -> Void)?

    private var registrations: [UInt32: (action: HotKeyAction, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1
    private let defaultsKey = "notchshot.hotkeys"

    private init() {
        loadBindings()
    }

    // MARK: Lifecycle

    public func start() {
        installEventHandler()
        registerAll()
    }

    public func stop() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    // MARK: Bindings

    public func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        // A duplicate would leave one of the two silently dead, so the newer
        // assignment wins and the older one is cleared.
        if let binding {
            for (other, existing) in bindings where other != action && existing == binding {
                bindings[other] = nil
            }
        }
        bindings[action] = binding
        saveBindings()
        registerAll()
    }

    public func restoreDefaults() {
        bindings = [:]
        for action in HotKeyAction.allCases {
            bindings[action] = action.defaultBinding
        }
        saveBindings()
        registerAll()
    }

    private func loadBindings() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([HotKeyAction: HotKeyBinding].self, from: data)
        else {
            for action in HotKeyAction.allCases {
                bindings[action] = action.defaultBinding
            }
            return
        }
        bindings = decoded
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: Registration

    private func registerAll() {
        unregisterAll()
        for (action, binding) in bindings {
            register(action: action, binding: binding)
        }
    }

    private func register(action: HotKeyAction, binding: HotKeyBinding) {
        let identifier = nextIdentifier
        nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E53_4854), id: identifier) // 'NSHT'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            // Almost always means another app already owns the combination.
            Log.app.notice("Couldn't register \(action.rawValue) (\(binding.displayString)); status \(status)")
            return
        }
        registrations[identifier] = (action, reference)
    }

    private func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let identifier = hotKeyID.id
            // Carbon calls back on the main run loop, but hop explicitly so the
            // isolation is checked rather than assumed.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeyController.shared.fire(identifier: identifier)
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    fileprivate func fire(identifier: UInt32) {
        guard let registration = registrations[identifier] else { return }
        handler?(registration.action)
    }
}
