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

    private var battery: AccessoryBattery? { snapshot.accessory }

    private var isConnected: Bool { snapshot.metric == "Connected" }

    var body: some View {
        NotchAlertRow(
            title: snapshot.subtitle ?? snapshot.title,
            subtitle: isConnected ? "Connected" : "Disconnected"
        ) {
            artwork
        } trailing: {
            if let battery, battery.hasAnyLevel {
                levels(for: battery)
            }
        }
        .padding(.horizontal, NotchAlertStyle.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.subtitle ?? snapshot.title), \(isConnected ? "connected" : "disconnected")")
        .accessibilityValue(accessibilityValue)
    }

    /// The case drifts, the way it does when Apple presents one. The motion is
    /// small on purpose: this card appears unbidden, so it should not be the
    /// liveliest thing on screen.
    private var artwork: some View {
        // A beat's delay so the float starts after the card has settled
        // rather than fighting the island's own expansion.
        LayerDrift(amplitude: 2, halfPeriod: 2.2, delay: 0.12, drifts: isConnected) {
            Image(systemName: battery?.symbolName ?? "headphones")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.islandInk(isConnected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .symbolRenderingMode(.hierarchical)
        }
        // A new accessory starts its drift over.
        .id(snapshot.subtitle)
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .accessibilityHidden(true)
            } else if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }

            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold))
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
