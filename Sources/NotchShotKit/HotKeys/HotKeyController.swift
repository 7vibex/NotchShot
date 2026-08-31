import AppKit
import Carbon.HIToolbox
import Foundation

public enum HotKeyAction: String, Sendable, CaseIterable, Identifiable, Codable {
    case captureArea
    case captureAreaToClipboard
    case captureWindow
    case captureDisplay
    case captureDisplayToClipboard
    case capturePreviousArea
    case captureScrolling
    case captureText
    case startRecording
    case stopRecording
    case toggleNotch
    case restoreLastCapture
    case showClipboard
    case toggleDictation
    case pushToTalk
    case showShelf

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureAreaToClipboard: "Capture Area to Clipboard"
        case .captureWindow: "Capture Window"
        case .captureDisplay: "Capture Full Screen"
        case .captureDisplayToClipboard: "Capture Full Screen to Clipboard"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureScrolling: "Scrolling Capture"
        case .captureText: "Capture Text (OCR)"
        case .startRecording: "Start Recording"
        case .stopRecording: "Stop Recording"
        case .toggleNotch: "Open the Notch"
        case .restoreLastCapture: "Restore Last Capture"
        case .showClipboard: "Clipboard History"
        case .toggleDictation: "Toggle Dictation"
        case .pushToTalk: "Push to Talk"
        case .showShelf: "Show Shelf"
        }
    }

    /// The macOS combination this action replaces, when NotchShot is set to take
    /// the system screenshot shortcuts over.
    public var systemStyleBinding: HotKeyBinding? {
        switch self {
        case .captureDisplay:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey))
        case .captureDisplayToClipboard:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | controlKey))
        case .captureArea:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey))
        case .captureAreaToClipboard:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey))
        case .startRecording:
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))
        default: nil
        }
    }

    /// Every action that can stand in for a macOS screenshot shortcut, paired
    /// with the system hotkey that has to be released for it to work.
    public static let systemShortcutReplacements: [(HotKeyAction, SystemScreenshotHotKeys.SymbolicHotKey)] = [
        (.captureDisplay, .fullScreenToFile),
        (.captureDisplayToClipboard, .fullScreenToClipboard),
        (.captureArea, .areaToFile),
        (.captureAreaToClipboard, .areaToClipboard),
        (.startRecording, .screenshotPanel),
    ]

    /// Defaults chosen to sit beside macOS's own ⇧⌘3/4/5 without colliding.
    public var defaultBinding: HotKeyBinding? {
        switch self {
        case .captureArea: HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        // No default of their own: these exist to stand in for ⌃⇧⌘3 and ⌃⇧⌘4.
        case .captureAreaToClipboard, .captureDisplayToClipboard: nil
        case .captureWindow: HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureDisplay: HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .capturePreviousArea: HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureScrolling: HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureText: HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .startRecording: HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .stopRecording: HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .toggleNotch: HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .restoreLastCapture: nil
        // No default: the clipboard history is off until the user turns it on,
        // so claiming a global combination for it before then would reserve a
        // shortcut for a feature that does nothing.
        case .showClipboard: nil
        case .toggleDictation: HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case .pushToTalk: nil
        // No default: the shelf is reachable from the menu bar, and claiming a
        // global combination for a surface that is empty most of the time is
        // not a trade the user asked for.
        case .showShelf: nil
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

    private static let supportedCarbonModifierMask = UInt32(
        cmdKey | shiftKey | optionKey | controlKey
    )

    /// `RegisterEventHotKey` only understands Carbon's command, shift, option,
    /// and control masks. Caps Lock and Fn are visible to AppKit but disappear
    /// during conversion; accepting either alone would therefore register the
    /// selected key globally with no modifier at all.
    public var isValidGlobalShortcut: Bool {
        modifiers != 0 && modifiers & ~Self.supportedCarbonModifierMask == 0
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

public enum HotKeyPhase: Sendable, Equatable {
    case pressed
    case released
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
    /// Includes release events for genuine push-to-talk behavior. Ordinary
    /// actions continue to use `handler` and fire only on key press.
    public var phaseHandler: ((HotKeyAction, HotKeyPhase) -> Void)?

    private var registrations: [UInt32: (action: HotKeyAction, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1
    private let defaultsKey = "notchshot.hotkeys"
    private let dictationDefaultMigrationKey = "notchshot.hotkeys.dictationDefaultInstalled"
    private let simpleDictationShortcutMigrationKey = "notchshot.hotkeys.simpleDictationShortcutInstalled"

    private init() {
        loadBindings()
    }

    // MARK: Lifecycle

    public func start() {
        // Restore only the exact shortcuts this app persisted as its own before
        // a previous crash. Never enable a shortcut the user disabled in macOS.
        SystemScreenshotHotKeys.shared.restoreAll()
        applySystemShortcutTakeover()
        installEventHandler()
        registerAll()
    }

    public func stop() {
        unregisterAll()
        // macOS gets its shortcuts back before this process goes away.
        SystemScreenshotHotKeys.shared.restoreAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Points ⇧⌘4 and ⇧⌘5 at NotchShot, or gives them back.
    ///
    /// The system owns those combinations at a level above app hotkeys, so the
    /// system ones have to be released before ours can register. Order matters:
    /// release first, then register.
    public func applySystemShortcutTakeover() {
        let wanted = Preferences.shared.usesSystemScreenshotShortcuts
        if wanted {
            SystemScreenshotHotKeys.shared.takeOver(
                Set(HotKeyAction.systemShortcutReplacements.map(\.1))
            )
        } else {
            SystemScreenshotHotKeys.shared.restoreAll()
        }
        for (action, _) in HotKeyAction.systemShortcutReplacements {
            let current = bindings[action]
            if wanted {
                // A combination the user picked themselves is theirs; only the
                // untouched default gets moved onto the system shortcut.
                guard current == action.defaultBinding || current == action.systemStyleBinding
                else { continue }
                bindings[action] = action.systemStyleBinding
            } else {
                guard current == action.systemStyleBinding else { continue }
                bindings[action] = action.defaultBinding
            }
        }
        registerAll()
    }

    // MARK: Bindings

    public func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        if let binding, !binding.isValidGlobalShortcut {
            Log.app.notice("Ignored shortcut with invalid Carbon modifiers for \(action.rawValue)")
            return
        }
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
        // Older builds could persist Caps Lock/Fn-only captures as a binding
        // with a zero Carbon modifier mask. Keep valid custom shortcuts exactly
        // as they are, but do not turn an invalid legacy entry into a bare
        // system-wide key.
        bindings = decoded.filter { $0.value.isValidGlobalShortcut }
        // Dictionaries from releases before Notch Dictation cannot contain the
        // new action. Install its default exactly once without changing any
        // existing custom or explicitly cleared shortcuts on later launches.
        if !UserDefaults.standard.bool(forKey: dictationDefaultMigrationKey) {
            if decoded[.toggleDictation] == nil {
                bindings[.toggleDictation] = HotKeyAction.toggleDictation.defaultBinding
            }
            UserDefaults.standard.set(true, forKey: dictationDefaultMigrationKey)
        }
        // Replace only the old shipped default. A custom binding — including a
        // user-cleared shortcut — remains entirely under the user's control.
        if !UserDefaults.standard.bool(forKey: simpleDictationShortcutMigrationKey) {
            let oldDefault = HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_D),
                modifiers: UInt32(cmdKey | shiftKey | optionKey)
            )
            if decoded[.toggleDictation] == oldDefault {
                bindings[.toggleDictation] = HotKeyAction.toggleDictation.defaultBinding
            }
            UserDefaults.standard.set(true, forKey: simpleDictationShortcutMigrationKey)
        }
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
        guard binding.isValidGlobalShortcut else {
            Log.app.notice("Refused to register shortcut with invalid Carbon modifiers for \(action.rawValue)")
            return
        }
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
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
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
            let phase: HotKeyPhase = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                ? .released
                : .pressed
            // Carbon calls back on the main run loop, but hop explicitly so the
            // isolation is checked rather than assumed.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeyController.shared.fire(identifier: identifier, phase: phase)
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
    }

    fileprivate func fire(identifier: UInt32, phase: HotKeyPhase) {
        guard let registration = registrations[identifier] else { return }
        phaseHandler?(registration.action, phase)
        if phase == .pressed {
            handler?(registration.action)
        }
    }
}
