import AppKit
import SwiftUI

/// A transient low-battery alert backed by the real IOKit reading carried in
/// `ContextSnapshot`. Low Power Mode is observed through Foundation and the
/// action hands off to System Settings, which owns the writable control.
struct BatteryAlertCard: View {
    let snapshot: ContextSnapshot
    var onOpenBatterySettings: () -> Void

    @State private var isLowPowerModeEnabled: Bool

    init(
        snapshot: ContextSnapshot,
        isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        onOpenBatterySettings: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onOpenBatterySettings = onOpenBatterySettings
        _isLowPowerModeEnabled = State(initialValue: isLowPowerModeEnabled)
    }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemYellow
        ))
    }

    var body: some View {
        NotchAlertRow(
            title: snapshot.title,
            meta: snapshot.metric,
            metaColor: accent,
            subtitle: PowerModePresentationPolicy.statusDescription(
                isLowPowerModeEnabled: isLowPowerModeEnabled
            )
        ) {
            IslandBatteryGlyph(
                level: PowerModePresentationPolicy.level(from: snapshot) ?? 0.2,
                tint: accent,
                width: 30
            )
            .frame(width: 34, height: 34)
        } trailing: {
            NotchAlertTextButton(
                title: "Settings",
                help: PowerModePresentationPolicy.settingsAccessibilityLabel(
                    isLowPowerModeEnabled: isLowPowerModeEnabled
                ),
                action: onOpenBatterySettings
            )
        }
        .padding(.horizontal, NotchAlertStyle.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(
            for: .NSProcessInfoPowerStateDidChange
        )) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Low battery, \(snapshot.metric ?? "battery level unavailable")")
        .accessibilityValue(PowerModePresentationPolicy.statusDescription(
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ))
    }
}
