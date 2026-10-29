import AppKit
import Observation
import SwiftUI

/// The only live gesture value views read. Kept in its own observable object
/// so a 120 Hz trackpad stream re-evaluates just the views that move with the
/// fingers, not every view that reads the coordinator.
@MainActor
@Observable
public final class IslandGestureState {
    public internal(set) var offset: CGFloat = 0
    public internal(set) var isTracking = false
    /// How far the closed player leans toward a track-skip swipe, -1…1.
    public internal(set) var trackPull: CGFloat = 0
    /// How far the closed notch is being pulled open, 0…1.
    public internal(set) var openPull: CGFloat = 0
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
        /// The user clicked or held the island open.
        case islandOpened
        /// A dropped file went into the island.
        case dropSwallowed
        /// A scroll moved a value one step, such as a timer's minute.
        case valueStep
        /// A swipe skipped a track.
        case trackSkipped
    }

    static func perform(_ moment: Moment) {
        guard Preferences.shared.islandHapticsEnabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch moment {
        case .activitySnap: .alignment
        case .dropTargetLocked: .alignment
        case .actionCompleted: .levelChange
        case .islandOpened: .generic
        case .dropSwallowed: .levelChange
        case .valueStep: .alignment
        case .trackSkipped: .levelChange
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
    /// A scroll over a single compact activity, which has no neighbour to
    /// swipe to: the timer's minutes, or the player's tracks.
    private var compactGesture: CompactGesture?
    private var timerStepper = IslandScrollStepper()
    private var trackSwipe = TrackSwipeDecision()
    private var openPull = OpenPullDecision()

    private enum CompactGesture {
        case timerMinutes
        case trackSkip
        /// Two fingers pulling the closed notch down, the way the Mac's own
        /// island opens.
        case pullOpen
    }

    /// What a pull-down on the closed notch opens.
    private enum PullOpenTarget {
        case captureMenu
        case islandPrimary
    }

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

        // A mouse wheel has no phases: each click is one minute on a timer.
        if event.phase.isEmpty {
            guard compactGestureKind(for: event, coordinator: coordinator) == .timerMinutes else { return false }
            let steps = IslandScrollStepper.wheelSteps(upward: Self.upwardDelta(event))
            if steps != 0, coordinator.context.timer.adjust(byMinutes: steps) {
                IslandHaptics.perform(.valueStep)
            }
            return true
        }

        if event.phase.contains(.began) {
            swallowMomentum = false
            compactGesture = nil
            if shouldBegin(event, coordinator: coordinator),
               case .island(let descriptor) = coordinator.activity {
                tracker.begin(
                    canNavigateLeading: descriptor.leadingID != nil,
                    canNavigateTrailing: descriptor.trailingID != nil,
                    at: event.timestamp
                )
                ownsGesture = true
            } else {
                ownsGesture = false
                compactGesture = compactGestureKind(for: event, coordinator: coordinator)
                    ?? (pullOpenTarget(for: event, coordinator: coordinator) != nil ? .pullOpen : nil)
                timerStepper.reset()
                trackSwipe = TrackSwipeDecision()
            }
            openPull = OpenPullDecision()
        }

        // Every sideways gesture on the closed notch also watches for a
        // decisive pull downward, and hands over to it when it sees one.
        if compactGesture != .pullOpen, !event.phase.contains(.ended), !event.phase.contains(.cancelled),
           pullOpenTarget(for: event, coordinator: coordinator) != nil {
            openPull.add(deltaX: event.scrollingDeltaX, downward: -Self.upwardDelta(event))
            if openPull.isVertical == true {
                if ownsGesture {
                    tracker.cancel()
                    ownsGesture = false
                    resetTracking()
                }
                if compactGesture == .trackSkip {
                    coordinator.islandGesture.trackPull = 0
                }
                compactGesture = .pullOpen
                coordinator.islandGesture.openPull = openPull.stretch
                return true
            }
        }

        if let compactGesture {
            return handleCompact(compactGesture, event: event, coordinator: coordinator)
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

    /// Which compact gesture a scroll over the closed island starts, if any.
    private func compactGestureKind(for event: NSEvent, coordinator: AppCoordinator) -> CompactGesture? {
        guard NSEvent.pressedMouseButtons == 0, event.window is NotchPanel else { return nil }
        let primary: IslandActivityKind?
        switch coordinator.activity {
        case .island(let descriptor):
            guard !descriptor.isExpanded, descriptor.overlay == nil else { return nil }
            // With a neighbour beside it, a sideways swipe switches to it.
            if descriptor.primaryKind == .media, descriptor.satelliteCount > 0 { return nil }
            primary = descriptor.primaryKind
        case .media:
            primary = .media
        default:
            return nil
        }
        switch primary {
        case .timer:
            guard let timer = coordinator.context.timer.current, timer.state != .completed else { return nil }
            return .timerMinutes
        case .media:
            guard ExtrasPreferences.shared.swipesBetweenTracks, event.hasPreciseScrollingDeltas else { return nil }
            return .trackSkip
        default:
            return nil
        }
    }

    /// What pulling the closed notch down would open, if anything. A timer
    /// keeps vertical scrolls for its minutes.
    private func pullOpenTarget(for event: NSEvent, coordinator: AppCoordinator) -> PullOpenTarget? {
        guard event.hasPreciseScrollingDeltas, NSEvent.pressedMouseButtons == 0, event.window is NotchPanel else {
            return nil
        }
        switch coordinator.activity {
        case .idle:
            return .captureMenu
        case .island(let descriptor):
            guard !descriptor.isExpanded, descriptor.overlay == nil, descriptor.hasPrimary,
                  descriptor.primaryKind != .timer else { return nil }
            return .islandPrimary
        default:
            return nil
        }
    }

    private func handleCompact(_ gesture: CompactGesture, event: NSEvent, coordinator: AppCoordinator) -> Bool {
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        switch gesture {
        case .timerMinutes:
            if !ended {
                let steps = timerStepper.steps(adding: Self.upwardDelta(event))
                // One tick per change, however many minutes a fast flick moved.
                if steps != 0, coordinator.context.timer.adjust(byMinutes: steps) {
                    IslandHaptics.perform(.valueStep)
                }
            }
        case .trackSkip:
            trackSwipe.add(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let skip = event.phase.contains(.ended) ? trackSwipe.command : nil
            if let skip {
                coordinator.media.send(skip)
                IslandHaptics.perform(.trackSkipped)
            }
            if ended {
                // A skip lets go of the stretch with a bounce; a swipe that
                // fell short just settles.
                withAnimation(skip == nil ? IslandMotion.pullSettle : IslandMotion.skipRelease) {
                    coordinator.islandGesture.trackPull = 0
                }
            } else {
                coordinator.islandGesture.trackPull = trackSwipe.pull
            }
        case .pullOpen:
            if !ended {
                openPull.add(deltaX: event.scrollingDeltaX, downward: -Self.upwardDelta(event))
                coordinator.islandGesture.openPull = openPull.stretch
            } else {
                let target = event.phase.contains(.ended) && openPull.opens
                    ? pullOpenTarget(for: event, coordinator: coordinator)
                    : nil
                withAnimation(target == nil ? IslandMotion.pullSettle : IslandMotion.skipRelease) {
                    coordinator.islandGesture.openPull = 0
                }
                switch target {
                case .captureMenu:
                    coordinator.openCaptureMenuFromLongPress()
                case .islandPrimary:
                    coordinator.expandIslandPrimary()
                    coordinator.noteIslandOpenedByPointer()
                case nil:
                    break
                }
            }
        }
        if ended {
            compactGesture = nil
            swallowMomentum = true
        }
        return true
    }

    /// Scroll distance toward "more": fingers or wheel moving up, whatever
    /// the natural-scrolling setting.
    private static func upwardDelta(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
    }

    private func resetTracking() {
        guard let coordinator else { return }
        if coordinator.islandGesture.isTracking || coordinator.islandGesture.offset != 0 {
            coordinator.islandGesture.isTracking = false
            coordinator.islandGesture.offset = 0
        }
    }
}
