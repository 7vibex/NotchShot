@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The narrow slice of `CSSearchableIndex` the indexer uses, so a test can hold
/// completion handlers and observe exactly which snapshots are consumed.
protocol SpotlightIndexing: AnyObject, Sendable {
    func deleteSearchableItems(
        withDomainIdentifiers domainIdentifiers: [String],
        completionHandler: (@Sendable (Error?) -> Void)?
    )
    func indexSearchableItems(
        _ items: [CSSearchableItem],
        completionHandler: (@Sendable (Error?) -> Void)?
    )
}

extension CSSearchableIndex: SpotlightIndexing {}

/// Opt-in local Spotlight metadata for Capture Library. Files are not copied
/// and OCR enters Spotlight only when the separate text-indexing preference
/// already allowed it into History.
///
/// `replaceIndex(with:)` only records the newest requested snapshot. The
/// expensive `CSSearchableItem` construction happens later, when a refresh is
/// actually about to hand items to the index, so a replacement that arrives
/// while an earlier refresh is in flight never materializes the superseded set.
@MainActor
public final class CaptureSpotlightIndexer {
    public static let shared = CaptureSpotlightIndexer()
    private nonisolated static let domain = "com.notchshot.capture-library"
    private static let maximumItems = 5_000

    private let index: any SpotlightIndexing
    private var desiredEntries: [HistoryEntry] = []
    private var refreshRequested = false
    private var isRefreshing = false

    /// Test seam: number of items materialized by the most recent refresh.
    @ObservationIgnored private(set) var lastMaterializedItemCount = 0

    public convenience init() {
        self.init(index: CSSearchableIndex.default())
    }

    /// Test seam: an injectable index lets a test control completion timing.
    init(index: any SpotlightIndexing) {
        self.index = index
    }

    public func replaceIndex(with entries: [HistoryEntry]) {
        desiredEntries = entries
        requestRefresh()
    }

    public func clear() {
        desiredEntries = []
        requestRefresh()
    }

    private func requestRefresh() {
        refreshRequested = true
        guard !isRefreshing else { return }
        beginRefresh()
    }

    private func beginRefresh() {
        guard refreshRequested else { return }
        refreshRequested = false
        isRefreshing = true
        let searchableIndex = index
        searchableIndex.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { [weak self] error in
            if let error {
                Log.history.error(
                    "Could not refresh Spotlight capture index: \(error.localizedDescription)"
                )
            }
            let deleteFailed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if deleteFailed {
                    self.finishRefresh()
                    return
                }
                // A replacement that arrived while the delete was in flight is
                // already the only snapshot that matters; the domain is empty,
                // so index the newest set directly and never build the one it
                // superseded.
                self.refreshRequested = false
                let items = self.desiredEntries.prefix(Self.maximumItems).map(Self.item)
                self.lastMaterializedItemCount = items.count
                guard !items.isEmpty else {
                    self.finishRefresh()
                    return
                }
                searchableIndex.indexSearchableItems(items) { [weak self] error in
                    if let error {
                        Log.history.error(
                            "Could not write Spotlight capture index: \(error.localizedDescription)"
                        )
                    }
                    Task { @MainActor [weak self] in self?.finishRefresh() }
                }
            }
        }
    }

    private func finishRefresh() {
        isRefreshing = false
        if refreshRequested { beginRefresh() }
    }

    nonisolated static func item(for entry: HistoryEntry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: entry.kind == .recording
            ? .mpeg4Movie : .image)
        attributes.title = entry.fileURL.lastPathComponent
        attributes.contentDescription = [
            entry.kind.displayName,
            entry.sourceApplicationName,
            entry.collectionName,
        ].compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = entry.libraryTags
        attributes.contentCreationDate = entry.createdAt
        attributes.pixelWidth = NSNumber(value: entry.pixelWidth)
        attributes.pixelHeight = NSNumber(value: entry.pixelHeight)
        if let duration = entry.duration {
            attributes.duration = NSNumber(value: duration)
        }
        attributes.textContent = entry.indexedText
        attributes.contentURL = entry.fileURL
        return CSSearchableItem(
            uniqueIdentifier: entry.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }
}
