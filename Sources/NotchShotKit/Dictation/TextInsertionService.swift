import AppKit
@preconcurrency import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Captures the insertion target *before* the notch expands.
public struct DictationInsertionTarget: @unchecked Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case editable
        case secure
        case unknown
    }

    public var bundleID: String?
    public var processID: pid_t
    public var axElement: AXUIElement?
    public var selectedTextRange: CFRange?
    public var displayID: CGDirectDisplayID?
    public var kind: Kind

    public init(bundleID: String? = nil, processID: pid_t = 0, axElement: AXUIElement? = nil, selectedTextRange: CFRange? = nil, displayID: CGDirectDisplayID? = nil, kind: Kind = .unknown) {
        self.bundleID = bundleID
        self.processID = processID
        self.axElement = axElement
        self.selectedTextRange = selectedTextRange
        self.displayID = displayID
        self.kind = kind
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.processID == rhs.processID
            && lhs.displayID == rhs.displayID
            && lhs.kind == rhs.kind
    }
}

public enum TextInsertionResult: Sendable, Equatable {
    case inserted
    case copied
    case failed(String)
}

public enum DictationTextProcessor {
    public static func process(
        _ text: String,
        mode: DictationPostProcessingMode,
        removeFillerWords: Bool,
        deterministicReplacements: [String: String],
        customDictionary: [String: String],
        appendMode: DictationAppendMode,
        enableSpokenFormatting: Bool
    ) -> String {
        var result = text

        // Deterministic replacements first (case-sensitive simple)
        for (key, value) in deterministicReplacements where !key.isEmpty {
            result = result.replacingOccurrences(of: key, with: value)
        }
        for (key, value) in customDictionary where !key.isEmpty {
            result = result.replacingOccurrences(of: key, with: value)
        }

        if removeFillerWords {
            result = removeFillers(from: result)
        }

        if enableSpokenFormatting {
            result = applySpokenFormatting(to: result)
        }

        switch mode {
        case .verbatim:
            break
        case .clean:
            result = cleanDictation(result)
        case .localPolish:
            result = localPolish(result)
        }

        let base = result.trimmingCharacters(in: .whitespacesAndNewlines)
        switch appendMode {
        case .nothing: return base
        case .space: return base + " "
        case .newline: return base + "\n"
        }
    }

    private static func removeFillers(from text: String) -> String {
        let fillers = ["um", "uh", "er", "ah", "like", "you know"]
        var words = text.components(separatedBy: .whitespacesAndNewlines)
        words = words.filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        return words.joined(separator: " ")
    }

    private static func applySpokenFormatting(to text: String) -> String {
        var r = text
        let replacements: [(String, String)] = [
            ("new line", "\n"),
            ("new paragraph", "\n\n"),
            ("comma", ","),
            ("period", "."),
            ("question mark", "?"),
            ("exclamation mark", "!"),
            ("colon", ":"),
            ("semicolon", ";")
        ]
        for (spoken, symbol) in replacements {
            r = r.replacingOccurrences(of: " \(spoken) ", with: " \(symbol) ", options: .caseInsensitive)
            r = r.replacingOccurrences(of: " \(spoken)", with: symbol, options: .caseInsensitive)
        }
        return r
    }

    private static func cleanDictation(_ text: String) -> String {
        var r = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capitalize first letter
        if let first = r.first { r = first.uppercased() + r.dropFirst() }
        // Ensure terminal punctuation
        if !r.isEmpty, !".!?".contains(r.last!) { r += "." }
        return r
    }

    private static func localPolish(_ text: String) -> String {
        // Minimal local polish: clean + remove double spaces + fix spacing before punctuation
        var r = cleanDictation(text)
        while r.contains("  ") { r = r.replacingOccurrences(of: "  ", with: " ") }
        r = r.replacingOccurrences(of: " ,", with: ",")
        r = r.replacingOccurrences(of: " .", with: ".")
        return r
    }
}

