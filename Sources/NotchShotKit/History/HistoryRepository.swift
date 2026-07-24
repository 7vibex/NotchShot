import AppKit
import CoreGraphics
import Foundation
import Observation

/// A capture as recorded in history.
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var fileURL: URL
    public var thumbnailFilename: String?
    public var kind: CaptureAssetKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var createdAt: Date
    public var sourceApplication: String?
    public var sourceApplicationName: String?
    public var duration: TimeInterval?
    public var projectPath: String?
    /// Only populated when "Search capture text" is on.
    public var indexedText: String?

    public init(asset: CaptureAsset, thumbnailFilename: String?, indexedText: String?) {
        self.id = asset.id
        self.fileURL = asset.url
        self.thumbnailFilename = thumbnailFilename
        self.kind = asset.kind
        self.pixelWidth = Int(asset.pixelSize.width)
        self.pixelHeight = Int(asset.pixelSize.height)
        self.scale = Double(asset.scale)
        self.createdAt = asset.createdAt
        self.sourceApplication = asset.sourceApplication
        self.sourceApplicationName = asset.sourceApplicationName
        self.duration = asset.duration
        self.projectPath = asset.projectURL?.path
        self.indexedText = indexedText
    }

    public var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public var dimensionsDescription: String { "\(pixelWidth) × \(pixelHeight)" }

    public var thumbnailURL: URL? {
        thumbnailFilename.map { AppPaths.thumbnails.appendingPathComponent($0) }
    }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public var asset: CaptureAsset {
        CaptureAsset(
            id: id,
            url: fileURL,
            kind: kind,
            pixelSize: pixelSize,
            scale: scale,
            createdAt: createdAt,
            sourceApplication: sourceApplication,
            sourceApplicationName: sourceApplicationName,
            duration: duration,
            recognizedText: indexedText,
            projectURL: projectPath.map { URL(fileURLWithPath: $0) }
        )
    }

    /// Matches a free-text query against filename, app, and — only if the user
    /// enabled text indexing — the recognised contents.
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        if fileURL.lastPathComponent.lowercased().contains(needle) { return true }
        if sourceApplicationName?.lowercased().contains(needle) == true { return true }
        if kind.displayName.lowercased().contains(needle) { return true }
        if let indexedText, indexedText.lowercased().contains(needle) { return true }
        return false
    }
}

/// Local, file-backed capture history.
///
/// Stored as a single JSON document rather than a database: the working set is
/// a few thousand rows at most, and a plain file is trivially inspectable and
/// deletable, which matters for something that indexes screen contents.
@MainActor
@Observable
public final class HistoryRepository {
    public static let shared = HistoryRepository()

    public private(set) var entries: [HistoryEntry] = []

    private let storeURL: URL
    private var saveWorkItem: DispatchWorkItem?

    public init(storeURL: URL = AppPaths.historyStore) {
        self.storeURL = storeURL
        AppPaths.ensureDirectories()
        load()
    }

    // MARK: Queries

    public func search(_ query: String) -> [HistoryEntry] {
        entries.filter { $0.matches(query) }
    }

