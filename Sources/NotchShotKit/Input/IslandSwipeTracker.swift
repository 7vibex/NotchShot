import CoreGraphics
import Foundation

/// Gesture math for switching between simultaneous activities with a
/// two-finger horizontal trackpad swipe.
///
/// Pure and clock-injected so thresholds, velocity, rubber-banding and
/// cancellation are unit-testable. The AppKit side (`IslandGestureCoordinator`)
/// only feeds it scroll deltas and phases.
///
/// Sign convention: `translation` follows the content. Moving the fingers left
/// (content left, negative) reveals the trailing satellite, exactly like
/// paging a scroll view.
public struct IslandSwipeTracker: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Travel that commits a switch on release regardless of velocity.
        public var commitDistance: CGFloat = 44
        /// A flick this fast commits with less travel…
        public var velocityThreshold: CGFloat = 360
        /// …but never a tiny accidental twitch.
        public var minimumFlickDistance: CGFloat = 12
        /// Movement ignored while deciding whether this is a horizontal swipe.
        public var deadZone: CGFloat = 5
        /// Horizontal must beat vertical by this ratio to claim the gesture.
        public var directionLockRatio: CGFloat = 1.25
        /// Visual travel for a direction with a neighbour.
        public var maximumTravel: CGFloat = 64
        /// Visual travel toward a boundary with no neighbour.
        public var rubberBandLimit: CGFloat = 14
        /// How far back velocity samples are considered.
        public var velocityWindow: TimeInterval = 0.1

        public init() {}
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Waiting to see whether the movement is horizontal.
        case undecided
        case tracking
        /// Vertical or otherwise not ours; ignored until the gesture ends.
        case rejected
    }

    public var configuration: Configuration
    public private(set) var phase: Phase = .idle
    public private(set) var translation: CGFloat = 0
    private var verticalTranslation: CGFloat = 0
    private var canNavigateLeading = false
    private var canNavigateTrailing = false
    private var samples: [Sample] = []

    private struct Sample: Sendable, Equatable {
        var time: TimeInterval
        var translation: CGFloat
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isActive: Bool { phase == .undecided || phase == .tracking }

    public mutating func begin(
        canNavigateLeading: Bool,
        canNavigateTrailing: Bool,
        at time: TimeInterval
    ) {
        phase = canNavigateLeading || canNavigateTrailing ? .undecided : .rejected
        translation = 0
        verticalTranslation = 0
        self.canNavigateLeading = canNavigateLeading
        self.canNavigateTrailing = canNavigateTrailing
        samples = [Sample(time: time, translation: 0)]
    }

    /// Feeds one scroll delta. Returns `true` while the swipe owns the gesture,
    /// so the caller knows whether to consume the event.
    @discardableResult
    public mutating func change(deltaX: CGFloat, deltaY: CGFloat, at time: TimeInterval) -> Bool {
        guard deltaX.isFinite, deltaY.isFinite else { return phase == .tracking }
        switch phase {
        case .idle, .rejected:
            return false
        case .undecided:
            translation += deltaX
            verticalTranslation += deltaY
            let horizontal = abs(translation)
            let vertical = abs(verticalTranslation)
            guard max(horizontal, vertical) >= configuration.deadZone else { return false }
            if horizontal >= vertical * configuration.directionLockRatio {
                phase = .tracking
                record(time)
                return true
            }
            phase = .rejected
            return false
        case .tracking:
            translation += deltaX
            record(time)
            return true
        }
    }

    /// Where the content should sit right now, following the fingers.
    public func visualOffset(reduceMotion: Bool) -> CGFloat {
        guard phase == .tracking, !reduceMotion else { return 0 }
        let magnitude = abs(translation)
        let sign: CGFloat = translation < 0 ? -1 : 1
        let hasNeighbour = translation < 0 ? canNavigateTrailing : canNavigateLeading
        let limit = hasNeighbour ? configuration.maximumTravel : configuration.rubberBandLimit
        // Asymptotic: follows 1:1-ish at first, then resists and never exceeds
        // the limit. Toward a boundary the limit is small, which reads as a
        // rubber band rather than as a blocked gesture.
        let eased = limit * (1 - 1 / (magnitude / limit + 1))
        return sign * eased
    }

    /// Recent velocity in points per second, following content sign.
    public var velocity: CGFloat {
        guard let last = samples.last,
              let first = samples.first(where: { last.time - $0.time <= configuration.velocityWindow }),
              last.time > first.time else { return 0 }
        return (last.translation - first.translation) / CGFloat(last.time - first.time)
    }

    /// Ends the gesture and returns the direction to navigate, if any.
    public mutating func end(at time: TimeInterval) -> IslandNavigationDirection? {
        defer { reset() }
        guard phase == .tracking else { return nil }
        let travel = translation
        let speed = velocity
        let distance = abs(travel)

        let travelDirection: IslandNavigationDirection? = travel < 0 ? .trailing : (travel > 0 ? .leading : nil)
        guard let travelDirection else { return nil }

        // A flick back toward the start cancels even after a long drag.
        let velocityOpposesTravel = speed != 0 && (speed < 0) != (travel < 0)
            && abs(speed) >= configuration.velocityThreshold
        if velocityOpposesTravel { return nil }

        let committedByDistance = distance >= configuration.commitDistance
        let committedByFlick = abs(speed) >= configuration.velocityThreshold
            && distance >= configuration.minimumFlickDistance
        guard committedByDistance || committedByFlick else { return nil }

        switch travelDirection {
        case .trailing: return canNavigateTrailing ? .trailing : nil
        case .leading: return canNavigateLeading ? .leading : nil
        }
    }

    /// The system cancelled the gesture (e.g. another gesture took over).
    public mutating func cancel() {
        reset()
    }

    private mutating func record(_ time: TimeInterval) {
        samples.append(Sample(time: time, translation: translation))
        let horizon = time - max(configuration.velocityWindow * 2, 0.2)
        samples.removeAll { $0.time < horizon }
    }

    private mutating func reset() {
        phase = .idle
        translation = 0
        verticalTranslation = 0
        samples.removeAll()
    }
}
