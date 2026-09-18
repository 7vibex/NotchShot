import Foundation
import Testing
@testable import NotchShotKit

/// The transfer store is the island's only publication path for transfers.
/// These tests pin the two properties that path has to keep: per-transfer
/// bookkeeping never outlives its transfer, and raw progress mutations cannot
/// bypass the publication cadence.
@Suite("Transfer activity store")
@MainActor
struct TransferActivityStoreTests {
    private static let t0 = Date(timeIntervalSince1970: 5_000_000)

    @Test("A late callback for an earlier file cannot regress files, filename, or bytes")
    func outOfOrderProgressCannotRegress() {
        let store = TransferActivityStore()
        var finished: [TransferActivitySnapshot] = []
        store.onFinish = { finished.append($0) }

        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 2,
            totalBytes: 200,
            now: Self.t0
        )
        // File A boundary, then file B boundary.
        store.update(id, completedFiles: 0, currentFilename: "A.bin", bytesTransferred: 50, now: Self.t0)
        store.update(id, completedFiles: 1, currentFilename: "B.bin", bytesTransferred: 100, now: Self.t0.addingTimeInterval(1))
        // A delayed older callback from file A arrives after the boundary.
        store.update(id, completedFiles: 0, currentFilename: "A.bin", bytesTransferred: 30, now: Self.t0.addingTimeInterval(2))

        var snapshot = store.stagedSnapshot(id)
        #expect(snapshot?.completedFiles == 1)
        #expect(snapshot?.currentFilename == "B.bin")
        #expect(snapshot?.bytesTransferred == 100)

        // Newer progress for file B still advances.
        store.update(id, completedFiles: 1, currentFilename: "B.bin", bytesTransferred: 150, now: Self.t0.addingTimeInterval(3))
        snapshot = store.stagedSnapshot(id)
        #expect(snapshot?.bytesTransferred == 150)
        #expect(snapshot?.completedFiles == 1)
        #expect(snapshot?.currentFilename == "B.bin")

        store.finish(id, now: Self.t0.addingTimeInterval(4))
        #expect(finished.count == 1)

