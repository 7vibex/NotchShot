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

    private var shouldPulse: Bool { state == .working && !isDimmed }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.tight) {
            // A layer animation: a SwiftUI `repeatForever` here redrew the
            // whole notch every frame for as long as the agent worked.
            LayerPulsingDot(diameter: 5, color: tint, pulseOpacity: 0.35, halfPeriod: 0.85, pulses: shouldPulse)
                .frame(width: 5, height: 5)

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

// MARK: - Row

/// One finished run: a single row, so history stays quiet.
struct AgentActivityRow: View {
    var activity: AIActivitySnapshot
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var stateTint: Color { activity.state.tint(sourceAccent: accent) }

    private let iconSize: CGFloat = 18

    var body: some View {
        recentRow
        .contentShape(RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title), \(activity.state.title)")
        .accessibilityValue(accessibilityValue)
    }

    private var recentRow: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            agentButton

            Text(activity.source.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .fixedSize()

            AgentStatePill(state: activity.state, tint: stateTint, isDimmed: true)

            Text(activity.title)
                .font(.system(size: 11))
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

    private var elapsedLabel: some View {
        Text(FocusTimerPolicy.formatted(activity.elapsed()))
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .accessibilityLabel("Elapsed \(FocusTimerPolicy.formatted(activity.elapsed()))")
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

    private var canActivateAgentApp: Bool {
        AgentIconCatalog.hasKnownApplication(for: activity.source)
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
        return parts.joined(separator: ", ")
    }
}

// MARK: - Expanded list

/// The expanded panel's body when no agent is live: a dimmed history, or a
/// waiting state.
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

    var body: some View {
        if activities.isEmpty && recent.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                // Not lazy: `AIActivityPolicy` caps this at five recent ones, so
                // laziness saves nothing and costs correctness anywhere the view
                // is laid out outside a window.
                VStack(spacing: NotchIsland.Spacing.element) {
                    if !recent.isEmpty {
                        historyHeader
                        ForEach(recent, id: \.displayIdentifier) { activity in
                            AgentActivityRow(
                                activity: activity,
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
