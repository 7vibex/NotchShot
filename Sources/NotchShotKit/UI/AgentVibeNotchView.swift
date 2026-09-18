import SwiftUI

/// Presentation rules shared by Claude, Codex, Cursor, and Terminal activity.
/// The source adapter remains the authority for state and text; this helper
/// only decides how the Vibe surface prioritises and labels those records.
enum AgentVibePresentation {
    static func statusText(
        for activity: AIActivitySnapshot,
        claudeSession: ClaudeCodeSession? = nil
    ) -> String {
        if claudeSession?.permission != nil { return "Waiting for approval" }
        return switch activity.state {
        case .working: "Processing"
        case .waiting: "Ready"
        case .finished: "Ended"
        case .failed: "Failed"
        }
    }

    static func sorted(
        _ activities: [AIActivitySnapshot],
        claudeSessions: [ClaudeCodeSession] = []
    ) -> [AIActivitySnapshot] {
        activities.sorted { lhs, rhs in
            let lhsSession = claudeSessions.first { $0.id == lhs.id && lhs.source == .claude }
            let rhsSession = claudeSessions.first { $0.id == rhs.id && rhs.source == .claude }
            let lhsNeedsAttention = lhs.state.isAttention || lhsSession?.permission != nil
            let rhsNeedsAttention = rhs.state.isAttention || rhsSession?.permission != nil
            if lhsNeedsAttention != rhsNeedsAttention {
                return lhsNeedsAttention
            }
            if lhs.state.isTerminal != rhs.state.isTerminal {
                return !lhs.state.isTerminal
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.displayIdentifier < rhs.displayIdentifier
        }
    }

    static func headerTitle(for activities: [AIActivitySnapshot]) -> String {
        guard let first = activities.first,
              activities.dropFirst().allSatisfy({ $0.source == first.source }) else {
            return "AI Agents"
        }
        return first.source.title + " Agents"
    }

    static func liveCountText(_ count: Int) -> String {
        count == 1 ? "1 live activity" : String(count) + " live activities"
    }
}

/// The provider mark used by the shared surface. Claude keeps the Vibe crab;
/// every other provider uses its current installed app icon or the existing
/// source-aware fallback glyph.
struct AgentVibeIdentity: View {
    let source: AISource
    let size: CGFloat

    var body: some View {
        if source == .claude {
            ClaudeVibeCrabIcon(size: size)
        } else {
            AgentGlyph(source: source, size: size)
        }
    }
}

/// Shared expanded Vibe surface for all generic AI activity providers. A
/// Claude session may additionally expose the already-supported local
/// transcript and permission bridge; Codex, Cursor, and Terminal stay within
/// the actions their reporter actually supports.
struct AgentVibeActivitySurface: View {
    var activities: [AIActivitySnapshot]
    var recent: [AIActivitySnapshot]
    var subtitle: String?
    var claudeSessions: [ClaudeCodeSession] = []
    /// The island draws its own header (with the travelling agent glyph)
    /// above this list.
    var showsHeader = true
    var onApprovePermission: (String) -> Void
    var onDenyPermission: (String) -> Void
    var onDismiss: (AIActivitySnapshot) -> Void
    var onClearHistory: () -> Void

    @State private var selectedClaudeSession: ClaudeCodeSession?

    private var liveActivities: [AIActivitySnapshot] {
        var merged = activities
        let existingIDs = Set(activities.map(\.displayIdentifier))
        for session in claudeSessions where !existingIDs.contains("claude:\(session.id)") {
            merged.append(session.aiActivity)
        }
        return AgentVibePresentation.sorted(merged, claudeSessions: claudeSessions)
    }

    private var recentActivities: [AIActivitySnapshot] {
        let liveIDs = Set(liveActivities.map(\.displayIdentifier))
        return recent.filter { !liveIDs.contains($0.displayIdentifier) }
    }

