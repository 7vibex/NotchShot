import Foundation
import Testing
@testable import NotchShotKit

/// `AIActivityMonitor` polls once a second. An unchanged directory must reuse
/// already-decoded activity values instead of re-reading and re-decoding every
/// file, while changed, replaced, deleted, or swapped files must never serve a
/// stale answer.
@Suite("AI activity refresh caching")
@MainActor
struct AIActivityRefreshCachingTests {
    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotchShotAICache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func monitor(in directory: URL) -> AIActivityMonitor {
        AIActivityMonitor(
            directory: directory,
            historyURL: directory.appendingPathComponent("history.json"),
            ownsURL: { _ in true }
        )
    }

    private func snapshot(_ id: String, title: String) -> AIActivitySnapshot {
        AIActivitySnapshot(id: id, source: .codex, state: .working, title: title, updatedAt: Date())
    }

    private func write(_ snapshot: AIActivitySnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    @Test("Unchanged files are decoded once and then reused")
    func unchangedFilesAreReused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        for index in 0 ..< 3 {
            try write(snapshot("s\(index)", title: "Session \(index)"), to: directory.appendingPathComponent("s\(index).json"))
        }

        let first = monitor.loadActivities()
        #expect(first.count == 3)
        #expect(monitor.lastLoadStatistics.filesDecoded == 3)
        #expect(monitor.lastLoadStatistics.filesReused == 0)

        let second = monitor.loadActivities()
        #expect(second.map(\.id).sorted() == first.map(\.id).sorted())
        #expect(monitor.lastLoadStatistics.filesDecoded == 0, "unchanged files were re-read")
        #expect(monitor.lastLoadStatistics.filesReused == 3)
    }

    @Test("Only a changed file is decoded again")
    func oneChangedFileDecodes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        let first = directory.appendingPathComponent("a.json")
        let second = directory.appendingPathComponent("b.json")
        try write(snapshot("a", title: "Before"), to: first)
        try write(snapshot("b", title: "Stable"), to: second)
        _ = monitor.loadActivities()

        try write(snapshot("a", title: "After"), to: first)
        let result = monitor.loadActivities()
        #expect(monitor.lastLoadStatistics.filesDecoded == 1, "only the changed file should decode")
        #expect(monitor.lastLoadStatistics.filesReused == 1)
        #expect(result.first { $0.id == "a" }?.title == "After")
        #expect(result.first { $0.id == "b" }?.title == "Stable")
    }

    @Test("A deleted file cannot keep serving its last value")
    func deletedFileIsEvicted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        let first = directory.appendingPathComponent("a.json")
        let second = directory.appendingPathComponent("b.json")
        try write(snapshot("a", title: "A"), to: first)
        try write(snapshot("b", title: "B"), to: second)
        _ = monitor.loadActivities()

        try FileManager.default.removeItem(at: first)
        let result = monitor.loadActivities()
        #expect(result.map(\.id) == ["b"])
        #expect(monitor.lastLoadStatistics.cacheEvictions == 1)
    }

    @Test("Replacing a file at the same pathname is not mistaken for the old one")
    func replacedFileIsNotReused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        let url = directory.appendingPathComponent("session.json")
        try write(snapshot("original", title: "Original"), to: url)
        let originalModification = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = monitor.loadActivities()

        // Same name, same size class, same modification time: only the file's
        // identity distinguishes the replacement.
        try FileManager.default.removeItem(at: url)
        try write(snapshot("replacement", title: "Replacement"), to: url)
        try FileManager.default.setAttributes([.modificationDate: originalModification ?? Date()], ofItemAtPath: url.path)

        let result = monitor.loadActivities()
        #expect(monitor.lastLoadStatistics.filesDecoded == 1)
        #expect(result.first?.id == "replacement")
        #expect(result.first?.title == "Replacement")
    }

    @Test("A regular file swapped for a symlink is rejected, not served from cache")
    func symlinkSwapIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        let target = directory.appendingPathComponent("target.json")
        let planted = directory.appendingPathComponent("session.json")
        try write(snapshot("target", title: "Target"), to: target)
        try write(snapshot("planted", title: "Planted"), to: planted)
        _ = monitor.loadActivities()

        try FileManager.default.removeItem(at: planted)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: target)
        let result = monitor.loadActivities()
        #expect(result.map(\.id) == ["target"], "the symlink must not resolve to a cached activity")
    }

    @Test("An empty directory decodes nothing")
    func emptyDirectoryDoesNoWork() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(in: directory)
        #expect(monitor.loadActivities().isEmpty)
        #expect(monitor.lastLoadStatistics == AIActivityLoadStatistics())
    }
}
