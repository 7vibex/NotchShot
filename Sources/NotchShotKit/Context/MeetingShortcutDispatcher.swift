import AppKit
import CoreGraphics
import Foundation

/// Serializes the focus handoff for call shortcuts. Keyboard events are sent
/// to the selected PID, so a focus race cannot deliver them to another app.
@MainActor
final class MeetingShortcutDispatcher {
    struct Hooks {
        var frontmostPID: () -> pid_t?
        var isRunning: (pid_t) -> Bool
        var activate: (pid_t) -> Bool
        var post: (MeetingControls.KeyCombo, pid_t) -> Bool
        var pause: (Duration) async throws -> Void
        var now: () -> TimeInterval

        static var live: Hooks {
            Hooks(
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                isRunning: { NSRunningApplication(processIdentifier: $0)?.isTerminated == false },
                activate: { NSRunningApplication(processIdentifier: $0)?.activate() ?? false },
                post: { combo, pid in
                    let source = CGEventSource(stateID: .hidSystemState)
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) else {
                        return false
                    }
                    down.flags = combo.flags
                    up.flags = combo.flags
                    down.postToPid(pid)
                    up.postToPid(pid)
                    return true
                },
                pause: { try await Task.sleep(for: $0) },
                now: { ProcessInfo.processInfo.systemUptime }
            )
        }
    }

    static let shared = MeetingShortcutDispatcher(hooks: .live)
    private let hooks: Hooks
    private var tail: Task<Bool, Never>?
    private var tailID: UUID?

    init(hooks: Hooks) { self.hooks = hooks }

    func send(_ combo: MeetingControls.KeyCombo, to pid: pid_t) async -> Bool {
        let previousRequest = tail
        let id = UUID()
        let request = Task { @MainActor [hooks] in
            _ = await previousRequest?.value
            return await Self.deliver(combo, to: pid, hooks: hooks)
        }
        tail = request
        tailID = id
        defer {
            if tailID == id { tail = nil; tailID = nil }
        }
        return await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private static func deliver(_ combo: MeetingControls.KeyCombo, to pid: pid_t, hooks: Hooks) async -> Bool {
        guard !Task.isCancelled, hooks.isRunning(pid) else { return false }
        let previous = hooks.frontmostPID()
        // Activation may complete just as a wait is canceled, and event
        // creation can fail after activation. Release focus on every exit.
        defer {
            if let previous, previous != pid,
               hooks.frontmostPID() == pid, hooks.isRunning(previous) {
                _ = hooks.activate(previous)
            }
        }
        if previous != pid {
            guard hooks.activate(pid) else { return false }
            let deadline = hooks.now() + 1
            while hooks.frontmostPID() != pid {
                guard !Task.isCancelled, hooks.isRunning(pid), hooks.now() < deadline else { return false }
                do { try await hooks.pause(.milliseconds(20)) }
                catch { return false }
            }
        }
        guard !Task.isCancelled, hooks.isRunning(pid), hooks.frontmostPID() == pid,
              hooks.post(combo, pid) else { return false }

        // Once both events were posted, cancellation must not report that a
        // toggle never happened. Restore only if the user has kept this focus.
        if let previous, previous != pid {
            try? await hooks.pause(.milliseconds(120))
        }
        return true
    }
}
