import Foundation

/// File work that quit has to wait for.
///
/// A copy, a move or a join off the main actor can be overtaken by quit, where
/// on main it could not be. Quit would then lose the rest of the copy, and a file
/// that has landed before its History row looks untracked to the sweep at quit.
/// Waiting never blocks the main thread: `.terminateLater` keeps it running.
@MainActor
final class FileWorkTracker {
    static let shared = FileWorkTracker()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isIdle: Bool { tasks.isEmpty }

    /// Runs `work` on the main actor as an unstructured task, so a window going
    /// away or a caller being cancelled does not cut it short.
    func run(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        // Nothing here can run before the entry is in place: the task starts
        // only once this synchronous turn on the main actor has ended.
        tasks[id] = Task { @MainActor [weak self] in
            await work()
            self?.tasks[id] = nil
        }
    }

    /// Returns once nothing is left, including anything started meanwhile.
    func waitUntilIdle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }
}
