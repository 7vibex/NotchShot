import AppKit
import Testing
@testable import NotchShotKit

@MainActor
private final class MenuCommandFixture: NSObject {
    var quits = 0
    var settings = 0
    @objc func quit(_ sender: Any?) { quits += 1 }
    @objc func openSettings(_ sender: Any?) { settings += 1 }
}

@Suite("Call actions and application commands", .serialized)
@MainActor
struct CallControlsAndMenuRegressionTests {
    @Test("Unknown call state describes a toggle rather than an assumed direction")
    func togglePresentation() {
        for (bundle, name) in [("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.hnc.Discord", "Discord"), ("com.tinyspeck.slackmacgap", "Slack")] {
            let presentation = MeetingControls.microphonePresentation(for: bundle)
            #expect(presentation.label == "Toggle microphone in \(name)")
            #expect(presentation.help.contains("current microphone state"))
        }
        let browser = MeetingControls.microphonePresentation(for: "com.google.Chrome")
        #expect(browser.label == "Toggle system microphone mute")
        #expect(browser.help.contains("every app"))
    }

    @Test("The application menu dispatches Quit and Settings without an open status menu")
    func menuKeyEquivalents() throws {
        _ = NSApplication.shared
        let target = MenuCommandFixture()
        let menu = AppCommandMenu.make(target: target, settings: #selector(MenuCommandFixture.openSettings(_:)), quit: #selector(MenuCommandFixture.quit(_:)))
        for (key, code) in [("q", UInt16(12)), (",", UInt16(43))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event))
        }
        #expect(target.quits == 1 && target.settings == 1)
    }
}
