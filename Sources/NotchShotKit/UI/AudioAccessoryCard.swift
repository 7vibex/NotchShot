import AppKit
import SwiftUI

/// The card shown when an audio accessory connects or disconnects.
///
/// The generic context card said "Audio Connected / <name> / Connected", which
/// is three ways of saying the same thing and nothing you didn't already know
/// from the sound changing. This shows the two facts worth a card: which
/// accessory it is, and how much charge it has left.
///
/// The artwork is an SF Symbol — Apple ships symbols for its own hardware, so
/// an accessory is drawn with the system's own glyph rather than a picture of
/// someone else's product, and anything unrecognised stays a plain pair of
/// headphones instead of pretending to be an Apple device.
struct AudioAccessoryCard: View {
    let snapshot: ContextSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isFloating = false

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemGreen
        ))
    }

    private var battery: AccessoryBattery? { snapshot.accessory }

    private var isConnected: Bool { snapshot.metric == "Connected" }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.group) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.subtitle ?? snapshot.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let battery, battery.hasAnyLevel {
                levels(for: battery)
            }
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.vertical, NotchIsland.Spacing.row)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: snapshot.subtitle) {
            guard !reduceMotion, isConnected else { return }
            // A beat's delay so the float starts after the card has settled
            // rather than fighting the island's own expansion.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            isFloating = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.subtitle ?? snapshot.title), \(isConnected ? "connected" : "disconnected")")
        .accessibilityValue(accessibilityValue)
    }

    /// The case drifts, the way it does when Apple presents one. The motion is
    /// small on purpose: this card appears unbidden, so it should not be the
    /// liveliest thing on screen.
    private var artwork: some View {
        Image(systemName: battery?.symbolName ?? "headphones")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 46, height: 46)
            .offset(y: isFloating ? -3 : 3)
            .shadow(
                color: accent.opacity(isFloating ? 0.34 : 0.16),
                radius: isFloating ? 12 : 6,
                y: isFloating ? 6 : 3
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                value: isFloating
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func levels(for battery: AccessoryBattery) -> some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            if let single = battery.single, battery.left == nil, battery.right == nil {
                level("", single)
            } else {
                if let left = battery.left { level("L", left) }
                if let right = battery.right { level("R", right) }
            }
            if let enclosure = battery.enclosure {
                level("Case", enclosure, symbol: "case.fill")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func level(_ label: String, _ percent: Int, symbol: String? = nil) -> some View {
        VStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .accessibilityHidden(true)
            } else if !label.isEmpty {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }

            Text("\(percent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .monospacedDigit()

            // A bar rather than a battery outline: at this size an outline is
            // three grey pixels and a suggestion, and the colour is doing the
            // work anyway.
            Capsule()
                .fill(Color.islandInk(NotchIsland.Ink.recessed))
                .frame(width: 26, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(AccessoryBatteryPolicy.tint(forPercent: percent))
                        .frame(width: max(3, 26 * CGFloat(percent) / 100), height: 3)
                }
        }
    }

    private var accessibilityValue: String {
        guard let battery, battery.hasAnyLevel else { return "" }
        var parts: [String] = []
        if let left = battery.left { parts.append("left \(left) percent") }
        if let right = battery.right { parts.append("right \(right) percent") }
        if let single = battery.single, battery.left == nil { parts.append("\(single) percent") }
        if let enclosure = battery.enclosure { parts.append("case \(enclosure) percent") }
        return parts.joined(separator: ", ")
    }
}

/// One place decides when a level is low, so the colour and any future warning
/// copy cannot disagree about it.
enum AccessoryBatteryPolicy {
    static let lowThreshold = 20
    static let mediumThreshold = 50

    static func tint(forPercent percent: Int) -> Color {
        if percent <= lowThreshold { return .red }
        if percent <= mediumThreshold { return .orange }
        return .green
    }
}
