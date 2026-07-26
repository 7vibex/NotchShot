import AppKit
import Foundation

/// Hides macOS's own volume and brightness overlay so only the notch shows it.
///
/// The system overlay is drawn by `OSDUIHelper`, a launch-on-demand agent. There
/// is no API or preference for turning it off, so it is paused with `SIGSTOP`:
/// a stopped process cannot draw, and `SIGCONT` restores it exactly as it was.
/// Nothing is patched, deleted, or reconfigured, and the helper is relaunched by
/// launchd on demand regardless of what happens to this app.
///
/// The agent is launched deliberately and paused before anything asks it to
/// draw. Pausing one that is mid-animation would leave that frame on screen.
///
/// Because a paused process stays paused, `resume()` must run before the app
/// goes away — `start()` therefore resumes any helper a previous crash left
/// stopped, so the worst case self-heals on the next launch rather than needing
/// a restart.
@MainActor
public final class SystemOSDSuppressor {
    public static let shared = SystemOSDSuppressor()

    nonisolated private static let bundleIdentifier = "com.apple.OSDUIHelper"
    private static let bundleURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/OSDUIHelper.app"
    )

    private var isEnabled = false
    private var observers: [NSObjectProtocol] = []
    private var pausedProcessIDs: Set<pid_t> = []
    private var launchTask: Task<Void, Never>?

    public init() {}

    /// Whether the system overlay is currently being held back.
    public var isSuppressing: Bool { isEnabled && !pausedProcessIDs.isEmpty }

    // MARK: Lifecycle

    /// Applies the stored preference, first undoing anything left behind by a
    /// crash so a stale paused helper can never outlive the app that paused it.
    public func start() {
        resumeAll()
        setEnabled(Preferences.shared.suppressesSystemOSD)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            installLaunchObserver()
            pauseHelper()
        } else {
            removeLaunchObserver()
            launchTask?.cancel()
            launchTask = nil
            resumeAll()
        }
    }

    /// Restores the system overlay. Safe to call more than once.
    public func stop() {
        removeLaunchObserver()
        launchTask?.cancel()
        launchTask = nil
        isEnabled = false
        resumeAll()
    }

    // MARK: Pausing

    private func pauseHelper() {
        let running = runningHelpers()
        if running.isEmpty {
            launchThenPause()
            return
        }
        for application in running {
            pause(application.processIdentifier)
        }
    }

    /// Starts the agent hidden so it can be paused before the system ever asks
    /// it to draw an overlay.
    private func launchThenPause() {
        guard launchTask == nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true

        launchTask = Task { [weak self] in
            defer { Task { @MainActor in self?.launchTask = nil } }
            do {
                let application = try await NSWorkspace.shared.openApplication(
                    at: Self.bundleURL,
                    configuration: configuration
                )
                guard let self, self.isEnabled else { return }
                self.pause(application.processIdentifier)
            } catch {
                Log.app.notice(
                    "Could not start the system overlay helper to pause it: \(error.localizedDescription)"
                )
            }
        }
    }

    private func pause(_ processID: pid_t) {
        guard processID > 0, !pausedProcessIDs.contains(processID) else { return }
        guard kill(processID, SIGSTOP) == 0 else {
            Log.app.notice("Could not pause the system overlay (errno \(errno))")
            return
        }
        pausedProcessIDs.insert(processID)
    }

    private func resumeAll() {
        // Anything this app paused, plus any live helper — after a crash the
        // stopped process is not in `pausedProcessIDs` any more.
        for processID in pausedProcessIDs.union(runningHelpers().map(\.processIdentifier)) {
            _ = kill(processID, SIGCONT)
        }
        pausedProcessIDs.removeAll()
    }

    private func runningHelpers() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
    }

    // MARK: Relaunch

    /// launchd starts a fresh helper whenever something needs an overlay, so a
    /// new one has to be paused as it appears. A helper that goes away has to be
    /// forgotten just as promptly: the kernel reuses process IDs, and a stale
    /// entry would eventually send `SIGCONT` to an unrelated process.
    private func installLaunchObserver() {
        guard observers.isEmpty else { return }
        observers.append(observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] processID in
            guard let self, self.isEnabled else { return }
            self.pause(processID)
        })
        observers.append(observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] processID in
            self?.pausedProcessIDs.remove(processID)
        })
    }

    /// Reduces a workspace notification to the helper's process ID, which is the
    /// only part of it that may cross into the main actor.
    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (pid_t) -> Void
    ) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            // Reduced to plain values here: the notification and the running
            // application it carries cannot cross into the isolated block.
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
                application.bundleIdentifier == Self.bundleIdentifier
            else { return }
            let processID = application.processIdentifier
            MainActor.assumeIsolated { handler(processID) }
        }
    }

    private func removeLaunchObserver() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
