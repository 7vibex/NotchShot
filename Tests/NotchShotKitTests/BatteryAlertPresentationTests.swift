import SwiftUI
import Testing
@testable import NotchShotKit

@Suite("Battery alert presentation")
struct BatteryAlertPresentationTests {
    @Test("Only the real low internal-battery transition uses the alert card")
    func alertRouting() throws {
        let previous = PowerSourceReading(
            percentage: 65,
            isConnectedToPower: false,
            isCharging: false
        )
        let current = PowerSourceReading(
            percentage: 15,
            isConnectedToPower: false,
            isCharging: false
        )
        let lowBattery = try #require(PowerContextPolicy.snapshot(
            previous: previous,
            current: current
        ))
        let charging = ContextSnapshot(kind: .power, title: "Charging", metric: "15%")
        let unrelated = ContextSnapshot(kind: .document, title: "Low Battery", metric: "15%")

        #expect(PowerModePresentationPolicy.isLowBatteryAlert(lowBattery))
        #expect(lowBattery.accentHex == "#FFD60A")
        #expect(!PowerModePresentationPolicy.isLowBatteryAlert(charging))
        #expect(!PowerModePresentationPolicy.isLowBatteryAlert(unrelated))
    }

    @Test("The Low Power action names the real System Settings handoff")
    func settingsHandoffCopy() throws {
        let url = try #require(PowerModePresentationPolicy.batterySettingsURL)

        #expect(url.scheme == "x-apple.systempreferences")
        #expect(PowerModePresentationPolicy.statusDescription(
            isLowPowerModeEnabled: true
        ) == "Low Power Mode is on")
        #expect(PowerModePresentationPolicy.settingsAccessibilityLabel(
            isLowPowerModeEnabled: false
        ) == "Open Battery Settings to enable Low Power Mode")
    }

    @MainActor
    @Test("The low-battery card renders at the compact alert contract size")
    func cardRenders() throws {
        let card = BatteryAlertCard(
            snapshot: ContextSnapshot(
                kind: .power,
                title: "Low Battery",
                subtitle: "Using internal battery",
                metric: "10%",
                accentHex: "#FFD60A"
            ),
            isLowPowerModeEnabled: false,
            onOpenBatterySettings: {}
        )
        .frame(width: 410, height: 78)

        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: 410, height: 78)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)

        #expect(image.size == CGSize(width: 410, height: 78))
        #expect(!(image.tiffRepresentation?.isEmpty ?? true))
    }
}