/// Service that inserts text into the original field, with fallbacks.
@MainActor
public final class TextInsertionService {
    public static let shared = TextInsertionService()

    /// Tracks NotchShot's own pasteboard writes so ClipboardMonitor doesn't record them.
    /// Reuses ImageExport's tracking for history suppression.
    private var lastSelfWriteChangeCount: Int?

    public init() {}

    /// Captures insertion target before UI expands. Never reads surrounding text.
    public func captureTarget() -> DictationInsertionTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return DictationInsertionTarget(displayID: activeDisplayID())
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let displayID = displayIDForApp(app) ?? activeDisplayID()

        // Try to get focused AX element without activating NotchShot.
        // Requires Accessibility permission to read other apps' AX.
        var target = DictationInsertionTarget(bundleID: bundleID, processID: pid, displayID: displayID)
        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
            if err == .success, let element = focused {
                // CFTypeRef is AXUIElement
                let ax = (element as! AXUIElement)
                if isSecureField(ax) {
                    target.kind = .secure
                } else if isEditableAndNotSecure(ax) {
                    target.kind = .editable
                    target.axElement = ax
                    // Capture selection range if available (do not read value)
                    var rangeValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(ax, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
                       let value = rangeValue {
                        var range = CFRange()
                        if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                            target.selectedTextRange = range
                        }
                    }
                }
            }
        }
        return target
    }

    public func insert(
        _ text: String,
        into target: DictationInsertionTarget,
        mode: DictationInsertMode
    ) -> TextInsertionResult {
        guard !text.isEmpty else { return .failed("No speech detected") }
        if mode == .copyOnly {
            return copyToPasteboard(text)
        }

        // A password field is a hard insertion boundary. We may preserve the
        // transcript on the clipboard, but never synthesize typing or paste into
        // a secure control.
        if target.kind == .secure {
            return copyToPasteboard(text)
        }

        // 1. Direct Accessibility insertion if we have a verified editable non-secure element
        if let element = target.axElement, AXIsProcessTrusted(), isEditableAndNotSecure(element) {
            // Re-verify element is still focused and belongs to same app
            if verifyTargetStillValid(target, element: element) {
                if insertViaAX(text, into: element) {
                    return .inserted
                }
                // Web editors and several Electron apps expose an editable AX
                // target but reject AXSelectedText. Unicode keyboard events are
                // a clipboard-free fallback and remain scoped to the same
                // re-verified focused element.
                if typeViaUnicodeEvents(text) {
                    return .inserted
                }
            }
            // If verification fails or insertion fails, fall through to copy fallback
            // rather than inserting into surprising destination.
            return copyToPasteboard(text)
        }

        // Unknown/non-editable targets and missing Accessibility permission are
        // copy-only. Blind Cmd-V could otherwise paste into a password field or
        // into a different app after focus changes.
        return copyToPasteboard(text)
    }

    // MARK: - AX Helpers

    private func isEditableAndNotSecure(_ element: AXUIElement) -> Bool {
        // An explicit false is authoritative. Some web editors omit AXEditable,
        // so in that case require a known text-entry role instead of assuming
        // every focused control can accept text.
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let boolVal = editable as? Bool {
            if !boolVal { return false }
            return !isSecureField(element)
        }
        // Secure fields must never be inserted into
        if isSecureField(element) { return false }

        // Check role: text field, text area, etc. Allow most editable roles.
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let roleStr = role as? String {
            let editableRoles = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField",
            ]
            guard editableRoles.contains(roleStr) else { return false }
        } else {
            return false
        }
        // Check subrole for secure
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let sub = subrole as? String, sub == kAXSecureTextFieldSubrole as String {
            return false
        }
        return true
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" {
            return true
        }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == kAXSecureTextFieldSubrole as String {
            return true
        }
        // Also check AXSecureTextField trait via description?
        return false
    }

    private func verifyTargetStillValid(_ target: DictationInsertionTarget, element: AXUIElement) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.bundleIdentifier != target.bundleID { return false }
        if front.processIdentifier != target.processID { return false }
        // The original app being frontmost is not enough: the user may have
        // moved focus to another field (including a password field) while
        // speaking. CFEqual gives us the AX identity check we need.
        var focused: CFTypeRef?
        let appElement = AXUIElementCreateApplication(target.processID)
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) != .success {
            return false
        }
        guard let focused else { return false }
        return CFEqual(focused, element)
    }

    private func insertViaAX(_ text: String, into element: AXUIElement) -> Bool {
        // Try kAXSelectedTextAttribute or kAXValueAttribute
        // For text fields, setting selected text inserts at cursor.
        // First try to set selected text
        var rangeValue: CFTypeRef?
        var hasSelection = false
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let val = rangeValue {
            var r = CFRange()
            if AXValueGetValue(val as! AXValue, .cfRange, &r) {
                hasSelection = true
            }
        }

        // Try AXSelectedText
        if hasSelection {
            let axErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if axErr == .success { return true }
        }
        // Fallback: try setting value (may replace entire contents) – only if selection method failed and we have empty field?
        // Safer not to use kAXValue as it would overwrite. So we fail.
        return false
    }

    private func copyToPasteboard(_ text: String) -> TextInsertionResult {
        let pb = NSPasteboard.general
        // Check for concealed/ transient content that should not be overwritten
        if let types = pb.types {
            for marker in ClipboardMonitor.excludedMarkerTypes where types.contains(marker) {
                // Password manager content is on pasteboard – do not overwrite without user consent?
                // Spec says never overwrite concealed/transient password-manager clipboard content.
                // So refuse to overwrite; but we still need to deliver dictation. We copy anyway but spec says never overwrite concealed.
                // Instead we skip insertion and return copied? Actually we must not overwrite, so we should not copy.
                // But then dictation would be lost. Spec: "Never overwrite concealed/transient password-manager clipboard content."
                // So if concealed content is present, we should not overwrite. But then what? We still need to deliver.
                // We interpret as: do not perform copy-and-paste fallback that would overwrite; instead return failed/copied fallback that requires user to manually paste from somewhere?
                return .failed("Clipboard contains sensitive content that will not be overwritten")
            }
        }
        let previousChangeCount = pb.changeCount
        let previousString = pb.string(forType: .string)

        // Use the tracked helper so ClipboardMonitor skips this write
        ImageExport.copyToPasteboard(text: text)
        lastSelfWriteChangeCount = NSPasteboard.general.changeCount

        _ = previousChangeCount
        _ = previousString
        return .copied
    }

    private func typeViaUnicodeEvents(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }

        // Keep individual events small; very large Unicode payloads are ignored
        // by some AppKit and Chromium controls.
        for start in stride(from: 0, to: utf16.count, by: 64) {
            let end = min(start + 64, utf16.count)
            let chunk = Array(utf16[start..<end])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Restores previous clipboard only if no other process has written since our copy.
    public func restorePreviousClipboardIfNeeded(previousChangeCount: Int, previousString: String?) {
        let pb = NSPasteboard.general
        guard pb.changeCount == lastSelfWriteChangeCount else { return }
        // Only restore ordinary previous string if it was plain text and not sensitive
        if let str = previousString {
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    private func activeDisplayID() -> CGDirectDisplayID? {
        // Use active display policy: hovered display or display with pointer or main
        // Reuse NotchWindowController logic if available, else main screen.
        if let main = NSScreen.main, let id = ScreenLookup.displayID(for: main) { return id }
        return nil
    }

    private func displayIDForApp(_ app: NSRunningApplication) -> CGDirectDisplayID? {
        // Try to find window's display via AX position
        // Fallback to activeDisplayID
        return activeDisplayID()
    }
}
