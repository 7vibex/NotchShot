import SwiftUI

/// Everything the run card draws, worked out once from a run's records so
/// the view only lays it out.
struct AgentRunCardModel: Equatable {
    var source: AISource
    var state: AIActivityState
    var isAsking: Bool
    var title: String
    /// What the run is doing now, or why it stopped.
    var headline: String
    /// The run's clock: running from `startedAt`, or stopped at `endedAt`.
    var startedAt: Date?
    var endedAt: Date?
    /// "Sonnet 5.5": the agent's own name is already on its mark.
    var modelLabel: String?
    var plan: [AIActivityStep]
    var progress: Double?
    /// The steps already done, newest last. The one under way is the headline.
    var rows: [AgentRunRow]
    var controls: AgentRunControls
    /// Claude's permission button title: approval opens a review first.
    var permissionReviewTitle: String?

    init(
        activity: AIActivitySnapshot,
        claudeSession: ClaudeCodeSession?,
        interaction: AgentInteraction?,
        modelName: String?,
        controls: AgentRunControls
    ) {
        source = activity.source
        state = activity.state
        isAsking = interaction != nil || claudeSession?.permission != nil
        permissionReviewTitle = claudeSession?.permission?.reviewActionTitle
        title = activity.title
        self.controls = controls
        progress = activity.progress
        plan = claudeSession.map(\.plan) ?? activity.steps
        rows = claudeSession.map { Array(AgentRunTimeline.rows(for: $0.actions, limit: 4).filter { !$0.isCurrent }.suffix(3)) } ?? []

        let name = modelName?.isEmpty == false ? modelName : nil
        modelLabel = name.map { name in
            activity.source == .claude && name.hasPrefix("Claude ") ? String(name.dropFirst(7)) : name
        }

        if let session = claudeSession {
            startedAt = session.turnStartedAt ?? session.startedAt
            endedAt = session.phase == .working ? nil : (session.turnEndedAt ?? session.updatedAt)
        } else {
            startedAt = activity.startedAt
            endedAt = activity.state == .working ? nil : activity.updatedAt
        }

        headline = Self.headline(
            activity: activity,
            claudeSession: claudeSession,
            interaction: interaction,
            control: controls.state
        )
    }

    private static func headline(
        activity: AIActivitySnapshot,
        claudeSession: ClaudeCodeSession?,
        interaction: AgentInteraction?,
        control: AgentRunControlState?
    ) -> String {
        if let interaction {
            switch interaction.kind {
            case .approval(let request): return "Wants to use " + request.tool
            case .question: return AgentVibePresentation.bodyText(for: activity, interaction: interaction)
            }
        }
        if let permission = claudeSession?.permission {
            return "Wants to use " + permission.toolName
        }
        switch control {
        case .paused(let next)?:
            guard let next, let first = next.first else { return "Paused" }
            return "Paused before " + first.lowercased() + next.dropFirst()
        case .pausing?: return "Pausing before the next step"
        case .stopping?: return "Stopping before the next step"
        case nil: break
        }
        switch activity.state {
        case .working:
            if let session = claudeSession {
                return AgentRunTimeline.currentText(for: session.actions)?.text ?? "Thinking"
            }
            return AgentVibePresentation.bodyText(for: activity)
        case .waiting:
            return AgentVibePresentation.bodyText(for: activity, claudeSession: claudeSession)
        case .finished:
            return "Done"
        case .failed:
            return AgentVibePresentation.bodyText(for: activity)
        }
    }

    /// "Step 3 of 6", "All 6 done" or "42%".
    var metaTrailing: String? {
        if let position = AgentRunPlan.position(of: plan) {
            return AgentRunPlan.isComplete(plan)
                ? "All \(position.total) done"
                : "Step \(position.current) of \(position.total)"
        }
        return progress.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" }
    }

    var isPaused: Bool { controls.state != nil && controls.state != .stopping }

