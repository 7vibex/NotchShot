import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContextContent: View {
    var snapshot: ContextSnapshot
    var isPreviewing: Bool
    /// The cutout this display routes content around, or `nil` when the island
    /// is synthetic and every pixel of it is actually visible.
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if PowerModePresentationPolicy.isLowBatteryAlert(snapshot) {
            BatteryAlertCard(
                snapshot: snapshot,
                onOpenBatterySettings: { coordinator.openBatterySettings() }
            )
        } else if NetworkContextPolicy.isNetworkCard(snapshot) {
            NetworkStatusCard(
                snapshot: snapshot,
                onDismiss: { coordinator.dismissContextAlert() },
                onOpenNetworkSettings: { coordinator.openNetworkSettings() }
            )
        } else if snapshot.kind == .audioRoute, snapshot.presentation != .expanded {
            AudioAccessoryCard(snapshot: snapshot)
        } else if snapshot.presentation == .expanded {
            expanded
        } else if isPreviewing {
            if let agent = headlineAgent {
                if hasLiveVibeSurface {
                    AgentVibePeekHeader(
                        activity: agent,
                        activityCount: vibeActivityCount
                    ) { coordinator.setContextExpanded(true) }
                } else {
                    AgentPeekHeader(activity: agent) { coordinator.setContextExpanded(true) }
                }
            } else {
                preview
            }
        } else {
            if let agent = headlineAgent {
                if hasLiveVibeSurface {
                    AgentVibeCompactStrip(
                        activity: agent,
                        activityCount: vibeActivityCount,
                        physicalNotchWidth: physicalNotchWidth
                    ) { coordinator.setContextExpanded(true) }
                } else {
                    AgentCompactStrip(
                        activity: agent,
                        otherAgentCount: max(0, snapshot.aiActivities.count - 1),
                        physicalNotchWidth: physicalNotchWidth
                    ) {
                        coordinator.setContextExpanded(true)
                    }
                }
            } else {
                compact
            }
        }
    }

    /// The agent a collapsed or peeking island stands for. Only the `.ai` kind
    /// has one; every other context keeps the generic symbol-and-metric strip.
    private var headlineAgent: AIActivitySnapshot? {
        guard snapshot.kind == .ai else { return nil }
        return snapshot.aiActivities.first ?? coordinator.context.claude.sessions.first?.aiActivity
    }

    private var hasLiveVibeSurface: Bool {
        snapshot.kind == .ai
            && (!snapshot.aiActivities.isEmpty || !coordinator.context.claude.sessions.isEmpty)
    }

    private var vibeActivityCount: Int {
        let directClaudeIDs = Set(coordinator.context.claude.sessions.map(\.id))
        let genericCount = snapshot.aiActivities.filter {
            $0.source != .claude || !directClaudeIDs.contains($0.id)
        }.count
        return max(1, genericCount + coordinator.context.claude.sessions.count)
    }

    private var accentNSColor: NSColor {
        NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemGreen
        )
    }

    private var accent: Color {
        Color(nsColor: accentNSColor)
    }

    private var accentForeground: Color {
        Color(nsColor: NotchShotColorPolicy.foreground(on: accentNSColor))
    }

    private var compact: some View {
        Button {
            coordinator.setContextExpanded(true)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: snapshot.kind.symbolName)
                    .foregroundStyle(accent)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A bare Spacer let the two ends share the whole strip, so a
                // longer metric drifted into the camera cutout and vanished.
                // Reserving the cutout keeps both ends in the visible wings.
                if let physicalNotchWidth {
                    Color.clear
                        .frame(width: physicalNotchWidth)
                        .accessibilityHidden(true)
                } else {
                    Spacer(minLength: 0)
                }

                Text(snapshot.metric ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.metric ?? snapshot.subtitle ?? "")
    }

    private var preview: some View {
        Button {
            coordinator.setContextExpanded(true)
        } label: {
            previewHeader
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.subtitle ?? snapshot.metric ?? "")
    }

    private var previewHeader: some View {
        HStack(spacing: 10) {
            if let agent = headlineAgent {
                AgentGlyph(source: agent.source, size: 24)
            } else {
                Image(systemName: snapshot.kind.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = snapshot.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(snapshot.metric ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The live AI card owns its source, state, task and progress
            // header. Repeating the generic context header above it made the
            // compact card feel like a row inside a settings panel instead of
            // the focused agent surface it is.
            if snapshot.kind != .ai {
                previewHeader
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(snapshot.title)
                    .accessibilityValue(snapshot.subtitle ?? snapshot.metric ?? "")
                Divider().overlay(.white.opacity(0.14))
            }
            if snapshot.kind == .calendar {
                HStack(alignment: .top, spacing: 14) {
                    eventList
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider().overlay(.white.opacity(0.14))
                    monthOverview
                        .frame(width: 160)
                }
            } else if snapshot.kind == .ai {
                if hasLiveVibeSurface {
                    AgentVibeActivitySurface(
                        activities: snapshot.aiActivities,
                        recent: snapshot.aiRecentActivities,
                        subtitle: snapshot.subtitle,
                        claudeSessions: coordinator.context.claude.sessions,
                        onApprovePermission: { coordinator.approveClaudePermission(sessionID: $0) },
                        onDenyPermission: { coordinator.denyClaudePermission(sessionID: $0) },
                        onDismiss: { activity in
                            if activity.source == .claude,
                               coordinator.context.claude.session(for: activity.id) != nil {
                                coordinator.context.claude.dismiss(sessionID: activity.id)
                            } else {
                                coordinator.dismissAIActivity(activity)
                            }
                        },
                        onClearHistory: { coordinator.clearAIActivityHistory() }
                    )
                } else {
                    AgentActivityList(
                        activities: snapshot.aiActivities,
                        recent: snapshot.aiRecentActivities,
                        subtitle: snapshot.subtitle,
                        onDismiss: { coordinator.dismissAIActivity($0) },
                        onClearHistory: { coordinator.clearAIActivityHistory() },
                        claudeSessions: coordinator.context.claude.sessions,
                        onApprovePermission: { coordinator.approveClaudePermission(sessionID: $0) },
                        onDenyPermission: { coordinator.denyClaudePermission(sessionID: $0) }
                    )
                }
            } else if snapshot.kind == .timer {
                focusTimerControls
            } else if snapshot.kind == .voiceNote {
                voiceNoteControls
            } else {
                eventList
            }
            Spacer(minLength: 0)
            HStack {
                if snapshot.kind == .power {
                    Text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode is on" : "Low Power Mode is off")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Button("Dismiss") { coordinator.setContextExpanded(false) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                    .contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    @ViewBuilder
    private var focusTimerControls: some View {
        if let timer = snapshot.focusTimer {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: min(1, timer.elapsed / max(1, timer.duration)))
                    .tint(accent)
                    .accessibilityLabel("Timer progress")
                HStack(spacing: 8) {
                    if timer.state == .running {
                        Button("Pause") { coordinator.pauseFocusTimer() }
                            .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                            .contentShape(Rectangle())
                    } else if timer.state == .paused {
                        Button("Resume") { coordinator.resumeFocusTimer() }
                            .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                            .contentShape(Rectangle())
                    }
                    Button(timer.state == .completed ? "Done" : "Cancel") {
                        coordinator.cancelFocusTimer()
                    }
                    .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                    .contentShape(Rectangle())
                    Spacer()
                    Text(FocusTimerPolicy.formatted(timer.remaining))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var voiceNoteControls: some View {
        if let note = snapshot.voiceNote {
            VStack(alignment: .leading, spacing: 10) {
                if note.state == .recording {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Recording & transcribing locally")
                        Spacer()
                        Text(FocusTimerPolicy.formatted(note.elapsed)).monospacedDigit()
                    }
                    let hasTranscript = !(note.transcript ?? "").isEmpty
                    if let transcript = note.transcript, hasTranscript {
                        Text(transcript)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .accessibilityLabel("Live transcript")
                            .accessibilityValue(transcript)
                    }
                    if let errorMessage = note.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.86))
                    } else if !hasTranscript {
                        Text("Listening for speech…")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Button("Stop & Finish") { coordinator.stopVoiceNote() }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                } else if note.state == .transcribing {
                    ProgressView().controlSize(.small)
                    Text("Finalizing the on-device transcript…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    if let transcript = note.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.caption)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    if let url = note.fileURL {
                        Button("Reveal Voice Note") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                    }
                    Button("Dismiss") { coordinator.dismissVoiceNote() }
                        .buttonStyle(.borderless)
                        .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        if snapshot.events.isEmpty {
            Text(snapshot.subtitle ?? snapshot.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        } else {
            VStack(spacing: 4) {
                ForEach(snapshot.events.prefix(5)) { event in
                    Button {
                        coordinator.openCalendarEvent(event)
                    } label: {
                        HStack(spacing: 8) {
                            Capsule().fill(Color(nsColor: NSColor(hex: event.colorHex) ?? .systemBlue))
                                .frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(event.timingDescription())
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                    .accessibilityLabel(event.title)
                    .accessibilityValue(event.timingDescription())
                    .accessibilityHint("Opens this event in Calendar")
                }
            }
        }
    }

    private var monthOverview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Date().formatted(.dateTime.month(.wide).year()))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                spacing: 4
            ) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .accessibilityHidden(true)
                }
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let isToday = Calendar.autoupdatingCurrent.isDateInToday(date)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? accentForeground : .white)
                            .frame(width: 18, height: 18)
                            .background(isToday ? accent : .clear, in: Circle())
                            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    } else {
                        Color.clear
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    private var monthCells: [Date?] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now),
              let days = calendar.range(of: .day, in: .month, for: now) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells = Array<Date?>(repeating: nil, count: leading)
        cells.append(contentsOf: days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month.start)
        })
        cells.append(contentsOf: repeatElement(nil, count: max(0, 42 - cells.count)))
        return Array(cells.prefix(42))
    }
}

// MARK: - Idle

struct IdleContent: View {
    var isPeeking: Bool
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if isPeeking {
            HStack(spacing: 10) {
                Button {
                    coordinator.toggleExpanded()
                } label: {
                    Label("Capture", systemImage: "camera.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Divider().frame(height: 14).overlay(.white.opacity(0.2))

                NotchIconButton(systemName: "square.dashed", label: "Capture area", visualScale: 0.8) {
                    coordinator.capture(.area)
                }

                NotchIconButton(systemName: "record.circle", label: "Record", visualScale: 0.8) {
                    coordinator.startRecording()
                }
            }
            .padding(.horizontal, 14)
        } else {
            // AppKit also bridges clicks from the physical cutout's trigger
            // band, because hardware pixels themselves cannot be hit-tested.
            Button {
                coordinator.toggleExpanded()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Open NotchShot")
        }
    }
}
