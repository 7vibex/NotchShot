import SwiftUI

/// A battery drawn at its real level, the way the phone's island draws it: a
/// solid body whose charged part is the full colour and whose empty part is
/// the same colour dimmed, with a small cap. No outline — at this size an
/// outline is a grey ring that competes with the fill. The SF battery symbols
/// only come in quarter steps, which made 64% and 51% look identical.
struct IslandBatteryGlyph: View {
    var level: Double
    var tint: Color
    var width: CGFloat = 26
    /// Fills from empty on first appearance, like a charge flowing in.
    var animatesIn = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownLevel: Double?

    private var height: CGFloat { width * 0.48 }
    private var clamped: Double { min(max(level, 0), 1) }

    var body: some View {
        let body = RoundedRectangle(cornerRadius: height * 0.34, style: .continuous)
        HStack(spacing: width * 0.05) {
            ZStack(alignment: .leading) {
                body.fill(tint.opacity(0.3))
                GeometryReader { proxy in
                    Rectangle()
                        .fill(tint)
                        .frame(width: proxy.size.width * (shownLevel ?? clamped))
                }
                .clipShape(body)
            }
            .frame(width: width * 0.89, height: height)
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: width * 0.04, topTrailing: width * 0.04),
                style: .continuous
            )
            .fill(tint.opacity(0.4))
            .frame(width: max(1.5, width * 0.06), height: height * 0.38)
        }
        .frame(width: width, height: height)
        .onAppear {
            guard animatesIn, !reduceMotion else { return }
            shownLevel = 0
            withAnimation(.easeOut(duration: 0.7).delay(0.12)) { shownLevel = nil }
        }
        .accessibilityHidden(true)
    }
}

/// The compact burst for plugging in, unplugging, or reaching full: the state
/// on the leading wing, the level on the trailing wing, the camera between.
struct PowerCompactStrip: View {
    var snapshot: ContextSnapshot
    var physicalNotchWidth: CGFloat?
    var onExpand: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glows = false

    private var level: Double { PowerModePresentationPolicy.level(from: snapshot) ?? 0 }
    private var isOnPower: Bool { PowerModePresentationPolicy.isOnPower(snapshot) }

    private var tint: Color {
        if isOnPower { return IslandSystemColor.green }
        return level <= 0.2 ? Color(red: 1, green: 0.84, blue: 0.04) : .white
    }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 0) {
                // The phone writes the state in white and lets the number and
                // the battery carry the colour.
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let physicalNotchWidth {
                    Color.clear.frame(width: physicalNotchWidth).accessibilityHidden(true)
                } else {
                    Spacer(minLength: 8)
                }

                HStack(spacing: 6) {
                    Text(snapshot.metric ?? "")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    IslandBatteryGlyph(level: level, tint: tint, width: 27, animatesIn: isOnPower)
                }
                .padding(.trailing, 11)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)
            // A brief green breath along the bottom edge when power arrives,
            // the island's way of saying "it worked" without a sound.
            .background(alignment: .bottom) {
                if isOnPower {
                    // Faded as a whole rather than by recolouring the fill:
                    // a changing fill re-blurs the glow on every frame, while
                    // an opacity change composites the one blurred layer.
                    Capsule()
                        .fill(tint.opacity(0.55))
                        .frame(height: 10)
                        .blur(radius: 8)
                        .offset(y: 10)
                        .opacity(glows ? 0 : 1)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard isOnPower, !reduceMotion else {
                glows = true
                return
            }
            withAnimation(.easeOut(duration: 1.4).delay(0.3)) { glows = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.metric ?? "")
    }
}
