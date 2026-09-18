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
    /// Files the user asked to send.
    public var fileCount: Int
    /// Files the transport has confirmed as successfully uploaded.
    public var completedFiles: Int
    /// Files the receiver actually accepted, once the transport has learned
    /// it. A completion describes the accepted files, never the selection that
    /// was merely offered.
    public var acceptedFiles: Int?
    public var currentFilename: String?

    /// The count a progress or completion description speaks about: accepted
    /// files when known, otherwise the full request.
    public var effectiveFileCount: Int { acceptedFiles ?? fileCount }
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
        if service == .localSend, effectiveFileCount > 0, state == .transferring {
            return min(1, Double(completedFiles) / Double(effectiveFileCount))
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
        effectiveFileCount == 1 ? "1 file" : "\(effectiveFileCount) files"
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

    /// The throttled mirror of `staged` that views observe. Raw progress
    /// updates land in `staged` and only reach this array when the publication
    /// policy says so, so SwiftUI observation cannot bypass the store's
    /// cadence. Structural events publish immediately.
    public private(set) var transfers: [TransferActivitySnapshot] = []
    public var onChange: (() -> Void)?
    /// Fired once when a transfer reaches a terminal state.
    public var onFinish: ((TransferActivitySnapshot) -> Void)?

    nonisolated static let maximumLiveTransfers = 6
    nonisolated static let completedLinger: TimeInterval = 2.5
    nonisolated static let failedLinger: TimeInterval = 5

    /// Authoritative transfer state. Every mutation lands here first; `transfers`
    /// is replaced from it only on an intended publication.
    @ObservationIgnored private var staged: [TransferActivitySnapshot] = []
    @ObservationIgnored private var cancelHandlers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var estimators: [UUID: TransferRateEstimator] = [:]
    @ObservationIgnored private var lastPublish: [UUID: Date] = [:]
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var trailingPublishTask: Task<Void, Never>?
    @ObservationIgnored private var trailingPublishDeadline: Date?
    @ObservationIgnored private var trailingPublishIDs: Set<UUID> = []

    private let completedRetireDelay: TimeInterval
    private let failedRetireDelay: TimeInterval

    public init() {
        completedRetireDelay = Self.completedLinger
        failedRetireDelay = Self.failedLinger
    }

    /// Test seam: production always uses the static linger constants above.
    init(completedLinger: TimeInterval, failedLinger: TimeInterval) {
        completedRetireDelay = completedLinger
        failedRetireDelay = failedLinger
    }

    /// Test seam: the number of live entries in each per-transfer bookkeeping
    /// table. All three must return to zero once a transfer is retired.
    var bookkeepingCounts: (cancelHandlers: Int, estimators: Int, lastPublish: Int) {
        (cancelHandlers.count, estimators.count, lastPublish.count)
    }

    /// Test seam: the authoritative snapshot, which may be newer than the
    /// published `transfers` entry while a progress update is being throttled.
    func stagedSnapshot(_ id: UUID) -> TransferActivitySnapshot? {
        staged.first { $0.id == id }
    }

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
            acceptedFiles: nil,
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
        staged.append(snapshot)
        if staged.count > Self.maximumLiveTransfers {
            retire(staged.prefix(staged.count - Self.maximumLiveTransfers).map(\.id))
        }
        if let cancel { cancelHandlers[id] = cancel }
        estimators[id] = TransferRateEstimator()
        publish()
        return id
    }

    public func markTransferring(_ id: UUID, now: Date = Date()) {
        mutate(id, now: now, forcePublish: true) { $0.state = .transferring }
    }

    /// Narrows the transfer to the files the receiver actually accepted.
    ///
    /// LocalSend learns this from its prepare-upload reply. Recording it keeps
    /// completion from promoting the requested selection to delivered files.
    public func updateAcceptedFiles(_ id: UUID, acceptedFiles: Int, now: Date = Date()) {
        guard let index = staged.firstIndex(where: { $0.id == id }),
              !staged[index].state.isTerminal else { return }
        let bounded = max(0, min(acceptedFiles, staged[index].fileCount))
        guard bounded != staged[index].acceptedFiles else { return }
        staged[index].acceptedFiles = bounded
        staged[index].completedFiles = min(staged[index].completedFiles, bounded)
        staged[index].updatedAt = now
        publish()
    }

    /// Applies a measured update. Byte updates arrive many times a second;
    /// the island is republished at most ~8 times a second.
    ///
    /// Progress callbacks can arrive out of order. Bytes never move backward,
    /// the completed-file count never moves backward, and a late callback for
    /// an earlier file can neither restore that file's name nor make the count
    /// jump back. Terminal snapshots reject progress entirely.
    public func update(
        _ id: UUID,
        completedFiles: Int? = nil,
        currentFilename: String? = nil,
        bytesTransferred: Int64? = nil,
        totalBytes: Int64? = nil,
        now: Date = Date()
    ) {
        guard let index = staged.firstIndex(where: { $0.id == id }),
              !staged[index].state.isTerminal else { return }
        var snapshot = staged[index]
        snapshot.state = .transferring
        var fileBoundary = false
        if let completedFiles {
            let bounded = min(max(0, completedFiles), snapshot.effectiveFileCount)
            if bounded > snapshot.completedFiles {
                snapshot.completedFiles = bounded
                fileBoundary = true
                if let currentFilename { snapshot.currentFilename = String(currentFilename.prefix(120)) }
            } else if bounded == snapshot.completedFiles, let currentFilename {
                snapshot.currentFilename = String(currentFilename.prefix(120))
            }
        } else if let currentFilename {
            snapshot.currentFilename = String(currentFilename.prefix(120))
        }
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
        staged[index] = snapshot
        let due = lastPublish[id].map { now.timeIntervalSince($0) >= 0.12 } ?? true
        if fileBoundary || due {
            lastPublish[id] = now
            publish()
        } else if let last = lastPublish[id] {
            // Trailing edge of the same window: without it, a transfer that
            // stalls would leave the published bytes a window behind the real
            // progress forever.
            scheduleTrailingPublish(for: id, at: last.addingTimeInterval(0.12))
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
        publish()
    }

    // MARK: Internals

    private func finish(_ id: UUID, state: TransferState, error: String?, now: Date) {
        guard let index = staged.firstIndex(where: { $0.id == id }),
              !staged[index].state.isTerminal else { return }
        staged[index].state = state
        staged[index].finishedAt = now
        staged[index].updatedAt = now
        staged[index].errorMessage = error.map { String($0.prefix(160)) }
        staged[index].estimatedCompletion = nil
        staged[index].canCancel = false
        if state == .completed {
            staged[index].completedFiles = staged[index].effectiveFileCount
            if let total = staged[index].totalBytes { staged[index].bytesTransferred = total }
        }
        cancelHandlers[id] = nil
        estimators[id] = nil
        let snapshot = staged[index]
        publish()
        onFinish?(snapshot)
        scheduleCleanup()
    }

    private func mutate(
        _ id: UUID,
        now: Date,
        forcePublish: Bool,
        _ body: (inout TransferActivitySnapshot) -> Void
    ) {
        guard let index = staged.firstIndex(where: { $0.id == id }),
              !staged[index].state.isTerminal else { return }
        body(&staged[index])
        staged[index].updatedAt = now
        if forcePublish { publish() }
    }

    /// Replaces the observable mirror and notifies once. Every path that makes
    /// a change visible to the UI goes through here. Any pending trailing
    /// publication is superseded by this one.
    private func publish() {
        trailingPublishTask?.cancel()
        trailingPublishTask = nil
        trailingPublishDeadline = nil
        trailingPublishIDs.removeAll()
        transfers = staged
        onChange?()
    }

    private func scheduleTrailingPublish(for id: UUID, at deadline: Date) {
        trailingPublishIDs.insert(id)
        if let trailingPublishDeadline, trailingPublishDeadline <= deadline { return }
        trailingPublishDeadline = deadline
        trailingPublishTask?.cancel()
        trailingPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.flushTrailingPublish()
        }
    }

    private func flushTrailingPublish() {
        guard !trailingPublishIDs.isEmpty else { return }
        trailingPublishTask = nil
        trailingPublishDeadline = nil
        let now = Date()
        for id in trailingPublishIDs where staged.contains(where: { $0.id == id }) {
            lastPublish[id] = now
        }
        trailingPublishIDs.removeAll()
        transfers = staged
        onChange?()
    }

    /// Permanently retires transfers, dropping every per-transfer entry that
    /// would otherwise outlive them. One pass over `staged`, one pass over the
    /// retiring identifiers, regardless of how many are removed.
    private func retire(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let retiring = Set(ids)
        staged.removeAll { retiring.contains($0.id) }
        for id in retiring {
            cancelHandlers[id] = nil
            estimators[id] = nil
            lastPublish[id] = nil
        }
    }

    private func forget(_ id: UUID) {
        retire([id])
    }

    /// Removes every transfer whose linger has elapsed, updating the published
    /// mirror once when anything was removed. Returns `true` when anything was
    /// removed. Internal so tests can drive the same path deterministically.
    @discardableResult
    func retireExpired(now: Date) -> Bool {
        let expired = staged.compactMap { transfer -> UUID? in
            guard let finishedAt = transfer.finishedAt else { return nil }
            let linger = transfer.state == .completed ? completedRetireDelay : failedRetireDelay
            return now.timeIntervalSince(finishedAt) >= linger ? transfer.id : nil
        }
        guard !expired.isEmpty else { return false }
        retire(expired)
        publish()
        return true
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
        let deadlines = staged.compactMap { transfer -> Date? in
            guard let finishedAt = transfer.finishedAt else { return nil }
            let linger = transfer.state == .completed ? completedRetireDelay : failedRetireDelay
            return finishedAt.addingTimeInterval(linger)
        }
        guard let next = deadlines.min() else { return }
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.retireExpired(now: Date())
            self.scheduleCleanup()
        }
    }
}
