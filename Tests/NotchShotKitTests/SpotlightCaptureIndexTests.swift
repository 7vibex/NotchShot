import CoreSpotlight
import Foundation
import Testing
@testable import NotchShotKit

/// Spotlight index replacement must not build items for snapshots that a newer
/// replacement already superseded.
@Suite("Spotlight capture index")
@MainActor
struct SpotlightCaptureIndexTests {
    private final class FakeIndex: SpotlightIndexing, @unchecked Sendable {
        nonisolated(unsafe) var deleteCallCount = 0
        nonisolated(unsafe) var domainsDeleted: [[String]] = []
        nonisolated(unsafe) var indexedBatches: [[CSSearchableItem]] = []
        nonisolated(unsafe) private var pendingDeletes: [(Error?) -> Void] = []
        nonisolated(unsafe) private var pendingIndexes: [(Error?) -> Void] = []

        func deleteSearchableItems(
            withDomainIdentifiers domainIdentifiers: [String],
            completionHandler: ((Error?) -> Void)?
        ) {
            deleteCallCount += 1
            domainsDeleted.append(domainIdentifiers)
            if let completionHandler { pendingDeletes.append(completionHandler) }
        }

        func indexSearchableItems(
            _ items: [CSSearchableItem],
            completionHandler: ((Error?) -> Void)?
        ) {
            indexedBatches.append(items)
            if let completionHandler { pendingIndexes.append(completionHandler) }
        }

        func completeDelete(error: Error? = nil) {
            guard !pendingDeletes.isEmpty else { return }
            pendingDeletes.removeFirst()(error)
        }

        func completeIndex(error: Error? = nil) {
            guard !pendingIndexes.isEmpty else { return }
            pendingIndexes.removeFirst()(error)
        }
    }

    private func entry(_ index: Int) -> HistoryEntry {
        HistoryEntry(
            asset: CaptureAsset(
                url: URL(fileURLWithPath: "/Users/test/Pictures/Capture \(index).png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 100, height: 100)
            ),
            thumbnailFilename: nil,
            indexedText: nil
        )
    }

    private func yieldUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Rapid replacements materialize only the newest snapshot")
    func supersededSnapshotsAreNotMaterialized() async {
        let fake = FakeIndex()
        let indexer = CaptureSpotlightIndexer(index: fake)

        let first = (0 ..< 10).map(entry)
        let middle = (100 ..< 110).map(entry)
        let newest = (200 ..< 205).map(entry)
        indexer.replaceIndex(with: first)
        indexer.replaceIndex(with: middle)
        indexer.replaceIndex(with: newest)

        #expect(fake.deleteCallCount == 1)
        #expect(indexer.lastMaterializedItemCount == 0, "nothing is built before the delete completes")

        fake.completeDelete()
        await yieldUntil { fake.indexedBatches.count == 1 }

        #expect(indexer.lastMaterializedItemCount == 5, "only the newest snapshot was built")
        #expect(fake.indexedBatches.first?.map(\.uniqueIdentifier) == newest.map { $0.id.uuidString })
        fake.completeIndex()
    }

    @Test("A replacement during indexing triggers a fresh refresh of the newest snapshot")
    func replacementDuringIndexingRefreshes() async {
        let fake = FakeIndex()
        let indexer = CaptureSpotlightIndexer(index: fake)

        let first = (0 ..< 3).map(entry)
        indexer.replaceIndex(with: first)
        fake.completeDelete()
        await yieldUntil { fake.indexedBatches.count == 1 }
        #expect(fake.indexedBatches[0].count == 3)

        // The first indexing call is still pending when the source changes.
        let newer = (10 ..< 12).map(entry)
        indexer.replaceIndex(with: newer)
        let deleteCountBefore = fake.deleteCallCount
        fake.completeIndex()
        await yieldUntil { fake.deleteCallCount == deleteCountBefore + 1 }

        fake.completeDelete()
        await yieldUntil { fake.indexedBatches.count == 2 }
        #expect(fake.indexedBatches.last?.map(\.uniqueIdentifier) == newer.map { $0.id.uuidString })
        fake.completeIndex()
    }

    @Test("Clearing indexes nothing and only deletes the domain")
    func clearMaterializesNothing() async {
        let fake = FakeIndex()
        let indexer = CaptureSpotlightIndexer(index: fake)

        indexer.replaceIndex(with: (0 ..< 4).map(entry))
        fake.completeDelete()
        await yieldUntil { fake.indexedBatches.count == 1 }
        fake.completeIndex()

        indexer.clear()
        fake.completeDelete()
        await yieldUntil { fake.deleteCallCount == 2 }
        await Task.yield()
        #expect(fake.indexedBatches.count == 1, "clear must not index anything")
    }
}
