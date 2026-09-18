import Foundation
import Observation

public enum TransferService: String, Sendable, Equatable {
    case localSend
    case airDrop

    public var title: String {
        switch self {
        case .localSend: "LocalSend"
        case .airDrop: "AirDrop"
        }
    }
}

public enum TransferDirection: String, Sendable, Equatable {
    case outgoing
    case incoming
}

public enum TransferState: String, Sendable, Equatable {
    case preparing
    case transferring
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// A file transfer as the island sees it. Byte counts are present only when the
/// transport measured them; AirDrop exposes state changes but no bytes, so its
/// transfers never carry any.
public struct TransferActivitySnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var service: TransferService
    public var direction: TransferDirection
    public var peerName: String
    public var fileCount: Int
    public var completedFiles: Int
    public var currentFilename: String?
    public var bytesTransferred: Int64?
    public var totalBytes: Int64?
    public var bytesPerSecond: Double?
    public var estimatedCompletion: Date?
    public var state: TransferState
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?
    public var canCancel: Bool

    /// Real progress only: bytes when measured, else completed files when the
    /// transport reports them, else nil (indeterminate).
    public var fraction: Double? {
        if state == .completed { return 1 }
        if let bytesTransferred, let totalBytes, totalBytes > 0 {
            return min(1, Double(bytesTransferred) / Double(totalBytes))
        }
        if service == .localSend, fileCount > 0, state == .transferring {
            return min(1, Double(completedFiles) / Double(fileCount))
        }
        return nil
    }

    public var title: String {
        switch state {
        case .preparing: "Preparing \(fileCountDescription)"
        case .transferring: direction == .outgoing ? "Sending \(fileCountDescription)" : "Receiving \(fileCountDescription)"
        case .completed: service == .airDrop ? "Shared with AirDrop" : "Sent \(fileCountDescription)"
        case .failed: "Transfer failed"
        case .cancelled: "Transfer cancelled"
        }
    }

    public var fileCountDescription: String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}

/// Live transfers for the island, plus a short linger for their outcome.
///
/// Transports report into this store; they keep ownership of the real work
/// and supply the cancel handler, so the island's Cancel is the transport's
/// own cancellation rather than a cosmetic removal.
@MainActor
@Observable
public final class TransferActivityStore {
    public static let shared = TransferActivityStore()

    public private(set) var transfers: [TransferActivitySnapshot] = []
    public var onChange: (() -> Void)?
    /// Fired once when a transfer reaches a terminal state.
    public var onFinish: ((TransferActivitySnapshot) -> Void)?

    nonisolated static let maximumLiveTransfers = 6
    nonisolated static let completedLinger: TimeInterval = 2.5
    nonisolated static let failedLinger: TimeInterval = 5

    private var cancelHandlers: [UUID: @MainActor () -> Void] = [:]
    private var estimators: [UUID: TransferRateEstimator] = [:]
    private var lastPublish: [UUID: Date] = [:]
    private var cleanupTask: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func begin(
        service: TransferService,
        direction: TransferDirection = .outgoing,
        peerName: String,
        fileCount: Int,
        totalBytes: Int64? = nil,
        cancel: (@MainActor () -> Void)? = nil,
        now: Date = Date()
    ) -> UUID {
        let id = UUID()
        let snapshot = TransferActivitySnapshot(
            id: id,
            service: service,
            direction: direction,
            peerName: String(peerName.prefix(60)),
            fileCount: max(0, fileCount),
            completedFiles: 0,
            currentFilename: nil,
            bytesTransferred: totalBytes == nil ? nil : 0,
            totalBytes: totalBytes,
            bytesPerSecond: nil,
            estimatedCompletion: nil,
            state: .preparing,
            startedAt: now,
            updatedAt: now,
            finishedAt: nil,
            errorMessage: nil,
            canCancel: cancel != nil
        )
        transfers.append(snapshot)
        if transfers.count > Self.maximumLiveTransfers {
            let overflow = transfers.prefix(transfers.count - Self.maximumLiveTransfers)
            for old in overflow { forget(old.id) }
        }
        if let cancel { cancelHandlers[id] = cancel }
        estimators[id] = TransferRateEstimator()
        onChange?()
        return id
    }

    public func markTransferring(_ id: UUID, now: Date = Date()) {
        mutate(id, now: now, forcePublish: true) { $0.state = .transferring }
    }

