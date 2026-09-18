import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Island swipe tracker")
struct IslandSwipeTrackerTests {
    private func tracker(leading: Bool = true, trailing: Bool = true) -> IslandSwipeTracker {
        var tracker = IslandSwipeTracker()
        tracker.begin(canNavigateLeading: leading, canNavigateTrailing: trailing, at: 0)
        return tracker
    }

    /// Feeds evenly spaced horizontal deltas at 120 Hz.
    private func drag(_ tracker: inout IslandSwipeTracker, total: CGFloat, steps: Int, startTime: TimeInterval = 0) -> TimeInterval {
        var time = startTime
        for _ in 0 ..< steps {
            time += 1.0 / 120
            tracker.change(deltaX: total / CGFloat(steps), deltaY: 0, at: time)
        }
        return time
    }

    @Test("Tiny accidental movement never switches")
    func tinyMovementIgnored() {
        var t = tracker()
        let end = drag(&t, total: -4, steps: 4)
        let value1 = t.end(at: end + 0.2)
        #expect((value1 == nil))
    }

    @Test("Slow travel past the commit distance switches toward the revealed side")
    func distanceCommits() {
        var t = tracker()
        // Slow: 60 pt over half a second.
        var time: TimeInterval = 0
        for _ in 0 ..< 60 {
            time += 0.5 / 60
            t.change(deltaX: -1, deltaY: 0, at: time)
        }
        // Pause so velocity decays to zero before lifting.
        t.change(deltaX: 0, deltaY: 0, at: time + 0.15)
        let value2 = t.end(at: time + 0.16)
        #expect((value2 == .trailing))
    }

    @Test("A short fast flick commits through velocity")
    func velocityCommits() {
        var t = tracker()
        let end = drag(&t, total: 24, steps: 4)
        #expect(t.velocity > 360)
        let value3 = t.end(at: end)
        #expect((value3 == .leading))
    }

    @Test("Travel under the threshold without speed springs back")
    func underThresholdCancels() {
        var t = tracker()
        var time: TimeInterval = 0
        for _ in 0 ..< 30 {
            time += 0.02
            t.change(deltaX: -1, deltaY: 0, at: time)
        }
        let value4 = t.end(at: time)
        #expect((value4 == nil))
    }

    @Test("A flick back toward the start cancels a long drag")
    func reverseFlickCancels() {
        var t = tracker()
        var time = drag(&t, total: -80, steps: 40)
        time += 0.2
        t.change(deltaX: 0, deltaY: 0, at: time)
        for _ in 0 ..< 4 {
            time += 1.0 / 120
            t.change(deltaX: 8, deltaY: 0, at: time)
        }
        let value5 = t.end(at: time)
        #expect((value5 == nil))
    }

    @Test("No neighbour on a side: no switch, and the offset rubber-bands within a small bound")
    func boundaryClamping() {
        var t = tracker(leading: true, trailing: false)
        let end = drag(&t, total: -400, steps: 40)
        let offset = t.visualOffset(reduceMotion: false)
        #expect(offset < 0)
        #expect(abs(offset) < IslandSwipeTracker.Configuration().rubberBandLimit)
        let value6 = t.end(at: end)
        #expect((value6 == nil))
    }

    @Test("Toward a neighbour the offset follows but never exceeds the travel limit")
    func travelLimit() {
        var t = tracker()
        _ = drag(&t, total: 1_000, steps: 50)
        let offset = t.visualOffset(reduceMotion: false)
        #expect(offset > 30)
        #expect(offset < IslandSwipeTracker.Configuration().maximumTravel)
    }

    @Test("Vertical scrolling is rejected so it reaches the content underneath")
    func verticalRejected() {
        var t = tracker()
        let consumed = t.change(deltaX: 1, deltaY: 12, at: 0.01)
        #expect(!consumed)
        #expect(t.phase == .rejected)
        let value7 = t.end(at: 0.2)
        #expect((value7 == nil))
    }

    @Test("A system cancellation resets without switching")
    func cancellation() {
        var t = tracker()
        _ = drag(&t, total: -90, steps: 10)
        t.cancel()
        #expect(t.phase == .idle)
        #expect(t.visualOffset(reduceMotion: false) == 0)
        let value8 = t.end(at: 1)
        #expect((value8 == nil))
    }

    @Test("Reduce Motion removes visual travel but keeps the switch")
    func reduceMotion() {
        var t = tracker()
        let end = drag(&t, total: -90, steps: 10)
        #expect(t.visualOffset(reduceMotion: true) == 0)
        let value9 = t.end(at: end)
        #expect((value9 == .trailing))
    }

