import AppKit
@preconcurrency import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import os

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
    public var displayID: CGDirectDisplayID?
    public var kind: Kind

    public init(bundleID: String? = nil, processID: pid_t = 0, axElement: AXUIElement? = nil, displayID: CGDirectDisplayID? = nil, kind: Kind = .unknown) {
        self.bundleID = bundleID
        self.processID = processID
        self.axElement = axElement
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

    /// Maps each custom word to itself. Tolerates repeats: the Settings field
    /// keeps whatever was typed, and one word entered twice must not trap.
    static func customDictionary(from words: [String]) -> [String: String] {
        Dictionary(words.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func removeFillers(from text: String) -> String {
        // Whole tokens only, with any punctuation attached. Whitespace around
        // what stays is left as it was, so a line break survives.
        let hesitation = "\\p{P}*(?:um|uh|er|ah)\\p{P}*"
        var result = text.replacingOccurrences(
            of: "(?im)^(?:\(hesitation)(?:[ \\t]+|$))+|[ \\t]+\(hesitation)(?=\\s|$)",
            with: "",
            options: .regularExpression
        )
        // "like" and "you know" are ordinary words ("I like this", "do you know
        // him"), so they go only where the punctuation sets them apart: between
        // commas, opening a sentence, or tagged onto the end of one.
        let ambiguous = "(?:like|you know)"
        result = result.replacingOccurrences(
            of: "(?i),\\s+\(ambiguous),(?=\\s)",
            with: ",",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?im)(^|[.!?]\\s+)\(ambiguous),\\s+",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?im),\\s+\(ambiguous)(?=[.!?]|$)",
            with: "",
            options: .regularExpression
        )
        return result
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
            // Word boundaries keep "periodically" and "commander" intact. A
            // symbol closes up to the word before it; a line break also takes
            // the space after it.
            let trailing = symbol.hasPrefix("\n") ? "\\s*" : ""
            r = r.replacingOccurrences(
                of: "(?i)\\s+\(spoken)\\b\(trailing)",
                with: symbol,
                options: .regularExpression
            )
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

/// Cancel, for an insertion waiting on the target app. Read on the AX queue as
/// well as on main, so a stalled app's turn can still be called off.
public final class InsertionCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() { cancelled.withLock { $0 = true } }

    public var isCancelled: Bool { cancelled.withLock { $0 } }
}

/// Service that inserts text into the original field, with fallbacks.
@MainActor
public final class TextInsertionService {
    public static let shared = TextInsertionService()

    /// Every Accessibility message waits on the target app's main thread, so
    /// none of them run on ours. Serial, because they are one conversation with
    /// one app.
    private nonisolated static let axQueue = DispatchQueue(
        label: "com.notchshot.dictation.accessibility",
        qos: .userInitiated
    )

    /// Off the main thread this only limits how long dictation waits on a hung
    /// app, and an app that misses it degrades to the clipboard, so it does not
    /// need to be tight. The system default is several seconds.
    private nonisolated static let axMessagingTimeout: Float = 2

    private let pasteboard: NSPasteboard

    public init() { pasteboard = .general }

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    private nonisolated static func onAXQueue<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// Who the insertion is for. Answered from NSWorkspace with no message to
    /// the app, so it is settled before the notch does anything.
    public func frontmostTarget() -> DictationInsertionTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return DictationInsertionTarget(displayID: activeDisplayID())
        }
        return DictationInsertionTarget(
            bundleID: app.bundleIdentifier,
            processID: app.processIdentifier,
            displayID: activeDisplayID()
        )
    }

    /// Adds the focused field to `target`. Never reads surrounding text.
    ///
    /// NotchShot does not activate, so awaiting this does not change what is
    /// focused in the other app. Requires Accessibility permission to read other
    /// apps' AX.
    public func resolvingFocusedField(of target: DictationInsertionTarget) async -> DictationInsertionTarget {
        guard target.processID != 0 else { return target }
        return await Self.onAXQueue {
            var target = target
            guard AXIsProcessTrusted() else { return target }
            let appElement = AXUIElementCreateApplication(target.processID)
            AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)
            var focused: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
            if err == .success, let element = focused {
                // CFTypeRef is AXUIElement
                let ax = (element as! AXUIElement)
                AXUIElementSetMessagingTimeout(ax, Self.axMessagingTimeout)
                if Self.isSecureField(ax) {
                    target.kind = .secure
                } else if Self.isEditable(ax) {
                    target.kind = .editable
                    target.axElement = ax
                }
            }
            return target
        }
    }

    public func insert(
        _ text: String,
        into target: DictationInsertionTarget,
        mode: DictationInsertMode,
        cancellation: InsertionCancellation = InsertionCancellation()
    ) async -> TextInsertionResult {
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
        if target.axElement != nil {
            let front = FrontmostApp.current()
            let attempt = await Self.onAXQueue {
                Self.attemptAXInsertion(text, into: target, front: front, cancellation: cancellation)
            }
            // The main actor kept running through that, so Cancel can have come.
            if cancellation.isCancelled { return .failed("Dictation was cancelled") }
            switch attempt {
            case .landed:
                return .inserted
            case .unverifiable:
                // The field publishes nothing we can compare, so there is
                // no way to tell an insertion from a no-op. Typing it a
                // second time would risk two copies of the transcript, so
                // take the recoverable outcome and say so.
                return copyToPasteboard(text)
            case .misdelivered:
                // `insertViaAX` sets the element directly rather than
                // posting keyboard events, so this outcome cannot arise
                // here; falling through keeps the switch total.
                break
            case .rejected:
                // Web editors and several Electron apps expose an editable
                // AX target but reject AXSelectedText. Unicode keyboard
                // events are a clipboard-free fallback and remain scoped to
                // the same re-verified focused element. Nothing was
                // inserted above, so this cannot double up.
                switch await typeViaUnicodeEvents(text, into: target, cancellation: cancellation) {
                case .landed:
                    return .inserted
                case .misdelivered:
                    // The target moved away while the keystrokes were in
                    // flight. The events may have landed in whatever the
                    // user focused instead, and a clipboard write would
                    // deliver the transcript a second time in a place the
                    // user did not ask for. Stop and say so.
                    return .failed("The insertion target changed while typing; the text was not copied or re-inserted")
                default:
                    break
                }
            }
            if cancellation.isCancelled { return .failed("Dictation was cancelled") }
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

    /// NSWorkspace's answer, read on the main actor and carried to the AX queue.
    private struct FrontmostApp: Sendable {
        var bundleID: String?
        var processID: pid_t?

        @MainActor static func current() -> FrontmostApp {
            let app = NSWorkspace.shared.frontmostApplication
            return FrontmostApp(bundleID: app?.bundleIdentifier, processID: app?.processIdentifier)
        }
    }

    /// `.unverifiable` also covers every reason not to try at all: each leads
    /// the caller to the clipboard and never to a second delivery.
    private nonisolated static func attemptAXInsertion(
        _ text: String,
        into target: DictationInsertionTarget,
        front: FrontmostApp,
        cancellation: InsertionCancellation
    ) -> InsertionOutcome {
        guard !cancellation.isCancelled, let element = target.axElement, AXIsProcessTrusted() else { return .unverifiable }
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        guard !isSecureField(element), isEditable(element) else { return .unverifiable }
        // Re-verify element is still focused and belongs to same app
        guard targetStillValid(target, element: element, front: front) else { return .unverifiable }
        return insertViaAX(text, into: element)
    }

    private nonisolated static func isEditable(_ element: AXUIElement) -> Bool {
        // An explicit false is authoritative. Some web editors omit AXEditable,
        // so in that case require a known text-entry role instead of assuming
        // every focused control can accept text.
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let boolVal = editable as? Bool {
            return boolVal
        }
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
            return editableRoles.contains(roleStr)
        }
        return false
    }

    /// A field that does not answer in time counts as secure: a password field
    /// is a hard boundary, and a slow app must not be able to talk its way past
    /// it. Both outcomes end on the clipboard rather than in the field.
    private nonisolated static func isSecureField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if roleError == .cannotComplete { return true }
        if roleError == .success, let r = role as? String, r == "AXSecureTextField" {
            return true
        }
        var subrole: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if subroleError == .cannotComplete { return true }
        if subroleError == .success, let s = subrole as? String, s == kAXSecureTextFieldSubrole as String {
            return true
        }
        // Also check AXSecureTextField trait via description?
        return false
    }

    private nonisolated static func targetStillValid(
        _ target: DictationInsertionTarget,
        element: AXUIElement,
        front: FrontmostApp
    ) -> Bool {
        if front.processID == nil { return false }
        if front.bundleID != target.bundleID { return false }
        if front.processID != target.processID { return false }
        // The original app being frontmost is not enough: the user may have
        // moved focus to another field (including a password field) while
        // speaking. CFEqual gives us the AX identity check we need.
        var focused: CFTypeRef?
        let appElement = AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) != .success {
            return false
        }
        guard let focused else { return false }
        return CFEqual(focused, element)
    }

    /// What actually became of an insertion attempt.
    ///
    /// `.success` from the Accessibility API means the target accepted the
    /// message, not that it changed anything — several web and Electron editors
    /// return success from `AXSelectedText` and then ignore it — and posted key
    /// events are fire-and-forget by construction. Both used to be reported as
    /// an insertion, which is how dictation came to announce text it had never
    /// delivered.
    enum InsertionOutcome: Equatable {
        /// The field moved: the text is in.
        case landed
        /// The insertion method refused the operation or no change was observed
        /// after unacknowledged keyboard delivery.
        case rejected
        /// The field exposes no comparable state or acknowledges an operation
        /// without an observable change. No retry is allowed here —
        /// a second attempt would double the text if the first one did work.
        case unverifiable
        /// The target stopped being the focused element while the events were
        /// in flight. Whatever received the keystrokes, it was not the field
        /// the user dictated into, and no further delivery may be attempted.
        case misdelivered
    }

    /// A content-free fingerprint of a text element: how many characters it
    /// holds and where the caret sits. Both are numbers, so verifying an
    /// insertion does not weaken the rule that this service never reads what
    /// the user already has in the field.
    ///
    /// Retain the whole selection: an equal-length replacement leaves both
    /// character count and selection end unchanged, but collapses its length.
    struct TextFieldState: Equatable {
        var characters: Int?
        var selection: NSRange?
        /// The app missed the deadline on the selection. It may still be
        /// working, which says nothing about whether the field has one.
        var selectionTimedOut = false
    }

    private nonisolated static func fieldState(of element: AXUIElement) -> TextFieldState {
        var state = TextFieldState()

        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &count
        ) == .success {
            state.characters = count as? Int
        }

        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        state.selectionTimedOut = rangeError == .cannotComplete
        if rangeError == .success, let value = rangeValue {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range),
               range.location >= 0, range.length >= 0 {
                state.selection = NSRange(location: range.location, length: range.length)
            }
        }
        return state
    }

    /// Compares the field either side of an attempt. An element that told us
    /// nothing before is unverifiable however it looks afterwards.
    nonisolated static func outcome(
        before: TextFieldState,
        after: TextFieldState,
        acknowledged: Bool = false
    ) -> InsertionOutcome {
        let counts = before.characters.flatMap { count in after.characters.map { count != $0 } }
        let selections = before.selection.flatMap { range in after.selection.map { range != $0 } }
        if counts == true || selections == true { return .landed }
        // Missing/changing AX observability is not evidence that text landed.
        // An acknowledged but unchanged snapshot may also be stale: never type
        // a second copy solely because the target has not published its edit.
        if acknowledged || (counts == nil && selections == nil) { return .unverifiable }
        return .rejected
    }

    /// Nil when the field can take an insertion. A field with no selection is
    /// left to the keyboard fallback, but one that is only slow must not get
    /// keystrokes it will deliver late, so it ends on the clipboard.
    nonisolated static func outcomeBeforeInserting(with state: TextFieldState) -> InsertionOutcome? {
        if state.selectionTimedOut { return .unverifiable }
        return state.selection == nil ? .rejected : nil
    }

    private nonisolated static func insertViaAX(_ text: String, into element: AXUIElement) -> InsertionOutcome {
        // Setting the selected text inserts at the cursor. Setting kAXValue
        // would overwrite the whole field, so a target that has no selection
        // range to insert into is left to the fallback instead.
        let before = fieldState(of: element)
        if let outcome = outcomeBeforeInserting(with: before) { return outcome }

        let axErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        // A timeout is not a refusal: a slow app may still apply the text, and
        // treating it as rejected would type a second copy on top.
        if axErr == .cannotComplete { return .unverifiable }
        guard axErr == .success else { return .rejected }
        return outcome(before: before, after: fieldState(of: element), acknowledged: true)
    }

    private func copyToPasteboard(_ text: String) -> TextInsertionResult {
        let pb = pasteboard
        // Never overwrite concealed or transient password-manager content, even
        // though that leaves this transcript undelivered.
        if let types = pb.types {
            for marker in ClipboardMonitor.excludedMarkerTypes where types.contains(marker) {
                return .failed("Clipboard contains sensitive content that will not be overwritten")
            }
        }

        // Use the tracked helper so ClipboardMonitor skips this write
        ImageExport.copyToPasteboard(text: text, to: pb)
        return .copied
    }

    /// Posted key events are fire-and-forget: `post` returns nothing about
    /// whether the front app was listening, so this reports what the field did,
    /// not what was sent. The events need a moment to cross to the other
    /// process and be handled before that reading means anything.
    private func typeViaUnicodeEvents(
        _ text: String,
        into target: DictationInsertionTarget,
        cancellation: InsertionCancellation
    ) async -> InsertionOutcome {
        // `target` carries the element across: it is what makes it Sendable.
        let before = await Self.onAXQueue { () -> TextFieldState? in
            guard !cancellation.isCancelled, let element = target.axElement, AXIsProcessTrusted() else { return nil }
            let state = Self.fieldState(of: element)
            return Self.postUnicodeEvents(text) ? state : nil
        }
        guard let before else { return .rejected }

        try? await Task.sleep(for: .milliseconds(120))
        // The focus was verified before the first chunk was posted, but the
        // user can click or type during the settle window. Events go to
        // whatever is focused now, so a moved target is reported as
        // misdelivered rather than compared against a field that legitimately
        // never received them.
        let front = FrontmostApp.current()
        return await Self.onAXQueue { () -> InsertionOutcome in
            guard let element = target.axElement,
                  Self.targetStillValid(target, element: element, front: front) else {
                return .misdelivered
            }
            return Self.outcome(before: before, after: Self.fieldState(of: element))
        }
    }

    /// Whether every chunk was posted.
    private nonisolated static func postUnicodeEvents(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }
        for chunk in unicodeEventChunks(utf16) {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            // Virtual key 0 is 'a'. Posting the pair without the payload
            // attached would type that letter instead of the transcript, so a
            // chunk that cannot be addressed is abandoned rather than sent.
            var attached = false
            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                attached = true
            }
            guard attached else { return false }
            // A modifier the user is still holding would turn the 'a' into a
            // shortcut such as Select All, and the next chunk would replace it.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Keep individual events small; very large Unicode payloads are ignored by
    /// some AppKit and Chromium controls. A chunk never ends between the two
    /// halves of a surrogate pair, which would deliver two replacement glyphs.
    nonisolated static func unicodeEventChunks(_ utf16: [UInt16], size: Int = 64) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var start = 0
        while start < utf16.count {
            var end = min(start + size, utf16.count)
            if end < utf16.count, end - start > 1, UTF16.isLeadSurrogate(utf16[end - 1]) {
                end -= 1
            }
            chunks.append(Array(utf16[start..<end]))
            start = end
        }
        return chunks
    }

    private func activeDisplayID() -> CGDirectDisplayID? {
        if let main = NSScreen.main, let id = ScreenLookup.displayID(for: main) { return id }
        return nil
    }
}
