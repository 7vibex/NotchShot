import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

/// A release must act on movement near the release, not on samples that were
/// already above the flick threshold before a long stationary hold.
@Suite("Island swipe release velocity")
struct IslandSwipeReleaseVelocityTests {
    private func tracker(leading: Bool = true, trailing: Bool = true) -> IslandSwipeTracker {
        var tracker = IslandSwipeTracker()
        tracker.begin(canNavigateLeading: leading, canNavigateTrailing: trailing, at: 0)
        return tracker
    }

    /// Feeds evenly spaced horizontal deltas at 120 Hz.
    private func drag(
        _ tracker: inout IslandSwipeTracker,
        total: CGFloat,
        steps: Int,
        startTime: TimeInterval = 0
    ) -> TimeInterval {
        var time = startTime
        for _ in 0 ..< steps {
            time += 1.0 / 120
            tracker.change(deltaX: total / CGFloat(steps), deltaY: 0, at: time)
        }
        return time
    }

    @Test("A fast 24-point flick released immediately commits")
    func fastFlickCommits() {
        var t = tracker()
        let release = drag(&t, total: -24, steps: 4)
        #expect(abs(t.velocity(at: release)) >= IslandSwipeTracker.Configuration().velocityThreshold)
        #expect(t.end(at: release) == .trailing)
    }

    @Test("The same flick held stationary for a second no longer commits")
    func stationaryHoldDecaysVelocity() {
        var t = tracker()
        let release = drag(&t, total: -24, steps: 4) + 1.0
        #expect(t.velocity(at: release) == 0)
        #expect(t.end(at: release) == nil)
    }

    @Test("A 60-point slow drag still commits by distance after a pause")
    func slowDragCommitsByDistance() {
        var t = tracker()
        var time: TimeInterval = 0
        for _ in 0 ..< 60 {
            time += 0.5 / 60
            t.change(deltaX: -1, deltaY: 0, at: time)
        }
        let release = time + 1.0
        #expect(t.velocity(at: release) == 0)
        #expect(t.end(at: release) == .trailing)
    }

    @Test("A reverse flick still cancels a long drag")
    func reverseFlickStillCancels() {
        var t = tracker()
        var time = drag(&t, total: -80, steps: 40)
        time += 0.2
        t.change(deltaX: 0, deltaY: 0, at: time)
        for _ in 0 ..< 4 {
            time += 1.0 / 120
            t.change(deltaX: 8, deltaY: 0, at: time)
        }
        #expect(t.end(at: time) == nil)
    }

    @Test("A distance commit needs no trailing zero-delta event")
    func distanceCommitNeedsNoZeroDelta() {
        var t = tracker()
        let release = drag(&t, total: -90, steps: 10)
        #expect(t.end(at: release) == .trailing)
    }
}
