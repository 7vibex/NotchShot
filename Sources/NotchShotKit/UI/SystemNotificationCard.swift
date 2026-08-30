import AppKit
import SwiftUI

/// Compact, source-aware presentation for a banner that macOS is visibly
/// presenting. The card owns only appearance and local interaction; source
/// activation and queue mutation stay with `AppCoordinator` through closures.
struct SystemNotificationCard: View {
    let snapshot: SystemNotificationSnapshot
    var onOpenSource: () -> Void
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var source: SystemNotificationSourcePresentation {
        SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
    }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: source.accentHex) ?? .systemPurple
        ))
    }

    private var canOpenSource: Bool {
        SystemNotificationSourceCatalog.applicationURL(for: source) != nil
    }

    var body: some View {
        ZStack {
            ambientGlow
            notificationCard
        }
        .padding(.horizontal, NotchIsland.Spacing.row)
        .padding(.vertical, NotchIsland.Spacing.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notification from \(snapshot.sourceName)")
        .accessibilityValue([snapshot.title, snapshot.body].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var notificationCard: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            SystemNotificationSourceGlyph(source: source, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)

                HStack(spacing: NotchIsland.Spacing.tight) {
                    Image(systemName: source.symbolName)
                        .font(.system(size: 7.5, weight: .bold))
                        .accessibilityHidden(true)
                    Text(snapshot.sourceName)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .lineLimit(1)

                    if !snapshot.body.isEmpty {
                        Circle()
                            .fill(Color.islandInk(NotchIsland.Ink.hairline))
                            .frame(width: 2, height: 2)
                            .accessibilityHidden(true)
                        Text(snapshot.body)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(accent)
            }

            Spacer(minLength: NotchIsland.Spacing.tight)

            VStack(alignment: .trailing, spacing: NotchIsland.Spacing.hairline) {
                TimelineView(.periodic(from: snapshot.receivedAt, by: 1)) { context in
                    Text(SystemNotificationTimePolicy.compactElapsed(
                        receivedAt: snapshot.receivedAt,
                        now: context.date
                    ))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                }

                HStack(spacing: NotchIsland.Spacing.tight) {
                    if canOpenSource {
                        openSourceButton
                    }
                    dismissButton
                }
            }
        }
        .padding(.leading, NotchIsland.Spacing.element)
        .padding(.trailing, NotchIsland.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.black.opacity(reduceTransparency ? 0.96 : 0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .stroke(Color.islandInk(NotchIsland.Ink.hairline), lineWidth: NotchIsland.Stroke.hairline)
        }
        .shadow(color: accent.opacity(reduceTransparency ? 0 : 0.16), radius: 12, y: 5)
    }

    private var openSourceButton: some View {
        Button(action: onOpenSource) {
            Image(systemName: source.supportsReplyHandoff
                ? "arrowshape.turn.up.left.fill"
                : "arrow.up.forward.app.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(accent.opacity(0.14), in: Circle())
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(source.openAccessibilityLabel)
        .accessibilityLabel(source.openAccessibilityLabel)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(width: 24, height: 24)
                .background(Color.islandInk(NotchIsland.Ink.fill), in: Circle())
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("Dismiss notification")
        .accessibilityLabel("Dismiss notification")
    }

    private var ambientGlow: some View {
        RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        accent.opacity(reduceTransparency ? 0.10 : 0.28),
                        Color(red: 0.26, green: 0.24, blue: 0.58)
                            .opacity(reduceTransparency ? 0.08 : 0.22),
                        .clear
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
            .blur(radius: reduceTransparency ? 0 : 9)
            .accessibilityHidden(true)
    }
}
