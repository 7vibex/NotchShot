import Foundation
import Testing

@testable import NotchShotKit

/// Loading history coalesces rows that name the same file, or that share an id.
/// The lookup behind the second of those became a dictionary — the loop used to
/// fall back to a linear scan for every row whose path it had not seen, which is
/// every row in a healthy store. These tests pin the rewrite against a verbatim
/// copy of what it replaced, over inputs built to collide on both keys.
@Suite("History coalescing")
struct HistoryCoalesceTests {

    /// The pre-optimisation implementation, kept verbatim as the oracle.
    private static func referenceCoalesce(
        _ orderedEntries: [HistoryEntry]
    ) -> (entries: [HistoryEntry], duplicates: [HistoryEntry]) {
        var result: [HistoryEntry] = []
        var indexByPath: [String: Int] = [:]
        var usedIDs = Set<UUID>()
        var duplicates: [HistoryEntry] = []

        for entry in orderedEntries {
            let path = entry.fileURL.standardizedFileURL.path
            if let index = indexByPath[path] ?? result.firstIndex(where: { $0.id == entry.id }) {
                if result[index].projectPath == nil { result[index].projectPath = entry.projectPath }
                if result[index].captionPath == nil { result[index].captionPath = entry.captionPath }
                if result[index].indexedText == nil { result[index].indexedText = entry.indexedText }
                duplicates.append(entry)
                continue
            }
            guard usedIDs.insert(entry.id).inserted else {
                duplicates.append(entry)
                continue
            }
            indexByPath[path] = result.count
            result.append(entry)
        }
        return (result, duplicates)
    }

    private static func entry(
        id: UUID,
        path: String,
        project: String? = nil,
        caption: String? = nil,
        text: String? = nil
    ) -> HistoryEntry {
        var entry = HistoryEntry(
            asset: CaptureAsset(
                id: id,
                url: URL(fileURLWithPath: path),
                kind: .screenshot,
                pixelSize: CGSize(width: 10, height: 10)
            ),
            thumbnailFilename: nil,
            indexedText: text
        )
        entry.projectPath = project
        entry.captionPath = caption
        return entry
    }

    /// Rows drawn from a small pool of ids and a small pool of paths, so the two
    /// collide independently: same path with different ids, same id with
    /// different paths, both, and neither.
    private static func makeCorpus(seed: UInt64) -> [HistoryEntry] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let ids = (0 ..< 6).map { _ in UUID() }
        let paths = (0 ..< 5).map { "/Users/test/Pictures/Capture \($0).png" }

        return (0 ..< 40).map { index in
            entry(
                id: ids[next(ids.count)],
                path: paths[next(paths.count)],
                project: next(3) == 0 ? "/Users/test/Projects/p\(index).notchshot" : nil,
                caption: next(3) == 0 ? "/Users/test/Pictures/Capture \(index).srt" : nil,
                text: next(2) == 0 ? "recognised text \(index)" : nil
            )
        }
    }

    @Test("Coalescing matches the linear-scan implementation it replaced")
    func matchesReference() {
        for seed in UInt64(1) ... 60 {
            let corpus = Self.makeCorpus(seed: seed)
            let actual = HistoryRepository.coalesceDuplicatePrimaryPaths(corpus)
            let expected = Self.referenceCoalesce(corpus)

            #expect(actual.entries.map(\.id) == expected.entries.map(\.id), "seed \(seed)")
            #expect(actual.duplicates.map(\.id) == expected.duplicates.map(\.id), "seed \(seed)")
            #expect(actual.entries.map(\.projectPath) == expected.entries.map(\.projectPath), "seed \(seed)")
            #expect(actual.entries.map(\.captionPath) == expected.entries.map(\.captionPath), "seed \(seed)")
            #expect(actual.entries.map(\.indexedText) == expected.entries.map(\.indexedText), "seed \(seed)")
        }
    }

    @Test("A repeated id at a different path still merges rather than dropping")
    func repeatedIDMerges() {
        let shared = UUID()
        let corpus = [
            Self.entry(id: shared, path: "/a/one.png"),
            Self.entry(id: shared, path: "/a/two.png", project: "/p.notchshot", text: "hello"),
        ]
        let result = HistoryRepository.coalesceDuplicatePrimaryPaths(corpus)

        #expect(result.entries.count == 1)
        #expect(result.entries[0].fileURL.path == "/a/one.png")
        #expect(result.entries[0].projectPath == "/p.notchshot")
        #expect(result.entries[0].indexedText == "hello")
        #expect(result.duplicates.count == 1)
    }
}
