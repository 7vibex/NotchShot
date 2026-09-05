import AppKit
import Testing
@testable import NotchShotKit

@Suite("Dictation insertion regression")
@MainActor
struct TextInsertionRegressionTests {
    @Test("Equal-length selection replacement is recognized from real text-view state")
    func sameLengthReplacement() {
        let textView = NSTextView(frame: .zero)
        textView.string = "cat"
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let before = TextInsertionService.TextFieldState(
            characters: textView.string.utf16.count, selection: textView.selectedRange()
        )

        // This is an in-memory AppKit control: no window, AX request, focus
        // change, keyboard event, or interaction with another application.
        textView.insertText("dog", replacementRange: textView.selectedRange())
        let after = TextInsertionService.TextFieldState(
            characters: textView.string.utf16.count, selection: textView.selectedRange()
        )

        #expect(textView.string == "dog")
        #expect(before.characters == after.characters)
        #expect(before.selection == NSRange(location: 0, length: 3))
        #expect(after.selection == NSRange(location: 3, length: 0))
        #expect(TextInsertionService.outcome(before: before, after: after, acknowledged: true) == .landed)
    }

    @Test("An acknowledged but unchanged field cannot trigger another insertion")
    func unchangedAcknowledgement() {
        let state = TextInsertionService.TextFieldState(
            characters: 3, selection: NSRange(location: 3, length: 0)
        )
        #expect(TextInsertionService.outcome(before: state, after: state, acknowledged: true) == .unverifiable)
        #expect(TextInsertionService.outcome(before: state, after: state, acknowledged: false) == .rejected)
    }

    @Test("Changing AX observability alone does not prove delivery")
    func observabilityChanges() {
        let unknown = TextInsertionService.TextFieldState()
        let observable = TextInsertionService.TextFieldState(
            characters: 3, selection: NSRange(location: 3, length: 0)
        )
        #expect(TextInsertionService.outcome(before: unknown, after: observable) == .unverifiable)
        #expect(TextInsertionService.outcome(before: observable, after: unknown) == .unverifiable)
    }

    @Test("Secure targets take the actual copy-only path on an isolated pasteboard")
    func secureTargetCopiesWithoutInsertion() async {
        let pasteboard = NSPasteboard(name: .init("notchshot.dictation-test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let service = TextInsertionService(pasteboard: pasteboard)
        let result = await service.insert(
            "synthetic transcript", into: DictationInsertionTarget(kind: .secure), mode: .automatic
        )
        #expect(result == .copied)
        #expect(pasteboard.string(forType: .string) == "synthetic transcript")
    }

    @Test("Secure-target fallback preserves concealed clipboard data")
    func concealedClipboardRefusal() async throws {
        let pasteboard = NSPasteboard(name: .init("notchshot.dictation-test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let marker = try #require(ClipboardMonitor.excludedMarkerTypes.first)
        pasteboard.declareTypes([.string, marker], owner: nil)
        pasteboard.setString("synthetic concealed value", forType: .string)
        pasteboard.setData(Data(), forType: marker)
        let before = pasteboard.changeCount
        let result = await TextInsertionService(pasteboard: pasteboard).insert(
            "synthetic transcript", into: DictationInsertionTarget(kind: .secure), mode: .automatic
        )
        guard case .failed = result else {
            Issue.record("Concealed clipboard content must produce a refusal")
            return
        }
        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.string(forType: .string) == "synthetic concealed value")
    }
}
