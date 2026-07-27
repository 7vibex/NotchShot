import Foundation
import Testing
@testable import NotchShotKit

@Suite("System integration ownership")
@MainActor
struct SystemIntegrationSafetyTests {
    private final class FakeSymbolicHotKeys {
        var enabled: [Int32: Bool]
        var mutations: [(Int32, Bool)] = []

        init(enabled: [Int32: Bool]) {
            self.enabled = enabled
        }

        func set(_ identifier: Int32, _ value: Bool) -> Int32 {
            mutations.append((identifier, value))
            enabled[identifier] = value
            return 0
        }

        func get(_ identifier: Int32) -> Bool {
            enabled[identifier] ?? false
        }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "notchshot.system-integration-tests.\(UUID().uuidString)")!
    }

    @Test("A user-disabled macOS shortcut is never claimed or restored")
    func preservesUserDisabledShortcut() {
        let system = FakeSymbolicHotKeys(enabled: [30: false])
        let controller = SystemScreenshotHotKeys(
            defaults: defaults(),
            setEnabled: system.set,
            isEnabled: system.get
        )

        controller.takeOver([.areaToFile])
        controller.restoreAll()

        #expect(system.mutations.isEmpty)
        #expect(system.enabled[30] == false)
    }

    @Test("A persisted claim is the only shortcut recovered after a crash")
    func restoresOnlyPersistedClaim() {
        let storage = defaults()
        let system = FakeSymbolicHotKeys(enabled: [30: true, 184: false, 28: false])
        var controller: SystemScreenshotHotKeys? = SystemScreenshotHotKeys(
            defaults: storage,
            setEnabled: system.set,
            isEnabled: system.get
        )

        controller?.takeOver([.areaToFile, .screenshotPanel])
        #expect(system.enabled[30] == false)
        #expect(system.enabled[184] == false)

        // Simulate a fresh process after a crash: in-memory ownership is gone,
        // but the isolated defaults domain still contains the exact claim.
        controller = SystemScreenshotHotKeys(
            defaults: storage,
            setEnabled: system.set,
            isEnabled: system.get
        )
        controller?.restoreAll()

        #expect(system.enabled[30] == true)
        #expect(system.enabled[184] == false)
        #expect(system.enabled[28] == false)
        #expect(system.mutations.filter { $0.1 }.map(\.0) == [30])
    }
}
