import AppKit
import Foundation

/// Presentation and routing rules for the low-battery alert.
///
/// Foundation exposes the current Low Power Mode state as read-only. The
/// supported mutation surface belongs to System Settings, so the alert offers
/// a direct handoff instead of running `pmset` or presenting a fake switch.
enum PowerModePresentationPolicy {
    static let lowBatteryTitle = "Low Battery"

    static var batterySettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.battery")
    }

    static func isLowBatteryAlert(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.kind == .power && snapshot.title == lowBatteryTitle
    }

    static func statusDescription(isLowPowerModeEnabled: Bool) -> String {
        isLowPowerModeEnabled
            ? "Low Power Mode is on"
            : "Open Battery Settings to enable Low Power Mode"
    }

    static func settingsAccessibilityLabel(isLowPowerModeEnabled: Bool) -> String {
        isLowPowerModeEnabled
            ? "Open Battery Settings. Low Power Mode is on"
            : "Open Battery Settings to enable Low Power Mode"
    }
}

@MainActor
enum BatterySettingsService {
    @discardableResult
    static func open() -> Bool {
        guard let url = PowerModePresentationPolicy.batterySettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }
}
