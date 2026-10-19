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

    /// The reading as a fraction, from the "64%" metric the monitor writes.
    static func level(from snapshot: ContextSnapshot) -> Double? {
        guard snapshot.kind == .power,
              let metric = snapshot.metric,
              let percent = Int(metric.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        else { return nil }
        return Double(min(max(percent, 0), 100)) / 100
    }

    /// Whether the card is about being on the adapter rather than the battery.
    static func isOnPower(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.kind == .power && (snapshot.title == "Charging" || snapshot.title == "Charged")
    }

    static func statusDescription(isLowPowerModeEnabled: Bool) -> String {
        isLowPowerModeEnabled
            ? "Low Power Mode is on"
            // The Settings button sits beside this line, so it says why rather
            // than repeating where.
            : "Turn on Low Power Mode to last longer"
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
