import AppKit
import SwiftUI

// MARK: - State colour

extension AIActivityState {
    /// The tint for this state.
    ///
    /// Only `working` borrows the agent's own accent; the rest are fixed
    /// semantic colours. The previous design tinted everything except `failed`
    /// with the source accent, which made "Needs attention" — the one state
    /// that exists to pull the eye — look identical to "Working".
    func tint(sourceAccent: Color) -> Color {
        switch self {
        case .working: sourceAccent
        case .waiting: .orange
        case .finished: .green
        case .failed: .red
        }
    }

    var isAttention: Bool { self == .waiting || self == .failed }

    /// A one-word form for the collapsed island, where `title` does not fit.
    var compactTitle: String {
        switch self {
        case .working: "Working"
        case .waiting: "Attention"
        case .finished: "Done"
        case .failed: "Failed"
        }
    }
}

// MARK: - Workspace path

enum AgentWorkspaceFormatter {
    /// Abbreviates the user's home directory to `~`.
    ///
    /// A full `/Users/name/...` prefix is the same on every row and costs the
    /// width that the distinguishing tail of the path needs. Paths outside the
    /// home directory are left alone — there is nothing redundant to drop.
    static func display(
        _ workspace: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        guard workspace == home || workspace.hasPrefix(home + "/") else { return workspace }
        return "~" + workspace.dropFirst(home.count)
    }
}

// MARK: - Status pill

/// Dot plus label on a tinted capsule. The dot pulses while an agent is
/// working, which is the panel's only ambient motion — it stops by itself when
/// the state leaves `working`, so nothing keeps animating behind a closed island.
struct AgentStatePill: View {
    var state: AIActivityState
    var tint: Color
    var isDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var shouldPulse: Bool { state == .working && !reduceMotion && !isDimmed }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .opacity(isPulsing ? 0.35 : 1)
                .animation(
                    shouldPulse
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : nil,
                    value: isPulsing
                )

            Text(state.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, NotchIsland.Spacing.snug)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous).fill(tint.opacity(0.16))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: NotchIsland.Stroke.hairline)
        }
        .onAppear { isPulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, pulse in isPulsing = pulse }
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }
}

// MARK: - Focus card content

/// Keeps the dense focus card honest and predictable. The adapter may report
/// six steps, but four is the most the notch card can show without either
/// shrinking the labels into noise or pushing the task summary out of view.
enum AgentFocusCardPolicy {
    static let maximumVisibleSteps = 4

    static func visibleSteps(in activity: AIActivitySnapshot) -> [AIActivityStep] {
        Array(activity.steps.prefix(maximumVisibleSteps))
    }

    static func overflowCount(in activity: AIActivitySnapshot) -> Int {
        max(0, activity.steps.count - maximumVisibleSteps)
    }
}

/// The agent's declared work as a vertical checklist. This follows the compact
/// scan pattern used by terminal agents: completed work above, the active item
/// in accent, and pending work below. When an adapter reports no steps, the
/// activity's real title is used as the single current item rather than
/// inventing a plan that the agent never supplied.
struct AgentStepList: View {
    var activity: AIActivitySnapshot
    var tint: Color

    private var visible: [AIActivityStep] {
        AgentFocusCardPolicy.visibleSteps(in: activity)
    }

    private var overflow: Int {
        AgentFocusCardPolicy.overflowCount(in: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if visible.isEmpty {
                fallbackActivityLine
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: NotchIsland.Spacing.tight) {
                        Image(systemName: symbol(for: step.state))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color(for: step.state))
                            .frame(width: 10)
                            .accessibilityHidden(true)

                        Text(step.label)
                            .font(.system(size: 9.5, weight: step.state == .working ? .semibold : .medium))
                            .foregroundStyle(labelColor(for: step.state))
                            .lineLimit(1)

                        Spacer(minLength: NotchIsland.Spacing.tight)

                        if index == visible.count - 1, overflow > 0 {
                            Text("+\(overflow)")
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        }
                    }
                    .frame(minHeight: 11)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Steps")
        .accessibilityValue(accessibilityValue)
    }

