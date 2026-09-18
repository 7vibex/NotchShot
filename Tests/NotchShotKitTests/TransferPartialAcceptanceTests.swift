import Foundation
import Testing
@testable import NotchShotKit

/// LocalSend may accept only a subset of the selected files. The requested,
/// accepted, and uploaded counts stay distinct, and completion never promotes
/// the selection to delivered files.
@Suite("Transfer partial acceptance")
@MainActor
struct TransferPartialAcceptanceTests {
    private static let t0 = Date(timeIntervalSince1970: 8_000_000)

    @Test("Requested 3, accepted 1, sent 1 reports one file")
    func subsetAcceptedReportsAcceptedCount() {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 3,
            totalBytes: 300,
            now: Self.t0
        )
        store.updateAcceptedFiles(id, acceptedFiles: 1, now: Self.t0)
        store.update(
            id,
            completedFiles: 1,
            currentFilename: "one.bin",
            bytesTransferred: 100,
            now: Self.t0
        )
        store.finish(id, now: Self.t0)

        let snapshot = store.transfers.first { $0.id == id }
        #expect(snapshot?.fileCount == 3)
        #expect(snapshot?.acceptedFiles == 1)
        #expect(snapshot?.completedFiles == 1)
        #expect(snapshot?.title == "Sent 1 file")
        #expect(snapshot?.fileCountDescription == "1 file")
        #expect(snapshot?.state == .completed)
    }

    @Test("Requested 3, accepted 2, second upload fails is not a completion")
    func partialFailureIsNotACompletion() {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 3,
            totalBytes: 300,
            now: Self.t0
        )
        store.updateAcceptedFiles(id, acceptedFiles: 2, now: Self.t0)
        store.update(
            id,
            completedFiles: 2,
            currentFilename: "two.bin",
            bytesTransferred: 200,
            now: Self.t0
        )
        store.finish(id, error: "The receiver rejected the upload", now: Self.t0)

        let snapshot = store.transfers.first { $0.id == id }
        #expect(snapshot?.state == .failed)
        #expect(snapshot?.title == "Transfer failed")
        #expect(snapshot?.completedFiles == 2)
        #expect(snapshot?.fileCount == 3)
    }

    @Test("All accepted and sent keeps the successful display")
    func fullAcceptanceKeepsSuccessfulDisplay() {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 3,
            totalBytes: 300,
            now: Self.t0
        )
        store.updateAcceptedFiles(id, acceptedFiles: 3, now: Self.t0)
        store.update(
            id,
            completedFiles: 3,
            currentFilename: "three.bin",
            bytesTransferred: 300,
            now: Self.t0
        )
        store.finish(id, now: Self.t0)

        let snapshot = store.transfers.first { $0.id == id }
        #expect(snapshot?.title == "Sent 3 files")
        #expect(snapshot?.completedFiles == 3)
        #expect(snapshot?.fileCountDescription == "3 files")
    }

    @Test("Completion cannot promote a requested count past the accepted count")
    func completionNeverPromotesRequestedCount() {
        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 5,
            totalBytes: 500,
            now: Self.t0
        )
        store.updateAcceptedFiles(id, acceptedFiles: 2, now: Self.t0)
        store.finish(id, now: Self.t0)

        let snapshot = store.transfers.first { $0.id == id }
        #expect(snapshot?.completedFiles == 2)
        #expect(snapshot?.title == "Sent 2 files")
    }

    @Test("A receiver that accepts none never produces a completed activity")
    func noneAcceptedIsNeverCompleted() {
        // LocalSend answers 204 No Content when the receiver declines.
        #expect(!LocalSendClient.prepareAccepted(statusCode: 204))
        #expect(LocalSendClient.prepareAccepted(statusCode: 200))

        let store = TransferActivityStore()
        let id = store.begin(
            service: .localSend,
            peerName: "Phone",
            fileCount: 3,
            totalBytes: 300,
            now: Self.t0
        )
        // The view's failure path for `LocalSendError.noFilesAccepted`.
        store.finish(
            id,
            error: LocalSendError.noFilesAccepted.localizedDescription,
            now: Self.t0
        )

        let snapshot = store.transfers.first { $0.id == id }
        #expect(snapshot?.state == .failed)
        #expect(snapshot?.title == "Transfer failed")
        #expect(snapshot?.completedFiles == 0)
    }
}