        // A terminal callback after completion cannot overwrite the outcome.
        store.update(id, completedFiles: 1, currentFilename: "A.bin", bytesTransferred: 10, now: Self.t0.addingTimeInterval(5))
        snapshot = store.stagedSnapshot(id)
        #expect(snapshot?.state == .completed)
        #expect(snapshot?.completedFiles == 2)
        #expect(snapshot?.bytesTransferred == 200)
        #expect(snapshot?.currentFilename == "B.bin")
    }

    @Test("A stalled transfer still publishes its final progress after the window")
    func trailingProgressPublication() async throws {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 1,
            totalBytes: 1_000,
            now: Self.t0
        )
        var publications = 0
        store.onChange = { publications += 1 }

        let now = Date()
        store.update(id, bytesTransferred: 100, now: now)
        store.update(id, bytesTransferred: 200, now: now.addingTimeInterval(0.01))
        #expect(store.transfers.first?.bytesTransferred == 100, "the second update is inside the window")

        for _ in 0 ..< 40 where store.transfers.first?.bytesTransferred != 200 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(store.transfers.first?.bytesTransferred == 200, "the final progress must not be dropped")
        #expect(publications == 2, "one immediate publication and one trailing publication")
    }

    @Test("A file boundary publishes immediately and a byte burst stays throttled")
    func publicationCadence() {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 2,
            totalBytes: 4_000,
            now: Self.t0
        )
        var publications = 0
        var refreshes = 0
        store.onChange = {
            publications += 1
            // This is exactly what `AppCoordinator` wires to its refresh.
            refreshes += 1
        }

        let base = Self.t0.addingTimeInterval(10)
        var raw = 0
        for step in 1 ... 100 {
            raw += 1
            store.update(
                id,
                bytesTransferred: Int64(step) * 10,
                now: base.addingTimeInterval(Double(step) * 0.005)
            )
        }
        #expect(raw == 100)
        #expect(publications < raw, "high-frequency progress must not publish per mutation")
        #expect(publications >= 1, "the burst still publishes at the throttle cadence")
        #expect(refreshes == publications)

        // A file boundary is structural and publishes at once even inside the
        // throttle window.
        let beforeBoundary = publications
        store.update(
            id,
            completedFiles: 1,
            currentFilename: "second.bin",
            now: base.addingTimeInterval(0.6)
        )
        #expect(publications == beforeBoundary + 1)
        #expect(store.transfers.first?.completedFiles == 1)
        #expect(store.transfers.first?.currentFilename == "second.bin")
    }

    @Test("Every permanently removed transfer retires all of its bookkeeping")
    func bookkeepingRetiredByTimedCleanup() async throws {
        let store = TransferActivityStore(completedLinger: 0.05, failedLinger: 0.05)
        let id = store.begin(service: .localSend, peerName: "Phone", fileCount: 1, totalBytes: 10)
        store.update(id, completedFiles: 1, currentFilename: "one.bin", bytesTransferred: 10)
        store.finish(id)

        #expect(store.transfers.count == 1)
        // `lastPublish` intentionally survives the finish; it is retired with
        // the transfer, not with the terminal transition.
        #expect(store.bookkeepingCounts == (0, 0, 1))

        // Poll rather than sleep a fixed interval: the cleanup task hops onto
        // the main actor, which the rest of the suite may be occupying.
        for _ in 0 ..< 100 where !store.transfers.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.transfers.isEmpty)
        #expect(store.bookkeepingCounts == (0, 0, 0))
    }

    @Test("Overflow removal uses the same retirement path as timed cleanup")
    func overflowRetiresBookkeeping() {
        let store = TransferActivityStore(completedLinger: 60, failedLinger: 60)
        var ids: [UUID] = []
        for index in 0 ..< TransferActivityStore.maximumLiveTransfers {
            let id = store.begin(
                service: .localSend,
                peerName: "peer-\(index)",
                fileCount: 1,
                totalBytes: 100
            )
            store.update(id, bytesTransferred: 10)
            ids.append(id)
        }
        #expect(store.bookkeepingCounts == (0, 6, 6))

        for index in 0 ..< 2 {
            let id = store.begin(
                service: .localSend,
                peerName: "overflow-\(index)",
                fileCount: 1,
                totalBytes: 100
            )
            store.update(id, bytesTransferred: 10)
            ids.append(id)
        }

        #expect(store.transfers.count == TransferActivityStore.maximumLiveTransfers)
        #expect(store.bookkeepingCounts == (0, 6, 6))
        // The oldest transfers were the ones retired.
        #expect(store.transfers.contains { $0.id == ids.last } == true)
        #expect(store.transfers.contains { $0.id == ids[0] } == false)
    }

    @Test("Explicit dismissal retires bookkeeping immediately")
    func dismissalRetiresBookkeeping() {
        let store = TransferActivityStore()
        let id = store.begin(service: .localSend, peerName: "Phone", fileCount: 1, totalBytes: 10)
        store.update(id, bytesTransferred: 5)
        store.dismiss(id)
        #expect(store.transfers.isEmpty)
        #expect(store.bookkeepingCounts == (0, 0, 0))
    }

    @Test("Hundreds of completed transfers leave no bookkeeping behind")
    func repeatedTransfersStayBounded() {
        let store = TransferActivityStore(completedLinger: 0, failedLinger: 0)
        var outcomes = 0
        store.onFinish = { _ in outcomes += 1 }

        for index in 0 ..< 250 {
            let now = Self.t0.addingTimeInterval(Double(index))
            let id = store.begin(
                service: .localSend,
                peerName: "peer-\(index)",
                fileCount: 1,
                totalBytes: 64,
                now: now
            )
            store.update(id, completedFiles: 1, currentFilename: "file.bin", bytesTransferred: 64, now: now)
            store.finish(id, now: now)
            // Deterministic stand-in for the linger task firing: same method.
            #expect(store.retireExpired(now: now))
            #expect(store.transfers.isEmpty)
            #expect(store.bookkeepingCounts == (0, 0, 0))
        }
        #expect(outcomes == 250)
    }

    @Test("A failed transfer keeps its own linger and then retires cleanly")
    func failedTransferLingersThenRetires() {
        let store = TransferActivityStore(completedLinger: 0.05, failedLinger: 1.0)
        let id = store.begin(service: .airDrop, peerName: "Mac", fileCount: 1, now: Self.t0)
        store.finish(id, error: "connection reset", now: Self.t0)

        #expect(store.transfers.first?.state == .failed)
        #expect(store.transfers.first?.errorMessage == "connection reset")
        #expect(!store.retireExpired(now: Self.t0.addingTimeInterval(0.5)))
        #expect(store.transfers.count == 1)
        #expect(store.retireExpired(now: Self.t0.addingTimeInterval(1.5)))
        #expect(store.transfers.isEmpty)
        #expect(store.bookkeepingCounts == (0, 0, 0))
    }

    @Test("Cancellation still reaches the transport's handler and reports once")
    func cancellationStillReachesTransport() {
        let store = TransferActivityStore()
        var cancelRequested = false
        var outcomes: [TransferState] = []
        store.onFinish = { outcomes.append($0.state) }

        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 1,
            totalBytes: 100,
            cancel: { cancelRequested = true }
        )
        store.requestCancel(id)
        #expect(cancelRequested)
        store.markCancelled(id)
        #expect(outcomes == [.cancelled])
        // A transport that reports cancellation twice must not double-fire.
        store.markCancelled(id)
        #expect(outcomes == [.cancelled])
        #expect(store.transfers.first?.state == .cancelled)
    }
}
