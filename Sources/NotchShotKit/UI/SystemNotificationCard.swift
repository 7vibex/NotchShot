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
    /// The stack stays up while the pointer is over it, so a banner being
    /// read (or a code being copied) doesn't slide away mid-sentence.
    var onHoverChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var rows: [SystemNotificationSnapshot] { snapshot.rows }

    private var headerSource: SystemNotificationSourcePresentation {
        SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
    }

    /// One app's banners are titled by the app; several apps simply
    /// "Notifications". A count ("5 Notifications") was cut off in the wing
    /// beside the camera, and the rows and "more" line already show it.
    private var headerTitle: String {
        let sources = Set(rows.map(\.sourceName))
        if sources.count <= 1 { return snapshot.sourceName }
        return "Notifications"
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
                // A stack's rows carry their own times; one here as well read
                // as a second "now" beside the first.
                if rows.count == 1 {
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
                }

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
                    bodyLineLimit: SystemNotificationCardLayout.bodyLineLimit(for: snapshot, row: index),
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
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
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
    var bodyLineLimit = 1
    var onOpen: () -> Void
    /// Nil when the banner has no Reply action of its own.
    var onReply: (() -> Void)?

    @State private var isHovered = false
    @State private var copiedCode = false

    private var source: SystemNotificationSourcePresentation {
        SystemNotificationSourcePresentation(sourceName: snapshot.sourceName)
    }

    /// A sign-in code in the banner, read from the text on screen.
    private var oneTimeCode: String? {
        guard ExtrasPreferences.shared.offersOneTimeCodes else { return nil }
        return SystemNotificationCardLayout.oneTimeCode(in: snapshot)
    }

    private var canOpen: Bool {
        SystemNotificationSourceCatalog.applicationURL(for: source) != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchAlertStyle.leadingGap) {
            SystemNotificationAvatar(snapshot: snapshot, source: source, size: Self.avatarSize)

            // Laid out as Messages and Mail lay out a list: the name with
            // its time on the first line, the preview with its count below.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.title)
                        .font(NotchAlertStyle.title)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.body.isEmpty ? snapshot.sourceName : snapshot.body)
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(Color.islandInk(0.82))
                        .lineLimit(bodyLineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if snapshot.groupCount > 1 {
                        // A quiet count, as Mail counts a thread. The red
                        // badge belongs to the Home Screen, not a message.
                        Text("\(min(snapshot.groupCount, 99))")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                            .padding(.horizontal, 5)
                            .frame(minWidth: SystemNotificationCardLayout.countWidth, minHeight: 15)
                            .background(Color.islandInk(0.14), in: Capsule())
                            .accessibilityLabel("\(snapshot.groupCount) messages")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let oneTimeCode {
                // Always shown: copying the code is why this banner was
                // looked at. White, as the island's primary actions are.
                Button {
                    OneTimeCodeClipboard.copy(oneTimeCode)
                    copiedCode = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copiedCode = false
                    }
                } label: {
                    Label(
                        copiedCode ? "Copied" : "Copy \(oneTimeCode)",
                        systemImage: copiedCode ? "checkmark" : "doc.on.doc"
                    )
                    .labelStyle(.titleOnly)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Color.white, in: Capsule())
                    .contentShape(Capsule())
                    .contentTransition(.opacity)
                }
                .buttonStyle(NotchPressButtonStyle())
                .fixedSize()
                .help("Copy the code. The clipboard is cleared after 90 seconds")
                .accessibilityLabel(copiedCode ? "Code copied" : "Copy code \(oneTimeCode.map(String.init).joined(separator: " "))")
            }
            if let onReply, isHovered {
                // Shown under the pointer only, so a resting stack reads as
                // messages rather than a row of buttons. It is added rather
                // than faded in: a transparent button still took its width
                // and cut the message short at rest.
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
                .transition(.opacity)
                .help("Reply in \(snapshot.sourceName)")
                .accessibilityLabel("Reply to \(snapshot.title)")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, SystemNotificationCardLayout.rowHorizontalPadding)
        .animation(.easeOut(duration: 0.15), value: isHovered)
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
        .accessibilityAction(named: "Copy Code") {
            if let oneTimeCode { OneTimeCodeClipboard.copy(oneTimeCode) }
        }
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
                    // The cool grey Contacts gives a monogram, light at the top.
                    colors: [
                        Color(red: 0.65, green: 0.67, blue: 0.72),
                        Color(red: 0.52, green: 0.54, blue: 0.58),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay {
                    if snapshot.title.contains(where: \.isLetter) {
                        Text(SystemNotificationInitials.initials(for: snapshot.title))
                            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, size * 0.14)
                    } else {
                        // A number with no name, drawn as Contacts draws an
                        // unknown sender rather than as its first digit.
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.5, weight: .medium))
                            .foregroundStyle(.white)
                            .offset(y: size * 0.04)
                    }
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

/// Sizes shared by the card and the notch's layout, so the room the notch
/// opens is the room the card draws in.
enum SystemNotificationCardLayout {
    static let width: CGFloat = 420
    static let rowHorizontalPadding: CGFloat = 4
    static let countWidth: CGFloat = 18
    /// What a second body line adds to a row. The first line fits beside the
    /// 38 pt avatar; a second one makes the text the taller of the two.
    static let secondLineHeight: CGFloat = 9

    /// A lone message gets two lines, as a banner does; a stack keeps one
    /// line per sender so it stays a glance. Only a body that needs the
    /// second line gets it, so a short message keeps the compact card.
    static func bodyLineLimit(for snapshot: SystemNotificationSnapshot, row: Int = 0) -> Int {
        guard row == 0, snapshot.earlier.isEmpty, !snapshot.body.isEmpty else { return 1 }
        // What sits beside the text at rest: the copy button, measured as
        // if codes were offered (at worst a short body gets a spare line),
        // and the thread count on the preview's own line.
        let codeButton: CGFloat = oneTimeCode(in: snapshot) != nil ? NotchAlertStyle.leadingGap + 96 : 0
        let count: CGFloat = snapshot.groupCount > 1 ? 6 + countWidth : 0
        let textWidth = width
            - 2 * (NotchAlertStyle.horizontalInset - 4)
            - 2 * rowHorizontalPadding
            - SystemNotificationRow.avatarSize
            - NotchAlertStyle.leadingGap
            - codeButton
            - count
        let bounds = (snapshot.body as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: bodyFontSize)]
        )
        return bounds.height > bodyLineHeight * 1.5 ? 2 : 1
    }

    /// `NotchAlertStyle.body`'s size, for measuring outside SwiftUI.
    private static let bodyFontSize: CGFloat = 12
    private static let bodyLineHeight = NSLayoutManager()
        .defaultLineHeight(for: NSFont.systemFont(ofSize: bodyFontSize))

    /// The code in the message itself first. A texted code often comes from
    /// a short-code sender such as "54321", which reads as a code too.
    static func oneTimeCode(in snapshot: SystemNotificationSnapshot) -> String? {
        if let code = OneTimeCodeDetector.code(in: snapshot.body) { return code }
        // A sender that is itself a number is that short code, never the
        // sign-in code, so only a worded title is searched with the body.
        let isNumericSender = snapshot.title.allSatisfy { $0.isNumber || $0.isWhitespace || "+-()".contains($0) }
        guard !isNumericSender else { return nil }
        return OneTimeCodeDetector.code(in: snapshot.title + "\n" + snapshot.body)
    }
}
