import AppKit
import SwiftUI

/// The phone's system colours on black. Kept in one place so a timer, a call
/// and the Silent pill use the same orange, green and red the iPhone's own
/// Dynamic Island does, rather than each picking its own.
enum IslandSystemColor {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let indigo = Color(red: 0.37, green: 0.36, blue: 0.90)
    /// Indigo is too dark to read as text on black; this is the same hue
    /// lifted to pass contrast, as the phone does for Focus labels.
    static let indigoText = Color(red: 0.55, green: 0.54, blue: 1.0)
    /// The neutral pill behind a white glyph (Ring, Focus Off).
    static let neutralPill = Color(white: 0.26)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
}

/// Clock strings as the phone's island writes them: no leading zero on the
/// first field, hours only when there are any — "0:08", "4:55", "1:04:55".
enum IslandClock {
    static func formatted(_ interval: TimeInterval, roundingUp: Bool = false) -> String {
        guard interval.isFinite else { return "0:00" }
        let seconds = max(0, Int(roundingUp ? interval.rounded(.up) : interval.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// The capsule the phone shows for Silent and Ring: a filled pill with a white
/// glyph in it, with the state's word on the other side of the camera.
struct IslandStatePill: View {
    var systemName: String
    var fill: Color
    var height: CGFloat = 22
    /// Draws the symbol change (a slash appearing, say) instead of swapping.
    var symbolTransition: ContentTransition = .symbolEffect(.replace)

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: height * 0.58, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(symbolTransition)
            .frame(width: height * 1.78, height: height)
            .background(fill, in: Capsule())
            .accessibilityHidden(true)
    }
}

/// Output muted: the phone's Silent indicator. The speaker arrives whole and
/// the slash is drawn across it a beat later, the way the bell is struck
/// through when the switch flips.
struct IslandSilentContent: View {
    var physicalNotchWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isStruck = false

    var body: some View {
        IslandWings(physicalNotchWidth: physicalNotchWidth) {
            IslandStatePill(
                systemName: isStruck ? "speaker.slash.fill" : "speaker.fill",
                fill: IslandSystemColor.red,
                symbolTransition: reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .replace))
            )
        } trailing: {
            Text("Silent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandSystemColor.red)
        }
        .task {
            guard !reduceMotion else {
                isStruck = true
                return
            }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.snappy(duration: 0.3)) { isStruck = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("Muted")
    }
}

/// The compact two-wing row every island indicator shares: content hugs the
/// camera's two sides, nothing is drawn behind it. On a display without a
/// cutout the wings simply sit at the pill's two ends.
struct IslandWings<Leading: View, Trailing: View>: View {
    var physicalNotchWidth: CGFloat?
    var leadingInset: CGFloat = 12
    var trailingInset: CGFloat = 12
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    private var isFloating: Bool { physicalNotchWidth == nil }

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .padding(.leading, isFloating ? NotchIsland.Geometry.floatingContentInset : leadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let physicalNotchWidth {
                Color.clear.frame(width: physicalNotchWidth).accessibilityHidden(true)
            } else {
                Spacer(minLength: NotchIsland.Spacing.element)
            }

            trailing()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, isFloating ? NotchIsland.Geometry.floatingContentInset : trailingInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A ring drawn to a battery reading, the way the phone shows AirPods charge
/// when they connect: the colour carries the state, the arc carries the level.
struct IslandBatteryRing: View {
    var percent: Int
    var diameter: CGFloat = 19
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var fraction: Double { Double(min(max(percent, 0), 100)) / 100 }
    private var tint: Color { AccessoryBatteryPolicy.tint(forPercent: percent) }
    private var lineWidth: CGFloat { max(2.5, diameter * 0.17) }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion else {
                shown = fraction
                return
            }
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) { shown = fraction }
        }
        .onChange(of: fraction) { _, value in
            withAnimation(IslandMotion.liveValue(reduceMotion: reduceMotion)) { shown = value }
        }
        .accessibilityHidden(true)
    }
}

/// An audio accessory connecting, in the island's compact shape: the device on
/// one side of the camera and its charge as a ring on the other. The full
/// left/right/case card is what the island opens to when hovered.
struct AudioAccessoryCompact: View {
    let snapshot: ContextSnapshot
    var physicalNotchWidth: CGFloat?

    @State private var arrived = 0

    private var battery: AccessoryBattery? { snapshot.accessory }
    private var isConnected: Bool { snapshot.metric == "Connected" }

    /// The lowest bud, which is the one that runs out first. A single-cell
    /// headset reports `single`.
    private var headlinePercent: Int? {
        guard let battery else { return nil }
        let buds = [battery.left, battery.right].compactMap { $0 }
        return buds.min() ?? battery.single
    }

    var body: some View {
        IslandWings(physicalNotchWidth: physicalNotchWidth) {
            Image(systemName: battery?.symbolName ?? "headphones")
                .font(.system(size: 19, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.islandInk(isConnected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .symbolEffect(.bounce, value: arrived)
        } trailing: {
            if !isConnected {
                Text("Disconnected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            } else if let percent = headlinePercent {
                IslandBatteryRing(percent: percent)
            } else {
                Text("Connected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandSystemColor.green)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            arrived += 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.subtitle ?? snapshot.title), \(isConnected ? "connected" : "disconnected")")
        .accessibilityValue(headlinePercent.map { "\($0) percent" } ?? "")
    }
}

/// The round portrait at the start of the phone's call banner. NotchShot has
/// no caller, only the app holding the microphone, so the app's icon stands
/// in, on the same grey disc the phone uses for a contact without a photo.
struct IslandCallAvatar: View {
    var bundleIdentifier: String
    var title: String
    var diameter: CGFloat = 44
    @State private var loadedIcon: NSImage?
    @State private var loadedBundleIdentifier: String?

    private var icon: NSImage? {
        if loadedBundleIdentifier == bundleIdentifier { return loadedIcon }
        return IslandAppIconCache.shared.cachedIcon(for: bundleIdentifier)
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.42))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(diameter * 0.12)
            } else {
                Text(title.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: diameter * 0.45, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .task(id: bundleIdentifier) {
            let requestedIdentifier = bundleIdentifier
            loadedBundleIdentifier = requestedIdentifier
            loadedIcon = IslandAppIconCache.shared.cachedIcon(for: requestedIdentifier)
            let resolvedIcon = await IslandAppIconCache.shared.load(for: requestedIdentifier)
            guard !Task.isCancelled, loadedBundleIdentifier == requestedIdentifier else { return }
            loadedIcon = resolvedIcon
        }
    }
}

/// Wi-Fi joining, the way the phone's status bar draws it: the bars sweep
/// outward while it connects, then settle at the real signal. The sweep is
/// the system's own variable-colour symbol effect, so the render server
/// runs it rather than a SwiftUI timer.
struct WiFiJoinGlyph: View {
    /// 0...1; nil draws full bars.
    var strength: Double?
    var size: CGFloat = 15
    var tint: Color = IslandSystemColor.green
    /// How long the sweep plays before the bars settle.
    static let sweepDuration: Duration = .milliseconds(1100)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var joined = false

    var body: some View {
        Image(systemName: "wifi", variableValue: joined ? (strength ?? 1) : 1)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeating,
                isActive: !joined
            )
            .task {
                guard !reduceMotion else {
                    joined = true
                    return
                }
                try? await Task.sleep(for: Self.sweepDuration)
                withAnimation(.easeOut(duration: 0.25)) { joined = true }
            }
            .accessibilityHidden(true)
    }
}

/// A mouse, keyboard or trackpad: the device on one wing, its charge as a
/// ring and a number on the other, like an AirPods case connecting.
struct PeripheralBatteryContent: View {
    var event: IslandTransientEvent
    var physicalNotchWidth: CGFloat?

    @State private var arrived = 0

    private var percent: Int? { event.level.map { Int(($0 * 100).rounded()) } }
    private var isLow: Bool { event.severity == .warning }

    var body: some View {
        IslandWings(physicalNotchWidth: physicalNotchWidth) {
            Image(systemName: event.symbolName)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .symbolEffect(.bounce, value: arrived)
        } trailing: {
            HStack(spacing: 6) {
                if physicalNotchWidth == nil || isLow {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isLow ? IslandSystemColor.red : Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let percent {
                    IslandBatteryRing(percent: percent)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            arrived += 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([event.detail, event.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(percent.map { "\($0) percent" } ?? "")
    }
}
