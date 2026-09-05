import AppKit
import Foundation
import Observation

/// Local, file-backed clipboard history.
///
/// Same shape as `HistoryRepository` on purpose — a JSON document plus managed
/// sidecar files — and with the same limits enforced in the same place. History
/// once wrote a store past the caps its own loader accepted and lost everything
/// on the next launch; this one budgets before it writes, and a store that
/// arrives over the limit is trimmed rather than discarded.
///
/// A clipboard is a far more sensitive surface than a capture list. Everything
/// here is off unless the user switched it on, transient and concealed
/// clippings are never recorded at all, and the whole store can be dropped in
/// one action.
@MainActor
@Observable
public final class ClipboardStore {
    public static let shared = ClipboardStore()

    nonisolated static let maximumStoreBytes = 8 * 1_024 * 1_024
    nonisolated static let storeByteBudget = 6 * 1_024 * 1_024
    nonisolated static let maximumRecoverableStoreBytes = 32 * 1_024 * 1_024
    nonisolated static let maximumEntryCount = 500
    /// A single clipping past this is remembered as a truncated preview instead
    /// of in full: a copied log file should not evict the rest of the history.
    nonisolated static let maximumTextBytes = 256 * 1_024
    nonisolated static let maximumImageBytes = 8 * 1_024 * 1_024

    public private(set) var entries: [ClipboardEntry] = []
    public private(set) var lastPersistenceError: String?

    private let storeURL: URL
    private let imageDirectory: URL
    private let usesManagedStore: Bool
    private let isEnabled: @MainActor () -> Bool
    private let imageWriter: @Sendable (CGImage, UUID, URL) async -> String?
    private let now: @MainActor () -> Date
    private var clearGeneration: UInt64 = 0
    private var clearedThrough: Date?
    private var saveWorkItem: DispatchWorkItem?
    private var mutationRevision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var lastWriteResultRevision: UInt64 = 0
    @ObservationIgnored private var searchCache: SearchCache?

    private struct SearchCache {
        var query: String
        var revision: UInt64
        var results: [ClipboardEntry]
    }

    private struct WriteRequest: Sendable {
        var entries: [ClipboardEntry]
        var storeURL: URL
        var revision: UInt64
    }

    public convenience init(
        storeURL: URL = AppPaths.clipboardStore,
        imageDirectory: URL = AppPaths.clipboard
    ) {
        self.init(
            storeURL: storeURL,
            imageDirectory: imageDirectory,
            isEnabled: { Preferences.shared.clipboardEnabled }
        )
    }

    init(
        storeURL: URL,
        imageDirectory: URL,
        isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        imageWriter: @escaping @Sendable (CGImage, UUID, URL) async -> String? = { image, id, directory in
            await Task.detached(priority: .utility) {
                ClipboardStore.writeImage(image, id: id, in: directory)
            }.value
        }
    ) {
        self.storeURL = storeURL
        self.imageDirectory = imageDirectory
        self.isEnabled = isEnabled
        self.imageWriter = imageWriter
        self.now = now
        usesManagedStore = storeURL.standardizedFileURL == AppPaths.clipboardStore.standardizedFileURL
        guard !usesManagedStore || AppPaths.ensureDirectories() else { return }
        load()
    }

    // MARK: Queries

    /// Pinned rows first, then newest. Pinning is the only reason a row ever
    /// jumps the queue, and it also exempts it from retention.
    public var ordered: [ClipboardEntry] {
        entries
    }

    public func search(_ query: String) -> [ClipboardEntry] {
        guard !query.isEmpty else { return entries }
        if let searchCache, searchCache.query == query, searchCache.revision == mutationRevision {
            return searchCache.results
        }
        let prepared = HistoryQuery(query)
        let results = entries.filter { $0.matches(prepared) }
        searchCache = SearchCache(query: query, revision: mutationRevision, results: results)
        return results
    }

