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
    /// Exact app-generated caption path. Nil for legacy rows, where ownership
    /// is unknown and the sibling file must be preserved.
    public var captionPath: String?
    /// Only populated when "Search capture text" is on.
    public var indexedText: String?
    /// Optional for backward-compatible decoding of history written before
    /// provenance was tracked. Legacy Application Support files are inferred.
    public var ownership: CaptureAssetOwnership?
    public var externalFileIdentity: ExternalFileIdentity?

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
        self.captionPath = asset.captionURL?.path
        self.indexedText = indexedText
        self.ownership = asset.ownership
        self.externalFileIdentity = asset.externalFileIdentity
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
        let resolvedOwnership = ownership
            ?? (AppPaths.owns(fileURL) ? .managedTemporary : .userDocument)
        return CaptureAsset(
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
            captionURL: captionPath.map { URL(fileURLWithPath: $0) },
            projectURL: projectPath.map { URL(fileURLWithPath: $0) },
            ownership: resolvedOwnership,
            externalFileIdentity: externalFileIdentity
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

        var entry = HistoryEntry(
            asset: asset,
            thumbnailFilename: thumbnailFilename,
            indexedText: indexedText
        )
        let canonicalPrimary = Self.canonicalPath(entry.fileURL)
        let duplicates = entries.filter {
            $0.id != entry.id && Self.canonicalPath($0.fileURL) == canonicalPrimary
        }
        // Preserve exact sidecar ownership when a caller records a newer view
        // of the same physical file without re-supplying its metadata.
        if entry.projectPath == nil {
            entry.projectPath = duplicates.compactMap(\.projectPath).first
        }
        if entry.captionPath == nil {
            entry.captionPath = duplicates.compactMap(\.captionPath).first
        }
        let removed = entries.filter { $0.id == entry.id || duplicates.contains($0) }
        entries.removeAll { candidate in
            candidate.id == entry.id || Self.canonicalPath(candidate.fileURL) == canonicalPrimary
        }
        for old in removed {
            if let thumbnailURL = old.thumbnailURL,
               thumbnailURL.lastPathComponent != entry.thumbnailFilename {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        entries.insert(entry, at: 0)
        Self.removeUnreferencedManagedSidecars(from: removed, retainedEntries: entries)
        scheduleSave()
    }

    public func updateProject(for id: UUID, projectURL: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].projectPath = projectURL?.path
        scheduleSave()
    }

    /// Removes the entry, its thumbnail, and optionally the capture itself.
    public func delete(id: UUID, includingFile: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        let remaining = entries.filter { $0.id != id }
        let protectedPaths = Self.referencedPaths(in: remaining)
        if includingFile {
            guard !protectedPaths.contains(Self.canonicalPath(entry.fileURL)) else {
                throw NotchShotError.exportFailed(
                    "That file is still referenced by another history entry"
                )
            }
            // Complete the user-visible operation before removing its record.
            // Otherwise a Trash failure disappears from the UI while the
            // sensitive file remains on disk.
            try Self.trashCaptureAndCaption(
                at: entry.fileURL,
                captionURL: Self.unsharedURL(entry.captionPath, protectedBy: protectedPaths),
                projectURL: Self.unsharedURL(entry.projectPath, protectedBy: protectedPaths)
            )
        } else {
            // Removing a row must also retire hidden unredacted working files
            // that no other row owns. User documents remain untouched.
            try Self.removeManagedArtifacts(for: entry, excluding: protectedPaths)
        }
        entries.remove(at: index)
        if let thumbnailURL = entry.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        scheduleSave()
    }

    /// Returns files that could not be moved to Trash. Their history rows are
    /// kept so failure is visible and retryable.
    @discardableResult
    public func clearAll(includingFiles: Bool) -> [URL] {
        var failed: [URL] = []
        var retained: [HistoryEntry] = []
        for entry in entries {
            if includingFiles {
                do {
                    try Self.trashCaptureAndCaption(
                        at: entry.fileURL,
                        captionURL: entry.captionPath.map { URL(fileURLWithPath: $0) },
                        projectURL: entry.projectPath.map { URL(fileURLWithPath: $0) }
                    )
                } catch {
                    failed.append(entry.fileURL)
                    retained.append(entry)
                    continue
                }
            } else {
                do {
                    try Self.removeManagedArtifacts(for: entry, excluding: [])
                } catch {
                    failed.append(entry.fileURL)
                    retained.append(entry)
                    continue
                }
            }
            if let thumbnailURL = entry.thumbnailURL {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        entries = retained
        scheduleSave()
        return failed
    }

    /// Trashes captions before their MP4, then the primary capture last. A
    /// failure never unlinks either file permanently; Finder Trash remains the
    /// recovery path.
    public nonisolated static func trashCaptureAndCaption(
        at fileURL: URL,
        captionURL: URL? = nil,
        projectURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        for sidecar in deletableSidecars(
            captionURL: captionURL,
            projectURL: projectURL
        ) where fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.trashItem(at: sidecar, resultingItemURL: nil)
        }
        try fileManager.trashItem(at: fileURL, resultingItemURL: nil)
    }

    nonisolated static func deletableSidecars(
        captionURL: URL?,
        projectURL: URL?
    ) -> [URL] {
        var urls: [URL] = []
        if let captionURL { urls.append(captionURL) }
        // A project contains the untouched source image. Delete it with its
        // capture only when it lives in NotchShot's managed storage; an
        // external project opened from Finder remains the user's document.
        if let projectURL, AppPaths.owns(projectURL) {
            urls.append(projectURL)
        }
        return urls
    }

    /// Drops every stored OCR string. Called when the user turns text search
    /// off, so the setting is retroactive rather than merely forward-looking.
    public func purgeIndexedText() {
        for index in entries.indices {
            entries[index].indexedText = nil
        }
        scheduleSave()
    }

    /// Removes private capture/recording files that have no history owner.
    ///
    /// This is especially important when History is disabled: clipboard-only
    /// and shelf-only files still need a real URL while the app is running, but
    /// they must not accumulate invisibly across launches. User folders,
    /// imported files, editable Projects, and in-progress recordings are never
    /// candidates for this sweep.
    @discardableResult
    public func removeUntrackedManagedFiles() -> Int {
        let fileManager = FileManager.default
        let allowedExtensions = Set(["png", "jpg", "jpeg", "heic", "mp4", "srt"])
        var candidates: [URL] = []
        for directory in [AppPaths.captures, AppPaths.recordings] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: contents.filter { url in
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                return values?.isRegularFile == true
                    && values?.isSymbolicLink != true
                    && allowedExtensions.contains(url.pathExtension.lowercased())
            })
        }

        let untracked = Self.untrackedManagedArtifacts(
            candidates: candidates,
            entries: entries
        )
        for url in untracked {
            try? fileManager.removeItem(at: url)
        }
        if !untracked.isEmpty {
            Log.history.info("Removed \(untracked.count) untracked managed artifacts")
        }
        return untracked.count
    }

    nonisolated static func untrackedManagedArtifacts(
        candidates: [URL],
        entries: [HistoryEntry]
    ) -> [URL] {
        let known = Set(entries.flatMap { entry in
            [entry.fileURL.path, entry.captionPath, entry.projectPath].compactMap { $0 }
        }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return candidates.filter {
            AppPaths.owns($0) && !known.contains($0.standardizedFileURL.path)
        }
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
                // Application Support is on the active home volume, so a
                // missing managed primary is genuinely gone. A user document
                // may simply live on a temporarily disconnected volume and
                // must remain retryable until normal age-based expiry.
                if retentionDeletesManagedFiles(for: entry) {
                    removed.append(entry)
                } else if retentionDays > 0,
                          now.timeIntervalSince(entry.createdAt)
                            > TimeInterval(retentionDays) * 86_400 {
                    removed.append(entry)
                } else {
                    kept.append(entry)
                }
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

        let protectedPaths = Self.referencedPaths(in: kept)
        var successfullyRemoved = Set<UUID>()
        for entry in removed {
            // A user-visible capture can still have an editable project in the
            // app's private Projects directory. Expiry must remove that hidden
            // unredacted copy without touching the user's primary document.
            do {
                try Self.removeManagedArtifacts(for: entry, excluding: protectedPaths)
                if let thumbnailURL = entry.thumbnailURL {
                    try? FileManager.default.removeItem(at: thumbnailURL)
                }
                successfullyRemoved.insert(entry.id)
            } catch {
                // Keep a durable retry row if a private artifact cannot be
                // removed. Losing the row would strand an unredacted project
                // with no visible owner or future cleanup attempt.
                Log.history.error(
                    "Retention could not remove managed artifacts for \(entry.fileURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        entries.removeAll { successfullyRemoved.contains($0.id) }

        Log.history.info("Retention removed \(successfullyRemoved.count) history entries")
        scheduleSave()
        removeOrphanedThumbnails()
        return successfullyRemoved.count
    }

    /// Retention deletes hidden managed working files, but never documents in a
    /// user-selected folder or external references.
    nonisolated static let retentionDeletesFiles = true

    nonisolated static func retentionDeletesManagedFiles(for entry: HistoryEntry) -> Bool {
        let ownership = entry.ownership
            ?? (AppPaths.owns(entry.fileURL) ? .managedTemporary : .userDocument)
        return ownership == .managedTemporary
    }

    private nonisolated static func removeManagedArtifacts(
        for entry: HistoryEntry,
        excluding protectedPaths: Set<String>
    ) throws {
        let fileManager = FileManager.default
        for url in managedArtifactsForRetention(for: entry)
            where !protectedPaths.contains(canonicalPath(url)) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    nonisolated static func managedArtifactsForRetention(
        for entry: HistoryEntry
    ) -> [URL] {
        [
            entry.captionPath.map { URL(fileURLWithPath: $0) },
            entry.projectPath.map { URL(fileURLWithPath: $0) },
            entry.fileURL,
        ].compactMap { $0 }.filter(AppPaths.owns)
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func referencedPaths(in entries: [HistoryEntry]) -> Set<String> {
        Set(entries.flatMap { entry in
            [entry.fileURL.path, entry.captionPath, entry.projectPath].compactMap { $0 }
        }.map { canonicalPath(URL(fileURLWithPath: $0)) })
    }

    private nonisolated static func unsharedURL(
        _ path: String?,
        protectedBy protectedPaths: Set<String>
    ) -> URL? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        return protectedPaths.contains(canonicalPath(url)) ? nil : url
    }

    private nonisolated static func removeUnreferencedManagedSidecars(
        from removed: [HistoryEntry],
        retainedEntries: [HistoryEntry]
    ) {
        let retainedPaths = referencedPaths(in: retainedEntries)
        let fileManager = FileManager.default
        for entry in removed {
            for path in [entry.captionPath, entry.projectPath].compactMap({ $0 }) {
                let url = URL(fileURLWithPath: path)
                guard AppPaths.owns(url),
                      !retainedPaths.contains(canonicalPath(url)),
                      fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    Log.history.error(
                        "Could not remove an unreferenced managed sidecar: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    nonisolated static func coalesceDuplicatePrimaryPaths(
        _ orderedEntries: [HistoryEntry]
    ) -> (entries: [HistoryEntry], duplicates: [HistoryEntry]) {
        var result: [HistoryEntry] = []
        var indexByPath: [String: Int] = [:]
        var usedIDs = Set<UUID>()
        var duplicates: [HistoryEntry] = []

        for entry in orderedEntries {
            let path = canonicalPath(entry.fileURL)
            if let index = indexByPath[path] ?? result.firstIndex(where: { $0.id == entry.id }) {
                if result[index].projectPath == nil {
                    result[index].projectPath = entry.projectPath
                }
                if result[index].captionPath == nil {
                    result[index].captionPath = entry.captionPath
                }
                if result[index].indexedText == nil {
                    result[index].indexedText = entry.indexedText
                }
                duplicates.append(entry)
                continue
            }
            guard usedIDs.insert(entry.id).inserted else {
                duplicates.append(entry)
                continue
            }
            indexByPath[path] = result.count
            result.append(entry)
        }
        return (result, duplicates)
    }

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
            let decoded = try decoder.decode([HistoryEntry].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
            let coalesced = Self.coalesceDuplicatePrimaryPaths(decoded)
            entries = coalesced.entries
            if !coalesced.duplicates.isEmpty {
                for duplicate in coalesced.duplicates {
                    if let thumbnailURL = duplicate.thumbnailURL {
                        try? FileManager.default.removeItem(at: thumbnailURL)
                    }
                }
                Self.removeUnreferencedManagedSidecars(
                    from: coalesced.duplicates,
                    retainedEntries: entries
                )
                save()
            }
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
