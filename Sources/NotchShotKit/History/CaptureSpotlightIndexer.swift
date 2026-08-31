@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Opt-in local Spotlight metadata for Capture Library. Files are not copied
/// and OCR enters Spotlight only when the separate text-indexing preference
/// already allowed it into History.
@MainActor
public final class CaptureSpotlightIndexer {
    private final class ItemBox: @unchecked Sendable {
        let items: [CSSearchableItem]
        init(_ items: [CSSearchableItem]) { self.items = items }
    }

    public static let shared = CaptureSpotlightIndexer()
    private nonisolated static let domain = "com.notchshot.capture-library"
    private let index = CSSearchableIndex.default()
    private var desiredItems: [CSSearchableItem] = []
    private var refreshRequested = false
    private var isRefreshing = false

    public func replaceIndex(with entries: [HistoryEntry]) {
        desiredItems = entries.prefix(5_000).map(Self.item)
        requestRefresh()
    }

    public func clear() {
        desiredItems = []
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
        let itemBox = ItemBox(desiredItems)
        let searchableIndex = index
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
            if let error {
                Log.history.error(
                    "Could not refresh Spotlight capture index: \(error.localizedDescription)"
                )
                Task { @MainActor [weak self] in self?.finishRefresh() }
                return
            }
            guard !itemBox.items.isEmpty else {
                Task { @MainActor [weak self] in self?.finishRefresh() }
                return
            }
            searchableIndex.indexSearchableItems(itemBox.items) { error in
                if let error {
                    Log.history.error(
                        "Could not write Spotlight capture index: \(error.localizedDescription)"
                    )
                }
                Task { @MainActor [weak self] in self?.finishRefresh() }
            }
        }
    }

    private func finishRefresh() {
        isRefreshing = false
        if refreshRequested { beginRefresh() }
    }

    private nonisolated static func item(for entry: HistoryEntry) -> CSSearchableItem {
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
