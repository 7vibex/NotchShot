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

    @Test("The newest-entry scan picks what a sorted directory listing would")
    func newestEntriesMatchListing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)
        func file(_ name: String, age: TimeInterval) throws {
            let url = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: base - age], ofItemAtPath: url.path)
        }
        // More than the budget, with runs of equal dates that only listing
        // order can break.
        for index in 0 ..< 60 {
            try file("s\(index).json", age: TimeInterval(index / 3))
        }
        try file("notes.txt", age: 0.5)
        // Hidden either way must never take a slot, however new.
        try file(".dot.json", age: -100)
        try file("flagged.json", age: -100)
        #expect(chflags(directory.appendingPathComponent("flagged.json").path, UInt32(UF_HIDDEN)) == 0)
        // A link ranks by its own date, not its target's; a folder still ranks.
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.json"),
            withDestinationURL: directory.appendingPathComponent("s59.json")
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder.json"),
            withIntermediateDirectories: false
        )

        let listing = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        func modified(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate ?? .distantPast
        }
        let dates = listing.map(modified)
        let ranked: [String] = listing.indices
            .sorted { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : $0 < $1 }
            .map { listing[$0].standardizedFileURL.path }

        for limit in [0, 1, 32, 200] {
            let scanned = try #require(AIActivityMonitor.newestEntries(in: directory, limit: limit))
            #expect(scanned.map(\.url.standardizedFileURL.path) == Array(ranked.prefix(limit)), "limit \(limit)")
        }

        // What validation reads must agree with what Foundation reports.
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ]
        for entry in try #require(AIActivityMonitor.newestEntries(in: directory, limit: 200)) {
            let values = try entry.url.resourceValues(forKeys: keys)
            let name = entry.url.lastPathComponent
            #expect(entry.isReadable, "\(name)")
            #expect(entry.isRegularFile == (values.isRegularFile ?? false), "\(name)")
            #expect(entry.isSymbolicLink == (values.isSymbolicLink ?? false), "\(name)")
            #expect(entry.url.hasDirectoryPath == (values.isDirectory ?? false), "\(name)")
            #expect(entry.modified == values.contentModificationDate, "\(name)")
            if entry.isRegularFile { #expect(entry.size == values.fileSize, "\(name)") }
            #expect(entry.identity != nil, "\(name)")
        }

        // Identical bytes and date, but a different file: identity alone tells.
        func identity(of name: String) throws -> AIActivityMonitor.FileIdentity? {
            try #require(AIActivityMonitor.newestEntries(in: directory, limit: 200)?
                .first { $0.url.lastPathComponent == name }).identity
        }
        let before = try identity(of: "s0.json")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("s0.json"))
        try file("s0.json", age: 0)
        #expect(try identity(of: "s0.json") != before)
        #expect(AIActivityMonitor.newestEntries(
            in: directory.appendingPathComponent("missing", isDirectory: true),
            limit: 32
        ) == nil)
    }
}
