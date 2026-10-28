import AppKit
import Testing
@testable import NotchShotKit

@MainActor
private final class MenuCommandFixture: NSObject {
    var quits = 0
    var settings = 0
    var closes = 0
    @objc func quit(_ sender: Any?) { quits += 1 }
    @objc func openSettings(_ sender: Any?) { settings += 1 }
    @objc func performClose(_ sender: Any?) { closes += 1 }
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

    @Test("A system mute set for calls is released only when all of them have ended")
    func systemMuteHoldEndsWithItsCalls() {
        let hold = SystemMuteHold(device: 42, calls: ["com.google.Chrome", "com.apple.Safari"])
        // Unrelated calls neither keep it nor end it.
        #expect(hold.remaining(live: ["com.google.Chrome", "us.zoom.xos"])
            == SystemMuteHold(device: 42, calls: ["com.google.Chrome"]))
        #expect(hold.remaining(live: ["com.apple.Safari"])?.calls == ["com.apple.Safari"])
        #expect(hold.remaining(live: ["us.zoom.xos"]) == nil)
        #expect(hold.remaining(live: []) == nil)
    }

    @Test("The application menu dispatches Quit, Settings and Command-W")
    func menuKeyEquivalents() throws {
        _ = NSApplication.shared
        let target = MenuCommandFixture()
        let menu = AppCommandMenu.make(target: target, settings: #selector(MenuCommandFixture.openSettings(_:)), quit: #selector(MenuCommandFixture.quit(_:)))
        let close = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(NSWindow.performClose(_:)) })
        #expect(close.target == nil)
        // The unbundled runner has no key window. Supply a receiver to prove
        // key dispatch; the signed app's actual responder chain is tested live.
        close.target = target
        for (key, code) in [("q", UInt16(12)), (",", UInt16(43)), ("w", UInt16(13))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event))
        }
        #expect(target.quits == 1 && target.settings == 1 && target.closes == 1)
    }
}