    var isRunning: Bool { state == .working && !isAsking && !(controls.state?.isPaused ?? false) }
}

/// The lead agent run. It is the agent rows' own layout with more under it:
/// the mark, the run's title and what it is doing now, the clock and model
/// where a row has its time; then, along the text column, the plan, the
/// steps already done, and Pause, Stop and Open run. It sits on the island's
/// black like the rows, with no box of its own.
struct AgentRunCard: View {
    /// The rows' mark size, so the card's text column lines up with theirs.
    static let markSize = NotchIsland.Mark.size
    private static let textInset = markSize + NotchAlertStyle.leadingGap

    let model: AgentRunCardModel
    let interaction: AgentInteraction?
    let showsPermissionButtons: Bool
    let canOpen: Bool
    let openHelp: String
    var onOpen: () -> Void
    var onControl: (AgentRunCommand) -> Void
    var onRespond: (AgentInteractionResponse) -> Void
    var onApprove: () -> Void
    var onDeny: () -> Void
    var onOpenConversation: (() -> Void)?
    var onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.vertical, NotchIsland.Spacing.row)
            details
                .padding(.leading, Self.textInset)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(NotchMotion.hoverSwap, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.source.title), \(model.title)")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: NotchAlertStyle.leadingGap) {
            // The mark is the way to the run, as on the rows.
            Button(action: onOpen) {
                AgentStateMark(
                    source: model.source,
                    state: model.state,
                    isAsking: model.isAsking,
                    isPaused: model.isPaused,
                    size: Self.markSize
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressButtonStyle())
            .disabled(!canOpen)
            .help(openHelp)
            .accessibilityLabel(openHelp)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(NotchAlertStyle.title)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                Text(model.headline)
                    .font(NotchAlertStyle.body)
                    .foregroundStyle(model.state == .failed && !model.isAsking
                        ? AgentStateMark.failedInk
                        : Color.islandInk(NotchIsland.Ink.body))
                    .lineLimit(model.isAsking ? 2 : 1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }

    /// The clock and the model at rest; the row controls under the pointer,
    /// in the same place, as the rows do it.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: 2) {
                clock
                if let modelLabel = model.modelLabel {
                    Text(modelLabel)
                        .font(NotchAlertStyle.meta)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .lineLimit(1)
                }
            }
            .opacity(isHovered ? 0 : 1)

            HStack(spacing: 2) {
                if let onOpenConversation {
                    IslandBandButton(systemName: "text.bubble", label: "Show conversation", action: onOpenConversation)
                }
                IslandBandButton(systemName: "xmark", label: "Hide \(model.source.title) activity", action: onDismiss)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }

    @ViewBuilder
    private var clock: some View {
        if let start = model.startedAt {
            if let end = model.endedAt {
                clockText(end.timeIntervalSince(start))
            } else {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    clockText(context.date.timeIntervalSince(start))
                }
            }
        }
    }

    private func clockText(_ seconds: TimeInterval) -> some View {
        IslandClockText(
            text: AgentRunPhrasing.clock(seconds),
            font: NotchAlertStyle.meta,
            color: Color.islandInk(model.endedAt == nil ? NotchIsland.Ink.secondary : NotchIsland.Ink.tertiary)
        )
        .accessibilityLabel("Running for \(AgentRunPhrasing.duration(seconds, running: true))")
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        if showsBar {
            bar
                .padding(.bottom, NotchIsland.Spacing.row)
        }
        if let interaction {
            AgentInteractionCard(interaction: interaction, onRespond: onRespond)
                .padding(.bottom, NotchIsland.Spacing.group)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            if !model.rows.isEmpty {
                steps
                    .padding(.bottom, showsControlRow ? NotchIsland.Spacing.tight : NotchIsland.Spacing.row)
            }
            if showsControlRow {
                controlRow
            }
        }
    }

    private var showsBar: Bool { !model.plan.isEmpty || model.progress != nil }

    /// The plan as one segment per step, in the rows' white, with where the
    /// run stands at the end.
    private var bar: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            Group {
                if !model.plan.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(model.plan) { step in
                            Capsule(style: .continuous)
                                .fill(segmentColor(step.state))
                        }
                    }
                } else if let progress = model.progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Self.track)
                            Capsule()
                                .fill(Color.islandInk(NotchIsland.Ink.body))
                                .frame(width: max(3, proxy.size.width * min(max(progress, 0), 1)))
                        }
                    }
                }
            }
            .frame(height: 3)

            if let trailing = model.metaTrailing {
                Text(trailing)
                    .font(NotchAlertStyle.meta)
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.plan.isEmpty ? "Progress" : "Plan")
        .accessibilityValue(model.metaTrailing ?? "")
    }

    private static let track = Color.islandInk(NotchIsland.Ink.track)

    private func segmentColor(_ state: AIActivityStepState) -> Color {
        switch state {
        case .completed: Color.islandInk(NotchIsland.Ink.body)
        case .working: Color.islandInk(NotchIsland.Ink.tertiary)
        case .pending: Self.track
        case .failed: AgentStateMark.failedInk
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
            ForEach(model.rows) { row in
                HStack(spacing: NotchIsland.Spacing.element) {
                    Text(row.text)
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.failed
                        ? "Failed"
                        : AgentRunPhrasing.duration(row.duration(now: row.endedAt ?? row.startedAt), running: false))
                        .font(NotchAlertStyle.meta)
                        .monospacedDigit()
                        .foregroundStyle(row.failed ? AgentStateMark.failedInk : Color.islandInk(NotchIsland.Ink.tertiary))
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Controls

    /// Only when there is something to press besides the way to the run,
    /// which the mark already is.
    private var showsControlRow: Bool {
        showsPermissionButtons || model.controls.canPause || model.controls.canStop
            || model.controls.state != nil
    }

    /// The answer rows' capsules: Resume is the white one, as the island's
    /// one call to action; Pause and Stop are quiet.
    private var controlRow: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            if showsPermissionButtons {
                NotchCapsuleButton("Deny", action: onDeny)
                    .accessibilityLabel("Deny Claude Code permission")
                NotchCapsuleButton(model.permissionReviewTitle ?? "Review in Terminal", prominence: .primary, action: onApprove)
                    .accessibilityLabel("Review Claude Code action")
            } else {
                let controls = model.controls
                if controls.showsResume {
                    NotchCapsuleButton("Resume", prominence: .primary) { onControl(.resume) }
                        .help("Let \(model.source.title) carry on")
                } else if controls.canPause {
                    NotchCapsuleButton("Pause") { onControl(.pause) }
                        .help("Pause before \(model.source.title)'s next step")
                }
                if controls.canStop || controls.state != nil {
                    let stopping = controls.state == .stopping
                    NotchCapsuleButton(stopping ? "Stopping…" : "Stop") { onControl(.stop) }
                        .disabled(stopping)
                        .opacity(stopping ? 0.55 : 1)
                        .help("End this turn before the next step")
                }
            }
            Spacer(minLength: NotchIsland.Spacing.element)
            if canOpen {
                AgentRunOpenButton(help: openHelp, action: onOpen)
            }
        }
    }

    private var accessibilityValue: String {
        var parts = [model.headline]
        if let trailing = model.metaTrailing { parts.append(trailing) }
        if let modelLabel = model.modelLabel { parts.append(modelLabel) }
        return parts.joined(separator: ", ")
    }
}

/// "Open run ↗": to the run's terminal tab or its page in Crewline. Drawn
/// like the questions' "Answer in Terminal ↗".
private struct AgentRunOpenButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("Open run")
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.islandInk(isHovered ? NotchIsland.Ink.secondary : NotchIsland.Ink.tertiary))
            .frame(minHeight: NotchIsland.Hit.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
