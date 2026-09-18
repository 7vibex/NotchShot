import Foundation

/// Liveness reporting for `notchshot-cli activity run`.
///
/// The app drops an activity that has not been updated for its stale interval
/// (15 minutes), which would make a long build or export disappear from the
/// island while it is still running. The wrapped command belongs to the user:
/// this type only fires a best-effort callback on its own queue while the
/// child is alive, stops as soon as it is asked to, and never observes or
/// changes the command's exit status.
public final class ActivityHeartbeat: @unchecked Sendable {
    /// Comfortably inside the app's 15-minute stale interval, and infrequent
    /// enough that a long job costs a handful of tiny socket writes.
    public static let defaultInterval: TimeInterval = 4 * 60

    public let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.notchshot.cli.activity-heartbeat")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var fired = 0
    private var stopped = true

    public init(interval: TimeInterval = ActivityHeartbeat.defaultInterval) {
        self.interval = max(0.01, interval)
    }

    /// Number of times the handler has run. Test seam.
    public var fireCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    /// Starts firing `handler` once per interval until `stop()`.
    public func start(_ handler: @escaping @Sendable () -> Void) {
        stop()
        lock.lock()
        stopped = false
        lock.unlock()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            // Scaled, not fixed: a one-second leeway is invisible at the
            // production interval and dominates a test-sized one.
            leeway: .milliseconds(Int((interval * 100).rounded()))
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped else {
                self.lock.unlock()
                return
            }
            self.fired += 1
            self.lock.unlock()
            handler()
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    /// Stops firing and returns only after an in-flight handler has finished,
    /// so a heartbeat can never race the terminal report that follows it.
    /// Must not be called from the handler itself.
    public func stop() {
        lock.lock()
        stopped = true
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
        queue.sync {}
    }
}
