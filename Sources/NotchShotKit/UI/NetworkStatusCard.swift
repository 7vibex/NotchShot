import AppKit
import SwiftUI

/// The connectivity card: a statement of fact plus the one handoff that can
/// act on it.
///
/// Laid out after the system's own no-connection alert — glyph, headline, what
/// to do about it, then a neutral dismiss beside a filled call to action.
/// Losing the connection gets that full treatment. Regaining it gets a single
/// quiet row, because there is nothing left for the user to decide.
struct NetworkStatusCard: View {
    let snapshot: ContextSnapshot
    var onDismiss: () -> Void
    var onOpenNetworkSettings: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Generously rounded, the way the system alert this follows draws them —
    /// a little over a third of the button's height, not the island's usual
    /// tighter control radius.
    static let buttonRadius: CGFloat = 16
    static let buttonHeight: CGFloat = 40

    private var isOffline: Bool { NetworkContextPolicy.isOfflineAlert(snapshot) }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemGreen
        ))
    }

    var body: some View {
        Group {
            if isOffline { offlineAlert } else { restoredRow }
        }
        .padding(.horizontal, NotchIsland.Spacing.row)
        .padding(.vertical, NotchIsland.Spacing.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.subtitle ?? "")
    }

    // MARK: States

    private var offlineAlert: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.gutter) {
            headline
            HStack(spacing: NotchIsland.Spacing.row) {
                dismissButton
                settingsButton
            }
        }
        .padding(.horizontal, NotchIsland.Spacing.group)
        .padding(.vertical, NotchIsland.Spacing.row)
    }

    private var restoredRow: some View {
        headline
            .padding(.horizontal, NotchIsland.Spacing.group)
            .frame(maxHeight: .infinity)
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: NotchIsland.Spacing.group) {
            // Bare glyph, no chip behind it — the reference leans on the mark
            // itself for colour, and a filled circle at this size reads as a
            // button the user is meant to press.
            Image(systemName: "wifi")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 38, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Text("OK")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .frame(maxWidth: .infinity)
                .frame(height: Self.buttonHeight)
                .notchControlSurface(
                    in: RoundedRectangle(cornerRadius: Self.buttonRadius, style: .continuous),
                    reduceTransparency: reduceTransparency
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("Dismiss this alert")
        .accessibilityLabel("Dismiss")
    }

    private var settingsButton: some View {
        Button(action: onOpenNetworkSettings) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: Self.buttonHeight)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: Self.buttonRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("Open Network Settings")
        .accessibilityLabel("Open Network Settings")
    }
}
