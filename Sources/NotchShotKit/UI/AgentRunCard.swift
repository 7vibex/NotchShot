import SwiftUI

/// Everything the run card draws, worked out once from a run's records so
/// the view only lays it out.
struct AgentRunCardModel: Equatable {
    var source: AISource
    var state: AIActivityState
    var isAsking: Bool
    var headline: String
    var headlineSymbol: String
    var title: String
    /// The run's clock: running from `startedAt`, or stopped at `endedAt`.
    var startedAt: Date?
    var endedAt: Date?
    var metaLeading: String
    var plan: [AIActivityStep]
    var progress: Double?
    var rows: [AgentRunRow]
    var toolCallCount: Int
    var controls: AgentRunControls

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
        title = activity.title
        self.controls = controls
        progress = activity.progress
        plan = claudeSession.map(\.plan) ?? activity.steps
        rows = claudeSession.map { AgentRunTimeline.rows(for: $0.actions) } ?? []
        toolCallCount = claudeSession?.toolCallCount ?? 0

        let workspace = claudeSession?.workspaceName
            ?? activity.workspace.map { URL(fileURLWithPath: $0).lastPathComponent }
        metaLeading = [modelName, workspace]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        if metaLeading.isEmpty { metaLeading = activity.source.title }

        if let session = claudeSession {
            startedAt = session.turnStartedAt ?? session.startedAt
            endedAt = session.phase == .working ? nil : (session.turnEndedAt ?? session.updatedAt)
        } else {
            startedAt = activity.startedAt
            endedAt = activity.state == .working ? nil : activity.updatedAt
        }

        (headline, headlineSymbol) = Self.headline(
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
    ) -> (String, String) {
        if let interaction {
            switch interaction.kind {
            case .approval(let request): return ("Wants to use " + request.tool, "hand.raised")
            case .question: return (AgentVibePresentation.bodyText(for: activity, interaction: interaction), "questionmark.bubble")
            }
        }
        if let permission = claudeSession?.permission {
            return ("Wants to use " + permission.toolName, "hand.raised")
        }
        switch control {
        case .paused(let next)?:
            guard let next, let first = next.first else { return ("Paused", "pause.circle") }
            return ("Paused before " + first.lowercased() + next.dropFirst(), "pause.circle")
        case .pausing?: return ("Pausing before the next step", "pause.circle")
        case .stopping?: return ("Stopping before the next step", "stop.circle")
        case nil: break
        }
        switch activity.state {
        case .working:
            if let session = claudeSession {
                if let current = AgentRunTimeline.currentText(for: session.actions) {
                    return (current.text, AgentRunPhrasing.symbol(for: current.kind))
                }
                return ("Thinking", "ellipsis")
            }
            return (AgentVibePresentation.bodyText(for: activity), "ellipsis")
        case .waiting:
            return (AgentVibePresentation.bodyText(for: activity, claudeSession: claudeSession), "checkmark.circle")
        case .finished:
            return ("Done", "checkmark.circle")
        case .failed:
            return (AgentVibePresentation.bodyText(for: activity), "exclamationmark.triangle")
        }
    }

    /// "Step 3 of 6", "All 6 done", "42%", or how many calls a run without
    /// a plan has made.
    var metaTrailing: String? {
        if let position = AgentRunPlan.position(of: plan) {
            return AgentRunPlan.isComplete(plan)
                ? "All \(position.total) done"
                : "Step \(position.current) of \(position.total)"
        }
        if let progress { return "\(Int((min(max(progress, 0), 1) * 100).rounded()))%" }
        return toolCallCount > 0 ? "Step \(toolCallCount)" : nil
    }

    var isRunning: Bool { state == .working && !isAsking && !(controls.state?.isPaused ?? false) }
}

