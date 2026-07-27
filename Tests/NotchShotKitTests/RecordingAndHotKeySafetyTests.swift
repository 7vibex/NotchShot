import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Recording area safety")
struct RecordingAreaSafetyTests {
    private let displays = [
        RecordingDisplayBounds(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        ),
        RecordingDisplayBounds(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100)
        ),
    ]

    @Test("A cross-display area is rejected instead of silently truncated")
    func crossDisplayAreaRejected() {
        #expect(throws: NotchShotError.captureFailed(
            "Area recordings must stay on one display. Choose a region that does not cross a display edge."
        )) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: 80, y: 10, width: 80, height: 50),
                displays: displays
            )
        }
    }

    @Test("An area partly beyond a display is clamped before becoming sourceRect")
    func clampsToDisplay() throws {
        let result = try RecordingAreaResolver.resolve(
            globalRect: CGRect(x: -20, y: -10, width: 70, height: 40),
            displays: displays
        )

        #expect(result.displayID == 1)
        #expect(result.globalRect == CGRect(x: 0, y: 0, width: 50, height: 30))
        #expect(result.displayLocalRect == CGRect(x: 0, y: 0, width: 50, height: 30))
    }

    @Test("An area outside every display is rejected")
    func rejectsOffDisplayArea() {
        #expect(throws: NotchShotError.displayNotFound) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: 250, y: 10, width: 20, height: 20),
                displays: displays
            )
        }
    }

    @Test("Non-finite recording geometry is rejected")
    func rejectsInvalidGeometry() {
        #expect(throws: NotchShotError.captureFailed("Selection has invalid geometry")) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20),
                displays: displays
            )
        }
    }
}

@Suite("Global hotkey safety")
struct GlobalHotKeySafetyTests {
    @Test("Caps Lock and Fn do not become a bare global shortcut")
    func nonCarbonModifiersAreRejected() {
        let capsLockOnly = HotKeyBinding.carbonModifiers(from: [.capsLock])
        let functionOnly = HotKeyBinding.carbonModifiers(from: [.function])
        let capsAndFunction = HotKeyBinding.carbonModifiers(from: [.capsLock, .function])

        #expect(capsLockOnly == 0)
        #expect(functionOnly == 0)
        #expect(capsAndFunction == 0)
        #expect(!HotKeyBinding(keyCode: 4, modifiers: capsLockOnly).isValidGlobalShortcut)
        #expect(!HotKeyBinding(keyCode: 4, modifiers: functionOnly).isValidGlobalShortcut)
    }

    @Test("Legitimate Carbon modifier combinations remain valid")
    func preservesLegitimateBindings() {
        let command = HotKeyBinding(
            keyCode: 4,
            modifiers: HotKeyBinding.carbonModifiers(from: [.command])
        )
        let fullCombination = HotKeyBinding(
            keyCode: 4,
            modifiers: HotKeyBinding.carbonModifiers(
                from: [.command, .shift, .option, .control, .capsLock, .function]
            )
        )

        #expect(command.modifiers == UInt32(cmdKey))
        #expect(command.isValidGlobalShortcut)
        #expect(fullCombination.modifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(fullCombination.isValidGlobalShortcut)
    }

    @Test("Unknown Carbon modifier bits are rejected")
    func rejectsUnknownModifierBits() {
        let binding = HotKeyBinding(
            keyCode: 4,
            modifiers: UInt32(cmdKey) | (1 << 31)
        )
        #expect(!binding.isValidGlobalShortcut)
    }
}
