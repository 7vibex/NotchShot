import CoreFoundation
import Foundation

/// Writes one log line for every main run-loop pass long enough to feel like a
/// freeze, so a hitch can be looked up afterwards instead of being reproduced.
///
/// It costs two clock reads per pass and adds no timer or wake-up, which is why
/// it can stay on all the time. It measures from the moment the run loop wakes
/// to the moment it goes back to sleep, after the Core Animation commit, so
/// event handling, timers, main-queue work, SwiftUI updates and the commit all
/// count. The clock excludes system sleep, and a nested run loop such as a modal
/// alert restarts the measurement, so waiting on the user reads as idle.
///
/// To read the results:
/// `/usr/bin/log show --last 1d --predicate 'subsystem == "com.notchshot.app" AND eventMessage BEGINSWITH "Main thread busy"'`
public final class MainThreadStallLogger: @unchecked Sendable {
    public static let shared = MainThreadStallLogger()

    /// Well past one frame and short enough to catch what a user calls "a bit".
    static let thresholdNanoseconds: UInt64 = 100_000_000

    // Read and written on the main thread only, from the observer below.
    private var busySince: UInt64 = 0
    private var observer: CFRunLoopObserver?

    private init() {}

    /// Starts logging. Call this first during launch, on the main thread: the
    /// first line it writes then also reports how long launch held the thread.
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard observer == nil else { return }
        busySince = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        // The largest order runs after Core Animation's commit observer, so the
        // commit is inside the measured pass.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, CFIndex.max
        ) { [unowned self] _, activity in
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if activity == .afterWaiting {
                busySince = now
                return
            }
            let busy = now &- busySince
            guard busy >= Self.thresholdNanoseconds else { return }
            let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
                .map { $0.rawValue as String } ?? "unknown"
            Log.app.notice(
                "Main thread busy \(busy / 1_000_000, privacy: .public) ms (mode \(mode, privacy: .public))"
            )
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