    /// Applies a measured update. Byte updates arrive many times a second;
    /// the island is republished at most ~8 times a second.
    public func update(
        _ id: UUID,
        completedFiles: Int? = nil,
        currentFilename: String? = nil,
        bytesTransferred: Int64? = nil,
        totalBytes: Int64? = nil,
        now: Date = Date()
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].state.isTerminal else { return }
        let previousFiles = transfers[index].completedFiles
        var snapshot = transfers[index]
        snapshot.state = .transferring
        if let completedFiles { snapshot.completedFiles = min(max(0, completedFiles), snapshot.fileCount) }
        if let currentFilename { snapshot.currentFilename = String(currentFilename.prefix(120)) }
        if let totalBytes, totalBytes >= 0 { snapshot.totalBytes = totalBytes }
        // Progress callbacks can arrive out of order; bytes never go backwards.
        if let bytesTransferred, bytesTransferred >= 0,
           bytesTransferred >= (snapshot.bytesTransferred ?? 0) {
            snapshot.bytesTransferred = min(bytesTransferred, snapshot.totalBytes ?? .max)
            var estimator = estimators[id] ?? TransferRateEstimator()
            estimator.record(bytes: bytesTransferred, at: now.timeIntervalSinceReferenceDate)
            estimators[id] = estimator
            snapshot.bytesPerSecond = estimator.rate
            if let total = snapshot.totalBytes,
               let remaining = estimator.estimatedSecondsRemaining(total: total) {
                snapshot.estimatedCompletion = now.addingTimeInterval(remaining)
            } else {
                snapshot.estimatedCompletion = nil
            }
        }
        snapshot.updatedAt = now
        transfers[index] = snapshot
        let fileBoundary = snapshot.completedFiles != previousFiles
        let due = lastPublish[id].map { now.timeIntervalSince($0) >= 0.12 } ?? true
        if fileBoundary || due {
            lastPublish[id] = now
            onChange?()
        }
    }

    public func finish(_ id: UUID, error: String? = nil, now: Date = Date()) {
        finish(id, state: error == nil ? .completed : .failed, error: error, now: now)
    }

    public func markCancelled(_ id: UUID, now: Date = Date()) {
        finish(id, state: .cancelled, error: nil, now: now)
    }

    /// Asks the transport to cancel. The transport then reports the outcome.
    public func requestCancel(_ id: UUID) {
        guard let handler = cancelHandlers[id] else { return }
        handler()
    }

    public func dismiss(_ id: UUID) {
        forget(id)
        onChange?()
    }

    // MARK: Internals

    private func finish(_ id: UUID, state: TransferState, error: String?, now: Date) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].state.isTerminal else { return }
        transfers[index].state = state
        transfers[index].finishedAt = now
        transfers[index].updatedAt = now
        transfers[index].errorMessage = error.map { String($0.prefix(160)) }
        transfers[index].estimatedCompletion = nil
        transfers[index].canCancel = false
        if state == .completed {
            transfers[index].completedFiles = transfers[index].fileCount
            if let total = transfers[index].totalBytes { transfers[index].bytesTransferred = total }
        }
        cancelHandlers[id] = nil
        estimators[id] = nil
        let snapshot = transfers[index]
        onChange?()
        onFinish?(snapshot)
        scheduleCleanup()
    }

    private func mutate(
        _ id: UUID,
        now: Date,
        forcePublish: Bool,
        _ body: (inout TransferActivitySnapshot) -> Void
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].state.isTerminal else { return }
        body(&transfers[index])
        transfers[index].updatedAt = now
        if forcePublish { onChange?() }
    }

    private func forget(_ id: UUID) {
        transfers.removeAll { $0.id == id }
        cancelHandlers[id] = nil
        estimators[id] = nil
        lastPublish[id] = nil
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        let deadlines = transfers.compactMap { transfer -> Date? in
            guard let finishedAt = transfer.finishedAt else { return nil }
            let linger = transfer.state == .completed ? Self.completedLinger : Self.failedLinger
            return finishedAt.addingTimeInterval(linger)
        }
        guard let next = deadlines.min() else { return }
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            let before = self.transfers.count
            self.transfers.removeAll { transfer in
                guard let finishedAt = transfer.finishedAt else { return false }
                let linger = transfer.state == .completed ? Self.completedLinger : Self.failedLinger
                return now.timeIntervalSince(finishedAt) >= linger
            }
            if self.transfers.count != before { self.onChange?() }
            self.scheduleCleanup()
        }
    }
}
