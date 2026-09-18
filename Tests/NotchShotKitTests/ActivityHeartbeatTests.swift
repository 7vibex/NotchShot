import Foundation
import NotchShotAIReporterSupport
import Testing
@testable import NotchShotKit

/// `notchshot-cli activity run` must keep a long job visible without changing
/// the command it wraps or the server's own staleness and lifetime rules.
@Suite("Activity heartbeat")
struct ActivityHeartbeatTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("Heartbeats fire while the wrapped command runs and stop when it exits")
    func heartbeatsStopWithChild() async throws {
        let heartbeat = ActivityHeartbeat(interval: 0.05)
        let counter = Counter()
        heartbeat.start { counter.increment() }
        try await Task.sleep(for: .milliseconds(220))
        #expect(counter.count >= 2, "a long-running child keeps reporting")
        #expect(heartbeat.isRunning)

        heartbeat.stop()
        let afterStop = counter.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == afterStop, "no heartbeat survives the child")
        #expect(!heartbeat.isRunning)
    }

    @Test("The default interval is safely inside the stale window")
    func defaultIntervalIsSafe() {
        #expect(ActivityHeartbeat.defaultInterval > 0)
        #expect(ActivityHeartbeat.defaultInterval < (15 * 60) / 2)
    }

    @Test("Heartbeats keep a job past the stale interval without inventing progress")
    func heartbeatsPreserveProgress() {
        var registry = ExternalActivityRegistry()
        let start = Date(timeIntervalSince1970: 9_000_000)
        registry.apply(
            LiveActivityUpdate(command: .start, id: "build", title: "Build", progress: 0.4),
            now: start
        )

        var now = start
        for _ in 0 ..< 6 {
            now = now.addingTimeInterval(ActivityHeartbeat.defaultInterval)
            registry.apply(
                LiveActivityUpdate(command: .update, id: "build", title: nil),
                now: now
            )
            let expired = registry.expire(now: now)
            #expect(!expired, "heartbeat keeps the job live")
        }
        // 24 minutes of heartbeats, well past the 15-minute stale interval.
        #expect(now.timeIntervalSince(start) > registry.limits.staleInterval)
        #expect(registry.live.first?.id == "build")
        #expect(registry.live.first?.progress == 0.4, "no progress was measured, so none changed")
    }

    @Test("Heartbeats never extend the absolute lifetime")
    func heartbeatsDoNotExtendLifetime() {
        var registry = ExternalActivityRegistry()
        let start = Date(timeIntervalSince1970: 9_000_000)
        registry.apply(
            LiveActivityUpdate(command: .start, id: "build", title: "Build"),
            now: start
        )

        var now = start
        while now < start.addingTimeInterval(registry.limits.maximumLifetime + ActivityHeartbeat.defaultInterval) {
            now = now.addingTimeInterval(ActivityHeartbeat.defaultInterval)
            registry.apply(
                LiveActivityUpdate(command: .update, id: "build", title: nil),
                now: now
            )
        }
        registry.expire(now: now)
        #expect(registry.live.isEmpty, "the hard ceiling outranks every heartbeat")
    }
}