    private var fallbackActivityLine: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            Image(systemName: activity.state.stripSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(activity.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(2)
        }
    }

    private var accessibilityValue: String {
        guard !visible.isEmpty else {
            return "\(activity.title), \(activity.state.title)"
        }
        var value = visible.map { "\($0.label), \($0.state.accessibilityDescription)" }
            .joined(separator: ". ")
        if overflow > 0 { value += ". \(overflow) more steps" }
        return value
    }

    private func symbol(for state: AIActivityStepState) -> String {
        switch state {
        case .pending: "circle"
        case .working: "circle.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
        }
    }

    private func color(for state: AIActivityStepState) -> Color {
        switch state {
        case .pending: Color.islandInk(NotchIsland.Ink.tertiary)
        case .working: tint
        case .completed: tint
        case .failed: .red
        }
    }

    private func labelColor(for state: AIActivityStepState) -> Color {
        state == .pending
            ? Color.islandInk(NotchIsland.Ink.tertiary)
            : Color.islandInk(NotchIsland.Ink.secondary)
    }
}

extension AIActivityStepState {
    var accessibilityDescription: String {
        switch self {
        case .pending: "pending"
        case .working: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

// MARK: - Row

/// One agent's card. Live work uses the same compact grammar as a terminal
/// agent: identity and state on top, a vertical command trail beside a recessed
/// task summary, and a quiet source-coloured glow at the bottom. Completed runs
/// collapse to one row so history never competes with work still in motion.
struct AgentActivityRow: View {
    var activity: AIActivitySnapshot
    var isRecent: Bool
    var onDismiss: () -> Void
    var claudeSession: ClaudeCodeSession? = nil
    var onApprovePermission: (() -> Void)? = nil
    var onDenyPermission: (() -> Void)? = nil
    var onOpenConversation: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var stateTint: Color { activity.state.tint(sourceAccent: accent) }

    private var iconSize: CGFloat { isRecent ? 18 : 20 }

    var body: some View {
        Group {
            if isRecent {
                recentRow
            } else {
                liveCard
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title), \(activity.state.title)")
        .accessibilityValue(accessibilityValue)
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.snug) {
            liveHeader

            HStack(alignment: .top, spacing: NotchIsland.Spacing.group) {
                AgentStepList(activity: activity, tint: stateTint)
                    .padding(.top, NotchIsland.Spacing.tight)

                taskSummary
                    .frame(width: 208)
            }

            focusRail
            permissionBar
        }
        .padding(.horizontal, NotchIsland.Spacing.group)
        .padding(.vertical, NotchIsland.Spacing.element)
        .background {
            liveCardBackground
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .stroke(borderTint, lineWidth: NotchIsland.Stroke.hairline)
        }
        .shadow(color: accent.opacity(reduceTransparency ? 0 : 0.12), radius: 12, y: 7)
    }

    private var recentRow: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            agentButton

            Text(activity.source.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .fixedSize()

            AgentStatePill(state: activity.state, tint: stateTint, isDimmed: true)

            Text(activity.title)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)

            Spacer(minLength: NotchIsland.Spacing.tight)

            elapsedLabel
            dismissButton
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

    /// An agent needing attention keeps a tinted edge even unhovered — it is
    /// the one row a glance has to find without reading.
    private var borderTint: Color {
        if activity.state.isAttention, !isRecent {
            return stateTint.opacity(0.42)
        }
        return Color.islandInk(NotchIsland.Ink.hairline)
    }

    private var liveHeader: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            agentButton

            Text(activity.source.title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .fixedSize()

            Circle()
                .fill(stateTint)
                .frame(width: 4, height: 4)
                .accessibilityHidden(true)

            Text(activity.state.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(stateTint)
                .lineLimit(1)

            Spacer(minLength: NotchIsland.Spacing.tight)

            if onOpenConversation != nil {
                conversationButton
            }
            elapsedLabel
            dismissButton
        }
    }

    @ViewBuilder
    private var permissionBar: some View {
        if let request = claudeSession?.permission,
           let onApprovePermission,
           let onDenyPermission,
           !isRecent {
            ClaudePermissionBar(
                request: request,
                onApprove: onApprovePermission,
                onDeny: onDenyPermission
            )
        }
    }

    @ViewBuilder
    private var taskSummary: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
            Text(activity.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = activity.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(3)
            }

            if let workspace = activity.workspace, !workspace.isEmpty {
                Label(AgentWorkspaceFormatter.display(workspace), systemImage: "folder")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(NotchIsland.Spacing.element)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.black.opacity(reduceTransparency ? 0.82 : 0.54))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .stroke(Color.islandInk(NotchIsland.Ink.hairline), lineWidth: NotchIsland.Stroke.hairline)
        }
    }

    @ViewBuilder
    private var focusRail: some View {
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
        } else {
            HStack(spacing: NotchIsland.Spacing.tight) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == 0 ? stateTint : Color.islandInk(NotchIsland.Ink.hairline))
                        .frame(width: index == 0 ? 24 : 16, height: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    private var elapsedLabel: some View {
        Text(FocusTimerPolicy.formatted(activity.elapsed()))
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .accessibilityLabel("Elapsed \(FocusTimerPolicy.formatted(activity.elapsed()))")
    }

    private var liveCardBackground: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .fill(Color.black.opacity(reduceTransparency ? 0.96 : 0.78))

            LinearGradient(
                colors: [
                    .clear,
                    accent.opacity(reduceTransparency ? 0.10 : 0.04),
                    accent.opacity(reduceTransparency ? 0.22 : 0.38)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 62)
            .clipShape(RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous))
        }
    }

