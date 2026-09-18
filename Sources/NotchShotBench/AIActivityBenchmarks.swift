import Foundation
import NotchShotKit

/// Measurement coverage for the AI activity directory reader: how much work a
/// one-second refresh does when nothing changed, when one file changed, and
/// when files are deleted or replaced. Decode counts come from the monitor's
/// own tally; the paired baseline re-reads and re-decodes every file.
@MainActor
enum AIActivityBenchmarks {
    static func run(enabled: (String) -> Bool) {
        guard enabled("ai.activity") else { return }

        let directory = Fixtures.runDirectory.appendingPathComponent("ai-activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = AIActivityMonitor(
            directory: directory,
            historyURL: directory.appendingPathComponent("history.json"),
            ownsURL: { _ in true }
        )

        func write(_ id: String, title: String, index: Int) {
            let snapshot = AIActivitySnapshot(
                id: id,
                source: .codex,
                state: .working,
                title: title,
                updatedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(snapshot).write(
                to: directory.appendingPathComponent("session-\(index).json"),
                options: .atomic
            )
        }

        // Correctness oracle for every scenario: the cached path and the
        // re-read baseline must agree on the complete result.
        func requireAgreement(_ label: String) {
            let cached = monitor.loadActivities().sorted { $0.id < $1.id }
            let baseline = Baselines.aiActivityLoadBefore(directory: directory).sorted { $0.id < $1.id }
            precondition(
                cached.map(\.id) == baseline.map(\.id)
                    && cached.map(\.title) == baseline.map(\.title),
                "AI activity cache disagrees with the re-read baseline: \(label)"
            )
        }

        // Empty directory.
        requireAgreement("empty")
        Benchmark.measure("ai.activity refresh empty", iterations: 50, warmup: 5) {
            Benchmark.blackHole(monitor.loadActivities())
        }

        // 1–3 files, then 32 files, unchanged across refreshes.
        for count in [1, 3, 32] {
            for index in 0 ..< count {
                write("session-\(index)", title: "Session \(index)", index: index)
            }
            requireAgreement("populated-\(count)")
            precondition(
                monitor.lastLoadStatistics.filesDecoded == count,
                "the first pass should decode every file"
            )
            Benchmark.measure("ai.activity refresh \(count) unchanged [cached]", iterations: 50, warmup: 5) {
                Benchmark.blackHole(monitor.loadActivities())
            }
            precondition(
                monitor.lastLoadStatistics.filesDecoded == 0
                    && monitor.lastLoadStatistics.filesReused == count,
                "unchanged files were re-decoded"
            )
            Benchmark.measure("ai.activity refresh \(count) unchanged [reread]", iterations: 50, warmup: 5) {
                Benchmark.blackHole(Baselines.aiActivityLoadBefore(directory: directory))
            }
            for index in 0 ..< count {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("session-\(index).json"))
            }
        }

        // One changed file per refresh.
        for count in [3, 32] {
            for index in 0 ..< count {
                write("session-\(index)", title: "Session \(index)", index: index)
            }
            _ = monitor.loadActivities()
            var revision = 0
            Benchmark.measure(
                "ai.activity refresh \(count) one-changed [cached]",
                iterations: 50,
                warmup: 5,
                setUp: {
                    revision += 1
                    write("session-0", title: "Revision \(revision)", index: 0)
                }
            ) {
                Benchmark.blackHole(monitor.loadActivities())
            }
            precondition(
                monitor.lastLoadStatistics.filesDecoded == 1
                    && monitor.lastLoadStatistics.filesReused == count - 1,
                "a single changed file should decode alone"
            )
            for index in 0 ..< count {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("session-\(index).json"))
            }
        }

        // Deleted and replaced files must not serve stale values.
        write("deleted", title: "Deleted soon", index: 0)
        write("replaced", title: "Original", index: 1)
        write("stable", title: "Stable", index: 2)
        _ = monitor.loadActivities()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("session-0.json"))
        var replacement = 0
        Benchmark.measure(
            "ai.activity refresh deleted+replaced",
            iterations: 50,
            warmup: 5,
            setUp: {
                replacement += 1
                write("replaced", title: "Replacement \(replacement)", index: 1)
            }
        ) {
            Benchmark.blackHole(monitor.loadActivities())
        }
        requireAgreement("deleted+replaced")
        precondition(
            monitor.loadActivities().contains { $0.id == "replaced" },
            "the replaced file must still be visible"
        )
        precondition(
            !monitor.loadActivities().contains { $0.id == "deleted" },
            "the deleted file must not linger"
        )

        try? FileManager.default.removeItem(at: directory)
    }
}
