import AppKit
import NotchShotAIReporterSupport
import SwiftUI

/// The expanded primary. Each kind places its shared element in a header
/// anchor first (it travels there from the compact wing), then reveals
/// secondary controls and details in stages.
struct IslandExpandedContent: View {
    var activity: IslandActivity
    var isFloating: Bool
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch activity.kind {
            case .media:
                MediaContent(
                    coordinator: coordinator,
                    isPeeking: true,
                    isFloating: isFloating,
                    sharedArtworkID: activity.id
                )
            case .recording:
                RecordingContent(coordinator: coordinator, sharedIndicatorID: activity.id)
            case .timer:
                IslandTimerExpanded(activity: activity, physicalNotchWidth: physicalNotchWidth, coordinator: coordinator)
            case .call:
                IslandCallExpanded(activity: activity, physicalNotchWidth: physicalNotchWidth, coordinator: coordinator)
            case .ai:
                IslandAIExpanded(activity: activity, coordinator: coordinator)
            case .transfer:
                IslandTransferExpanded(activity: activity, coordinator: coordinator)
            case .external:
                IslandExternalExpanded(activity: activity, coordinator: coordinator)
            case .voiceNote:
                if let note = coordinator.context.voiceNotes.snapshot {
                    expandedContext(VoiceNoteCoordinator.context(from: note))
                }
            case .calendar:
                if let calendar = coordinator.context.calendarGlanceSnapshot {
                    expandedContext(calendar)
                }
            }
        }
        // Keyboard: ← → switch activities, Esc collapses. Focusable without the
        // blue ring, which would trace the island's corners (see ShelfContent).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            coordinator.selectIslandNeighbor(.leading) ? .handled : .ignored
        }
        .onKeyPress(.rightArrow) {
            coordinator.selectIslandNeighbor(.trailing) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            coordinator.collapseIsland()
            return .handled
        }
    }

    private func expandedContext(_ snapshot: ContextSnapshot) -> some View {
        var expanded = snapshot
        expanded.presentation = .expanded
        return ContextContent(
            snapshot: expanded,
            isPreviewing: false,
            physicalNotchWidth: physicalNotchWidth,
            coordinator: coordinator
        )
    }
}

/// An open transfer or reported activity, laid out like the other cards:
/// its glyph and name in the band left of the camera, how far it has got to
/// the right, then the route, the bar and the measured details below. The
/// header used to start under the camera, below an empty black strip.
private struct IslandProgressCard<Action: View>: View {
    var activity: IslandActivity
    var title: String
    var subtitle: String?
    var tint: Color
    var stateTint: Color
    var detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IslandBandHeader(leadingInset: NotchIsland.Spacing.gutter + 2, trailingInset: NotchIsland.Spacing.gutter + 2) {
                HStack(spacing: NotchIsland.Spacing.element) {
                    // The compact wing's glyph lands here, at about its size.
                    IslandGlyphSlot(id: activity.id, size: 20)
                    Text(title)
                        .font(.system(size: NotchIsland.TextSize.body, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } trailing: {
                if let fraction = activity.progress.fraction, !activity.lifecycle.isTerminal {
                    IslandClockText(
                        text: "\(Int((fraction * 100).rounded(.down)))%",
                        font: .system(size: 15, weight: .semibold, design: .rounded),
                        color: .white
                    )
                } else {
                    IslandStateText(
                        text: activity.stateLabel ?? "",
                        font: .system(size: NotchIsland.TextSize.body, weight: .semibold),
                        color: stateTint
                    )
                }
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: NotchIsland.TextSize.meta, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }
                IslandProgressBar(progress: activity.progress, tint: tint)
                    .islandReveal(stage: 1)
                HStack(spacing: NotchIsland.Spacing.element) {
                    Text(detail)
                        .font(.system(size: NotchIsland.TextSize.meta, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    action()
                }
                .frame(minHeight: NotchIsland.Hit.control)
                .padding(.top, 2)
                .islandReveal(stage: 2)
            }
            .padding(.horizontal, NotchIsland.Spacing.gutter + 2)
            .padding(.top, NotchIsland.Spacing.tight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A capsule progress bar showing only real progress: determinate draws the
/// fraction, indeterminate shows a quiet moving segment.
struct IslandProgressBar: View {
    var progress: IslandProgress
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(NotchIsland.Ink.track))
                switch progress {
                case .determinate(let fraction):
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * fraction))
                        .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: fraction)
                case .indeterminate:
                    // The sweep runs on the render server. As a SwiftUI
                    // `repeatForever` offset it redrew the notch on the main
                    // thread every frame the bar was on screen.
                    LayerProgressSweep(tint: tint.opacity(0.8), segment: 0.28, pass: 1.1)
                case .none:
                    EmptyView()
                }
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "In progress")
    }
}