    public func entry(id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    // MARK: Mutation

    /// Records a clipping, or promotes the existing row when the same content
    /// is copied again.
    ///
    /// `image` is written beside the store; the caller has already bounded it.
    @discardableResult
    public func record(_ entry: ClipboardEntry, image: CGImage? = nil) -> ClipboardEntry? {
        guard isEnabled() else { return nil }

        // Re-copying something already held is the common case, and it should
        // feel like the row moving to the top rather than the list growing a
        // near-identical neighbour.
        if let existingIndex = entries.firstIndex(where: { $0.contentHash == entry.contentHash }) {
            var existing = entries.remove(at: existingIndex)
            existing.createdAt = entry.createdAt
            existing.sourceApplicationName = entry.sourceApplicationName
            existing.sourceApplicationBundleID = entry.sourceApplicationBundleID
            if entry.kind == .files {
                existing.filePaths = entry.filePaths
                existing.fileIdentities = entry.fileIdentities
            }
            insert(existing)
            enforceStoreBudget()
            scheduleSave()
            return existing
        }

        var stored = entry
        if let image {
            stored.imageFilename = writeImage(image, id: stored.id)
            if stored.imageFilename == nil { return nil }
            stored.pixelWidth = image.width
            stored.pixelHeight = image.height
        }
        insert(stored)
        enforceStoreBudget()
        scheduleSave()
        return stored
    }

    /// Image decoding happens in `ClipboardMonitor`; PNG encoding and disk I/O
    /// happen here off the main actor before the completed row is committed.
    @discardableResult
    public func recordImage(_ entry: ClipboardEntry, image: CGImage) async -> ClipboardEntry? {
        // Decoding in the monitor can finish after Clear, before this method
        // even starts. The copy timestamp closes that earlier suspension gap.
        guard isEnabled(), clearedThrough.map({ entry.createdAt > $0 }) ?? true else { return nil }
        if entries.contains(where: { $0.contentHash == entry.contentHash }) {
            return record(entry)
        }

        let directory = imageDirectory
        let generation = clearGeneration
        let filename = await imageWriter(image, entry.id, directory)
        guard let filename else { return nil }
        guard isEnabled(), generation == clearGeneration else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
            return nil
        }

        var stored = entry
        stored.imageFilename = filename
        stored.pixelWidth = image.width
        stored.pixelHeight = image.height
        insert(stored)
        enforceStoreBudget()
        scheduleSave()
        return stored
    }

    /// Pinned rows sort above unpinned ones; within each group, newest first.
    private func insert(_ entry: ClipboardEntry) {
        let index = entries.firstIndex { candidate in
            if entry.isPinned != candidate.isPinned { return entry.isPinned }
            return entry.createdAt >= candidate.createdAt
        }
        entries.insert(entry, at: index ?? entries.count)
    }

