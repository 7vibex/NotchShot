import SwiftUI

/// The one layout every transient alert in the notch uses: a 36 pt mark, a
/// title with optional metadata on its baseline, one secondary line, and
/// whatever controls the alert needs at the trailing edge.
///
/// It sits directly on the island's black, like the music player. The earlier
/// cards each drew a bordered box inside the island, a coloured glow or a
/// painted backdrop, and picked their own type sizes between 7.5 and 15 pt;
/// side by side they read as five different apps.
struct NotchAlertRow<Leading: View, Trailing: View>: View {
    var title: String
    var meta: String? = nil
    var metaColor: Color = .islandInk(NotchIsland.Ink.tertiary)
    var subtitle: String? = nil
    var subtitleLines: Int = 1
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: NotchAlertStyle.leadingGap) {
            leading()
                .frame(width: NotchAlertStyle.markSize, height: NotchAlertStyle.markSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: NotchIsland.Spacing.snug) {
                    Text(title)
                        .font(NotchAlertStyle.title)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let meta, !meta.isEmpty {
                        Text(meta)
                            .font(NotchAlertStyle.meta)
                            .monospacedDigit()
                            .foregroundStyle(metaColor)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(subtitleLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: subtitleLines > 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
    }
}

extension NotchAlertRow where Trailing == EmptyView {
    init(
        title: String,
        meta: String? = nil,
        metaColor: Color = .islandInk(NotchIsland.Ink.tertiary),
        subtitle: String? = nil,
        subtitleLines: Int = 1,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title,
            meta: meta,
            metaColor: metaColor,
            subtitle: subtitle,
            subtitleLines: subtitleLines,
            leading: leading,
            trailing: { EmptyView() }
        )
    }
}

/// Shared measurements and type for notch alerts.
enum NotchAlertStyle {
    static let markSize = NotchIsland.Mark.size
    static let leadingGap: CGFloat = 12
    /// Inset from the island's edge. The island's bottom corners are 22 pt, so
    /// anything closer than this sits in the curve.
    static let horizontalInset: CGFloat = 18

    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let meta = Font.system(size: 11, weight: .medium)

    /// A bare SF Symbol at the mark's size, in one colour. No chip behind it: a
    /// filled circle at this size reads as a button.
    static func symbol(_ name: String, color: Color, size: CGFloat = 22) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
    }
}

/// A 28 pt round icon control on the island's black, with a 44 pt target.
struct NotchAlertIconButton: View {
    var systemName: String
    var label: String
    var emphasized = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(emphasized ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .frame(width: 28, height: 28)
                .islandControlSurface(Circle(), isHovered: emphasized)
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

