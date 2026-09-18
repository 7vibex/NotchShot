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

/// A short event: icon on one wing, one line on the other. Icons stay still.
struct IslandEventContent: View {
    var event: IslandTransientEvent
    var physicalNotchWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch event.severity {
        case .informational: Color.islandInk(NotchIsland.Ink.primary)
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: event.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.leading, physicalNotchWidth == nil ? NotchIsland.Geometry.floatingContentInset : 12)
                .frame(maxWidth: physicalNotchWidth == nil ? nil : .infinity, alignment: .leading)

            if let physicalNotchWidth {
                Color.clear.frame(width: physicalNotchWidth).accessibilityHidden(true)
            } else {
                Spacer().frame(width: NotchIsland.Spacing.row)
            }

            VStack(alignment: physicalNotchWidth == nil ? .leading : .trailing, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                if let detail = event.detail, physicalNotchWidth == nil {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.trailing, physicalNotchWidth == nil ? NotchIsland.Geometry.floatingContentInset : 12)
            .frame(maxWidth: .infinity, alignment: physicalNotchWidth == nil ? .leading : .trailing)
        }
        .frame(maxHeight: .infinity)
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
        let diameter = layout.satelliteDiameter
        let distance = layout.size.width / 2 + layout.satelliteSpacing + diameter / 2
        return IslandSatelliteView(
            activity: activity,
            diameter: diameter,
            coordinator: coordinator
        )
        .offset(x: (slot == .leading ? -distance : distance) + gesture.offset * 0.5)
        .transition(IslandMotion.satelliteTransition(reduceMotion: reduceMotion))
        .id(activity.id)
    }
}

struct IslandSatelliteView: View {
    var activity: IslandActivity
    var diameter: CGFloat
    @Bindable var coordinator: AppCoordinator
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            coordinator.selectIslandActivity(activity.id, expand: true)
        } label: {
            ZStack {
                Circle()
                    .fill(.black)
                    .overlay {
                        Circle().stroke(
                            activity.kind == .recording
                                ? Color.red.opacity(0.7)
                                : Color.islandInk(isHovered ? NotchIsland.Ink.recessed : NotchIsland.Ink.hairline),
                            lineWidth: 1
                        )
                    }
                // Drawn in place. Routing satellite icons through the shared
                // layer made them fly in from wherever they were last seen
                // whenever satellites reappeared after a collapse.
                IslandActivityGlyph(activity: activity, coordinator: coordinator)
                    .frame(width: max(12, diameter - 12), height: max(12, diameter - 12))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: diameter, height: diameter)
            // The visible circle is smaller than a comfortable target; the hit
            // area is not.
            .frame(
                width: max(diameter, NotchIsland.Hit.control),
                height: max(diameter, NotchIsland.Hit.control)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(activity.accessibilitySummary)
        .accessibilityLabel(activity.kind.title)
        .accessibilityValue(IslandAccessibility.value(for: activity, coordinator: coordinator))
        .accessibilityHint("Shows this activity in the notch")
    }
}