    /// The icon doubles as the control that brings the agent forward. It is the
    /// row's only affordance for "take me to it", and an app icon is already
    /// the thing a pointer goes to.
    private var agentButton: some View {
        Button {
            activateAgentApp()
        } label: {
            AgentGlyph(source: activity.source, size: iconSize)
                .scaleEffect(NotchShotMotion.activeScale(
                    isActive: isHovered,
                    reduceMotion: reduceMotion,
                    activeScale: 1.06
                ))
                .frame(
                    width: NotchIsland.Hit.control,
                    height: NotchIsland.Hit.control
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(!canActivateAgentApp)
        .opacity(canActivateAgentApp ? 1 : NotchIconButton.disabledOpacity)
        .help(canActivateAgentApp ? "Open \(activity.source.title)" : activity.source.title)
        .accessibilityLabel(canActivateAgentApp
            ? "Open \(activity.source.title)"
            : "\(activity.source.title) app unavailable")
    }

    private var conversationButton: some View {
        Button {
            onOpenConversation?()
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Color.islandInk(NotchIsland.Ink.fill))
                }
                .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help("Open Claude Code conversation")
        .accessibilityLabel("Open Claude Code conversation")
        .accessibilityHint("Read the recent local transcript")
    }

    private var canActivateAgentApp: Bool {
        AgentIconCatalog.applicationURL(for: activity.source) != nil
    }

    private func activateAgentApp() {
        AgentIconCatalog.activate(activity.source)
    }

    /// Revealed on hover, but always present to VoiceOver and to keyboard
    /// focus — a control that only exists under a pointer is not a control.
    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Color.islandInk(NotchIsland.Ink.fill))
                }
                .frame(
                    width: NotchIsland.Hit.control,
                    height: NotchIsland.Hit.control
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .opacity(isHovered ? 1 : NotchIsland.Ink.secondary)
        .help("Dismiss this activity")
        .accessibilityLabel("Dismiss \(activity.source.title) activity")
    }

    private var accessibilityValue: String {
        var parts: [String] = [activity.title]
        if let workspace = activity.workspace, !workspace.isEmpty {
            parts.append("in \(AgentWorkspaceFormatter.display(workspace))")
        }
        if let progress = activity.progress {
            parts.append("\(Int((progress * 100).rounded())) percent")
        }
        if claudeSession?.permission != nil {
            parts.append("Permission requested")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Expanded list

/// The expanded panel's body: live agents first, then a dimmed history.
///
/// Only the list scrolls. The section headers and the panel's own dismiss
/// controls stay reachable, which is why the scroll region is here rather than
/// wrapped around the whole panel.
struct AgentActivityList: View {
    var activities: [AIActivitySnapshot]
    var recent: [AIActivitySnapshot]
    var subtitle: String?
    var onDismiss: (AIActivitySnapshot) -> Void
    var onClearHistory: () -> Void
    var claudeSessions: [ClaudeCodeSession] = []
    var onApprovePermission: (String) -> Void = { _ in }
    var onDenyPermission: (String) -> Void = { _ in }

    @State private var selectedClaudeSession: ClaudeCodeSession?

    var body: some View {
        if let selectedClaudeSession {
            ClaudeConversationPanel(session: selectedClaudeSession) {
                self.selectedClaudeSession = nil
            }
        } else if activities.isEmpty && recent.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                // Not lazy: `AIActivityPolicy` caps this at three live agents
                // plus five recent ones, so laziness saves nothing and costs
                // correctness anywhere the view is laid out outside a window.
                VStack(spacing: NotchIsland.Spacing.element) {
                    ForEach(activities, id: \.displayIdentifier) { activity in
                        let session = claudeSession(for: activity)
                        AgentActivityRow(
                            activity: activity,
                            isRecent: false,
                            onDismiss: { onDismiss(activity) },
                            claudeSession: session,
                            onApprovePermission: session?.permission == nil
                                ? nil
                                : { onApprovePermission(activity.id) },
                            onDenyPermission: session?.permission == nil
                                ? nil
                                : { onDenyPermission(activity.id) },
                            onOpenConversation: session.map { session in
                                { selectedClaudeSession = session }
                            }
                        )
                    }

                    if !recent.isEmpty {
                        historyHeader
                        ForEach(recent, id: \.displayIdentifier) { activity in
                            AgentActivityRow(
                                activity: activity,
                                isRecent: true,
                                onDismiss: { onDismiss(activity) }
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .accessibilityLabel("AI activities")
        }
    }

    private func claudeSession(for activity: AIActivitySnapshot) -> ClaudeCodeSession? {
        guard activity.source == .claude else { return nil }
        return claudeSessions.first { $0.id == activity.id }
    }

    /// A waiting panel still has to look designed — this is the state a user
    /// sees when they open the island before an agent has reported anything.
    private var emptyState: some View {
        VStack(spacing: NotchIsland.Spacing.element) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            Text(subtitle ?? "Waiting for a local AI activity update")
                .font(.system(size: 11))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
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
}

// MARK: - Collapsed strip

/// What the collapsed strip puts in its trailing wing.
///
/// A physical notch leaves roughly 75pt either side, which is one glyph or one
/// short number — not a sentence. So the strip picks exactly one signal by
/// priority rather than trying to show state and progress together.
enum AgentStripSignal: Equatable {
    /// The run has stopped and wants the user. Outranks progress: a run that is
    /// 90% done but blocked on approval needs the person, not a percentage.
    case attention(symbol: String)
    case percent(Int)
    case glyph(symbol: String)

    static func signal(for activity: AIActivitySnapshot) -> AgentStripSignal {
        if activity.state.isAttention {
            return .attention(symbol: activity.state.stripSymbol)
        }
        if let progress = activity.progress {
            return .percent(Int((min(max(progress, 0), 1) * 100).rounded()))
        }
        return .glyph(symbol: activity.state.stripSymbol)
    }
}

extension AIActivityState {
    /// A single filled glyph, legible at 13pt in a notch wing. The row's
    /// `symbolName` values are too detailed to survive that size.
    var stripSymbol: String {
        switch self {
        case .working: "ellipsis"
        case .waiting: "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

/// The closed island.
///
/// On a notched Mac the centre of this strip is a hole in the display — not a
/// dark pixel, but absent glass. Anything laid out there is not dimmed, it is
/// gone. So the cutout's width is reserved explicitly and the content is placed
/// into the two visible wings, the same way the system-level HUD does it. On a
/// display with no cutout there is nothing to route around, and the strip uses
/// its full width for a genuinely more informative row.
struct AgentCompactStrip: View {
    var activity: AIActivitySnapshot
    /// Agents running besides this one, shown as a count rather than as more
    /// icons: a second 24pt glyph does not fit a 75pt wing beside the first.
    var otherAgentCount: Int = 0
    /// The cutout to route around, or `nil` on a synthetic island.
    var physicalNotchWidth: CGFloat?
    var onOpen: () -> Void

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var tint: Color { activity.state.tint(sourceAccent: accent) }

    private var signal: AgentStripSignal { AgentStripSignal.signal(for: activity) }

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let physicalNotchWidth {
                    wings(around: physicalNotchWidth)
                } else {
                    continuousRow
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens agent activity")
    }

    private func wings(around notchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            leading
                .padding(.leading, NotchIsland.Spacing.snug)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The cutout, reserved. Without this the wings would share the full
            // width and a long signal would slide under the camera.
            Color.clear
                .frame(width: notchWidth)
                .accessibilityHidden(true)

            signalView
                .padding(.trailing, NotchIsland.Spacing.element)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var continuousRow: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            leading
            Text(activity.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)
            Spacer(minLength: NotchIsland.Spacing.tight)
            signalView
        }
        .padding(.horizontal, NotchIsland.Spacing.group)
    }

    private var leading: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            AgentRingGlyph(
                source: activity.source,
                progress: activity.progress,
                tint: tint,
                isPulsing: activity.state == .working
            )
            if otherAgentCount > 0 {
                Text("+\(otherAgentCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .monospacedDigit()
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private var accessibilityLabel: String {
        var text = "\(activity.source.title), \(activity.state.title)"
        if case .percent(let value) = signal { text += ", \(value) percent" }
        if otherAgentCount > 0 { text += ", \(otherAgentCount) more running" }
        return text
    }
}

/// The agent's icon wearing its own progress ring.
///
/// Merging identity and progress into one element is what makes the wing
/// budget work: the trailing wing is then free for the state signal instead of
/// having to carry a progress bar too.
struct AgentRingGlyph: View {
    var source: AISource
    var progress: Double?
    var tint: Color
    var isPulsing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    private let outer: CGFloat = 24
    private let ringWidth: CGFloat = 2

    /// No determinate ring means no arc to draw — a full circle at rest would
    /// read as "complete". The pulse carries "running" instead.
    private var shouldPulse: Bool { isPulsing && progress == nil && !reduceMotion }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.20), lineWidth: ringWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress)
            }

            AgentGlyph(source: source, size: outer - ringWidth * 2 - 4)
        }
        .frame(width: outer, height: outer)
        .opacity(isDimmed ? 0.55 : 1)
        .animation(
            shouldPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
            value: isDimmed
        )
        .onAppear { isDimmed = shouldPulse }
        .onChange(of: shouldPulse) { _, pulse in isDimmed = pulse }
        .accessibilityHidden(true)
    }
}

// MARK: - Peek header

/// The hover peek: enough to decide whether to open the panel, and no more.
struct AgentPeekHeader: View {
    var activity: AIActivitySnapshot
    var onOpen: () -> Void

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var tint: Color { activity.state.tint(sourceAccent: accent) }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: NotchIsland.Spacing.row) {
                AgentGlyph(source: activity.source, size: 26)

                VStack(alignment: .leading, spacing: NotchIsland.Spacing.hairline) {
                    HStack(spacing: NotchIsland.Spacing.snug) {
                        Text(activity.source.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                            .fixedSize()
                        AgentStatePill(state: activity.state, tint: tint)
                    }
                    Text(activity.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }

                Spacer(minLength: NotchIsland.Spacing.element)

                if let progress = activity.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, NotchIsland.Spacing.gutter)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.source.title), \(activity.state.title)")
        .accessibilityValue(activity.title)
        .accessibilityHint("Opens agent activity")
    }
}
