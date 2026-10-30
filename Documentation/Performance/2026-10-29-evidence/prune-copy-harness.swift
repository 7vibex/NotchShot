import Foundation
import Testing
@testable import NotchShotKit

/// Temporary: prunes a copy of a real AI Activity folder and checks the poll
/// reads the same from it as from an untouched copy. Never the live folder.
@Suite("ZZ prune harness")
struct ZZPruneHarness {
    @MainActor @Test func pruneCopy() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AIPRUNE_HARNESS"] == "1", let full = env["AIPRUNE_FULL"], let pruned = env["AIPRUNE_PRUNED"],
              !pruned.contains("Application Support") else { return }
        let fullURL = URL(fileURLWithPath: full, isDirectory: true)
        let prunedURL = URL(fileURLWithPath: pruned, isDirectory: true)
        func monitor(_ url: URL) -> AIActivityMonitor {
            AIActivityMonitor(directory: url, historyURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zz-\(UUID().uuidString).json"), ownsURL: { _ in true })
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: pruned).count
        let start = ContinuousClock.now
        let removed = AIActivityMonitor.pruneStatusFiles(in: prunedURL, owns: { _ in true })
        let elapsed = ContinuousClock.now - start
        let after = try FileManager.default.contentsOfDirectory(atPath: pruned).count
        let second = AIActivityMonitor.pruneStatusFiles(in: prunedURL, owns: { _ in true })
        let a = monitor(fullURL).loadActivities()
        let b = monitor(prunedURL).loadActivities()
        var lines = ["entries \(before) -> \(after), removed \(removed) in \(elapsed); second pass removed \(second)",
                     "activities full \(a.count), pruned \(b.count), identical \(a == b)"]
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: pruned))
        lines.append("left: json \(names.filter { $0.hasSuffix(".json") }.count), tmp \(names.filter { $0.hasSuffix(".tmp") }.count), other \(names.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".tmp") }.sorted())")
        try lines.joined(separator: "\n").write(toFile: env["AIPRUNE_OUT"] ?? "/dev/stdout", atomically: true, encoding: .utf8)
        #expect(a == b)
    }
}
