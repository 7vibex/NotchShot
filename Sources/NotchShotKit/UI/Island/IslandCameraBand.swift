import SwiftUI

/// The strip at the top of an open island that the camera sits in.
///
/// Expanded cards used to start their content below this strip, so every one
/// of them opened with a tall black "forehead" under the notch. Apple's
/// Live Activity guidance is that expanded content wraps the camera instead:
/// a leading group to its left, a trailing group to its right. Cards read the
/// band from the environment and put their header there.
struct IslandCameraBand: Equatable, Sendable {
    /// Width of the physical cutout, or nil on a display without one, where
    /// the island is a drawn pill and nothing sits between the two groups.
    var notchWidth: CGFloat?
    /// Height of the physical cutout's band.
    var height: CGFloat

    /// Header row height on a floating island. Shorter than a menu bar: there
    /// is no camera to clear, only the pill's rounded top edge.
    static let floatingRowHeight: CGFloat = 30

    /// Height of the header row this band gives a card.
    var rowHeight: CGFloat { notchWidth == nil ? Self.floatingRowHeight : height }

    /// Room either side of the camera, so content pressed against the
    /// cutout's edge doesn't read as clipped by it.
    static let cameraClearance: CGFloat = 12

    static let floating = IslandCameraBand(notchWidth: nil, height: floatingRowHeight)
}

extension EnvironmentValues {
    @Entry var islandCameraBand: IslandCameraBand = .floating
}

/// A card's header, laid out in the camera band: `leading` in the visible
/// strip left of the camera, `trailing` in the strip to its right.
///
/// Wing content must fit the band's height. A control may keep a larger hit
/// target than it draws; the extra simply overlaps the row below.
struct IslandBandHeader<Leading: View, Trailing: View>: View {
    var leadingInset: CGFloat = 14
    var trailingInset: CGFloat = 12
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.islandCameraBand) private var band

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .padding(.leading, band.notchWidth == nil ? leadingInset + 4 : leadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let notchWidth = band.notchWidth {
                Color.clear
                    .frame(width: notchWidth + IslandCameraBand.cameraClearance)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: NotchIsland.Spacing.group)
            }
            trailing()
                .padding(.trailing, band.notchWidth == nil ? trailingInset + 4 : trailingInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: band.rowHeight)
        // A floating pill's top edge is fully rounded; start the row a little
        // lower so neither group sits in the curve.
        .padding(.top, band.notchWidth == nil ? 4 : 0)
    }
}

/// The small icon-and-title pair most cards put in the left wing.
struct IslandBandTitle: View {
    var systemImage: String?
    var title: String
    var tint: Color = .islandInk(NotchIsland.Ink.secondary)

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A 24 pt round glyph button sized for the band, with a full hit target.
struct IslandBandButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.islandInk(isHovered ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .frame(width: 24, height: 24)
                .islandControlSurface(Circle(), isHovered: isHovered)
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