// MARK: - Timer

/// One row of an expanded island that wraps the camera instead of hanging
/// below it, as the phone's timer and call do: one group in the band to the
/// camera's left, one to its right, the cutout's width left clear between.
///
/// The row is pinned to the top of the shell at its own height, so a level
/// HUD appended below an open island never pulls it off-centre.
struct IslandWrappingRow<Leading: View, Trailing: View>: View {
    var physicalNotchWidth: CGFloat?
    var height: CGFloat
    var leadingInset: CGFloat = 12
    var trailingInset: CGFloat = 14
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .padding(.leading, leadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let physicalNotchWidth {
                // A little wider than the cutout: content pressed against the
                // camera's edge reads as clipped by it.
                Color.clear.frame(width: physicalNotchWidth + 12).accessibilityHidden(true)
            } else {
                Spacer(minLength: NotchIsland.Spacing.group)
            }
            trailing()
                .padding(.trailing, trailingInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The timer opened, as the phone lays it out: pause and cancel to the left
/// of the camera, the name and a large countdown to its right, all in the
/// band the camera sits in.
private struct IslandTimerExpanded: View {
    var activity: IslandActivity
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    private var accent: Color { Color(nsColor: NSColor(hex: activity.accentHex) ?? .systemOrange) }

    var body: some View {
        let timer = coordinator.context.timer.current
        let state = timer?.state
        let ink = accent.opacity(state == .paused ? 0.6 : 1)
        IslandWrappingRow(
            physicalNotchWidth: physicalNotchWidth,
            height: NotchIsland.Geometry.expandedRowHeight,
            trailingInset: 18
        ) {
            HStack(spacing: 8) {
                if state == .completed {
                    IslandRoundButton(systemName: "checkmark", label: "Done", tint: IslandSystemColor.green, filled: true) {
                        coordinator.performIslandAction(.cancel, on: activity.id)
                    }
                } else {
                    IslandRoundButton(
                        systemName: state == .paused ? "play.fill" : "pause.fill",
                        label: state == .paused ? "Resume" : "Pause",
                        tint: accent,
                        filled: true
                    ) {
                        coordinator.performIslandAction(state == .paused ? .resume : .pause, on: activity.id)
                    }
                    IslandRoundButton(systemName: "xmark", label: "Cancel timer", tint: .white, filled: false) {
                        coordinator.performIslandAction(.cancel, on: activity.id)
                    }
                    .islandReveal(stage: 1)
                }
            }
        } trailing: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(state == .completed ? "Done" : (timer?.label ?? activity.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                IslandClockText(
                    text: timer.map { IslandClock.formatted($0.remaining, roundingUp: true) } ?? activity.metric ?? "",
                    font: .system(size: 30, weight: .semibold, design: .rounded),
                    color: ink
                )
                .fixedSize()
            }
        }
    }
}

/// A 40 pt round control on the island's black. `filled` tints the circle in
/// the control's own colour, as the phone does for a timer's pause; otherwise
/// it takes the island's near-black surface.
struct IslandRoundButton: View {
    var systemName: String
    var label: String
    var tint: Color
    var filled: Bool
    /// A solid disc with a white glyph — the phone's answer and decline
    /// buttons — instead of a tinted glyph on a dimmed disc.
    var solid = false
    var diameter: CGFloat = 40
    var action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            // Pause turning into play, a microphone gaining its slash: the
            // glyph morphs into the next one rather than being swapped.
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(solid ? .white : (filled ? tint : Color.islandInk(NotchIsland.Ink.primary)))
                .contentTransition(NotchSymbolMotion.swap(reduceMotion: reduceMotion))
                .frame(width: diameter, height: diameter)
                .modifier(RoundButtonSurface(tint: tint, filled: filled, solid: solid, isHovered: isHovered))
                .contentShape(Circle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct RoundButtonSurface: ViewModifier {
    var tint: Color
    var filled: Bool
    var solid: Bool
    var isHovered: Bool

    func body(content: Content) -> some View {
        if solid {
            content.background(tint.opacity(isHovered ? 0.86 : 1), in: Circle())
        } else if filled {
            content.background(tint.opacity(isHovered ? 0.34 : 0.24), in: Circle())
        } else {
            // The phone's neutral round button (cancel, hide) is a flat grey
            // disc, lighter than the island's other controls and unedged.
            content.background(Color.islandInk(isHovered ? 0.3 : 0.22), in: Circle())
        }
    }
}

// MARK: - AI

private struct IslandAIExpanded: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    /// Every run the list shows, so the header counts what the user sees.
    private var liveRuns: [AIActivitySnapshot] {
        var runs = coordinator.context.islandAIActivities
        let ids = Set(runs.map(\.displayIdentifier))
        for session in coordinator.context.claude.sessions where !ids.contains("claude:" + session.id) {
            runs.append(session.aiActivity)
        }
        return runs
    }

    var body: some View {
        let runs = liveRuns
        let interactions = coordinator.agentInteractions
        let sessions = coordinator.context.claude.sessions
        let needsYou = AgentVibePresentation.attentionCount(interactions: interactions, claudeSessions: sessions) > 0
        VStack(alignment: .leading, spacing: 0) {
            // The same band the notification stack uses: what this is beside
            // the camera on the left, its one line of state on the right.
            IslandBandHeader(leadingInset: 16, trailingInset: 16) {
                HStack(spacing: 6) {
                    // Which agents are running, as their own marks, rather
                    // than a generic sparkle.
                    AgentMarkStack(sources: AgentVibePresentation.sources(
                        of: AgentVibePresentation.sorted(runs, claudeSessions: sessions, interactions: interactions)
                    ))
                    Text(AgentVibePresentation.headerTitle(for: runs))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }
            } trailing: {
                Text(AgentVibePresentation.summaryText(live: runs, interactions: interactions, claudeSessions: sessions))
                    .font(NotchAlertStyle.meta)
                    .monospacedDigit()
                    .foregroundStyle(needsYou ? Color.orange : Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            AgentVibeActivitySurface(
                activities: coordinator.context.islandAIActivities,
                recent: coordinator.context.islandAIRecentActivities,
                subtitle: nil,
                claudeSessions: coordinator.context.claude.sessions,
                showsHeader: false,
                onApprovePermission: { coordinator.approveClaudePermission(sessionID: $0) },
                onDenyPermission: { coordinator.denyClaudePermission(sessionID: $0) },
                onDismiss: { agent in
                    if agent.source == .claude,
                       coordinator.context.claude.session(for: agent.id) != nil {
                        coordinator.context.claude.dismiss(sessionID: agent.id)
                    } else {
                        coordinator.dismissAIActivity(agent)
                    }
                },
                onClearHistory: { coordinator.clearAIActivityHistory() },
                interactions: coordinator.agentInteractions,
                onRespond: { coordinator.respondToAgent($0, with: $1) },
                onJump: { coordinator.jumpToAgent($0) },
                contextBySession: coordinator.context.claudeUsage.contextBySession,
                accessory: AnyView(AgentUsageStrip(coordinator: coordinator)),
                runControls: { coordinator.runControls(for: $0) },
                onRunControl: { coordinator.controlAgentRun($0, $1) },
                modelName: { coordinator.runModelName(for: $0) },
                onShowRun: { run in
                    if run.source == .claude { coordinator.context.claude.refreshModel(sessionID: run.id) }
                }
            )
            .islandReveal(stage: 1)
        }
    }
}

// MARK: - Transfer

private struct IslandTransferExpanded: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    private var transfer: TransferActivitySnapshot? {
        coordinator.transfers.transfers.first { $0.id.uuidString == activity.id.key }
    }

    var body: some View {
        // White, as the island's other bars are: the old blue read as a link.
        IslandProgressCard(
            activity: activity,
            title: transfer?.title ?? activity.title,
            subtitle: transfer.map {
                $0.service == .download
                    ? $0.peerName
                    : "\($0.service.title) · \($0.direction == .outgoing ? "to" : "from") \($0.peerName)"
            },
            tint: .white,
            stateTint: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: .white),
            detail: detailLine
        ) {
            if transfer?.canCancel == true {
                NotchCapsuleButton("Cancel", systemImage: "xmark", prominence: .destructive) {
                    coordinator.performIslandAction(.cancel, on: activity.id)
                }
            }
        }
    }

    /// Only measured facts: bytes, files, speed and ETA each appear only when
    /// the transport actually reported them.
    private var detailLine: String {
        guard let transfer else { return "" }
        if let error = transfer.errorMessage { return error }
        var parts: [String] = []
        if let bytes = transfer.bytesTransferred, let total = transfer.totalBytes {
            parts.append(
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            )
        } else if let bytes = transfer.bytesTransferred {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else if transfer.service == .localSend {
            parts.append("\(transfer.completedFiles) of \(transfer.effectiveFileCount) files")
        } else {
            parts.append(transfer.fileCountDescription)
        }
        if let rate = transfer.bytesPerSecond, !transfer.state.isTerminal {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
        }
        if let eta = transfer.estimatedCompletion, !transfer.state.isTerminal {
            let seconds = max(0, eta.timeIntervalSinceNow)
            parts.append(IslandFormat.remaining(seconds))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - External

private struct IslandExternalExpanded: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    private var external: ExternalLiveActivity? {
        coordinator.externalActivities.live.first { $0.id == activity.id.key }
    }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.accentHex) ?? .systemBlue
        ))
    }

    var body: some View {
        IslandProgressCard(
            activity: activity,
            title: activity.title,
            subtitle: [external?.source, activity.subtitle == external?.source ? nil : activity.subtitle]
                .compactMap { $0 }
                .joined(separator: " · "),
            tint: accent,
            stateTint: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: accent),
            detail: detailLine
        ) {
            NotchCapsuleButton("Hide", systemImage: "eye.slash") {
                coordinator.performIslandAction(.dismiss, on: activity.id)
            }
            .help("Hides this activity from the island. The reporting tool keeps running.")
        }
    }

    private var detailLine: String {
        guard let external else { return "" }
        var parts: [String] = []
        if let state = external.stateLabel { parts.append(state) }
        if let current = external.current {
            parts.append(IslandFormat.measured(current, total: external.total, unit: external.unit))
        }
        if let eta = external.estimatedCompletion, external.lifecycle == .active {
            parts.append(IslandFormat.remaining(max(0, eta.timeIntervalSinceNow)))
        }
        return parts.joined(separator: " · ")
    }
}

enum IslandFormat {
    static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        return (formatter.string(from: seconds) ?? "") + " left"
    }

    static func measured(_ current: Int64, total: Int64?, unit: LiveActivityUnit?) -> String {
        switch unit {
        case .bytes:
            let head = ByteCountFormatter.string(fromByteCount: current, countStyle: .file)
            guard let total else { return head }
            return head + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        case .items, .count, .none:
            guard let total else { return "\(current)" }
            return "\(current) of \(total)"
        }
    }
}
