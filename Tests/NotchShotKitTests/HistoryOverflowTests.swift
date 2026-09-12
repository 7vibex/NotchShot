import Foundation
import Testing

@testable import NotchShotKit

/// The store's two caps used to live only on the read side. Nothing stopped the
/// app writing past them, and `load()` handled a store it could not accept the
/// same way it handles corruption: move the file aside and come back with an
/// empty History. A user with text search on and retention set to Forever could
/// therefore lose every row they had, reported only to the log.
///
/// These pin the two halves of the repair — the write side keeps the store
/// inside the caps, and the read side recovers an over-sized store instead of
/// discarding it — because the failure is invisible from inside the app.
@Suite("History overflow")
@MainActor
struct HistoryOverflowTests {

    private static func makeStore() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-overflow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    private static func entries(count: Int, textBytes: Int) -> [HistoryEntry] {
        let text = textBytes > 0 ? String(repeating: "a", count: textBytes) : nil
        return (0 ..< count).map { index in
            var asset = CaptureAsset(
                url: URL(fileURLWithPath: "/Users/test/Pictures/Capture \(index).png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 2880, height: 1800),
                scale: 2
            )
            asset.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: text)
        }
    }

    /// Writes with the same settings `performWrite` uses, so the fixture is the
    /// file the app itself would have produced.
    @discardableResult
    private static func write(_ entries: [HistoryEntry], to store: URL) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(entries)
        try data.write(to: store, options: .atomic)
        return data.count
    }

    private static func corruptSiblings(of store: URL) -> [String] {
        let directory = store.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.contains("corrupt-") }
    }

    @Test("A store past the byte cap is recovered, not discarded")
    func oversizedStoreIsRecovered() throws {
        let store = Self.makeStore()
        // 5,000 rows of realistic recognised text clears 16 MB comfortably.
        let byteCount = try Self.write(
            Self.entries(count: 5_000, textBytes: 3_600),
            to: store
        )
        #expect(byteCount > HistoryRepository.maximumStoreBytes)

        let repository = HistoryRepository(storeURL: store)

        // Every row survives: recognised text is shed first, and it is the only
        // field big enough to have caused this.
        #expect(repository.entries.count == 5_000)
        #expect(Self.corruptSiblings(of: store).isEmpty)
    }

    @Test("A store past the row cap keeps the newest entries")
    func overlongStoreKeepsNewest() throws {
        let store = Self.makeStore()
        try Self.write(
            Self.entries(count: HistoryRepository.maximumEntryCount + 25, textBytes: 0),
            to: store
        )

        let repository = HistoryRepository(storeURL: store)

        #expect(repository.entries.count == HistoryRepository.maximumEntryCount)
        #expect(Self.corruptSiblings(of: store).isEmpty)
        // Newest-first ordering means the survivors are the recent ones.
        let newest = repository.entries.first
        #expect(newest?.fileURL.lastPathComponent == "Capture 10024.png")
    }

    @Test("Recording past the row cap trims instead of growing without limit")
    func recordingStopsAtTheRowCap() throws {
        let store = Self.makeStore()
        try Self.write(
            Self.entries(count: HistoryRepository.maximumEntryCount, textBytes: 0),
            to: store
        )
        let repository = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
        #expect(repository.entries.count == HistoryRepository.maximumEntryCount)

        repository.record(
            asset: CaptureAsset(
                url: URL(fileURLWithPath: "/Users/test/Pictures/Newest.png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 100, height: 100)
            ),
            image: nil
        )

        #expect(repository.entries.count == HistoryRepository.maximumEntryCount)
        #expect(repository.entries.first?.fileURL.lastPathComponent == "Newest.png")
    }

    /// A store the app has just written must be one it can read back. This is
    /// the invariant whose absence was the whole defect.
    @Test("A store written after budgeting is readable without repair")
    func writtenStoreLoadsUnchanged() throws {
        let store = Self.makeStore()
        let repository = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            // Recognised text is the only field large enough to push a store
            // past its cap, so this test explicitly indexes it.
            indexesCaptureText: true
        )
        // Control characters expand to six-byte JSON escape sequences. The
        // fast estimate deliberately cannot model every escape, so this drives
        // the exact write-side shedding path whose normalized result must be
        // mirrored back into memory.
        let escapedText = String(repeating: "\u{0001}", count: 400_000)
        for index in 0 ..< 20 {
            repository.record(
                asset: CaptureAsset(
                    url: URL(fileURLWithPath: "/Users/test/Pictures/Shot \(index).png"),
                    kind: .screenshot,
                    pixelSize: CGSize(width: 100, height: 100)
                ),
                image: nil,
                recognizedText: escapedText
            )
        }
        try repository.save()

        let size = try store.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size <= HistoryRepository.maximumStoreBytes)

        let reloaded = HistoryRepository(storeURL: store)
        #expect(reloaded.entries.count == repository.entries.count)
        #expect(reloaded.entries.map(\.id) == repository.entries.map(\.id))
        #expect(reloaded.entries.map(\.indexedText) == repository.entries.map(\.indexedText))
        #expect(Self.corruptSiblings(of: store).isEmpty)
    }

    /// The fast estimate does not see every field. A very long capture path is
    /// ordinary row data that survives sanitising, so a text-free store can
    /// exceed the write cap while the estimate still reads inside the budget;
    /// before the fix the save threw forever and every later capture lived only
    /// in memory.
    @Test("A text-free store past the write cap sheds oldest rows instead of failing")
    func oversizedTextFreeStoreShrinks() throws {
        let store = Self.makeStore()
        let longDirectory = String(repeating: "p", count: 2_000)
        let seeded = (0 ..< 8_500).map { index -> HistoryEntry in
            var asset = CaptureAsset(
                url: URL(fileURLWithPath: "/Users/test/Pictures/\(longDirectory)/Capture \(index).png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 2880, height: 1800),
                scale: 2
            )
            asset.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)
        }
        let byteCount = try Self.write(seeded, to: store)
        #expect(byteCount > HistoryRepository.maximumStoreBytes)
        #expect(byteCount <= HistoryRepository.maximumRecoverableStoreBytes)

        let repository = HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
        try repository.save()

        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        let size = (attributes[.size] as? Int) ?? 0
        #expect(size <= HistoryRepository.maximumStoreBytes)
        #expect(repository.entries.count < seeded.count)
        #expect(repository.entries.first?.fileURL.lastPathComponent == "Capture 8499.png")
        #expect(repository.entries.last?.fileURL.lastPathComponent != "Capture 0.png")

        let reloaded = HistoryRepository(storeURL: store)
        #expect(reloaded.entries.count == repository.entries.count)
        #expect(Self.corruptSiblings(of: store).isEmpty)
    }
}
