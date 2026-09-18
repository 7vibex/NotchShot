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
                IslandTimerExpanded(activity: activity, coordinator: coordinator)
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

/// Header row shared by the island's own expanded cards.
private struct IslandExpandedHeader<Trailing: View>: View {
    var activity: IslandActivity
    var glyphSize: CGFloat = 38
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.group) {
            IslandGlyphSlot(id: activity.id, size: glyphSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule progress bar showing only real progress: determinate draws the
/// fraction, indeterminate shows a quiet moving segment.
struct IslandProgressBar: View {
    var progress: IslandProgress
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(NotchIsland.Ink.fill * 1.5))
                switch progress {
                case .determinate(let fraction):
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * fraction))
                        .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: fraction)
                case .indeterminate:
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: proxy.size.width * 0.28)
                        .offset(x: sweep ? proxy.size.width * 0.72 : 0)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                sweep = true
                            }
                        }
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

/// A text button styled for the island's black surface with a full hit target.
struct IslandTextButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, NotchIsland.Spacing.row)
                .frame(minHeight: 28)
                .background(Capsule().fill(Color.islandInk(NotchIsland.Ink.fill * 1.6)))
                .frame(minHeight: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.islandInk(NotchIsland.Ink.primary))
    }
}

// MARK: - Timer

private struct IslandTimerExpanded: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    private var accent: Color { Color(nsColor: NSColor(hex: activity.accentHex) ?? .systemOrange) }

    var body: some View {
        let timer = coordinator.context.timer.current
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.row) {
            IslandExpandedHeader(
                activity: activity,
                title: timer?.label ?? activity.title,
                subtitle: activity.stateLabel
            ) {
                IslandNumericText(
                    text: timer.map { FocusTimerPolicy.formatted($0.remaining) } ?? activity.metric ?? "",
                    countsDown: true,
                    font: .system(size: 26, weight: .semibold, design: .rounded),
                    color: accent
                )
            }
            IslandProgressBar(progress: activity.progress, tint: accent)
                .islandReveal(stage: 2)
            HStack(spacing: NotchIsland.Spacing.element) {
                if timer?.state == .running {
                    IslandTextButton(title: "Pause", systemImage: "pause.fill") {
                        coordinator.performIslandAction(.pause, on: activity.id)
                    }
                } else if timer?.state == .paused {
                    IslandTextButton(title: "Resume", systemImage: "play.fill") {
                        coordinator.performIslandAction(.resume, on: activity.id)
                    }
                }
                IslandTextButton(
                    title: timer?.state == .completed ? "Done" : "Cancel",
                    systemImage: timer?.state == .completed ? "checkmark" : "xmark",
                    role: timer?.state == .completed ? nil : .destructive
                ) {
                    coordinator.performIslandAction(.cancel, on: activity.id)
                }
                Spacer(minLength: 0)
            }
            .islandReveal(stage: 1)
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.vertical, NotchIsland.Spacing.row)
    }
}

// MARK: - AI

private struct IslandAIExpanded: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
            IslandExpandedHeader(
                activity: activity,
                glyphSize: 30,
                title: activity.title,
                subtitle: activity.subtitle
            ) {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    IslandStateText(
                        text: activity.stateLabel ?? "",
                        font: .system(size: 11, weight: .semibold),
                        color: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: .white)
                    )
                    if let metric = activity.metric {
                        IslandNumericText(
                            text: metric,
                            font: .system(size: 12, weight: .bold, design: .rounded),
                            color: Color.islandInk(NotchIsland.Ink.primary)
                        )
                    }
                }
            }
            .padding(.horizontal, NotchIsland.Spacing.group)
            .padding(.top, NotchIsland.Spacing.element)

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
                onClearHistory: { coordinator.clearAIActivityHistory() }
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
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.row) {
            IslandExpandedHeader(
                activity: activity,
                title: transfer?.title ?? activity.title,
                subtitle: transfer.map { "\($0.service.title) · \($0.direction == .outgoing ? "to" : "from") \($0.peerName)" }
            ) {
                if let fraction = activity.progress.fraction, !activity.lifecycle.isTerminal {
                    IslandNumericText(
                        text: "\(Int((fraction * 100).rounded(.down)))%",
                        font: .system(size: 18, weight: .semibold, design: .rounded),
                        color: .white
                    )
                } else {
                    IslandStateText(
                        text: activity.stateLabel ?? "",
                        font: .system(size: 12, weight: .semibold),
                        color: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: .blue)
                    )
                }
            }
            IslandProgressBar(progress: activity.progress, tint: .blue)
                .islandReveal(stage: 1)
            HStack(spacing: NotchIsland.Spacing.element) {
                Text(detailLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if transfer?.canCancel == true {
                    IslandTextButton(title: "Cancel", systemImage: "xmark", role: .destructive) {
                        coordinator.performIslandAction(.cancel, on: activity.id)
                    }
                }
            }
            .islandReveal(stage: 2)
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.vertical, NotchIsland.Spacing.row)
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
        } else if transfer.service == .localSend {
            parts.append("\(transfer.completedFiles) of \(transfer.fileCount) files")
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
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.row) {
            IslandExpandedHeader(
                activity: activity,
                title: activity.title,
                subtitle: [external?.source, activity.subtitle == external?.source ? nil : activity.subtitle]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            ) {
                if let fraction = activity.progress.fraction, !activity.lifecycle.isTerminal {
                    IslandNumericText(
                        text: "\(Int((fraction * 100).rounded(.down)))%",
                        font: .system(size: 18, weight: .semibold, design: .rounded),
                        color: .white
                    )
                } else {
                    IslandStateText(
                        text: activity.stateLabel ?? "",
                        font: .system(size: 12, weight: .semibold),
                        color: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: accent)
                    )
                }
            }
            IslandProgressBar(progress: activity.progress, tint: accent)
                .islandReveal(stage: 1)
            HStack(spacing: NotchIsland.Spacing.element) {
                Text(detailLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                IslandTextButton(title: "Hide", systemImage: "eye.slash") {
                    coordinator.performIslandAction(.dismiss, on: activity.id)
                }
                .help("Hides this activity from the island. The reporting tool keeps running.")
            }
            .islandReveal(stage: 2)
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.vertical, NotchIsland.Spacing.row)
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
