import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Caps Lock and keyboard-language changes for the island's bursts.
///
/// Caps Lock arrives as a `flagsChanged` event. Global key monitors only see
/// events once the app is trusted for Accessibility or Input Monitoring, so
/// without either grant the lock state is read from the window server a few
/// times a second instead. The read is one cheap call and needs no
/// permission. Input sources announce themselves through a distributed
/// notification, so they never poll.
@MainActor
final class KeyboardStateMonitor {
    var onCapsLockChange: ((Bool) -> Void)?
    /// The new input source.
    var onInputSourceChange: ((InputSource) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var inputSourceObserver: NSObjectProtocol?
    private var capsLockOn = KeyboardStateMonitor.readCapsLock()
    private var inputSourceID = KeyboardStateMonitor.currentInputSource()?.id

    private(set) var watchesCapsLock = false
    private(set) var watchesInputSource = false

    func update(capsLock: Bool, inputSource: Bool) {
        if capsLock != watchesCapsLock {
            capsLock ? startCapsLock() : stopCapsLock()
        }
        if inputSource != watchesInputSource {
            inputSource ? startInputSource() : stopInputSource()
        }
    }

    func stop() {
        update(capsLock: false, inputSource: false)
    }

    // MARK: Caps Lock

    private func startCapsLock() {
        watchesCapsLock = true
        capsLockOn = Self.readCapsLock()
        if AXIsProcessTrusted() || CGPreflightListenEventAccess() {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let isOn = event.modifierFlags.contains(.capsLock)
                Task { @MainActor in self?.capsLockMaybeChanged(isOn) }
            }
        } else {
            // 4 Hz is quick enough that the burst follows the key press,
            // and the generous tolerance lets the timer share wake-ups.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.capsLockMaybeChanged(Self.readCapsLock()) }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        // Global monitors never see events aimed at NotchShot's own windows.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isOn = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.capsLockMaybeChanged(isOn) }
            return event
        }
    }

    private func stopCapsLock() {
        watchesCapsLock = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func capsLockMaybeChanged(_ isOn: Bool) {
        guard isOn != capsLockOn else { return }
        capsLockOn = isOn
        onCapsLockChange?(isOn)
    }

    static func readCapsLock() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    // MARK: Input source

    private func startInputSource() {
        watchesInputSource = true
        inputSourceID = Self.currentInputSource()?.id
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceMaybeChanged() }
        }
    }

    private func stopInputSource() {
        watchesInputSource = false
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
        inputSourceObserver = nil
    }

    private func inputSourceMaybeChanged() {
        guard let source = Self.currentInputSource(), source.id != inputSourceID else { return }
        inputSourceID = source.id
        // With one keyboard layout there is nothing to switch between; the
        // notification then means a palette or emoji picker, not a language.
        guard Self.selectableKeyboardSourceCount() > 1 else { return }
        onInputSourceChange?(source)
    }

    struct InputSource: Equatable {
        var id: String
        var name: String
        /// The first language the source types, such as "ro".
        var language: String?

        /// "Romanian" for "Romanian – Standard": the variant rarely fits
        /// beside the notch and the language is what the user checks.
        var shortName: String {
            for separator in [" – ", " — ", " - "] {
                if let range = name.range(of: separator) {
                    let head = name[..<range.lowerBound]
                    if !head.isEmpty { return String(head) }
                }
            }
            return name
        }

        /// The badge text: "RO", or the name's first letters for a layout
        /// with no language, such as Dvorak.
        var badge: String {
            if let language, !language.isEmpty {
                return String(language.split(separator: "-").first ?? Substring(language)).uppercased()
            }
            return String(shortName.prefix(2)).uppercased()
        }
    }

    static func currentInputSource() -> InputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        var language: String?
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
            language = languages?.first
        }
        return InputSource(
            id: id,
            name: stringProperty(source, kTISPropertyLocalizedName) ?? id,
            language: language
        )
    }

    static func selectableKeyboardSourceCount() -> Int {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(list)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
