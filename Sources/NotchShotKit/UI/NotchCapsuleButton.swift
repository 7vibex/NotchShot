import SwiftUI

/// The island's one capsule button. `primary` is white with black text, the
/// way the system marks the affirmative choice on a dark surface; `secondary`
/// is a soft grey fill with no edge; `destructive` is the secondary capsule
/// with red text.
///
/// Every capsule on the island goes through this, so a notification's Reply,
/// an agent run's Pause and the idle bar's Area shortcut are the same object
/// rather than five near-copies with their own fills and heights.
struct NotchCapsuleButton: View {
    enum Prominence {
        case primary
        case secondary
        case destructive
    }

    enum Size {
        /// The standard 28 pt capsule, on a full-height hit target.
        case regular
        /// A 24 pt capsule for use inside a row's text column, where a 28 pt
        /// one would make the row taller. Its hit target still reaches past
        /// the capsule without taking layout room.
        case compact

        var height: CGFloat {
            switch self {
            case .regular: 28
            case .compact: 24
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .regular: NotchIsland.TextSize.body
            case .compact: NotchIsland.TextSize.meta
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: NotchIsland.Spacing.group
            case .compact: NotchIsland.Spacing.row
            }
        }
    }

    var title: String
    var systemImage: String?
    var iconTint: Color?
    var prominence: Prominence
    var size: Size
    var expands: Bool
    var help: String?
    var accessibilityLabel: String?
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        prominence: Prominence = .secondary,
        size: Size = .regular,
        expands: Bool = false,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.prominence = prominence
        self.size = size
        self.expands = expands
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: size.fontSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, size.horizontalPadding)
                .frame(maxWidth: expands ? .infinity : nil)
                .frame(height: size.height)
                .background(fill, in: Capsule(style: .continuous))
                .modifier(CapsuleHitTarget(size: size))
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 && isEnabled }
        .animation(NotchMotion.hoverSwap, value: isHovered)
        .fixedSize(horizontal: !expands, vertical: false)
        .help(help ?? title)
        .accessibilityLabel(accessibilityLabel ?? help ?? title)
    }

    /// A symbol that arrives later (Copy turning into a checkmark) draws
    /// itself on rather than popping in.
    private var label: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size.fontSize - 1, weight: .bold))
                    .foregroundStyle(iconTint ?? foreground)
                    .transition(.symbolEffect(.drawOn))
                    .accessibilityHidden(true)
            }
            Text(title)
        }
    }

    private var foreground: Color {
        switch prominence {
        case .primary: .black
        case .secondary: Color.islandInk(NotchIsland.Ink.primary)
        case .destructive: .red
        }
    }

    private var fill: Color {
        switch prominence {
        case .primary:
            .white.opacity(isHovered ? 0.86 : 1)
        case .secondary, .destructive:
            Color.islandInk(isHovered ? NotchIsland.Surface.capsuleHover : NotchIsland.Surface.capsule)
        }
    }
}

/// The capsule's clickable area. A regular capsule sits on a full control
/// target; a compact one keeps its 24 pt layout and only widens what the
/// pointer can hit, so it fits beside a line of text.
private struct CapsuleHitTarget: ViewModifier {
    var size: NotchCapsuleButton.Size

    func body(content: Content) -> some View {
        switch size {
        case .regular:
            content
                .frame(minHeight: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        case .compact:
            let outset = (NotchIsland.Hit.control - size.height) / 2
            content
                .padding(.vertical, outset)
                .contentShape(Rectangle())
                .padding(.vertical, -outset)
        }
    }
}