    @Test("A gesture with nowhere to go is rejected up front")
    func nothingToNavigate() {
        var t = IslandSwipeTracker()
        t.begin(canNavigateLeading: false, canNavigateTrailing: false, at: 0)
        #expect(t.phase == .rejected)
        let value10 = t.change(deltaX: -50, deltaY: 0, at: 0.1)
        #expect(!(value10))
    }
}

@Suite("Island transient bursts")
struct IslandTransientQueueTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func event(_ key: String, severity: IslandEventSeverity = .informational, at time: Date = t0) -> IslandTransientEvent {
        IslandTransientEvent(kind: .activityCompleted, severity: severity, coalescingKey: key, symbolName: "checkmark", title: key, createdAt: time)
    }

    @Test("An event appears, holds, and dismisses on expiry")
    func appearsAndExpires() {
        var queue = IslandTransientQueue()
        let value11 = queue.enqueue(event("a"))
        #expect((value11))
        #expect(queue.current?.coalescingKey == "a")
        let value12 = queue.expire(now: Self.t0.addingTimeInterval(1))
        #expect(!(value12))
        let value13 = queue.expire(now: Self.t0.addingTimeInterval(10))
        #expect((value13))
        #expect(queue.current == nil)
    }

    @Test("Repeated events coalesce in place and restart their hold")
    func coalesces() {
        var queue = IslandTransientQueue()
        queue.enqueue(event("focus"))
        let later = event("focus", at: Self.t0.addingTimeInterval(2))
        let value14 = queue.enqueue(later)
        #expect((value14))
        #expect(queue.pending.isEmpty)
        #expect(queue.current?.createdAt == later.createdAt)
    }

    @Test("A pending event coalesces instead of queueing twice")
    func pendingCoalesces() {
        var queue = IslandTransientQueue()
        queue.enqueue(event("a"))
        queue.enqueue(event("b"))
        queue.enqueue(event("b"))
        #expect(queue.pending.count == 1)
    }

    @Test("Pending events start their hold when they become current")
    func pendingStartsLater() {
        var queue = IslandTransientQueue()
        queue.enqueue(event("a"))
        queue.enqueue(event("b"))
        let now = Self.t0.addingTimeInterval(5)
        queue.expire(now: now)
        #expect(queue.current?.coalescingKey == "b")
        #expect(queue.current?.createdAt == now)
    }

    @Test("The queue is bounded and drops informational events before errors")
    func bounded() {
        var queue = IslandTransientQueue()
        queue.enqueue(event("current"))
        queue.enqueue(event("error", severity: .error))
        for index in 0 ..< 10 { queue.enqueue(event("info-\(index)")) }
        #expect(queue.pending.count == IslandTransientQueue.maximumPending)
        #expect(queue.pending.contains { $0.coalescingKey == "error" })
    }

    @Test("Hold durations are bounded and errors hold longer")
    func holdDurations() {
        #expect(IslandTransientEvent(kind: .focus, symbolName: "x", title: "x", holdDuration: 999).holdDuration == 8)
        #expect(IslandTransientEvent(kind: .focus, symbolName: "x", title: "x", holdDuration: 0).holdDuration == 0.8)
        let error = IslandTransientEvent(kind: .activityFailed, severity: .error, symbolName: "x", title: "x")
        let info = IslandTransientEvent(kind: .focus, symbolName: "x", title: "x")
        #expect(error.holdDuration > info.holdDuration)
        #expect(!IslandEventSeverity.error.allowsPlayfulMotion)
        #expect(IslandEventSeverity.success.allowsPlayfulMotion)
    }

    @Test("Titles and details are bounded")
    func boundedText() {
        let event = IslandTransientEvent(
            kind: .focus,
            symbolName: "x",
            title: String(repeating: "t", count: 500),
            detail: String(repeating: "d", count: 500)
        )
        #expect(event.title.count == IslandTransientQueue.maximumTitleLength)
        #expect(event.detail?.count == IslandTransientQueue.maximumDetailLength)
    }

    @Test("Focus bursts fire only on real transitions between known states")
    func focusTransitions() {
        #expect(FocusTransitionPolicy.transition(previous: nil, current: true) == nil)
        #expect(FocusTransitionPolicy.transition(previous: false, current: nil) == nil)
        #expect(FocusTransitionPolicy.transition(previous: true, current: true) == nil)
        #expect(FocusTransitionPolicy.transition(previous: false, current: true) == true)
        #expect(FocusTransitionPolicy.transition(previous: true, current: false) == false)
    }
}