    var body: some View {
        if let selectedClaudeSession {
            ClaudeConversationPanel(session: selectedClaudeSession) {
                self.selectedClaudeSession = nil
            }
        } else if liveActivities.isEmpty && recentActivities.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
                if showsHeader {
                    header
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
                        ForEach(liveActivities, id: \.displayIdentifier) { activity in
                            AgentVibeActivityRow(
                                activity: activity,
                                claudeSession: claudeSession(for: activity),
                                onOpenConversation: { session in
                                    selectedClaudeSession = session
                                },
                                onApprove: { onApprovePermission(activity.id) },
                                onDeny: { onDenyPermission(activity.id) },
                                onOpenAgent: { AgentIconCatalog.activate(activity.source) },
                                onDismiss: { onDismiss(activity) }
                            )
                        }

                        if !recentActivities.isEmpty {
                            historyHeader
                            ForEach(recentActivities, id: \.displayIdentifier) { activity in
                                AgentVibeRecentRow(
                                    activity: activity,
                                    onOpenAgent: { AgentIconCatalog.activate(activity.source) },
                                    onDismiss: { onDismiss(activity) }
                                )
                            }
                        }
                    }
                    .padding(.trailing, NotchIsland.Spacing.tight)
                }
                .scrollIndicators(.visible)
            }
            .padding(.horizontal, NotchIsland.Spacing.group)
            .padding(.vertical, NotchIsland.Spacing.element)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI agent activity")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            AgentVibeIdentity(source: liveActivities.first?.source ?? .terminal, size: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(AgentVibePresentation.headerTitle(for: liveActivities))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                Text(subtitle ?? AgentVibePresentation.liveCountText(liveActivities.count))
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
            }

            Spacer(minLength: NotchIsland.Spacing.tight)

            Text("\(liveActivities.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(headerTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(headerTint.opacity(0.14), in: Capsule(style: .continuous))
                .accessibilityLabel(AgentVibePresentation.liveCountText(liveActivities.count))
        }
    }

    private var headerTint: Color {
        guard let first = liveActivities.first else { return .secondary }
        let accent = Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: first.source.accentHex) ?? .systemGreen
        ))
        return first.state.tint(sourceAccent: accent)
    }

    private var emptyState: some View {
        VStack(spacing: NotchIsland.Spacing.tight) {
            AgentVibeIdentity(source: .terminal, size: 24)
            Text("No agent activity")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            Text("Connect Codex, Cursor, Claude, or a terminal reporter in Settings.")
                .font(.system(size: 9))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var historyHeader: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            Text("Recent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))

            Rectangle()
                .fill(Color.islandInk(NotchIsland.Ink.hairline))
                .frame(height: 1)

            Button("Clear", action: onClearHistory)
                .buttonStyle(NotchPressButtonStyle())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(minHeight: NotchIsland.Hit.control)
                .accessibilityLabel("Clear recent activities")
        }
        .padding(.top, NotchIsland.Spacing.tight)
    }

    private func claudeSession(for activity: AIActivitySnapshot) -> ClaudeCodeSession? {
        guard activity.source == .claude else { return nil }
        return claudeSessions.first { $0.id == activity.id }
    }

    private var accessibilityValue: String {
        liveActivities.map {
            let session = claudeSession(for: $0)
            return "\($0.source.title), \($0.title), \(AgentVibePresentation.statusText(for: $0, claudeSession: session))"
        }.joined(separator: ". ")
    }
}

private struct AgentVibeActivityRow: View {
    let activity: AIActivitySnapshot
    let claudeSession: ClaudeCodeSession?
    let onOpenConversation: (ClaudeCodeSession) -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onOpenAgent: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var stateTint: Color { activity.state.tint(sourceAccent: accent) }

    private var statusText: String {
        AgentVibePresentation.statusText(for: activity, claudeSession: claudeSession)
    }

    private var canOpenConversation: Bool { claudeSession != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.snug) {
            HStack(alignment: .top, spacing: NotchIsland.Spacing.snug) {
                agentButton

                VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
                    HStack(spacing: NotchIsland.Spacing.tight) {
                        Text(activity.source.title)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                            .fixedSize()

                        Circle()
                            .fill(stateTint)
                            .frame(width: 4, height: 4)
                            .accessibilityHidden(true)

                        Text(statusText)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(stateTint)
                            .lineLimit(1)
                    }

                    Text(activity.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(2)

                    if let detail = detailText {
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundStyle(claudeSession?.permission == nil
                                ? Color.islandInk(NotchIsland.Ink.secondary)
                                : .orange)
                            .lineLimit(2)
                    }

                    if let workspace = activity.workspace, !workspace.isEmpty {
                        Label(AgentWorkspaceFormatter.display(workspace), systemImage: "folder")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actions
            }

            if !activity.steps.isEmpty {
                AgentStepList(activity: activity, tint: stateTint)
                    .padding(.leading, NotchIsland.Spacing.group)
            }

            progressRail
        }
        .padding(.horizontal, NotchIsland.Spacing.element)
        .padding(.vertical, NotchIsland.Spacing.snug)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.black.opacity(reduceTransparency ? 0.84 : (isHovered ? 0.42 : 0.30)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .stroke(
                    activity.state.isAttention ? stateTint.opacity(0.42) : Color.islandInk(NotchIsland.Ink.hairline),
                    lineWidth: NotchIsland.Stroke.hairline
                )
        }
        .shadow(color: stateTint.opacity(reduceTransparency ? 0 : 0.10), radius: 10, y: 5)
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title) activity \(activity.title)")
        .accessibilityValue(statusText)
    }