    public func entry(id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    public var recent: [HistoryEntry] {
        Array(entries.prefix(50))
    }

    // MARK: Mutation

    /// Records a capture. `image` is used to make the thumbnail; `text` is only
    /// stored when the user has opted into text search.
    public func record(
        asset: CaptureAsset,
        image: CGImage?,
        recognizedText: String? = nil
    ) {
        guard Preferences.shared.historyEnabled else { return }

        let thumbnailFilename = image.flatMap { writeThumbnail($0, id: asset.id) }
        let indexedText = Preferences.shared.indexesCaptureText ? recognizedText : nil

        let entry = HistoryEntry(
            asset: asset,
            thumbnailFilename: thumbnailFilename,
            indexedText: indexedText
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        scheduleSave()
    }

    public func updateProject(for id: UUID, projectURL: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].projectPath = projectURL?.path
        scheduleSave()
    }

    /// Removes the entry, its thumbnail, and optionally the capture itself.
    public func delete(id: UUID, includingFile: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        if let thumbnailURL = entry.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        if includingFile {
            // Trash rather than unlink, so a mis-tap is recoverable.
            try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
        }
        scheduleSave()
    }

    public func clearAll(includingFiles: Bool) {
        for entry in entries {
            if let thumbnailURL = entry.thumbnailURL {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
            if includingFiles {
                try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
            }
        }
        entries.removeAll()
        scheduleSave()
    }

    /// Drops every stored OCR string. Called when the user turns text search
    /// off, so the setting is retroactive rather than merely forward-looking.
    public func purgeIndexedText() {
        for index in entries.indices {
            entries[index].indexedText = nil
        }
        scheduleSave()
    }

    // MARK: Retention

    /// Splits entries into those retention keeps and those it drops.
    ///
    /// Pure, and separated from the file-system side effects so the policy —
    /// which quietly deletes user-visible rows — can be tested exhaustively.
    ///
    /// - Parameters:
    ///   - retentionDays: `0` means keep forever.
    ///   - fileExists: injected so tests don't need real files on disk.
    public nonisolated static func partitionByRetention(
        _ entries: [HistoryEntry],
        retentionDays: Int,
        now: Date,
        fileExists: (HistoryEntry) -> Bool
    ) -> (kept: [HistoryEntry], removed: [HistoryEntry]) {
        var kept: [HistoryEntry] = []
        var removed: [HistoryEntry] = []

        for entry in entries {
            // A capture the user deleted or moved elsewhere shouldn't linger as
            // a dead row forever.
            guard fileExists(entry) else {
                removed.append(entry)
                continue
            }
            guard retentionDays > 0 else {
                kept.append(entry)
                continue
            }
            let age = now.timeIntervalSince(entry.createdAt)
            if age > TimeInterval(retentionDays) * 86_400 {
                removed.append(entry)
            } else {
                kept.append(entry)
            }
        }
        return (kept, removed)
    }

    /// Applies the retention window and drops rows whose files are gone.
    ///
    /// Returns the number of entries removed.
    @discardableResult
    public func applyRetention(now: Date = Date()) -> Int {
        let (kept, removed) = Self.partitionByRetention(
            entries,
            retentionDays: Preferences.shared.historyRetentionDays,
            now: now,
            fileExists: { $0.fileExists }
        )

        guard !removed.isEmpty else {
            removeOrphanedThumbnails()
            return 0
        }

        for entry in removed {
            if let thumbnailURL = entry.thumbnailURL {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        entries = kept

        Log.history.info("Retention removed \(removed.count) history entries")
        scheduleSave()
        removeOrphanedThumbnails()
        return removed.count
    }

    /// Retention only ever deletes the *record* and its thumbnail; the capture
    /// file on disk belongs to the user, so it is left alone.
    nonisolated static let retentionDeletesFiles = false

    private func removeOrphanedThumbnails() {
        let known = Set(entries.compactMap(\.thumbnailFilename))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.thumbnails,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where !known.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Storage

    private func writeThumbnail(_ image: CGImage, id: UUID) -> String? {
        guard let thumbnail = ImageExport.makeThumbnail(from: image) else { return nil }
        let filename = "\(id.uuidString).png"
        let url = AppPaths.thumbnails.appendingPathComponent(filename)
        do {
            _ = try ImageExport.write(thumbnail, to: url, format: .png, quality: 1, dpiScale: 1)
            return filename
        } catch {
            Log.history.error("Thumbnail write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes are debounced: a burst of captures shouldn't rewrite the whole
    /// store once per shot.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    public func save() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Log.history.error("History save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([HistoryEntry].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            // A corrupt store must not stop the app launching; move it aside so
            // it can be inspected rather than silently overwritten.
            Log.history.error("History load failed: \(error.localizedDescription)")
            let backup = storeURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            entries = []
        }
    }
}
