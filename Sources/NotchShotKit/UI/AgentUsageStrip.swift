import SwiftUI

/// Plan limits under the agent list: one quiet line per provider, Claude from
/// its status line and Codex from Crewline. It reads like the island's other
/// metadata (a short label, a thin meter, a number) and only takes colour
/// when a limit is close: orange past 70%, red past 90%. Draws nothing until
/// a source has reported numbers.
struct AgentUsageStrip: View {
    private var coordinator: AppCoordinator?
    private var fixedGroups: [AgentUsageGroup] = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Fixed numbers, for previews and render checks.
    init(groups: [AgentUsageGroup]) {
        fixedGroups = groups
    }

    var body: some View {
        let groups = (coordinator?.agentUsageGroups ?? fixedGroups)
            .filter { $0.meters.contains { $0.kind != .context } }
        if !groups.isEmpty {
            HStack(spacing: NotchIsland.Spacing.gutter + NotchIsland.Spacing.tight) {
                ForEach(groups) { group in
                    AgentUsageGroupView(group: group)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Plan limits")
        }
    }
}

private struct AgentUsageGroupView: View {
    let group: AgentUsageGroup

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            AgentVibeIdentity(source: group.source, size: 14)
                .help(group.label)
            ForEach(group.meters.filter { $0.kind != .context }) { meter in
                AgentUsageMeterView(meter: meter)
            }
        }
        .opacity(group.isStale ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label + (group.isStale ? ", not recently updated" : ""))
    }
}

/// "5h ▬▬▬ 38%". The bar is the same capsule the island uses for progress,
/// thinned to a hairline-weight meter.
struct AgentUsageMeterView: View {
    let meter: AgentUsageMeter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Text(meter.kind.shortTitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(NotchIsland.Ink.hairline * 1.4))
                Capsule()
                    .fill(AgentUsageMeterView.tint(for: meter.usedPercent, resting: Color.islandInk(0.82)))
                    .frame(width: max(3, 30 * meter.usedPercent / 100))
                    .animation(NotchMotion.liveValue(reduceMotion: reduceMotion), value: meter.usedPercent)
            }
            .frame(width: 30, height: 3)
            Text("\(Int(meter.usedPercent.rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AgentUsageMeterView.tint(
                    for: meter.usedPercent,
                    resting: Color.islandInk(NotchIsland.Ink.secondary)
                ))
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.kind.title)
        .accessibilityValue("\(Int(meter.usedPercent.rounded())) percent used")
        .accessibilityHint(AgentUsagePolicy.resetText(meter.resetsAt) ?? "")
    }

    /// Plain ink until the points where a user would change what they ask
    /// the agent to do. A provider colour would blur that: Claude's coral
    /// reads as a warning at any level.
    static func tint(for percent: Double, resting: Color) -> Color {
        if percent >= 90 { return Color(red: 1, green: 0.36, blue: 0.33) }
        if percent >= 70 { return .orange }
        return resting
    }

    private var helpText: String {
        let used = "\(meter.kind.title): \(Int(meter.usedPercent.rounded()))% used"
        guard let reset = AgentUsagePolicy.resetText(meter.resetsAt) else { return used }
        return used + "\n" + reset
    }
}
