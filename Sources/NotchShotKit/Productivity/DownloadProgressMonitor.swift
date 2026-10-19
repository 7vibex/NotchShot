import Foundation

/// Browser downloads, as the island sees them.
///
/// Safari, Chrome and most other browsers publish an `NSProgress` for each
/// file they are downloading — it is what draws the progress bar on the icon
/// in Finder. Subscribing to the Downloads folder receives those objects
/// directly, so the island shows the browser's own byte counts and can cancel
/// through the browser's own cancellation handler. Nothing polls, and no file
/// is opened or read.
@MainActor
final class DownloadProgressMonitor {
    /// Downloads that finish faster than this never appear: a burst for every
    /// favicon-sized file would be noise.
    nonisolated static let appearanceDelay: Duration = .milliseconds(900)

    private let store: TransferActivityStore
    private var subscriber: Any?
    private var tracked: [ObjectIdentifier: TrackedDownload] = [:]

    private(set) var isRunning = false

    init(store: TransferActivityStore = .shared) {
        self.store = store
    }

    func start(folder: URL? = nil) {
        guard !isRunning,
              let folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        isRunning = true
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            let box = ProgressBox(progress)
            Task { @MainActor in self?.published(box) }
            return {
                Task { @MainActor in self?.unpublished(box) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        for download in tracked.values {
            download.invalidate()
            if let id = download.transferID { store.dismiss(id) }
        }
        tracked.removeAll()
    }

    // MARK: Lifecycle

    private func published(_ box: ProgressBox) {
        let progress = box.progress
        guard isRunning,
              DownloadProgressPolicy.isDownload(kind: progress.kind, operation: progress.fileOperationKind),
              let url = progress.userInfo[.fileURLKey] as? URL else { return }
        let key = ObjectIdentifier(progress)
        guard tracked[key] == nil else { return }
        let download = TrackedDownload(box: box, displayName: DownloadProgressPolicy.displayName(for: url))
        tracked[key] = download
        download.appearanceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.appearanceDelay)
            guard !Task.isCancelled else { return }
            self?.appear(key)
        }
    }

    private func appear(_ key: ObjectIdentifier) {
        guard let download = tracked[key], download.transferID == nil else { return }
        let progress = download.box.progress
        guard !progress.isFinished, !progress.isCancelled else { return }
        let total = DownloadProgressPolicy.byteCount(progress.totalUnitCount)
        let box = download.box
        var cancel: (@MainActor @Sendable () -> Void)?
        if progress.isCancellable {
            cancel = { box.progress.cancel() }
        }
        let id = store.begin(
            service: .download,
            direction: .incoming,
            peerName: download.displayName,
            fileCount: 1,
            totalBytes: total,
            cancel: cancel
        )
        download.transferID = id
        store.markTransferring(id)
        report(download)
        // KVO fires on whichever thread the browser's XPC callback lands on;
        // every update hops to the main actor before touching the store.
        download.observations = [
            progress.observe(\.completedUnitCount) { [weak self] _, _ in
                Task { @MainActor in self?.report(key) }
            },
            progress.observe(\.totalUnitCount) { [weak self] _, _ in
                Task { @MainActor in self?.report(key) }
            },
        ]
    }

    private func report(_ key: ObjectIdentifier) {
        guard let download = tracked[key] else { return }
        report(download)
    }

    private func report(_ download: TrackedDownload) {
        guard let id = download.transferID else { return }
        let progress = download.box.progress
        store.update(
            id,
            currentFilename: download.displayName,
            bytesTransferred: DownloadProgressPolicy.byteCount(progress.completedUnitCount),
            totalBytes: DownloadProgressPolicy.byteCount(progress.totalUnitCount)
        )
    }

    private func unpublished(_ box: ProgressBox) {
        let key = ObjectIdentifier(box.progress)
        guard let download = tracked.removeValue(forKey: key) else { return }
        download.invalidate()
        guard let id = download.transferID else { return }
        report(download)
        let progress = box.progress
        switch DownloadProgressPolicy.outcome(
            isCancelled: progress.isCancelled,
            completed: progress.completedUnitCount,
            total: progress.totalUnitCount
        ) {
        case .completed: store.finish(id)
        case .cancelled: store.markCancelled(id)
        }
    }
}

/// The decisions behind the monitor, kept free of `Progress` so tests can
/// pin them.
enum DownloadProgressPolicy {
    enum Outcome: Equatable {
        case completed
        case cancelled
    }

    /// Suffixes browsers give a file while it is still downloading.
    static let partialSuffixes = ["download", "crdownload", "part", "partial", "opdownload"]

    static func isDownload(kind: ProgressKind?, operation: Progress.FileOperationKind?) -> Bool {
        if let operation { return operation == .downloading }
        return kind == .file
    }

    /// The name the file will have once it lands: Safari's `.download`
    /// bundle and Chrome's `.crdownload` suffix are dropped.
    static func displayName(for url: URL) -> String {
        var name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if partialSuffixes.contains(ext) {
            name = url.deletingPathExtension().lastPathComponent
        }
        return name.isEmpty ? "Download" : name
    }

    /// Browsers report bytes; a negative count means "not known yet".
    static func byteCount(_ units: Int64) -> Int64? {
        units >= 0 ? units : nil
    }

    /// A progress that disappears is a finished download unless it was
    /// cancelled or stopped short of a known size. A stop short of the end —
    /// a paused or failed download — reads as stopped rather than failed,
    /// because the browser alone knows which it was.
    static func outcome(isCancelled: Bool, completed: Int64, total: Int64) -> Outcome {
        if isCancelled { return .cancelled }
        if total > 0, completed < total { return .cancelled }
        return .completed
    }
}

/// `Progress` is thread-safe but not `Sendable`; this carries one across the
/// subscriber's queue hop.
private final class ProgressBox: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

@MainActor
private final class TrackedDownload {
    let box: ProgressBox
    let displayName: String
    var transferID: UUID?
    var appearanceTask: Task<Void, Never>?
    var observations: [NSKeyValueObservation] = []

    init(box: ProgressBox, displayName: String) {
        self.box = box
        self.displayName = displayName
    }

    func invalidate() {
        appearanceTask?.cancel()
        appearanceTask = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
}
