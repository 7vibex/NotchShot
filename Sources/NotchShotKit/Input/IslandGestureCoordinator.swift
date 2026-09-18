import AppKit
import Observation

/// The only live gesture value views read. Kept in its own observable object
/// so a 120 Hz trackpad stream re-evaluates just the views that move with the
/// fingers, not every view that reads the coordinator.
@MainActor
@Observable
public final class IslandGestureState {
    public internal(set) var offset: CGFloat = 0
    public internal(set) var isTracking = false
    public init() {}
}

/// Direct-manipulation feedback. Only ever called from a user gesture or a
/// user-initiated action completing — never for a background event.
@MainActor
enum IslandHaptics {
    enum Moment {
        /// A swipe snapped to a different activity.
        case activitySnap
        /// A drop target locked in under the pointer.
        case dropTargetLocked
        /// A direct user action finished.
        case actionCompleted
    }

    static func perform(_ moment: Moment) {
        guard Preferences.shared.islandHapticsEnabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch moment {
        case .activitySnap: .alignment
        case .dropTargetLocked: .alignment
        case .actionCompleted: .levelChange
        }
        // A no-op on hardware without a Force Touch trackpad.
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Turns two-finger horizontal trackpad scrolls over the island into activity
/// switches.
///
/// Arbitration, in order — any "no" passes the event through untouched:
/// - the preference is on and the island has a neighbour to switch to;
/// - the event is a phased, precise (trackpad) scroll, not a mouse wheel;
/// - no mouse button is down (a scrubber or slider drag, a file drag);
/// - the event targets a notch panel, which only accepts events over the
///   island itself;
/// - no burst is covering the island;
/// - an expanded island only swipes from its header band, so scroll views,
///   sliders and the media scrubber below keep their own gestures;
/// - the movement is decisively horizontal (`IslandSwipeTracker` direction lock).
///
/// Momentum events after a committed or cancelled swipe are swallowed so the
/// flick's tail cannot scroll something underneath.
@MainActor
final class IslandGestureCoordinator {
    /// Height of the band at the top of an expanded island that accepts swipes.
    static let expandedHeaderBand: CGFloat = 64

    private weak var coordinator: AppCoordinator?
    private var monitor: Any?
    private var tracker = IslandSwipeTracker()
    private var ownsGesture = false
    private var swallowMomentum = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resetTracking()
    }

    /// Returns `true` when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                defer { swallowMomentum = false }
                return swallowMomentum
            }
            return swallowMomentum
        }

        guard let coordinator else { return false }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if event.phase.contains(.began) {
            swallowMomentum = false
            guard shouldBegin(event, coordinator: coordinator),
                  case .island(let descriptor) = coordinator.activity else {
                ownsGesture = false
                return false
            }
            tracker.begin(
                canNavigateLeading: descriptor.leadingID != nil,
                canNavigateTrailing: descriptor.trailingID != nil,
                at: event.timestamp
            )
            ownsGesture = true
        }

        guard ownsGesture else { return false }

        if event.phase.contains(.changed) || event.phase.contains(.began) {
            let consumed = tracker.change(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                at: event.timestamp
            )
            if tracker.phase == .rejected {
                ownsGesture = false
                resetTracking()
                return false
            }
            coordinator.islandGesture.isTracking = tracker.phase == .tracking
            coordinator.islandGesture.offset = tracker.visualOffset(reduceMotion: reduceMotion)
            return consumed
        }

        if event.phase.contains(.ended) {
            let wasTracking = tracker.phase == .tracking
            let direction = tracker.end(at: event.timestamp)
            ownsGesture = false
            swallowMomentum = wasTracking
            resetTracking()
            if let direction, coordinator.selectIslandNeighbor(direction) {
                IslandHaptics.perform(.activitySnap)
            }
            return wasTracking
        }

        if event.phase.contains(.cancelled) {
            let wasTracking = tracker.phase == .tracking
            tracker.cancel()
            ownsGesture = false
            swallowMomentum = wasTracking
            resetTracking()
            return wasTracking
        }
        return false
    }

    private func shouldBegin(_ event: NSEvent, coordinator: AppCoordinator) -> Bool {
        guard Preferences.shared.swipesBetweenActivities,
              event.hasPreciseScrollingDeltas,
              NSEvent.pressedMouseButtons == 0,
              let window = event.window as? NotchPanel,
              case .island(let descriptor) = coordinator.activity,
              descriptor.hasPrimary,
              descriptor.satelliteCount > 0,
              descriptor.overlay == nil else { return false }
        if descriptor.isExpanded {
            // Header band only, measured from the top of the window's content.
            let fromTop = window.frame.height - event.locationInWindow.y
            let displayID = coordinator.windowController?.activeDisplayID
            let topInset = displayID
                .flatMap { coordinator.windowController?.metrics(for: $0) }
                .map { $0.hasPhysicalNotch ? $0.notchSize.height : NotchIsland.Geometry.floatingTopInset }
                ?? 0
            return fromTop <= topInset + Self.expandedHeaderBand
        }
        return true
    }

    private func resetTracking() {
        guard let coordinator else { return }
        if coordinator.islandGesture.isTracking || coordinator.islandGesture.offset != 0 {
            coordinator.islandGesture.isTracking = false
            coordinator.islandGesture.offset = 0
        }
    }
}
