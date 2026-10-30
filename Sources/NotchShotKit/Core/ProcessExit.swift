import Foundation

extension Process {
    /// Waits for the process to end without `waitUntilExit()`.
    ///
    /// With no termination handler set, `waitUntilExit()` on the thread that
    /// launched the process waits for a block Foundation queues on that
    /// thread's run loop. On a dispatch or Swift concurrency worker that block
    /// sometimes never runs: in a probe on macOS 26, 13 of 568 such waits
    /// never returned, with `isRunning` already false. Foundation's exit
    /// handler clears `isRunning` itself, so polling it cannot miss the exit.
    func waitForExit() async {
        while isRunning {
            // Cancellation can't end the wait, because the caller reads the
            // exit status next; it only stops the sleep from yielding.
            if (try? await Task.sleep(for: .milliseconds(5))) == nil { usleep(5_000) }
        }
    }

    /// The same for a synchronous caller, which is already holding a thread.
    func blockUntilExit() {
        while isRunning { usleep(5_000) }
    }
}
