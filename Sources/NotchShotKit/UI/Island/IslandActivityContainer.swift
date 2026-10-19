import AppKit
import SwiftUI

/// Everything drawn *inside* the primary shell for `.island`: the compact or
/// expanded primary, or the burst covering it.
///
/// The container keeps one identity for the life of the island. Promotion,
/// expansion and bursts replace only the pieces that genuinely enter or leave,
/// so the island never crossfades as a whole.
struct IslandActivityContainer: View {
    var descriptor: IslandLayoutDescriptor
    var metrics: NotchMetrics
    var isActiveDisplay: Bool
    @Bindable var coordinator: AppCoordinator
    @Bindable var gesture: IslandGestureState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: IslandPresentation { coordinator.islandPresentation }

    private var physicalNotchWidth: CGFloat? {
        metrics.hasPhysicalNotch ? metrics.notchSize.width : nil
    }

    /// The primary as this display presents it. Level comes from the
    /// display-routed descriptor, so a secondary display never expands.
    private var primary: IslandActivity? {
        guard let id = descriptor.primaryID else { return nil }
        return presentation.primary?.id == id ? presentation.primary : nil
    }

    private var overlay: IslandOverlay? {
        guard descriptor.overlay != nil else { return nil }
        return presentation.transientOverlay
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let overlay, !descriptor.isExpanded || primary == nil {
                IslandOverlayContent(
                    overlay: overlay,
                    physicalNotchWidth: physicalNotchWidth,
                    coordinator: coordinator
                )
                .transition(IslandMotion.burstTransition(severity: overlay.severity, reduceMotion: reduceMotion))
                .id("overlay-" + (descriptor.overlayKey ?? ""))
            } else if let primary {
                primaryContent(primary)
                    .id(primary.id.description + "-" + descriptor.level.rawValue)
                    .transition(transition)
                    .offset(x: gesture.offset)
            }

            if descriptor.isExpanded, let overlay {
                expandedBand(overlay)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func primaryContent(_ primary: IslandActivity) -> some View {
        if descriptor.isExpanded {
            IslandExpandedContent(
                activity: primary,
                isFloating: !metrics.hasPhysicalNotch,
                physicalNotchWidth: physicalNotchWidth,
                coordinator: coordinator
            )
        } else {
            IslandCompactContent(
                activity: primary,
                physicalNotchWidth: physicalNotchWidth,
                coordinator: coordinator
            )
        }
    }

    /// A promoted activity travels in from the side it came from; a level
    /// change stages content behind the shell.
    private var transition: AnyTransition {
        if let edge = presentation.primaryArrivalEdge, !descriptor.isExpanded {
            return IslandMotion.primarySwap(from: edge, reduceMotion: reduceMotion)
        }
        return IslandMotion.levelTransition(reduceMotion: reduceMotion)
    }

    /// A level HUD or burst over an expanded island sits in a band at the
    /// bottom instead of covering what the user opened.
    @ViewBuilder
    private func expandedBand(_ overlay: IslandOverlay) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch overlay {
                case .systemLevel(let level):
                    SystemLevelContent(level: level)
                case .event(let event):
                    IslandEventContent(event: event, physicalNotchWidth: nil)
                case .context:
                    EmptyView()
                }
            }
            .frame(height: 46)
            .padding(.horizontal, NotchIsland.Spacing.element)
            .padding(.bottom, 5)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
    }
}

/// The burst layer's content.
struct IslandOverlayContent: View {
    var overlay: IslandOverlay
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        switch overlay {
        case .systemLevel(let level):
            SystemLevelContent(level: level, physicalNotchWidth: physicalNotchWidth)
        case .context(let snapshot):
            ContextContent(
                snapshot: snapshot,
                isPreviewing: false,
                physicalNotchWidth: physicalNotchWidth,
                coordinator: coordinator
            )
        case .event(let event):
            IslandEventContent(event: event, physicalNotchWidth: physicalNotchWidth)
        }
    }
}

/// A short event: icon on one wing, one line on the other. Icons stay still,
/// except the mode switches — Focus and Caps Lock — which take the phone's
/// Silent/Ring form: a filled pill with the state's word beside the camera,
/// because they are the same kind of news: a mode switched on or off.
struct IslandEventContent: View {
    var event: IslandTransientEvent
    var physicalNotchWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = 0

    private var isModeSwitch: Bool { event.kind == .focus || event.kind == .capsLock }

    /// Focus and Caps Lock carry their state in the symbol's fill.
    private var isModeOn: Bool {
        switch event.kind {
        case .focus: event.symbolName == "moon.fill"
        case .capsLock: event.symbolName == "capslock.fill"
        default: false
        }
    }

    private var modeOnFill: Color { event.kind == .focus ? IslandSystemColor.indigo : IslandSystemColor.green }
    private var modeOnText: Color { event.kind == .focus ? IslandSystemColor.indigoText : IslandSystemColor.green }

    private var tint: Color {
        if isModeSwitch {
            return isModeOn ? modeOnText : Color.islandInk(NotchIsland.Ink.secondary)
        }
        switch event.severity {
        case .informational: return Color.islandInk(NotchIsland.Ink.primary)
        case .success: return IslandSystemColor.green
        case .warning: return IslandSystemColor.orange
        case .error: return IslandSystemColor.red
        }
    }

