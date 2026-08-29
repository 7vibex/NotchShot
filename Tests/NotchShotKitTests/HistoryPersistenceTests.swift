import Foundation
import Testing

@testable import NotchShotKit

/// Encoding the store moved off the main actor for the debounced save, while
/// `save()` stayed synchronous because `applicationShouldTerminate` calls it and
/// the process may exit the moment it returns. Both paths share one serial
/// queue so the last write requested is the last to land. These tests pin that:
/// a store that loses the newest capture on quit is the failure this design is
/// built to avoid.
@Suite("History persistence")
struct HistoryPersistenceTests {

    private static func makeStore() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-persist-\(UUID().uuidString).json")
    }

    private static func asset(named name: String) -> CaptureAsset {
        CaptureAsset(
            url: URL(fileURLWithPath: "/Users/test/Pictures/\(name).png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 100, height: 100)
        )
    }

    /// Persistence tests should not contend over the process-wide Preferences
    /// singleton with unrelated suites running in parallel.
    @MainActor
    private static func repository(at store: URL) -> HistoryRepository {
        HistoryRepository(
            storeURL: store,
            managedArtifactDirectories: [],
            historyEnabled: true,
            indexesCaptureText: false
        )
    }

    private static func rowsOnDisk(at store: URL) throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: store)
        return try decoder.decode([HistoryEntry].self, from: data)
            .map(\.fileURL.lastPathComponent)
    }

    /// Waits for the store to hold `expected`, up to a generous deadline.
    ///
    /// The debounced save runs off a main-queue timer, so a fixed sleep asserts
    /// that the main queue was serviced within it — which is not true when the
    /// rest of the suite is contending for the main actor. Waiting on the
    /// condition instead of the clock is what makes this deterministic.
    private static func waitForRows(
        _ expected: [String],
        at store: URL,
        timeout: Duration = .seconds(20)
    ) async -> [String]? {
        let deadline = ContinuousClock.now + timeout
        var lastSeen: [String]?
        while ContinuousClock.now < deadline {
            lastSeen = try? rowsOnDisk(at: store)
            if lastSeen == expected { return lastSeen }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lastSeen
    }

    @Test("save() is durable by the time it returns")
    @MainActor
    func synchronousSaveIsDurable() throws {
        let store = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let repository = Self.repository(at: store)
        repository.record(asset: Self.asset(named: "First"), image: nil)
        try repository.save()

        #expect(try Self.rowsOnDisk(at: store) == ["First.png"])
        #expect(!repository.hasUnpersistedChanges)
        #expect(repository.lastPersistenceError == nil)
    }

    /// The ordering hazard the serial queue exists for: a background encode
    /// started from a snapshot taken before the last capture must not land after
    /// — and overwrite — the blocking save that follows it.
    @Test("A blocking save lands after work the debounced path already queued")
    @MainActor
    func blockingSaveWinsOverQueuedWork() async throws {
        let store = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let repository = Self.repository(at: store)
        repository.record(asset: Self.asset(named: "First"), image: nil)
        // Let the debounced write actually run, so the queue has real history.
        #expect(await Self.waitForRows(["First.png"], at: store) == ["First.png"])

        repository.record(asset: Self.asset(named: "Second"), image: nil)
        try repository.save()

        // Newest first, and the earlier row survived.
        #expect(try Self.rowsOnDisk(at: store) == ["Second.png", "First.png"])

        // Nothing queued may reach disk afterwards and undo that.
        try await Task.sleep(for: .seconds(1))
        #expect(try Self.rowsOnDisk(at: store) == ["Second.png", "First.png"])
    }

    @Test("The debounced save reaches disk without an explicit save")
    @MainActor
    func debouncedSaveLands() async throws {
        let store = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let repository = Self.repository(at: store)
        repository.record(asset: Self.asset(named: "Only"), image: nil)
        #expect(!FileManager.default.fileExists(atPath: store.path))

        #expect(await Self.waitForRows(["Only.png"], at: store) == ["Only.png"])
    }

    @Test("A burst of captures all survive the debounce")
    @MainActor
    func burstOfCapturesSurvives() async throws {
        let store = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let repository = Self.repository(at: store)
        for index in 0 ..< 25 {
            repository.record(asset: Self.asset(named: "Capture \(index)"), image: nil)
        }
        try repository.save()

        let onDisk = try Self.rowsOnDisk(at: store)
        #expect(onDisk.count == 25)
        #expect(onDisk.first == "Capture 24.png")

        // Reloading the store must see exactly what was recorded.
        #expect(Self.repository(at: store).entries.count == 25)
    }

    @Test("A failed save throws and remains visibly dirty")
    @MainActor
    func failedSaveIsObservable() {
        let store = URL(fileURLWithPath: "/dev/null/history.json")
        let repository = Self.repository(at: store)
        repository.record(asset: Self.asset(named: "Unsaved"), image: nil)

        do {
            try repository.save()
            Issue.record("Expected the invalid store destination to reject the save")
        } catch {
            #expect(repository.hasUnpersistedChanges)
            #expect(repository.lastPersistenceError != nil)
        }
    }
}
