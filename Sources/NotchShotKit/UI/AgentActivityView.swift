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

// MARK: - Progress

/// A determinate bar drawn on the island's ladder rather than the system
/// `ProgressView`, whose control-tinted track disappears against black.
struct AgentProgressBar: View {
    var progress: Double
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.islandInk(NotchIsland.Ink.fill))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.72)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, proxy.size.width * clamped))
                }
            }
            .frame(height: 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: clamped)

            Text("\(Int((clamped * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("Reported progress")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}

// MARK: - Step trail

/// The agent's declared steps as a connected trail. Each step keeps its own
/// state colour, so a failure mid-run is visible without reading the labels.
struct AgentStepTrail: View {
    var steps: [AIActivityStep]
    var tint: Color

    private static let visibleLimit = 4

    private var visible: [AIActivityStep] { Array(steps.prefix(Self.visibleLimit)) }
    private var overflow: Int { max(0, steps.count - Self.visibleLimit) }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Color.islandInk(NotchIsland.Ink.hairline))
                        .frame(width: 6, height: 1)
                        .accessibilityHidden(true)
                }

                HStack(spacing: NotchIsland.Spacing.tight) {
                    Image(systemName: step.state.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color(for: step.state))
                    Text(step.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            step.state == .pending
                                ? Color.islandInk(NotchIsland.Ink.tertiary)
                                : Color.islandInk(NotchIsland.Ink.secondary)
                        )
                        .lineLimit(1)
                }
                .layoutPriority(step.state == .working ? 1 : 0)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Steps")
        .accessibilityValue(
            visible.map { "\($0.label), \($0.state.accessibilityDescription)" }
                .joined(separator: ". ")
        )
    }

    private func color(for state: AIActivityStepState) -> Color {
        switch state {
        case .pending: Color.islandInk(NotchIsland.Ink.tertiary)
        case .working: tint
        case .completed: .green
        case .failed: .red
        }
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

/// One agent's card.
///
/// The bands always appear in the same order — who, what, where, how far, which
/// step — so rows for different agents scan as one column rather than as a set
/// of unrelated boxes, and a band is omitted rather than reordered when an
/// agent reports nothing for it. A recent run keeps only the first band: its
/// progress and steps are no longer actionable, and the space belongs to the
/// agents still running.
struct AgentActivityRow: View {
    var activity: AIActivitySnapshot
    var isRecent: Bool
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.source.accentHex) ?? .systemGreen
        ))
    }

    private var stateTint: Color { activity.state.tint(sourceAccent: accent) }

    private var iconSize: CGFloat { isRecent ? 20 : 28 }

    var body: some View {
        HStack(alignment: .top, spacing: NotchIsland.Spacing.row) {
            agentButton

            VStack(alignment: .leading, spacing: NotchIsland.Spacing.snug) {
                identityBand

                if !isRecent {
                    Text(activity.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    contextLine

                    if let progress = activity.progress {
                        AgentProgressBar(progress: progress, tint: stateTint)
                            .padding(.top, NotchIsland.Spacing.hairline)
                    }

                    if !activity.steps.isEmpty {
                        AgentStepTrail(steps: activity.steps, tint: stateTint)
                    }
                }
            }
        }
        .padding(isRecent ? NotchIsland.Spacing.element : NotchIsland.Spacing.group)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .fill(Color.black.opacity(NotchIsland.Ink.recessed))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous)
                .stroke(borderTint, lineWidth: NotchIsland.Stroke.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchIsland.Radius.card, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title), \(activity.state.title)")
        .accessibilityValue(accessibilityValue)
    }

    /// An agent needing attention keeps a tinted edge even unhovered — it is
    /// the one row a glance has to find without reading.
    private var borderTint: Color {
        if activity.state.isAttention, !isRecent {
            return stateTint.opacity(0.42)
        }
        return Color.islandInk(NotchIsland.Ink.hairline)
    }

    private var identityBand: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            Text(activity.source.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .fixedSize()

            AgentStatePill(state: activity.state, tint: stateTint, isDimmed: isRecent)

            if isRecent {
                Text(activity.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: NotchIsland.Spacing.tight)

            Text(FocusTimerPolicy.formatted(activity.elapsed()))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .accessibilityLabel("Elapsed \(FocusTimerPolicy.formatted(activity.elapsed()))")

            dismissButton
        }
    }

    /// Where the agent is working and what it is doing, on one line.
    ///
    /// These were separate rows. In a panel bounded to 320pt they cost a line
    /// each while saying one thing — the run's context — so they share a line,
    /// with the path truncating from the head because the distinguishing part
    /// of a repository path is its tail.
    @ViewBuilder
    private var contextLine: some View {
        let workspace = activity.workspace.flatMap { $0.isEmpty ? nil : AgentWorkspaceFormatter.display($0) }
        let detail = activity.detail.flatMap { $0.isEmpty ? nil : $0 }

        if workspace != nil || detail != nil {
            HStack(spacing: NotchIsland.Spacing.snug) {
                if let workspace {
                    HStack(spacing: NotchIsland.Spacing.tight) {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                        Text(workspace)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .layoutPriority(1)
                }

                if let detail {
                    if workspace != nil {
                        Circle()
                            .fill(Color.islandInk(NotchIsland.Ink.hairline))
                            .frame(width: 2, height: 2)
                            .accessibilityHidden(true)
                    }
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                        .layoutPriority(2)
                }

                Spacer(minLength: 0)
            }
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

    var body: some View {
        if activities.isEmpty && recent.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                // Not lazy: `AIActivityPolicy` caps this at three live agents
                // plus five recent ones, so laziness saves nothing and costs
                // correctness anywhere the view is laid out outside a window.
                VStack(spacing: NotchIsland.Spacing.element) {
                    ForEach(activities, id: \.displayIdentifier) { activity in
                        AgentActivityRow(activity: activity, isRecent: false) {
                            onDismiss(activity)
                        }
                    }

                    if !recent.isEmpty {
                        historyHeader
                        ForEach(recent, id: \.displayIdentifier) { activity in
                            AgentActivityRow(activity: activity, isRecent: true) {
                                onDismiss(activity)
                            }
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
