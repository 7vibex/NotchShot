import AppKit
import SwiftUI

/// The banners macOS is visibly presenting, stacked the way the Dynamic
/// Island stacks messages: one row per sender, newest on top, the sender's
/// initials with the app as a badge, and a count when a thread has more than
/// one message. The card owns only appearance and local interaction; opening
/// a source and clearing the stack stay with `AppCoordinator`.
struct SystemNotificationCard: View {
    let snapshot: SystemNotificationSnapshot
    var onOpenSource: (SystemNotificationSnapshot) -> Void
    var onReply: (SystemNotificationSnapshot) -> Void = { _ in }
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var rows: [SystemNotificationSnapshot] { snapshot.rows }

    private var headerSource: SystemNotificationSourcePresentation {
        SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
    }

    /// One app's banners are titled by the app; several apps by the count.
    private var headerTitle: String {
        let sources = Set(rows.map(\.sourceName))
        if sources.count <= 1 { return snapshot.sourceName }
        return "\(rows.count + snapshot.overflowCount) Notifications"
    }

    /// The app and the time beside the camera, where the open island used to
    /// show an empty black strip above the first row.
    private var bandHeader: some View {
        IslandBandHeader(leadingInset: 16, trailingInset: 8) {
            HStack(spacing: 6) {
                if Set(rows.map(\.sourceName)).count <= 1 {
                    SystemNotificationSourceGlyph(source: headerSource, size: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                }
                Text(headerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
            }
        } trailing: {
            ZStack(alignment: .trailing) {
                TimelineView(.periodic(from: snapshot.receivedAt, by: 15)) { context in
                    Text(SystemNotificationTimePolicy.compactElapsed(
                        receivedAt: snapshot.receivedAt,
                        now: context.date
                    ))
                    .font(NotchAlertStyle.meta)
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .padding(.trailing, 8)
                }
                .opacity(isHovered ? 0 : 1)

                // The one control the stack needs, and only under the pointer.
                IslandBandButton(systemName: "xmark", label: "Dismiss notifications", action: onDismiss)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            bandHeader
                .padding(.horizontal, -(NotchAlertStyle.horizontalInset - 4))

            ForEach(Array(rows.enumerated()), id: \.element.groupKey) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Color.islandInk(0.10))
                        .frame(height: 1)
                        .padding(.leading, SystemNotificationRow.avatarSize + NotchAlertStyle.leadingGap)
                }
                SystemNotificationRow(
                    snapshot: row,
                    // A row carries its own time only when the stack mixes
                    // senders; one sender's time is already in the header.
                    showsTime: rows.count > 1,
                    onOpen: { onOpenSource(row) },
                    onReply: row.replyKey != nil && ExtrasPreferences.shared.notificationRepliesEnabled
                        ? { onReply(row) }
                        : nil
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
            if snapshot.overflowCount > 0 {
                Text("\(snapshot.overflowCount) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SystemNotificationRow.avatarSize + NotchAlertStyle.leadingGap)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, NotchAlertStyle.horizontalInset - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { isHovered = $0 }
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: rows.map(\.id))
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            rows.count == 1
                ? "Notification from \(snapshot.sourceName)"
                : "\(rows.count) notifications"
        )
    }
}

/// One sender in the stack.
private struct SystemNotificationRow: View {
    static let avatarSize: CGFloat = 38

    let snapshot: SystemNotificationSnapshot
    var showsTime: Bool
    var onOpen: () -> Void
    /// Nil when the banner has no Reply action of its own.
    var onReply: (() -> Void)?

    @State private var isHovered = false

    private var source: SystemNotificationSourcePresentation {
        SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
    }

    private var canOpen: Bool {
        SystemNotificationSourceCatalog.applicationURL(for: source) != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchAlertStyle.leadingGap) {
            SystemNotificationAvatar(snapshot: snapshot, source: source, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(NotchAlertStyle.title)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                Text(snapshot.body.isEmpty ? snapshot.sourceName : snapshot.body)
                    .font(NotchAlertStyle.body)
                    .foregroundStyle(Color.islandInk(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let onReply {
                    // Shown under the pointer only, so a resting stack reads
                    // as messages rather than a row of buttons.
                    Button(action: onReply) {
                        Text("Reply")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Color.islandInk(0.16), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(NotchPressButtonStyle())
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .help("Reply in \(snapshot.sourceName)")
                    .accessibilityLabel("Reply to \(snapshot.title)")
                }
                if snapshot.groupCount > 1 {
                    Text("\(min(snapshot.groupCount, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.red, in: Capsule())
                        .accessibilityLabel("\(snapshot.groupCount) messages")
                }
                if showsTime {
                    TimelineView(.periodic(from: snapshot.receivedAt, by: 15)) { context in
                        Text(SystemNotificationTimePolicy.compactElapsed(
                            receivedAt: snapshot.receivedAt,
                            now: context.date
                        ))
                        .font(NotchAlertStyle.meta)
                        .monospacedDigit()
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    }
                }
            }
            .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(
            Color.islandInk(isHovered && canOpen ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { onOpen() } }
        .onHover { isHovered = $0 }
        .help(canOpen ? source.openAccessibilityLabel : snapshot.sourceName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title), \(snapshot.sourceName)")
        .accessibilityValue(snapshot.body)
        .accessibilityAddTraits(canOpen ? .isButton : [])
        .accessibilityAction { if canOpen { onOpen() } }
        .accessibilityAction(named: "Reply") { onReply?() }
    }
}

/// A chat sender leads with their initials and the app shrinks to a badge;
/// anything else leads with the app's own icon.
struct SystemNotificationAvatar: View {
    let snapshot: SystemNotificationSnapshot
    let source: SystemNotificationSourcePresentation
    let size: CGFloat

    var body: some View {
        if source.kind.isConversation {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.62), Color(white: 0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay {
                    Text(SystemNotificationInitials.initials(for: snapshot.title))
                        .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, size * 0.14)
                }
                .frame(width: size, height: size)
                // The badge sits on the circle's edge, as the phone draws it:
                // small, ringed in the island's black, mostly outside the
                // initials so both letters stay readable.
                .overlay(alignment: .bottomTrailing) {
                    SystemNotificationSourceGlyph(source: source, size: size * 0.4)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous))
                        .padding(1.5)
                        .background(
                            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                                .fill(.black)
                        )
                        .offset(x: size * 0.16, y: size * 0.12)
                }
                .accessibilityHidden(true)
        } else {
            SystemNotificationSourceGlyph(source: source, size: size)
        }
    }
}

enum SystemNotificationInitials {
    /// Up to two letters from the first two words: "Mia Chen" is "MC",
    /// "mom" is "M". A title with no letters at all falls back to its first
    /// character so the circle is never blank.
    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
        if !words.isEmpty {
            return String(words.prefix(2)).uppercased()
        }
        return name.first.map { String($0) } ?? "?"
    }
}
