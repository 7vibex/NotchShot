import AppKit
import SwiftUI

/// A transient low-battery alert backed by the real IOKit reading carried in
/// `ContextSnapshot`. Low Power Mode is observed through Foundation and the
/// action hands off to System Settings, which owns the writable control.
struct BatteryAlertCard: View {
    let snapshot: ContextSnapshot
    var onOpenBatterySettings: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        ZStack {
            forestBackdrop
            legibilityScrim
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .stroke(
                    Color.islandInk(NotchIsland.Ink.hairline),
                    lineWidth: NotchIsland.Stroke.hairline
                )
        }
        .padding(.horizontal, NotchIsland.Spacing.row)
        .padding(.vertical, NotchIsland.Spacing.snug)
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

    private var content: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            Image(systemName: "battery.25percent")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.42), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: NotchIsland.Spacing.tight) {
                    Text(snapshot.title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    if let metric = snapshot.metric, !metric.isEmpty {
                        Text(metric)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))

                Text(PowerModePresentationPolicy.statusDescription(
                    isLowPowerModeEnabled: isLowPowerModeEnabled
                ))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)
            }

            Spacer(minLength: NotchIsland.Spacing.tight)
            settingsButton
        }
        .padding(.leading, NotchIsland.Spacing.element)
        .padding(.trailing, NotchIsland.Spacing.tight)
    }

    private var settingsButton: some View {
        Button(action: onOpenBatterySettings) {
            HStack(spacing: NotchIsland.Spacing.tight) {
                Image(systemName: isLowPowerModeEnabled ? "bolt.fill" : "gearshape.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(isLowPowerModeEnabled ? "On" : "Set")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(isLowPowerModeEnabled ? Color.black : accent)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                isLowPowerModeEnabled ? accent : accent.opacity(0.16),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(accent.opacity(0.44), lineWidth: NotchIsland.Stroke.hairline)
            }
            .frame(minWidth: NotchIsland.Hit.control, minHeight: NotchIsland.Hit.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(PowerModePresentationPolicy.settingsAccessibilityLabel(
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ))
        .accessibilityLabel(PowerModePresentationPolicy.settingsAccessibilityLabel(
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ))
    }

    /// A deterministic, asset-free woodland treatment keeps the visual warmth
    /// of the reference without shipping a decorative photo or doing work on a
    /// ten-second system alert.
    private var forestBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: reduceTransparency
                    ? [Color(red: 0.06, green: 0.10, blue: 0.07), Color.black]
                    : [
                        Color(red: 0.10, green: 0.23, blue: 0.14),
                        Color(red: 0.18, green: 0.10, blue: 0.05)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .bottom, spacing: 23) {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(index.isMultiple(of: 2)
                            ? Color(red: 0.34, green: 0.18, blue: 0.08)
                            : Color(red: 0.21, green: 0.29, blue: 0.14))
                        .frame(
                            width: CGFloat(9 + (index % 3) * 3),
                            height: CGFloat(66 + (index % 4) * 9)
                        )
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2 : 2))
                }
            }
            .opacity(reduceTransparency ? 0.18 : 0.56)
            .blur(radius: reduceTransparency ? 0 : 1.2)
        }
        .accessibilityHidden(true)
    }

    private var legibilityScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.80), Color.black.opacity(0.38), Color.black.opacity(0.70)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .accessibilityHidden(true)
    }
}