    private var detailText: String? {
        if let permission = claudeSession?.permission {
            return "\(permission.toolName) needs approval"
        }
        if let detail = activity.detail, !detail.isEmpty { return detail }
        if let step = activity.steps.first(where: { $0.state == .working }) {
            return step.label
        }
        return nil
    }

    private var agentButton: some View {
        Button(action: onOpenAgent) {
            AgentVibeIdentity(source: activity.source, size: 20)
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(AgentIconCatalog.applicationURL(for: activity.source) == nil)
        .opacity(AgentIconCatalog.applicationURL(for: activity.source) == nil
            ? NotchIconButton.disabledOpacity
            : 1)
        .help("Open \(activity.source.title)")
        .accessibilityLabel("Open \(activity.source.title)")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            if let claudeSession, canOpenConversation {
                Button {
                    onOpenConversation(claudeSession)
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(NotchPressButtonStyle())
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .accessibilityLabel("Open Claude Code conversation")
            }

            if claudeSession?.permission != nil {
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
            }

            Button(action: onDismiss) {
                Image(systemName: "archivebox")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(NotchPressButtonStyle())
            .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .accessibilityLabel("Dismiss \(activity.source.title) activity")
        }
    }

    @ViewBuilder
    private var progressRail: some View {
        if let progress = activity.progress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.islandInk(NotchIsland.Ink.hairline))
                    Capsule(style: .continuous)
                        .fill(stateTint)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("Reported progress")
            .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
        }
    }
}

private struct AgentVibeRecentRow: View {
    let activity: AIActivitySnapshot
    let onOpenAgent: () -> Void
    let onDismiss: () -> Void

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            Button(action: onOpenAgent) {
                AgentVibeIdentity(source: activity.source, size: 18)
                    .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            }
            .buttonStyle(NotchPressButtonStyle())
            .disabled(AgentIconCatalog.applicationURL(for: activity.source) == nil)
            .accessibilityLabel("Open \(activity.source.title)")

            Text(activity.source.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .fixedSize()

            AgentStatePill(
                state: activity.state,
                tint: activity.state.tint(sourceAccent: accent),
                isDimmed: true
            )

            Text(activity.title)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)

            Spacer(minLength: NotchIsland.Spacing.tight)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(NotchPressButtonStyle())
            .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            .accessibilityLabel("Dismiss \(activity.source.title) activity")
        }
        .padding(.leading, NotchIsland.Spacing.tight)
        .padding(.trailing, NotchIsland.Spacing.element)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .fill(Color.black.opacity(NotchIsland.Ink.recessed))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .stroke(Color.islandInk(NotchIsland.Ink.hairline), lineWidth: NotchIsland.Stroke.hairline)
        }
    }
}

/// Shared collapsed Vibe strip. The source mark remains visible in the
/// leading wing while the right wing carries progress or the semantic state
/// glyph, so the same compact grammar works for Codex and every other source.
struct AgentVibeCompactStrip: View {
    let activity: AIActivitySnapshot
    let activityCount: Int
    let physicalNotchWidth: CGFloat?
    let onOpen: () -> Void

    private var sourceAccent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var tint: Color { activity.state.tint(sourceAccent: sourceAccent) }
    private var signal: AgentStripSignal { AgentStripSignal.signal(for: activity) }

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

                    signalView
                        .padding(.trailing, NotchIsland.Spacing.element)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: NotchIsland.Spacing.element) {
                    leading
                    Text(activity.source.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                    Spacer(minLength: NotchIsland.Spacing.tight)
                    signalView
                }
                .padding(.horizontal, NotchIsland.Spacing.group)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.source.title)
        .accessibilityValue("\(AgentVibePresentation.statusText(for: activity)), \(activityCount) activities")
        .accessibilityHint("Opens AI agent activity")
    }

    private var leading: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            AgentVibeIdentity(source: activity.source, size: 16)
            if activityCount > 1 {
                Text("+\(activityCount - 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }
        }
    }

    @ViewBuilder
    private var signalView: some View {
        switch signal {
        case .attention(let symbol), .glyph(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        case .percent(let value):
            Text("\(value)%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
    }
}

struct AgentVibePeekHeader: View {
    let activity: AIActivitySnapshot
    let activityCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: NotchIsland.Spacing.element) {
                AgentVibeIdentity(source: activity.source, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.source.title)
                        .font(.system(size: 11.5, weight: .bold))
                    Text(activity.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text("\(activityCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
                        NSColor(hex: activity.source.accentHex) ?? .systemGreen
                    )))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, NotchIsland.Spacing.group)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.source.title)
        .accessibilityValue("\(activity.title), \(activityCount) activities")
        .accessibilityHint("Opens AI agent activity")
    }
}