    var body: some View {
        IslandWings(physicalNotchWidth: physicalNotchWidth) {
            if isModeSwitch {
                IslandStatePill(
                    systemName: event.kind == .focus ? "moon.fill" : event.symbolName,
                    fill: isModeOn ? modeOnFill : IslandSystemColor.neutralPill
                )
                .symbolEffect(.bounce, value: arrived)
            } else if event.kind == .inputSource, let code = event.detail {
                // The language code in the pill, the way the input menu
                // shows it, so the burst reads at a glance.
                Text(code)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 39, minHeight: 22)
                    .padding(.horizontal, 2)
                    .background(IslandSystemColor.blue, in: Capsule())
                    .accessibilityHidden(true)
            } else {
                Image(systemName: event.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
        } trailing: {
            VStack(alignment: physicalNotchWidth == nil ? .leading : .trailing, spacing: 0) {
                Text(event.title)
                    .font(.system(size: isModeSwitch ? 13 : 12, weight: .semibold))
                    .foregroundStyle(isModeSwitch ? tint : Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail = event.detail, physicalNotchWidth == nil, event.kind != .inputSource {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                }
            }
        }
        .task {
            guard !reduceMotion, isModeSwitch else { return }
            try? await Task.sleep(for: .milliseconds(160))
            arrived += 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.title)
        .accessibilityValue(event.detail ?? "")
    }
}

/// Minimal activities beside the primary shell. Each is its own small black
/// shape with the activity's shared element inside, and a full-size button.
struct IslandSatelliteLayer: View {
    var descriptor: IslandLayoutDescriptor
    var layout: NotchLayout
    @Bindable var coordinator: AppCoordinator
    @Bindable var gesture: IslandGestureState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if descriptor.showsSatellites {
                if let id = descriptor.leadingID, let activity = activity(id) {
                    satellite(activity, slot: .leading)
                }
                if let id = descriptor.trailingID, let activity = activity(id) {
                    satellite(activity, slot: .trailing)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func activity(_ id: IslandActivityID) -> IslandActivity? {
        coordinator.islandPresentation.visibleActivities.first { $0.id == id }
    }

    private func satellite(_ activity: IslandActivity, slot: IslandSlot) -> some View {
        let width = layout.satelliteWidth
        let distance = layout.size.width / 2 + layout.satelliteSpacing + width / 2
        let direction: CGFloat = slot == .leading ? -1 : 1
        return IslandSatelliteView(
            activity: activity,
            diameter: layout.satelliteDiameter,
            valueWidth: layout.satelliteValueWidth,
            slot: slot,
            coordinator: coordinator
        )
        .offset(x: direction * distance + gesture.offset * 0.5)
        .transition(IslandMotion.satelliteTransition(
            reduceMotion: reduceMotion,
            // From its resting place back to the primary's edge, where it
            // buds out of and merges back into the shell.
            travel: -direction * (layout.satelliteSpacing + width / 2),
            gap: layout.satelliteSpacing,
            height: layout.satelliteDiameter,
            slot: slot
        ))
        .id(activity.id)
    }
}

struct IslandSatelliteView: View {
    var activity: IslandActivity
    var diameter: CGFloat
    var valueWidth: CGFloat = 0
    var slot: IslandSlot = .trailing
    @Bindable var coordinator: AppCoordinator
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { diameter + valueWidth }

    var body: some View {
        Button {
            coordinator.selectIslandActivity(activity.id, expand: true)
            coordinator.noteIslandOpenedByPointer()
        } label: {
            ZStack {
                Capsule()
                    .fill(.black)
                    .overlay {
                        Capsule().stroke(
                            activity.kind == .recording
                                ? Color.red.opacity(0.7)
                                : Color.islandInk(isHovered ? NotchIsland.Ink.recessed : NotchIsland.Ink.hairline),
                            lineWidth: 1
                        )
                    }
                HStack(spacing: 4) {
                    // Drawn in place. Routing satellite icons through the
                    // shared layer made them fly in from wherever they were
                    // last seen whenever satellites reappeared after a collapse.
                    IslandActivityGlyph(activity: activity, coordinator: coordinator)
                        .frame(width: max(12, diameter - 12), height: max(12, diameter - 12))
                    if valueWidth > 0 {
                        IslandSatelliteValue(activity: activity, coordinator: coordinator)
                            .frame(width: valueWidth - 10, alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .padding(.leading, valueWidth > 0 ? 6 : 0)
                .frame(width: width, alignment: valueWidth > 0 ? .leading : .center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(width: width, height: diameter)
            // An agent beside the music that is blocked on the user wears a
            // badge, the way an app icon does, rather than a lit border.
            .overlay(alignment: .topTrailing) {
                if needsAnswer {
                    LayerPulsingDot(
                        diameter: 9,
                        color: .orange,
                        pulseOpacity: 0.45,
                        halfPeriod: 1.1,
                        pulses: !reduceMotion,
                        outlineColor: .black,
                        outlineWidth: 2
                    )
                    .frame(width: 9, height: 9)
                    .offset(x: 1, y: -1)
                    .transition(.opacity)
                }
            }
            // The visible shape is smaller than a comfortable target; the hit
            // area is not.
            .frame(
                width: max(width, NotchIsland.Hit.control),
                height: max(diameter, NotchIsland.Hit.control)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(activity.accessibilitySummary)
        .accessibilityLabel(activity.kind.title)
        .accessibilityValue(IslandAccessibility.value(for: activity, coordinator: coordinator))
        .accessibilityHint(needsAnswer ? "An agent is waiting for your answer" : "Shows this activity in the notch")
    }

    /// An agent beside the music that is blocked on the user.
    private var needsAnswer: Bool {
        activity.kind == .ai && activity.lifecycle == .waiting
    }
}

