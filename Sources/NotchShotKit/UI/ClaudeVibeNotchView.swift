import SwiftUI

/// Presentation rules for the Claude-specific surface. Keeping these outside
/// the view makes the Vibe Notch ordering deterministic and easy to exercise
/// without launching the menu-bar app.
enum ClaudeVibeSessionPresentation {
    static func statusText(for session: ClaudeCodeSession) -> String {
        if session.permission != nil { return "Waiting for approval" }
        return switch session.phase {
        case .working: "Processing"
        case .waiting: "Ready"
        case .finished: "Ended"
        case .failed: "Failed"
        }
    }

    static func phase(for state: AIActivityState) -> ClaudeCodeSessionPhase {
        return switch state {
        case .working: .working
        case .waiting: .waiting
        case .finished: .finished
        case .failed: .failed
        }
    }

    static func sorted(_ sessions: [ClaudeCodeSession]) -> [ClaudeCodeSession] {
        sessions.sorted { lhs, rhs in
            let lhsNeedsAttention = lhs.permission != nil || lhs.phase == .failed
            let rhsNeedsAttention = rhs.permission != nil || rhs.phase == .failed
            if lhsNeedsAttention != rhsNeedsAttention {
                return lhsNeedsAttention
            }
            if lhs.phase.isTerminal != rhs.phase.isTerminal {
                return !lhs.phase.isTerminal
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

/// The small Claude mark used by Vibe Notch. It stays drawn rather than
/// depending on a separately-installed Claude app icon, so the surface remains
/// recognizable on every Mac where Claude Code runs.
struct ClaudeVibeCrabIcon: View {
    let size: CGFloat
    private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            func rect(_ source: CGRect) -> CGRect {
                CGRect(
                    x: xOffset + source.minX * scale,
                    y: source.minY * scale,
                    width: source.width * scale,
                    height: source.height * scale
                )
            }

            func fill(_ source: CGRect, color: Color) {
                context.fill(Path(rect(source)), with: .color(color))
            }

            // Antennae and legs preserve the pixel-art silhouette from the
            // reference app at the small sizes used in the notch.
            fill(CGRect(x: 0, y: 13, width: 6, height: 13), color: accent)
            fill(CGRect(x: 60, y: 13, width: 6, height: 13), color: accent)
            for x in [CGFloat(6), 18, 42, 54] {
                fill(CGRect(x: x, y: 39, width: 6, height: 13), color: accent)
            }
            fill(CGRect(x: 6, y: 0, width: 54, height: 39), color: accent)
            fill(CGRect(x: 12, y: 13, width: 6, height: 6.5), color: .black)
            fill(CGRect(x: 48, y: 13, width: 6, height: 6.5), color: .black)
        }
        .frame(width: size * (66 / 52), height: size)
        .accessibilityHidden(true)
    }
}

/// Claude's expanded session list, used only while a real Claude hook-backed
/// session is live. Other NotchShot context modules keep their existing views.
struct ClaudeVibeActivitySurface: View {
    var sessions: [ClaudeCodeSession]
    var subtitle: String?
    var onApprovePermission: (String) -> Void
    var onDenyPermission: (String) -> Void
    var onDismiss: (String) -> Void

    @State private var selectedSession: ClaudeCodeSession?

    var body: some View {
        if let selectedSession {
            ClaudeConversationPanel(session: selectedSession) {
                self.selectedSession = nil
            }
        } else {
            VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
                header

                if sessions.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: NotchIsland.Spacing.tight) {
                            ForEach(ClaudeVibeSessionPresentation.sorted(sessions)) { session in
                                ClaudeVibeSessionRow(
                                    session: session,
                                    onOpenConversation: { selectedSession = session },
                                    onApprove: { onApprovePermission(session.id) },
                                    onDeny: { onDenyPermission(session.id) },
                                    onDismiss: { onDismiss(session.id) }
                                )
                            }
                        }
                        .padding(.trailing, NotchIsland.Spacing.tight)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .padding(.horizontal, NotchIsland.Spacing.group)
            .padding(.vertical, NotchIsland.Spacing.element)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Claude Code sessions")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            ClaudeVibeCrabIcon(size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                Text(subtitle ?? headerSubtitle)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: NotchIsland.Spacing.tight)
            Text("\(sessions.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.14), in: Capsule(style: .continuous))
                .accessibilityLabel("\(sessions.count) sessions")
        }
    }

    private var headerSubtitle: String {
        sessions.count == 1 ? "1 live session" : "\(sessions.count) live sessions"
    }

    private var emptyState: some View {
        VStack(spacing: NotchIsland.Spacing.tight) {
            ClaudeVibeCrabIcon(size: 24)
            Text("No sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            Text("Run claude in Terminal")
                .font(.system(size: 9))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityValue: String {
        let statuses = ClaudeVibeSessionPresentation.sorted(sessions).map {
            "\($0.title), \(ClaudeVibeSessionPresentation.statusText(for: $0))"
        }
        return statuses.joined(separator: ". ")
    }
}

private struct ClaudeVibeSessionRow: View {
    let session: ClaudeCodeSession
    let onOpenConversation: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var stateTint: Color {
        switch session.phase {
        case .working: .orange
        case .waiting: .orange
        case .finished: .green
        case .failed: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NotchIsland.Spacing.snug) {
            stateIndicator
                .frame(width: 18, height: 22)

            VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
                HStack(spacing: NotchIsland.Spacing.tight) {
                    Text(session.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                    Text(ClaudeVibeSessionPresentation.statusText(for: session))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(stateTint)
                        .lineLimit(1)
                }

                detailLine

                if !session.cwd.isEmpty {
                    Label(session.workspaceName, systemImage: "folder")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(.horizontal, NotchIsland.Spacing.element)
        .padding(.vertical, NotchIsland.Spacing.snug)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.10 : 0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .stroke(stateTint.opacity(session.permission == nil ? 0.12 : 0.42), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code session \(session.title)")
        .accessibilityValue(ClaudeVibeSessionPresentation.statusText(for: session))
    }

    private var detailLine: some View {
        let text = session.permission.map { "\($0.toolName) needs approval" }
            ?? session.detail
            ?? session.lastTool.map { "Using \($0)" }
            ?? "No recent activity"
        return Text(text)
            .font(.system(size: 9))
            .foregroundStyle(session.permission == nil
                ? Color.islandInk(NotchIsland.Ink.secondary)
                : .orange)
            .lineLimit(2)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if session.phase == .working {
            ProgressView()
                .controlSize(.small)
                .tint(stateTint)
        } else {
            Image(systemName: stateSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(stateTint)
        }
    }

    private var stateSymbol: String {
        switch session.phase {
        case .working: "circle.dotted"
        case .waiting: session.permission == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var actions: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            Button(action: onOpenConversation) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(NotchPressButtonStyle())
            .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            .accessibilityLabel("Open Claude Code conversation")

            if session.permission != nil {
                Button("Deny", action: onDeny)
                    .buttonStyle(NotchPressButtonStyle())
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .frame(minWidth: 42, minHeight: NotchIsland.Hit.control)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Deny Claude Code permission")

                Button("Allow", action: onApprove)
                    .buttonStyle(NotchPressButtonStyle())
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 46, minHeight: NotchIsland.Hit.control)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Allow Claude Code permission")
            } else {
                Button(action: onDismiss) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(NotchPressButtonStyle())
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .accessibilityLabel("Dismiss Claude Code session")
            }
        }
    }
}

/// Claude's closed state: a crab on the leading wing and a status signal on
/// the trailing wing, with the physical camera cutout explicitly reserved.
struct ClaudeVibeCompactStrip: View {
    let activity: AIActivitySnapshot
    let sessionCount: Int
    let physicalNotchWidth: CGFloat?
    let onOpen: () -> Void

    private var tint: Color {
        switch activity.state {
        case .working: .orange
        case .waiting: .orange
        case .finished: .green
        case .failed: .red
        }
    }

    var body: some View {
        Button(action: onOpen) {
            if let physicalNotchWidth {
                HStack(spacing: 0) {
                    leading
                        .padding(.leading, NotchIsland.Spacing.snug)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(width: physicalNotchWidth)
                        .accessibilityHidden(true)
                    status
                        .padding(.trailing, NotchIsland.Spacing.element)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: NotchIsland.Spacing.element) {
                    leading
                    Text("Claude Code")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                    Spacer(minLength: NotchIsland.Spacing.tight)
                    status
                }
                .padding(.horizontal, NotchIsland.Spacing.group)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude Code")
        .accessibilityValue("\(ClaudeVibeSessionPresentation.statusText(for: syntheticSession)), \(sessionCount) sessions")
        .accessibilityHint("Opens Claude Code sessions")
    }

    private var leading: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            ClaudeVibeCrabIcon(size: 16)
            if sessionCount > 1 {
                Text("+\(sessionCount - 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch activity.state {
        case .working:
            ProgressView()
                .controlSize(.small)
                .tint(tint)
        case .waiting:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private var syntheticSession: ClaudeCodeSession {
        ClaudeCodeSession(
            id: activity.id,
            cwd: activity.workspace ?? "",
            phase: ClaudeVibeSessionPresentation.phase(for: activity.state),
            title: activity.title,
            detail: activity.detail,
            updatedAt: activity.updatedAt
        )
    }
}

struct ClaudeVibePeekHeader: View {
    let activity: AIActivitySnapshot
    let sessionCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: NotchIsland.Spacing.element) {
                ClaudeVibeCrabIcon(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(activity.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(sessionCount == 1 ? "1" : "\(sessionCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, NotchIsland.Spacing.group)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude Code")
        .accessibilityValue("\(activity.title), \(sessionCount) sessions")
        .accessibilityHint("Opens Claude Code sessions")
    }
}