    public func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.isPinned = pinned
        insert(entry)
        scheduleSave()
    }

    /// Gives a clipping a short purpose label without changing what will be
    /// pasted. Blank labels restore the content-derived title.
    @discardableResult
    public func setLabel(_ rawLabel: String?, id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let label = Self.sanitizedLabel(rawLabel)
        guard entries[index].label != label else { return true }
        entries[index].label = label
        scheduleSave()
        return true
    }

    nonisolated static func sanitizedLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else { return nil }
        let collapsed = rawLabel
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(80))
    }

    /// Stores only text the user explicitly requested from a clipboard image.
    /// Keeping this separate from recording the image preserves the promise
    /// that clipboard OCR is opt-in rather than a silent background indexer.
    @discardableResult
    public func setRecognizedText(_ rawText: String?, id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].kind == .image else { return false }
        let trimmed = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.flatMap { value in
            value.isEmpty ? nil : String(value.prefix(Self.maximumTextBytes / 4))
        }
        guard entries[index].text != text else { return true }
        entries[index].text = text
        enforceStoreBudget()
        scheduleSave()
        return true
    }

    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        removeManagedImage(for: entry)
        scheduleSave()
    }

    /// Clears everything, or everything the user has not pinned.
    public func clear(keepingPinned: Bool = false) {
        clearGeneration &+= 1
        clearedThrough = now()
        let removed = keepingPinned ? entries.filter { !$0.isPinned } : entries
        entries = keepingPinned ? entries.filter(\.isPinned) : []
        for entry in removed {
            removeManagedImage(for: entry)
        }
        scheduleSave()
    }

    /// Drops rows past the retention window. Pinned rows never expire — that is
    /// what pinning is for.
    @discardableResult
    public func applyRetention(now: Date = Date()) -> Int {
        let days = Preferences.shared.clipboardRetentionDays
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = entries.filter { !$0.isPinned && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return 0 }
        let expiredIDs = Set(expired.map(\.id))
        entries.removeAll { expiredIDs.contains($0.id) }
        for entry in expired {
            removeManagedImage(for: entry)
        }
        scheduleSave()
        Log.history.info("Clipboard retention removed \(expired.count) entries")
        return expired.count
    }

    /// Removes managed images no row still refers to.
    public func removeOrphanedImages() {
        let known = Set(entries.compactMap(\.imageFilename))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where !known.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Budget

    /// The same contract History learned the hard way: whatever is written here
    /// must be readable by the next launch.
    @discardableResult
    private func enforceStoreBudget() -> Bool {
        var changed = false

        if entries.count > Self.maximumEntryCount {
            // Pinned rows are the user's explicit "keep this", so the cap is
            // applied to everything else first and only reaches a pinned row if
            // the user has pinned more than the store can hold.
            var kept: [ClipboardEntry] = []
            var dropped: [ClipboardEntry] = []
            var unpinnedBudget = Self.maximumEntryCount - min(
                entries.count(where: \.isPinned),
                Self.maximumEntryCount
            )
            for entry in entries {
                if entry.isPinned {
                    kept.count < Self.maximumEntryCount ? kept.append(entry) : dropped.append(entry)
                } else if unpinnedBudget > 0 {
                    unpinnedBudget -= 1
                    kept.append(entry)
                } else {
                    dropped.append(entry)
                }
            }
            entries = kept
            for entry in dropped {
                removeManagedImage(for: entry)
            }
            changed = !dropped.isEmpty
        }

        // JSON escaping can expand a clipping far beyond its UTF-8 size (for
        // example, control characters become `\u0000`). Budget the encoded
        // document, not only an estimate, or a store that looks like 6 MB here
        // can exceed the loader's 8 MB contract on disk.
        while Self.encodedStoreBytes(entries) > Self.storeByteBudget {
            let unpinnedText = entries.indices.filter {
                !entries[$0].isPinned && (entries[$0].text?.utf8.count ?? 0) > 4_096
            }
            let textCandidates = unpinnedText.isEmpty
                ? entries.indices.filter { (entries[$0].text?.utf8.count ?? 0) > 4_096 }
                : unpinnedText
            if !textCandidates.isEmpty {
                // Pinned means keep the clipping, not allow one clipping to
                // make the entire store unreadable. Unpinned rows are reduced
                // first; pinned text is shortened only when it is necessary to
                // preserve the store as a whole.
                for index in textCandidates {
                    guard let text = entries[index].text else { continue }
                    let targetCharacters = max(2_048, text.count / 2)
                    entries[index].text = String(text.prefix(targetCharacters)) + "…"
                }
                changed = true
                continue
            }

            // Paths and metadata can still exceed the budget after text has
            // been bounded. Retire the oldest unpinned row first and a pinned
            // row only as the final safety valve.
            let index = entries.lastIndex(where: { !$0.isPinned }) ?? entries.indices.last
            guard let index else { break }
            let entry = entries.remove(at: index)
            removeManagedImage(for: entry)
            changed = true
        }
        return changed
    }

    nonisolated static func estimatedEntryBytes(_ entry: ClipboardEntry) -> Int {
        var total = 420
        total += entry.label?.utf8.count ?? 0
        total += entry.text?.utf8.count ?? 0
        total += entry.sourceApplicationName?.utf8.count ?? 0
        for path in entry.filePaths { total += path.utf8.count }
        return total
    }

    nonisolated static func estimatedStoreBytes(_ entries: [ClipboardEntry]) -> Int {
        entries.reduce(64) { $0 + estimatedEntryBytes($1) }
    }

    nonisolated static func encodedStoreBytes(_ entries: [ClipboardEntry]) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries).count) ?? Int.max
    }

    // MARK: Storage

    private func writeImage(_ image: CGImage, id: UUID) -> String? {
        Self.writeImage(image, id: id, in: imageDirectory)
    }

    private nonisolated static func writeImage(
        _ image: CGImage,
        id: UUID,
        in imageDirectory: URL
    ) -> String? {
        let filename = "\(id.uuidString).png"
        let url = imageDirectory.appendingPathComponent(filename)
        do {
            _ = try ImageExport.write(image, to: url, format: .png, quality: 1, dpiScale: 1)
            // Matches the 0600 the JSON store below sets on itself. A clipboard
            // image is the same class of content as the entry describing it —
            // it should not be the one part of the store readable by everyone
            // on the machine because an atomic write inherited the umask.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return filename
        } catch {
            Log.history.error("Clipboard image write failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func removeManagedImage(for entry: ClipboardEntry) {
        guard let url = entry.imageURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static let writeQueue = DispatchQueue(
        label: "com.notchshot.clipboard.write",
        qos: .utility
    )

    private func scheduleSave() {
        mutationRevision += 1
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveWorkItem = nil
                do {
                    let request = try self.makeWriteRequest()
                    Self.writeQueue.async { [weak self] in
                        do {
                            try Self.performWrite(request.entries, to: request.storeURL)
                            Task { @MainActor [weak self] in
                                self?.recordWriteSuccess(revision: request.revision)
                            }
                        } catch {
                            let message = error.localizedDescription
                            Log.history.error("Clipboard save failed: \(message)")
                            Task { @MainActor [weak self] in
                                self?.recordWriteFailure(message, revision: request.revision)
                            }
                        }
                    }
                } catch {
                    self.recordWriteFailure(
                        error.localizedDescription,
                        revision: self.mutationRevision
                    )
                }
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    public func save() throws {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let request = try makeWriteRequest()
            try Self.writeQueue.sync {
                try Self.performWrite(request.entries, to: request.storeURL)
            }
            recordWriteSuccess(revision: request.revision)
        } catch {
            recordWriteFailure(error.localizedDescription, revision: mutationRevision)
            throw error
        }
    }

    private func makeWriteRequest() throws -> WriteRequest {
        guard !usesManagedStore || AppPaths.owns(storeURL) else {
            throw HistoryPersistenceError.unsafeManagedStore
        }
        return WriteRequest(entries: entries, storeURL: storeURL, revision: mutationRevision)
    }

    private func recordWriteSuccess(revision: UInt64) {
        guard revision >= lastWriteResultRevision else { return }
        lastWriteResultRevision = revision
        persistedRevision = max(persistedRevision, revision)
        lastPersistenceError = nil
    }

    private func recordWriteFailure(_ message: String, revision: UInt64) {
        guard revision >= lastWriteResultRevision else { return }
        lastWriteResultRevision = revision
        lastPersistenceError = message
        Log.history.error("Clipboard save failed: \(message)")
    }

    private nonisolated static func performWrite(
        _ entries: [ClipboardEntry],
        to storeURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        guard data.count <= Self.maximumStoreBytes else {
            throw NotchShotError.exportFailed("Clipboard data exceeded its safe size limit")
        }
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: .atomic)
        // Owner-only: this file holds whatever the user has copied. Applied
        // after the write, because an atomic write replaces the file and the
        // replacement takes its permissions from the temporary one.
        //
        // Not `.completeFileProtection` — that is an iOS data-protection class,
        // and asking for it on macOS fails the whole write with EPERM.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
            let values = try storeURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize <= Self.maximumRecoverableStoreBytes else {
                throw NotchShotError.exportFailed("Clipboard data exceeded its safe size limit")
            }
            let data = try SafeAssetFile.readData(
                at: storeURL,
                maximumBytes: Int64(Self.maximumRecoverableStoreBytes)
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try decoder.decode([ClipboardEntry].self, from: data)
            entries = raw
                .map(Self.sanitizedEntry)
                .sorted { lhs, rhs in
                    if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                    return lhs.createdAt > rhs.createdAt
                }
            if enforceStoreBudget() {
                try? save()
            }
        } catch {
            Log.history.error("Clipboard load failed: \(error.localizedDescription)")
            let backup = storeURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            entries = []
        }
    }

    private nonisolated static func sanitizedEntry(_ entry: ClipboardEntry) -> ClipboardEntry {
        var entry = entry
        entry.label = sanitizedLabel(entry.label)
        // A row can only ever name its own UUID image, so anything else is
        // dropped rather than trusted.
        if entry.imageURL == nil { entry.imageFilename = nil }
        if entry.kind == .image, entry.imageFilename == nil {
            entry.kind = .text
            entry.text = entry.text ?? "Image (no longer available)"
        }
        if let text = entry.text, text.utf8.count > Self.maximumTextBytes {
            entry.text = String(text.prefix(Self.maximumTextBytes / 4))
        }
        entry.filePaths = Array(entry.filePaths.prefix(64))
        if let identities = entry.fileIdentities,
           identities.count >= entry.filePaths.count {
            entry.fileIdentities = Array(identities.prefix(entry.filePaths.count))
        } else if entry.fileIdentities != nil {
            entry.fileIdentities = nil
        }
        if let width = entry.pixelWidth, width < 0 || width > 100_000 { entry.pixelWidth = nil }
        if let height = entry.pixelHeight, height < 0 || height > 100_000 { entry.pixelHeight = nil }
        return entry
    }
}