/// The lead agent run as a card: what it is doing now and for how long,
/// which model and project, its plan as segments, its last few steps with
/// their times, and Pause, Stop and Open run.
struct AgentRunCard: View {
    static let accent = Color(red: 0.45, green: 0.62, blue: 1.0)

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
            meta
                .padding(.top, 10)
            if showsBar {
                bar
                    .padding(.top, 8)
            }
            if let interaction {
                AgentInteractionCard(interaction: interaction, onRespond: onRespond)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                if !model.rows.isEmpty {
                    steps
                        .padding(.top, 14)
                }
                if showsControlRow {
                    controlRow
                        .padding(.top, 10)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, showsControlRow && interaction == nil ? 8 : 14)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape
                .fill(Color.islandInk(0.045))
                .overlay { shape.strokeBorder(Color.islandInk(0.10), lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(model.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.source.title), \(model.title)")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AgentRunRing(
                source: model.source,
                state: model.state,
                isAsking: model.isAsking,
                isPaused: model.controls.state != nil && model.controls.state != .stopping
            )
            Image(systemName: model.headlineSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.islandInk(0.62))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(model.headline)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.state == .failed && !model.isAsking
                    ? AgentStateMark.failedInk
                    : Color.islandInk(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                clock
                    .opacity(isHovered ? 0 : 1)
                HStack(spacing: 0) {
                    if let onOpenConversation {
                        IslandBandButton(systemName: "text.bubble", label: "Show conversation", action: onOpenConversation)
                    }
                    IslandBandButton(systemName: "xmark", label: "Hide \(model.source.title) activity", action: onDismiss)
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(height: 34)
        }
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
            font: .system(size: 14, weight: .medium),
            color: Color.islandInk(model.endedAt == nil ? 0.62 : 0.42)
        )
        .accessibilityLabel("Running for \(AgentRunPhrasing.duration(seconds, running: true))")
    }

    // MARK: Meta and plan

    private var meta: some View {
        HStack(spacing: 8) {
            Text(model.metaLeading)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let trailing = model.metaTrailing {
                Text(trailing)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.islandInk(0.5))
    }

    private var showsBar: Bool {
        !model.plan.isEmpty || model.progress != nil || model.isRunning
    }

    @ViewBuilder
    private var bar: some View {
        if !model.plan.isEmpty {
            HStack(spacing: 5) {
                ForEach(model.plan) { step in
                    Capsule(style: .continuous)
                        .fill(segmentColor(step.state))
                        .frame(height: 4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Plan")
            .accessibilityValue(model.metaTrailing ?? "")
        } else if let progress = model.progress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.islandInk(0.12))
                    Capsule()
                        .fill(Self.accent)
                        .frame(width: max(4, proxy.size.width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(model.metaTrailing ?? "")
        } else {
            // Working with no plan to measure against: a sweep on a layer,
            // so it costs the app nothing per frame.
            LayerProgressSweep(tint: Self.accent.opacity(0.8), segment: 0.22, pass: 1.4)
                .frame(height: 4)
                .background(Capsule().fill(Color.islandInk(0.12)))
                .clipShape(Capsule())
                .accessibilityHidden(true)
        }
    }

    private func segmentColor(_ state: AIActivityStepState) -> Color {
        switch state {
        case .completed: Self.accent
        case .working: Self.accent.opacity(0.42)
        case .pending: Color.islandInk(0.12)
        case .failed: AgentStateMark.failedInk
        }
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: AgentRunPhrasing.symbol(for: row.kind))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.islandInk(0.5))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(row.text)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.islandInk(row.isCurrent ? 0.55 : 0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    rowTime(row)
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func rowTime(_ row: AgentRunRow) -> some View {
        if row.failed {
            Text("Failed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgentStateMark.failedInk)
        } else if row.isCurrent, model.endedAt == nil {
            TimelineView(.periodic(from: row.startedAt, by: 1)) { context in
                durationText(row.duration(now: context.date), running: true)
            }
        } else {
            durationText(row.duration(now: model.endedAt ?? row.startedAt), running: row.isCurrent)
        }
    }

    private func durationText(_ seconds: TimeInterval, running: Bool) -> some View {
        IslandClockText(
            text: AgentRunPhrasing.duration(seconds, running: running),
            font: .system(size: 12, weight: .medium),
            color: Color.islandInk(0.42)
        )
    }

    // MARK: Controls

    private var showsControlRow: Bool {
        showsPermissionButtons || canOpen || model.controls.canPause || model.controls.canStop
            || model.controls.state != nil
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            if showsPermissionButtons {
                AgentCapsuleButton(title: "Deny", isPrimary: false, action: onDeny)
                    .accessibilityLabel("Deny Claude Code permission")
                AgentCapsuleButton(title: "Allow", isPrimary: true, action: onApprove)
                    .accessibilityLabel("Allow Claude Code permission")
            } else {
                let controls = model.controls
                if controls.showsResume {
                    AgentRunControlButton(symbol: "play", title: "Resume") { onControl(.resume) }
                } else if controls.canPause {
                    AgentRunControlButton(symbol: "pause", title: "Pause") { onControl(.pause) }
                }
                if controls.canStop || controls.state != nil {
                    AgentRunControlButton(
                        symbol: "stop",
                        title: controls.state == .stopping ? "Stopping…" : "Stop"
                    ) { onControl(.stop) }
                    .disabled(controls.state == .stopping)
                }
            }
            Spacer(minLength: 8)
            if canOpen {
                AgentRunOpenButton(help: openHelp, action: onOpen)
            }
        }
    }

    private var accessibilityValue: String {
        var parts = [model.headline]
        if let trailing = model.metaTrailing { parts.append(trailing) }
        parts.append(model.metaLeading)
        return parts.joined(separator: ", ")
    }
}

/// The agent's mark inside a ring that carries the run's state: an arc
/// turning while it works, orange while it waits on the user, red when it
/// failed, a still grey ring while paused.
private struct AgentRunRing: View {
    let source: AISource
    let state: AIActivityState
    let isAsking: Bool
    let isPaused: Bool

    private static let diameter: CGFloat = 30

    var body: some View {
        ZStack {
            if state == .working, !isAsking, !isPaused {
                // A layer animation: a SwiftUI loop would redraw the notch
                // every frame for as long as the agent works.
                LayerSpinner(
                    diameter: Self.diameter,
                    lineWidth: 1.75,
                    tint: Color(white: 0.8),
                    trackOpacity: 0.16,
                    arcLength: 0.3,
                    period: 1.4
                )
            } else {
                Circle()
                    .strokeBorder(ringColor, lineWidth: 1.75)
            }
            AgentRunMark(source: source, size: 23)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }

    private var ringColor: Color {
        if isAsking { return .orange }
        if state == .failed { return AgentStateMark.failedInk }
        if isPaused { return Color.islandInk(0.4) }
        return Color.islandInk(0.16)
    }
}

/// Claude's crab on a round graphite disc, the other agents' app icons as
/// they are.
private struct AgentRunMark: View {
    let source: AISource
    let size: CGFloat

    var body: some View {
        if source == .claude {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.2), Color(white: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay { ClaudeVibeCrabIcon(size: (size * 0.52).rounded()) }
                .frame(width: size, height: size)
        } else {
            AgentVibeIdentity(source: source, size: size + 2)
        }
    }
}

/// An outlined capsule with a glyph and a word: Pause, Resume, Stop.
private struct AgentRunControlButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.islandInk(isEnabled ? 0.92 : 0.45))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(Color.islandInk(isHovered ? 0.10 : 0.04)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.islandInk(0.16), lineWidth: 1))
            .frame(minHeight: NotchIsland.Hit.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 && isEnabled }
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// "Open run ↗": to the run's terminal tab or its page in Crewline.
private struct AgentRunOpenButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Open run")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.islandInk(isHovered ? 1 : 0.78))
            .frame(minHeight: NotchIsland.Hit.control)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
