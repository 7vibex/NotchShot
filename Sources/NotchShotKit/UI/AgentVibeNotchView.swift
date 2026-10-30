import SwiftUI

/// Presentation rules shared by Claude, Codex, Cursor, and Terminal activity.
/// The source adapter remains the authority for state and text; this helper
/// only decides how the Vibe surface prioritises and labels those records.
enum AgentVibePresentation {
    static func statusText(
        for activity: AIActivitySnapshot,
        claudeSession: ClaudeCodeSession? = nil,
        interaction: AgentInteraction? = nil
    ) -> String {
        if let interaction { return interaction.isQuestion ? "Asked a question" : "Waiting for approval" }
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
        claudeSessions: [ClaudeCodeSession] = [],
        interactions: [AgentInteraction] = []
    ) -> [AIActivitySnapshot] {
        let asking = Set(interactions.map(\.activityKey))
        return activities.sorted { lhs, rhs in
            let lhsSession = claudeSessions.first { $0.id == lhs.id && lhs.source == .claude }
            let rhsSession = claudeSessions.first { $0.id == rhs.id && rhs.source == .claude }
            let lhsNeedsAttention = lhs.state.isAttention || lhsSession?.permission != nil
                || asking.contains(lhs.displayIdentifier)
            let rhsNeedsAttention = rhs.state.isAttention || rhsSession?.permission != nil
                || asking.contains(rhs.displayIdentifier)
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

    /// Runs waiting on the user: open questions and approvals, counted once
    /// per run.
    static func attentionCount(
        interactions: [AgentInteraction],
        claudeSessions: [ClaudeCodeSession]
    ) -> Int {
        var keys = Set(interactions.map(\.activityKey))
        for session in claudeSessions where session.permission != nil {
            keys.insert(AISource.claude.rawValue + ":" + session.id)
        }
        return keys.count
    }

    /// The header's one line of state: who needs the user first, else how
    /// many are working.
    static func summaryText(
        live: [AIActivitySnapshot],
        interactions: [AgentInteraction],
        claudeSessions: [ClaudeCodeSession]
    ) -> String {
        let asking = attentionCount(interactions: interactions, claudeSessions: claudeSessions)
        if asking > 0 { return asking == 1 ? "1 needs you" : "\(asking) need you" }
        let working = live.filter { $0.state == .working }.count
        if working > 0 { return "\(working) working" }
        return live.count == 1 ? "1 run" : "\(live.count) runs"
    }

    /// The row's second line: what the run is asking, else what it is doing,
    /// in the agent's own words where it gave any.
    static func bodyText(
        for activity: AIActivitySnapshot,
        claudeSession: ClaudeCodeSession? = nil,
        interaction: AgentInteraction? = nil
    ) -> String {
        if let interaction {
            switch interaction.kind {
            case .approval(let request): return "Wants to use " + request.tool
            case .question(let form):
                if let prompt = form.questions.first?.prompt, !prompt.isEmpty { return prompt }
                return "Has a question"
            }
        }
        if let permission = claudeSession?.permission {
            return "Wants to use " + permission.toolName
        }
        switch activity.state {
        case .working:
            if let detail = activity.detail, !detail.isEmpty { return detail }
            if let step = activity.steps.first(where: { $0.state == .working }) { return step.label }
            return "Working"
        case .waiting:
            return activity.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Your turn"
        case .finished:
            return "Done"
        case .failed:
            return activity.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Stopped with an error"
        }
    }

    /// Where the run card's "Open run" goes, in words.
    static func jumpHelp(for activity: AIActivitySnapshot, claudeSession: ClaudeCodeSession?) -> String {
        switch activity.source {
        case .claude where claudeSession?.tty != nil || claudeSession?.pid != nil: "Go to this session's terminal"
        case .crewline: "Open this run in Crewline"
        default: "Open \(activity.source.title)"
        }
    }

    /// Each provider once, in list order, for the header's stacked marks.
    static func sources(of activities: [AIActivitySnapshot]) -> [AISource] {
        var seen = Set<AISource>()
        return activities.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
    }
}

/// The provider mark used by every agent surface. Codex, Crewline and Cursor
/// are their installed app icons; Claude Code's crab sits on a tile cut to the
/// same icon grid, so a list of agents reads as one set of icons rather than
/// app icons beside a loose sprite.
struct AgentVibeIdentity: View {
    let source: AISource
    let size: CGFloat

    var body: some View {
        if source == .claude {
            ClaudeCodeTile(size: size)
        } else {
            AgentGlyph(source: source, size: size)
        }
    }
}

/// The crab on a graphite tile. The tile covers the share of the frame an
/// app icon's body does (macOS icons leave a margin inside their square), so
/// it lines up with the Codex and Crewline icons at every size.
struct ClaudeCodeTile: View {
    let size: CGFloat

    private var side: CGFloat { (size * AgentIconGrid.bodyScale).rounded() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * AgentIconGrid.cornerScale, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: [Color(white: 0.21), Color(white: 0.11)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5) }
            .overlay { ClaudeVibeCrabIcon(size: (side * 0.5).rounded()) }
            .frame(width: side, height: side)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Up to three provider marks, overlapping like shared-with avatars, so the
/// header says which agents are running instead of showing a generic glyph.
struct AgentMarkStack: View {
    let sources: [AISource]
    var size: CGFloat = 18

    /// The visible tile: an app icon's frame includes the grid's margin.
    private var tile: CGFloat { (size * AgentIconGrid.bodyScale).rounded() }

    var body: some View {
        HStack(spacing: -(size - tile) - tile * 0.18) {
            ForEach(Array(sources.prefix(3).enumerated()), id: \.element) { index, source in
                AgentVibeIdentity(source: source, size: size)
                    // A black edge cut around each tile so overlapping
                    // icons stay apart, as stacked avatars do.
                    .background {
                        RoundedRectangle(cornerRadius: (tile + 3) * AgentIconGrid.cornerScale, style: .continuous)
                            .fill(Color.black)
                            .frame(width: tile + 3, height: tile + 3)
                    }
                    .zIndex(Double(3 - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Shared expanded Vibe surface for all generic AI activity providers. It
/// reads like the island's notification stack: one row per run, the agent's
/// mark on the left, what it is doing in the island's title and body type,
/// the time on the right, and hairlines between rows. No cards or outlines.
/// Controls sit under the pointer; an agent asking for something gets its
/// answer controls inline under its row.
struct AgentVibeActivitySurface: View {
    var activities: [AIActivitySnapshot]
    var recent: [AIActivitySnapshot]
    var subtitle: String?
    var claudeSessions: [ClaudeCodeSession] = []
    /// The island draws its own header beside the camera above this list.
    var showsHeader = true
    var onApprovePermission: (String) -> Void
    var onDenyPermission: (String) -> Void
    var onDismiss: (AIActivitySnapshot) -> Void
    var onClearHistory: () -> Void
    /// Pending approvals and questions from every source. A row with one
    /// draws the shared answer controls in place of the Claude-only buttons.
    var interactions: [AgentInteraction] = []
    var onRespond: (AgentInteraction, AgentInteractionResponse) -> Void = { _, _ in }
    /// Takes the user to the exact place the agent runs: its terminal tab,
    /// or its run in Crewline. Without one, the agent's app is opened.
    var onJump: ((AIActivitySnapshot) -> Void)?
    /// Context window use per Claude session id, from the status line.
    var contextBySession: [String: Double] = [:]
    /// Pinned under the list (plan limits).
    var accessory: AnyView?
    /// Pause, Resume and Stop for the lead run's card.
    var runControls: (AIActivitySnapshot) -> AgentRunControls = { _ in .none }
    var onRunControl: (AIActivitySnapshot, AgentRunCommand) -> Void = { _, _ in }
    /// The model behind a run, when anything names it.
    var modelName: (AIActivitySnapshot) -> String? = { _ in nil }
    /// Called when a run becomes the card, to fetch what it still lacks.
    var onShowRun: (AIActivitySnapshot) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedClaudeSession: ClaudeCodeSession?
    /// The run the user picked for the card; else the one that matters most.
    @State private var selectedRunKey: String?
    /// Where a run's mark and title travel between its row and the card.
    @Namespace private var runNamespace
    /// The run the card showed as of the last update. In the update that
    /// hands the card to another run it still names the one leaving, whose
    /// row then fades in under its travelling mark and title instead of
    /// dropping in like a new run.
    @State private var cardRunKey: String?
    /// The runs that needed the user as of the last update, so a run that
    /// starts needing them can be told apart; nil until the list is drawn.
    @State private var needingYouKeys: Set<String>?

    private var liveActivities: [AIActivitySnapshot] {
        var merged = activities
        let existingIDs = Set(activities.map(\.displayIdentifier))
        for session in claudeSessions where !existingIDs.contains("claude:\(session.id)") {
            merged.append(session.aiActivity)
        }
        return AgentVibePresentation.sorted(merged, claudeSessions: claudeSessions, interactions: interactions)
    }

    private var recentActivities: [AIActivitySnapshot] {
        let liveIDs = Set(liveActivities.map(\.displayIdentifier))
        return recent.filter { !liveIDs.contains($0.displayIdentifier) }
    }

    var body: some View {
        // The list and the conversation panel overlap while one pushes the
        // other out, both hanging from the top.
        ZStack(alignment: .top) {
            if let selectedClaudeSession {
                ClaudeConversationPanel(session: selectedClaudeSession) {
                    self.selectedClaudeSession = nil
                }
                .transition(AgentListMotion.conversationTransition(reduceMotion: reduceMotion))
            } else {
                surface
                    .transition(AgentListMotion.listTransition(reduceMotion: reduceMotion))
            }
        }
        .onChange(of: needingYouNow, initial: true) { _, keys in
            needingYouKeys = keys
        }
        .onChange(of: leadActivity(in: liveActivities)?.displayIdentifier, initial: true) { _, key in
            cardRunKey = key
        }
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader, !liveActivities.isEmpty {
                header
            }
            if liveActivities.isEmpty && recentActivities.isEmpty {
                emptyState
            } else {
                list
            }
            if let accessory {
                Rectangle()
                    .fill(Color.islandInk(0.10))
                    .frame(height: 1)
                accessory
                    .padding(.top, NotchIsland.Spacing.snug)
            }
        }
        .padding(.horizontal, NotchAlertStyle.horizontalInset - 4)
        .padding(.bottom, NotchIsland.Spacing.element)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: liveActivities.map(\.displayIdentifier))
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: interactions.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI agent activity")
        .accessibilityValue(accessibilityValue)
    }

    private var list: some View {
        let live = liveActivities
        let lead = leadActivity(in: live)
        let others = live.filter { $0.displayIdentifier != lead?.displayIdentifier }
        // Under Reduce Motion nothing travels: the card swap crossfades.
        let namespace = reduceMotion ? nil : runNamespace
        return ScrollView(.vertical) {
            // A plain stack: there are only a handful of runs, and a lazy one
            // can build the view a mark travels to too late for the two to be
            // matched, leaving the mark to pop rather than glide.
            VStack(alignment: .leading, spacing: 0) {
                if let lead {
                    runCard(for: lead, namespace: namespace)
                        // One card per run, so handing the card to another run
                        // is a removal and an insertion the mark and title
                        // can travel across.
                        .id(lead.displayIdentifier)
                        .transition(.opacity)
                }
                ForEach(Array(others.enumerated()), id: \.element.displayIdentifier) { index, activity in
                    if index > 0 || lead != nil { AgentRowSeparator() }
                    let interaction = interaction(for: activity)
                    AgentVibeActivityRow(
                        activity: activity,
                        claudeSession: claudeSession(for: activity),
                        interaction: interaction,
                        contextPercent: activity.source == .claude ? contextBySession[activity.id] : nil,
                        onOpenConversation: { session in
                            selectedClaudeSession = session
                        },
                        onApprove: { onApprovePermission(activity.id) },
                        onDeny: { onDenyPermission(activity.id) },
                        onRespond: { response in
                            if let interaction { onRespond(interaction, response) }
                        },
                        canOpenAgent: onJump != nil
                            || AgentIconCatalog.applicationURL(for: activity.source) != nil,
                        onOpenAgent: {
                            if let onJump { onJump(activity) } else { AgentIconCatalog.activate(activity.source) }
                        },
                        onDismiss: { onDismiss(activity) },
                        onSelect: { choose(activity) },
                        namespace: namespace,
                        announcesAttention: startsNeedingYou(activity)
                    )
                    // The run leaving the card fades in under its mark and
                    // title, which travel back down from the card.
                    .transition(activity.displayIdentifier == cardRunKey
                        ? .opacity
                        : AgentListMotion.rowTransition(reduceMotion: reduceMotion))
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
        }
        .scrollIndicators(.automatic)
    }

    /// The run that gets the card: the user's pick while it is live, else
    /// one asking for something, else one at work, else the first.
    private func leadActivity(in live: [AIActivitySnapshot]) -> AIActivitySnapshot? {
        if let selectedRunKey, let chosen = live.first(where: { $0.displayIdentifier == selectedRunKey }) {
            return chosen
        }
        return live.first { interaction(for: $0) != nil || claudeSession(for: $0)?.permission != nil }
            ?? live.first { $0.state == .working }
            ?? live.first
    }

    /// Makes a row's run the card: its mark and title travel up into the
    /// card while the run that had it settles back into the list.
    private func choose(_ activity: AIActivitySnapshot) {
        withAnimation(NotchMotion.content(reduceMotion: reduceMotion)) {
            selectedRunKey = activity.displayIdentifier
        }
    }

    /// The orange badge's meaning, per run: a question or approval waiting,
    /// or the turn handed back.
    private func needsYou(_ activity: AIActivitySnapshot) -> Bool {
        AgentMarkWiggle.needsYou(
            state: activity.state,
            isAsking: interaction(for: activity) != nil || claudeSession(for: activity)?.permission != nil
        )
    }

    private var needingYouNow: Set<String> {
        Set(liveActivities.filter(needsYou).map(\.displayIdentifier))
    }

    /// True only in the update where the run starts needing the user, which
    /// is when its mark shakes.
    private func startsNeedingYou(_ activity: AIActivitySnapshot) -> Bool {
        AgentMarkWiggle.startsNeedingYou(
            activity.displayIdentifier,
            needsYou: needsYou(activity),
            before: needingYouKeys
        )
    }

    private func runCard(for activity: AIActivitySnapshot, namespace: Namespace.ID?) -> some View {
        let session = claudeSession(for: activity)
        let interaction = interaction(for: activity)
        return AgentRunCard(
            model: AgentRunCardModel(
                activity: activity,
                claudeSession: session,
                interaction: interaction,
                modelName: modelName(activity),
                controls: runControls(activity)
            ),
            interaction: interaction,
            showsPermissionButtons: interaction == nil && session?.permission != nil,
            canOpen: onJump != nil || AgentIconCatalog.applicationURL(for: activity.source) != nil,
            openHelp: AgentVibePresentation.jumpHelp(for: activity, claudeSession: session),
            onOpen: {
                if let onJump { onJump(activity) } else { AgentIconCatalog.activate(activity.source) }
            },
            onControl: { onRunControl(activity, $0) },
            onRespond: { response in
                if let interaction { onRespond(interaction, response) }
            },
            onApprove: { onApprovePermission(activity.id) },
            onDeny: { onDenyPermission(activity.id) },
            onOpenConversation: session.map { session in { selectedClaudeSession = session } },
            onDismiss: { onDismiss(activity) },
            runKey: activity.displayIdentifier,
            namespace: namespace,
            announcesAttention: startsNeedingYou(activity)
        )
        .task(id: activity.displayIdentifier) { onShowRun(activity) }
    }

    /// Only drawn where the island has no camera-band header of its own.
    private var header: some View {
        HStack(spacing: 6) {
            AgentMarkStack(sources: AgentVibePresentation.sources(of: liveActivities))
            Text(AgentVibePresentation.headerTitle(for: liveActivities))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)
            Spacer(minLength: NotchIsland.Spacing.element)
            Text(subtitle ?? AgentVibePresentation.summaryText(
                live: liveActivities,
                interactions: interactions,
                claudeSessions: claudeSessions
            ))
            .font(NotchAlertStyle.meta)
            .foregroundStyle(attentionCount > 0 ? Color.orange : Color.islandInk(NotchIsland.Ink.tertiary))
            .lineLimit(1)
        }
        .frame(height: 28)
    }

    private var attentionCount: Int {
        AgentVibePresentation.attentionCount(interactions: interactions, claudeSessions: claudeSessions)
    }

    private var emptyState: some View {
        VStack(spacing: NotchIsland.Spacing.tight) {
            Text("No agents running")
                .font(NotchAlertStyle.title)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            Text("Claude Code, Codex and Crewline runs show up here.")
                .font(NotchAlertStyle.body)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var historyHeader: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            Text("Earlier")
                .font(NotchAlertStyle.meta)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            Spacer(minLength: 0)
            Button(action: onClearHistory) {
                Text("Clear")
                    .font(NotchAlertStyle.meta)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .frame(minWidth: NotchIsland.Hit.control, minHeight: 28, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressButtonStyle())
            .accessibilityLabel("Clear earlier agent activity")
        }
        .padding(.top, liveActivities.isEmpty ? 0 : NotchIsland.Spacing.element)
    }

    private func claudeSession(for activity: AIActivitySnapshot) -> ClaudeCodeSession? {
        guard activity.source == .claude else { return nil }
        return claudeSessions.first { $0.id == activity.id }
    }

    /// The oldest open request for this run: answer them in the order asked.
    private func interaction(for activity: AIActivitySnapshot) -> AgentInteraction? {
        interactions
            .filter { $0.activityKey == activity.displayIdentifier }
            .min { $0.receivedAt < $1.receivedAt }
    }

    private var accessibilityValue: String {
        liveActivities.map {
            let session = claudeSession(for: $0)
            return "\($0.source.title), \($0.title), \(AgentVibePresentation.statusText(for: $0, claudeSession: session, interaction: interaction(for: $0)))"
        }.joined(separator: ". ")
    }
}

/// The notification stack's divider: a hairline starting at the text column.
private struct AgentRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.islandInk(0.10))
            .frame(height: 1)
            .padding(.leading, AgentVibeActivityRow.markSize + NotchAlertStyle.leadingGap)
    }
}

private struct AgentVibeActivityRow: View {
    static let markSize = NotchIsland.Mark.size

    let activity: AIActivitySnapshot
    let claudeSession: ClaudeCodeSession?
    let interaction: AgentInteraction?
    let contextPercent: Double?
    let onOpenConversation: (ClaudeCodeSession) -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onRespond: (AgentInteractionResponse) -> Void
    /// False only when there is nowhere to go: no jump handler and the
    /// agent's app is not installed.
    let canOpenAgent: Bool
    let onOpenAgent: () -> Void
    let onDismiss: () -> Void
    /// Makes this run the card.
    var onSelect: (() -> Void)?
    /// Pairs the mark and title with the card's, so they travel between the
    /// two when the card changes hands.
    var namespace: Namespace.ID?
    /// True in the update where this run starts needing the user.
    var announcesAttention = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// Whether the row still draws the legacy Claude Allow/Deny buttons:
    /// only when no shared answer controls stand in for them.
    private var showsLegacyPermissionButtons: Bool {
        interaction == nil && claudeSession?.permission != nil
    }

    private var isAsking: Bool { interaction != nil || claudeSession?.permission != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: NotchAlertStyle.leadingGap) {
                mark
                    .agentRunMatch(.mark, run: activity.displayIdentifier, in: namespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(NotchAlertStyle.title)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                        .agentRunMatch(.title, run: activity.displayIdentifier, in: namespace)
                    Text(bodyText)
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(bodyColor)
                        .lineLimit(isAsking ? 2 : 1)
                        .truncationMode(.tail)
                    if let progress = activity.progress, !isAsking, !activity.state.isTerminal {
                        progressBar(progress)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSelect?() }
                .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
                .accessibilityAction(named: "Show this run") { onSelect?() }

                trailing
            }
            .padding(.vertical, NotchIsland.Spacing.row)

            if let interaction {
                AgentInteractionCard(interaction: interaction, onRespond: onRespond)
                    .padding(.leading, Self.markSize + NotchAlertStyle.leadingGap)
                    .padding(.bottom, NotchIsland.Spacing.group)
                    .transition(AgentListMotion.answerTransition(reduceMotion: reduceMotion))
            } else if showsLegacyPermissionButtons {
                HStack(spacing: NotchIsland.Spacing.element) {
                    Spacer(minLength: 0)
                    NotchCapsuleButton("Deny", action: onDeny)
                        .accessibilityLabel("Deny Claude Code permission")
                    NotchCapsuleButton(claudeSession?.permission?.reviewActionTitle ?? "Review in Terminal", prominence: .primary, action: onApprove)
                        .accessibilityLabel("Review Claude Code action")
                }
                .padding(.leading, Self.markSize + NotchAlertStyle.leadingGap)
                .padding(.bottom, NotchIsland.Spacing.group)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(NotchMotion.hoverSwap, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title), \(activity.title)")
        .accessibilityValue(AgentVibePresentation.statusText(
            for: activity,
            claudeSession: claudeSession,
            interaction: interaction
        ))
    }

    // MARK: Mark

    /// The agent's mark, which is also the way to its terminal or run. A
    /// small dot on its corner carries the state, the way an app badge does.
    private var mark: some View {
        Button(action: onOpenAgent) {
            AgentStateMark(
                source: activity.source,
                state: activity.state,
                isAsking: isAsking,
                size: Self.markSize,
                announcesAttention: announcesAttention
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(!canOpenAgent)
        .help(jumpHelp)
        .accessibilityLabel(jumpHelp)
    }

    private var jumpHelp: String {
        switch activity.source {
        case .claude where claudeSession?.tty != nil || claudeSession?.pid != nil: "Go to this session's terminal"
        case .crewline: "Open this run in Crewline"
        default: "Open \(activity.source.title)"
        }
    }

    // MARK: Text

    private var bodyText: String {
        AgentVibePresentation.bodyText(for: activity, claudeSession: claudeSession, interaction: interaction)
    }

    private var bodyColor: Color {
        if activity.state == .failed, !isAsking { return AgentStateMark.failedInk }
        return Color.islandInk(NotchIsland.Ink.body)
    }

    private func progressBar(_ value: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(NotchIsland.Ink.track))
                Capsule()
                    .fill(Color.islandInk(NotchIsland.Ink.body))
                    .frame(width: max(3, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 160)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) percent")
    }

    // MARK: Trailing

    /// Agent, context and time at rest; the row's two controls under the
    /// pointer, in the same place, so a resting list reads as work rather
    /// than a column of buttons.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: 2) {
                TimelineView(.periodic(from: activity.updatedAt, by: 30)) { context in
                    Text(SystemNotificationTimePolicy.compactElapsed(
                        receivedAt: activity.startedAt ?? activity.updatedAt,
                        now: context.date
                    ))
                    .font(NotchAlertStyle.meta)
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                }
                if let secondaryMeta {
                    Text(secondaryMeta)
                        .font(NotchAlertStyle.meta)
                        .monospacedDigit()
                        .foregroundStyle(contextTint)
                        .lineLimit(1)
                }
            }
            .opacity(isHovered ? 0 : 1)

            HStack(spacing: 2) {
                if let claudeSession {
                    IslandBandButton(systemName: "text.bubble", label: "Show conversation") {
                        onOpenConversation(claudeSession)
                    }
                }
                IslandBandButton(systemName: "xmark", label: "Hide \(activity.source.title) activity", action: onDismiss)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }

    /// "54% context" for Claude, else the agent's name when a source hosts
    /// several.
    private var secondaryMeta: String? {
        if let contextPercent { return "\(Int(contextPercent.rounded()))% context" }
        return activity.agentLabel
    }

    private var contextTint: Color {
        guard let contextPercent else { return Color.islandInk(NotchIsland.Ink.tertiary) }
        return AgentUsageMeterView.tint(for: contextPercent, resting: Color.islandInk(NotchIsland.Ink.tertiary))
    }
}

/// A finished run that is still worth a glance: one quiet line.
private struct AgentVibeRecentRow: View {
    let activity: AIActivitySnapshot
    let onOpenAgent: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: NotchAlertStyle.leadingGap) {
            Button(action: onOpenAgent) {
                AgentVibeIdentity(source: activity.source, size: 22)
                    .opacity(0.72)
                    .frame(width: AgentVibeActivityRow.markSize, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressButtonStyle())
            .disabled(AgentIconCatalog.applicationURL(for: activity.source) == nil)
            .accessibilityLabel("Open \(activity.source.title)")

            Text(activity.title)
                .font(NotchAlertStyle.body)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                Text(activity.state == .failed ? "Failed" : "Done")
                    .font(NotchAlertStyle.meta)
                    .foregroundStyle(activity.state == .failed
                        ? AgentStateMark.failedInk
                        : Color.islandInk(NotchIsland.Ink.tertiary))
                    .opacity(isHovered ? 0 : 1)
                IslandBandButton(systemName: "xmark", label: "Remove \(activity.title)", action: onDismiss)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(NotchMotion.hoverSwap, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.source.title), \(activity.title)")
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

    private var tint: Color { AgentStateMark.ink(for: activity.state) }
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
                        .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
    }
}

/// The hover peek for agent activity: the lead run as one row of the list it
/// opens into, so the peek and the list read as the same thing. The project
/// and what the agent is doing take the space; the state rides on the mark's
/// badge rather than in a coloured word, and progress or the run's age sits
/// at the trailing edge with the count of other runs under it.
struct AgentVibePeekHeader: View {
    let activity: AIActivitySnapshot
    let activityCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: NotchAlertStyle.leadingGap) {
                AgentStateMark(source: activity.source, state: activity.state, size: NotchIsland.Mark.size)

                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.title)
                        .font(NotchAlertStyle.title)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                    Text(AgentVibePresentation.bodyText(for: activity))
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(activity.state == .failed ? AgentStateMark.failedInk : Color.islandInk(NotchIsland.Ink.body))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    if let progress = activity.progress, !activity.state.isTerminal {
                        Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    } else {
                        TimelineView(.periodic(from: activity.updatedAt, by: 30)) { context in
                            Text(SystemNotificationTimePolicy.compactElapsed(
                                receivedAt: activity.startedAt ?? activity.updatedAt,
                                now: context.date
                            ))
                            .font(NotchAlertStyle.meta)
                            .monospacedDigit()
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        }
                    }
                    if activityCount > 1 {
                        Text("+\(activityCount - 1) more")
                            .font(NotchAlertStyle.meta)
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.source.title)
        .accessibilityValue("\(AgentVibePresentation.statusText(for: activity)), \(activity.title), \(activityCount) activities")
        .accessibilityHint("Opens AI agent activity")
    }
}

/// An agent's mark with its state as a badge on the tile's corner, the way
/// an app icon carries a count: orange when it needs you, red when it
/// failed, a breathing white dot while it works, nothing once it is done.
/// Never the provider colour: Claude's coral reads as the orange that means
/// "needs you". The mark shakes once when its run starts needing you.
struct AgentStateMark: View {
    static let failedInk = Color(red: 1, green: 0.45, blue: 0.42)
    private static let failedBadge = Color(red: 1, green: 0.36, blue: 0.33)

    let source: AISource
    let state: AIActivityState
    var isAsking = false
    /// A working run held by Pause: the dot stops pulsing and greys.
    var isPaused = false
    let size: CGFloat
    /// True in the update where the run starts needing you: the cue for
    /// the one shake. The list works it out, since a mark created for the
    /// card in that same update has no earlier state of its own to compare.
    var announcesAttention = false

    /// The colour a state's word or glyph takes on the island's black.
    static func ink(for state: AIActivityState) -> Color {
        switch state {
        case .working: Color.islandInk(NotchIsland.Ink.body)
        case .waiting: .orange
        // White, as the open list's "Done" is: green read as one more alert.
        case .finished: Color.islandInk(NotchIsland.Ink.primary)
        case .failed: failedInk
        }
    }

    private var badge: CGFloat { max(8, (size * 0.3).rounded()) }
    private var outline: CGFloat { max(2, badge * 0.25) }
    /// Puts the badge's centre just inside the tile's corner rather than the
    /// frame's: the icon grid leaves a margin around the tile.
    private var inset: CGFloat {
        size * (1 - AgentIconGrid.bodyScale) / 2 + size * 0.04 - badge / 2
    }

    var body: some View {
        AgentVibeIdentity(source: source, size: size)
            .overlay(alignment: .bottomTrailing) {
                stateBadge
                    .frame(width: badge, height: badge)
                    .offset(x: -inset, y: -inset)
            }
            .frame(width: size, height: size)
            .modifier(AgentAttentionWiggle(cue: announcesAttention))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let ring = Circle().stroke(Color.black, lineWidth: outline)
        if AgentMarkWiggle.needsYou(state: state, isAsking: isAsking) {
            Circle().fill(Color.orange).overlay(ring)
        } else if state == .failed {
            Circle().fill(Self.failedBadge).overlay(ring)
        } else if state == .working, isPaused {
            Circle().fill(Color(white: 0.55)).overlay(ring)
        } else if state == .working {
            // A layer animation: a SwiftUI `repeatForever` opacity redrew the
            // whole notch every frame for as long as the agent worked.
            LayerPulsingDot(diameter: badge, color: .white, pulseOpacity: 0.3, outlineColor: .black, outlineWidth: outline)
        }
    }
}
