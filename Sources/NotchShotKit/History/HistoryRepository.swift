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
    /// Despite the legacy name, this is the recorded identity of every new
    /// primary file, not only Finder imports. Existing rows decode it as nil.
    public var externalFileIdentity: ExternalFileIdentity?
    public var captionFileIdentity: ExternalFileIdentity?
    public var projectFileIdentity: ExternalFileIdentity?
    /// User-authored library organization. Optional storage keeps older JSON
    /// documents source-compatible without a migration gate.
    public var tags: [String]?
    public var collectionName: String?
    public var isFavorite: Bool?

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
        self.captionFileIdentity = asset.captionFileIdentity
        self.projectFileIdentity = asset.projectFileIdentity
        self.tags = nil
        self.collectionName = nil
        self.isFavorite = nil
    }

    public var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public var dimensionsDescription: String { "\(pixelWidth) × \(pixelHeight)" }
    public var libraryTags: [String] { tags ?? [] }
    public var favorite: Bool { isFavorite ?? false }

    public var thumbnailURL: URL? {
        HistoryRepository.validatedThumbnailURL(filename: thumbnailFilename, id: id)
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
            captionURL: HistoryRepository.validatedCaptionURL(
                path: captionPath,
                for: fileURL
            ),
            projectURL: projectPath.map { URL(fileURLWithPath: $0) },
            ownership: resolvedOwnership,
            externalFileIdentity: externalFileIdentity,
            captionFileIdentity: captionFileIdentity,
            projectFileIdentity: projectFileIdentity,
            // Persisted nil means legacy/unverified. Reconstructing a row must
            // never bless whatever now happens to occupy its old pathname.
            captureMissingFileIdentities: false
        )
    }

    /// Matches a free-text query against filename, app, and — only if the user
    /// enabled text indexing — the recognised contents.
    public func matches(_ query: String) -> Bool {
        matches(HistoryQuery(query))
    }

    /// The same match against a query that has already been prepared.
    ///
    /// Searching a store row by row with a `String` re-derives the same lowercased
    /// needle once per row, so preparing it once is most of the win here.
    public func matches(_ query: HistoryQuery) -> Bool {
        guard !query.isEmpty else { return true }
        return query.appears(in: fileURL.lastPathComponent)
            || query.appears(in: sourceApplicationName)
            || query.appears(in: kind.displayName)
            || query.appears(in: indexedText)
            || libraryTags.contains { query.appears(in: $0) }
            || query.appears(in: collectionName)
    }
}

/// A history search term, prepared once for a whole pass over the store.
///
/// The obvious spelling — `haystack.lowercased().contains(needle.lowercased())`
/// per field per row — allocates a lowercased copy of every string it looks at,
/// including the recognised-text blob, which is by far the largest thing in a
/// row. Over five thousand rows that was about 900 ms per keystroke, and the
/// history window recomputes its list on every view update, not only on input.
///
/// So the common case is answered by scanning the haystack's UTF-8 bytes with
/// ASCII case folding, which allocates nothing. That is equivalent to the
/// original only when both strings are what this type calls *simple ASCII*:
/// every byte below 0x80, and no carriage return. Under that restriction each
/// byte is exactly one `Character`, and `lowercased()` is exactly the A–Z fold,
/// so the two agree by construction.
///
/// Both halves of the restriction are load-bearing, and `HistorySearchTests`
/// caught each of them. Allowing non-ASCII lets a byte match land inside a
/// grapheme cluster — a filename holding a decomposed "é" is `e` followed by a
/// combining accent, so a byte scan finds "cafe" inside "Café" where the string
/// comparison does not. Carriage return is the one ASCII byte that is not its
/// own `Character`, because CR LF is a single cluster. Anything failing the
/// restriction falls back to the original comparison, which is no worse than
/// before for those rows.
public struct HistoryQuery: Sendable {
    public let text: String
    let isEmpty: Bool
    private let unicodeNeedle: String
    /// Non-nil only when the query itself is pure ASCII, which is what makes the
    /// byte scan applicable at all.
    private let asciiNeedle: [UInt8]?

    public init(_ query: String) {
        text = query
        isEmpty = query.isEmpty
        let lowered = query.lowercased()
        unicodeNeedle = lowered
        let bytes = Array(lowered.utf8)
        asciiNeedle = bytes.allSatisfy(Self.isSimpleASCII) ? bytes : nil
    }

    func appears(in haystack: String?) -> Bool {
        guard let haystack, !haystack.isEmpty else { return false }
        guard let asciiNeedle else {
            return haystack.lowercased().contains(unicodeNeedle)
        }
        // Doubly optional: the outer nil means no contiguous storage, the inner
        // one means the scan declined. Both lead to the same fallback.
        let fastAnswer = haystack.utf8.withContiguousStorageIfAvailable { buffer in
            Self.scan(buffer, for: asciiNeedle)
        } ?? nil
        // A nil means either the haystack is not simple ASCII or the string is
        // not contiguous UTF-8 — a bridged `NSString`, say. Both need the
        // original comparison.
        return fastAnswer ?? haystack.lowercased().contains(unicodeNeedle)
    }

    /// Bytes that stand for exactly one `Character` and fold with plain A–Z
    /// arithmetic. CR is excluded because CR LF is a single grapheme cluster.
    private static func isSimpleASCII(_ byte: UInt8) -> Bool {
        byte < 0x80 && byte != 0x0D
    }

    /// Whether `needle` occurs in `haystack`, or nil when the fast path does not
    /// apply because the haystack is not simple ASCII.
    private static func scan(
        _ haystack: UnsafeBufferPointer<UInt8>,
        for needle: [UInt8]
    ) -> Bool? {
        for byte in haystack where !isSimpleASCII(byte) { return nil }
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        let first = needle[0]
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if fold(haystack[index]) == first {
                var offset = 1
                while offset < needle.count, fold(haystack[index + offset]) == needle[offset] {
                    offset += 1
                }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte &+ 32 : byte
    }
}

/// Local, file-backed capture history.
///
/// Stored as a single JSON document rather than a database: the working set is
/// a few thousand rows at most, and a plain file is trivially inspectable and
/// deletable, which matters for something that indexes screen contents.
public enum HistoryPersistenceError: LocalizedError {
    case unsafeManagedStore

    public var errorDescription: String? {
        switch self {
        case .unsafeManagedStore:
            "NotchShot refused to write History because its managed storage location is unsafe"
        }
    }
}

public enum HistoryLoadOutcome: Sendable, Equatable {
    case missing
    case loaded
    case failed(message: String, backupURL: URL?)

    public var permitsManagedCleanup: Bool {
        if case .failed = self { return false }
        return true
    }
}

@MainActor
@Observable
public final class HistoryRepository {
    public static let shared = HistoryRepository()

    nonisolated static let maximumStoreBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumEntryCount = 10_000

    /// What the *write* side aims for, with headroom under `maximumStoreBytes`
    /// so an estimate that runs slightly low still lands inside the read limit.
    nonisolated static let storeByteBudget = 12 * 1_024 * 1_024

    /// A store between `maximumStoreBytes` and this is over-sized, not corrupt:
    /// it is read, trimmed back inside the budget, and rewritten. Only past this
    /// is the file treated as runaway data and set aside unread.
    nonisolated static let maximumRecoverableStoreBytes = 64 * 1_024 * 1_024

    /// Conservative ceiling for one pretty-printed row. Used by the size
    /// estimate and by byte-pressure eviction, and deliberately larger than the
    /// measured ~400-byte typical row.
    nonisolated static let estimatedStoreRowBytes = 1_100

    public private(set) var entries: [HistoryEntry] = []
    public private(set) var lastPersistenceError: String?
    public private(set) var loadOutcome: HistoryLoadOutcome = .missing
    public var hasUnpersistedChanges: Bool { persistedRevision < mutationRevision }
    public var loadRecoveryMessage: String? {
        guard case .failed = loadOutcome else { return nil }
        return "History could not be loaded, so NotchShot preserved every managed capture and disabled automatic cleanup. The damaged index was quarantined for recovery."
    }

    private let storeURL: URL
    private let usesManagedStore: Bool
    private let managedArtifactDirectories: [URL]
    private let historyEnabledOverride: Bool?
    private let indexesCaptureTextOverride: Bool?
    private var saveWorkItem: DispatchWorkItem?
    private var mutationRevision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var lastWriteResultRevision: UInt64 = 0
    @ObservationIgnored private var searchCache: SearchCache?

    private struct SearchCache {
        var query: String
        var revision: UInt64
        var results: [HistoryEntry]
    }

    private struct WriteRequest: Sendable {
        var entries: [HistoryEntry]
        var storeURL: URL
        var revision: UInt64
    }

    private struct WriteResult: Sendable {
        var entries: [HistoryEntry]
        var revision: UInt64
        var droppedEntries: [HistoryEntry] = []
    }

    public convenience init(storeURL: URL = AppPaths.historyStore) {
        self.init(
            storeURL: storeURL,
            managedArtifactDirectories: [AppPaths.captures, AppPaths.recordings],
            historyEnabled: nil,
            indexesCaptureText: nil
        )
    }

    init(
        storeURL: URL,
        managedArtifactDirectories: [URL],
        historyEnabled: Bool?,
        indexesCaptureText: Bool?
    ) {
        self.storeURL = storeURL
        self.managedArtifactDirectories = managedArtifactDirectories
        historyEnabledOverride = historyEnabled
        indexesCaptureTextOverride = indexesCaptureText
        usesManagedStore = storeURL.standardizedFileURL == AppPaths.historyStore.standardizedFileURL
        guard !usesManagedStore || AppPaths.ensureDirectories() else {
            loadOutcome = .failed(
                message: "Managed History storage is unavailable",
                backupURL: nil
            )
            return
        }
        load()
    }

    // MARK: Queries

    public func search(_ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        if let searchCache,
           searchCache.query == query,
           searchCache.revision == mutationRevision {
            return searchCache.results
        }
        let prepared = HistoryQuery(query)
        let results = entries.filter { $0.matches(prepared) }
        searchCache = SearchCache(
            query: query,
            revision: mutationRevision,
            results: results
        )
        return results
    }

    /// The History browser's visible rows: the cached search results, then the
    /// optional library filters.
    ///
    /// With neither optional filter active the cached array is returned
    /// directly, so the common case allocates nothing on top of the search the
    /// repository already memoises. The filter path preserves the exact
    /// semantics the browser had before (`favoritesOnly` AND the collection
    /// name) and keeps search order.
    public func search(
        _ query: String,
        favoritesOnly: Bool,
        collectionName: String?
    ) -> [HistoryEntry] {
        let results = search(query)
        guard favoritesOnly || collectionName != nil else { return results }
        return results.filter { entry in
            (!favoritesOnly || entry.favorite)
                && (collectionName == nil || entry.collectionName == collectionName)
        }
    }

    public func entry(id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    public var recent: [HistoryEntry] {
        Array(entries.prefix(50))
    }

    public var collectionNames: [String] {
        Array(Set(entries.compactMap(\.collectionName))).sorted()
    }

    public func updateLibraryMetadata(
        id: UUID,
        tags: [String],
        collectionName: String?,
        isFavorite: Bool
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let cleanedTags = Array(Set(tags.compactMap(Self.sanitizedLibraryLabel))).sorted()
        entries[index].tags = cleanedTags.isEmpty ? nil : cleanedTags
        entries[index].collectionName = collectionName.flatMap(Self.sanitizedLibraryLabel)
        entries[index].isFavorite = isFavorite ? true : nil
        searchCache = nil
        scheduleSave()
        syncSpotlightIfEnabled()
    }

    public func setFavorite(id: UUID, _ favorite: Bool) {
        guard let entry = entry(id: id) else { return }
        updateLibraryMetadata(
            id: id,
            tags: entry.libraryTags,
            collectionName: entry.collectionName,
            isFavorite: favorite
        )
    }

    public func refreshSpotlightIndex() {
        syncSpotlightIfEnabled()
    }

    // MARK: Mutation

    /// Records a capture. `image` is used to make the thumbnail; `text` is only
    /// stored when the user has opted into text search.
    ///
    /// Pass `thumbnail` when the caller has already downsampled the same pixels
    /// — the capture flow needs one for the shelf either way, and resampling a
    /// full-screen image twice is tens of milliseconds of duplicated work.
    public func record(
        asset: CaptureAsset,
        image: CGImage?,
        recognizedText: String? = nil,
        thumbnail: CGImage? = nil
    ) {
        guard historyEnabledOverride ?? Preferences.shared.historyEnabled else { return }

        let thumbnailSource = thumbnail ?? image.flatMap { ImageExport.makeThumbnail(from: $0) }
        let thumbnailFilename = thumbnailSource.flatMap { writeThumbnail($0, id: asset.id) }
        let indexesCaptureText = indexesCaptureTextOverride
            ?? Preferences.shared.indexesCaptureText
        let indexedText = indexesCaptureText ? recognizedText : nil

        var entry = HistoryEntry(
            asset: asset,
            thumbnailFilename: thumbnailFilename,
            indexedText: indexedText
        )
        let canonicalPrimary = Self.canonicalPath(entry.fileURL)

        // One pass over the store rather than four. The original spelling — a
        // `filter` for duplicates, a `contains` against it, then a `removeAll`
        // with the same predicate — canonicalised every stored path twice and
        // scanned the duplicate list once per row. Canonicalising a URL is not
        // free, and this runs on the main actor while the capture is waiting.
        var retained: [HistoryEntry] = []
        retained.reserveCapacity(entries.count + 1)
        var removed: [HistoryEntry] = []
        var inheritedProjectPath: String?
        var inheritedCaptionPath: String?
        var inheritedProjectIdentity: ExternalFileIdentity?
        var inheritedCaptionIdentity: ExternalFileIdentity?
        var inheritedTags: [String]?
        var inheritedCollection: String?
        var inheritedFavorite: Bool?

        for candidate in entries {
            let isSameRow = candidate.id == entry.id
            let isSameFile = !isSameRow
                && Self.canonicalPath(candidate.fileURL) == canonicalPrimary
            guard isSameRow || isSameFile else {
                retained.append(candidate)
                continue
            }
            removed.append(candidate)
            // Preserve exact sidecar ownership when a caller records a newer
            // view of the same physical file without re-supplying its metadata.
            // First non-nil wins, as taking `.first` of the duplicates did.
            if isSameFile {
                inheritedProjectPath = inheritedProjectPath ?? candidate.projectPath
                inheritedCaptionPath = inheritedCaptionPath ?? candidate.captionPath
                inheritedProjectIdentity = inheritedProjectIdentity
                    ?? candidate.projectFileIdentity
                inheritedCaptionIdentity = inheritedCaptionIdentity
                    ?? candidate.captionFileIdentity
            }
            inheritedTags = inheritedTags ?? candidate.tags
            inheritedCollection = inheritedCollection ?? candidate.collectionName
            inheritedFavorite = inheritedFavorite ?? candidate.isFavorite
        }

        if entry.projectPath == nil {
            entry.projectPath = inheritedProjectPath
            entry.projectFileIdentity = inheritedProjectIdentity
        }
        if entry.captionPath == nil {
            entry.captionPath = inheritedCaptionPath
            entry.captionFileIdentity = inheritedCaptionIdentity
        }
        entry.tags = inheritedTags
        entry.collectionName = inheritedCollection
        entry.isFavorite = inheritedFavorite

        for old in removed {
            if let thumbnailURL = old.thumbnailURL,
               thumbnailURL.lastPathComponent != entry.thumbnailFilename {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
        retained.insert(entry, at: 0)
        entries = retained
        enforceStoreBudget()
        Self.removeUnreferencedManagedSidecars(from: removed, retainedEntries: entries)
        scheduleSave()
        syncSpotlightIfEnabled()
    }

    /// Keeps the store inside the limits `load()` enforces.
    ///
    /// Both caps used to exist only on the read side, so the app could write a
    /// store it would refuse on the next launch — and a refusal is handled as
    /// corruption, which moved the whole file aside and came back with an empty
    /// History. Budgeting here is what makes the caps a property of the store
    /// rather than a trap sprung at launch.
    ///
    /// Recognised text is shed before any row is. Losing search coverage on old
    /// captures costs the user less than losing the rows those captures are
    /// findable by, and the text is the only field large enough to matter.
    @discardableResult
    private func enforceStoreBudget() -> Bool {
        var changed = false

        if entries.count > Self.maximumEntryCount {
            changed = dropOldestEntries(
                entries.count - Self.maximumEntryCount,
                reason: "row limit"
            ) || changed
        }

        var estimate = Self.estimatedStoreBytes(entries)
        guard estimate > Self.storeByteBudget else { return changed }
        // `entries` is newest-first, so shedding from the end is shedding the
        // oldest recognised text first.
        var shedCount = 0
        for index in entries.indices.reversed() where estimate > Self.storeByteBudget {
            guard let text = entries[index].indexedText else { continue }
            entries[index].indexedText = nil
            estimate -= text.utf8.count
            shedCount += 1
        }
        if shedCount > 0 {
            Log.history.notice(
                "History reached its size budget; dropped indexed text from \(shedCount) older entries"
            )
            changed = true
        }
        // Text alone cannot always bring a store back under the budget. Keep
        // dropping the oldest rows until it can be written, so a store the app
        // can load is always a store it can save — otherwise every later save
        // fails and the captures in this session are lost at quit.
        while estimate > Self.storeByteBudget, entries.count > 1 {
            let excess = estimate - Self.storeByteBudget
            let wholeRows = (excess + Self.estimatedStoreRowBytes - 1) / Self.estimatedStoreRowBytes
            let rowsToDrop = min(entries.count - 1, max(1, wholeRows))
            guard dropOldestEntries(rowsToDrop, reason: "size budget") else { break }
            changed = true
            estimate = Self.estimatedStoreBytes(entries)
        }
        return changed
    }

    /// Removes the oldest `count` rows and retires their managed artifacts,
    /// keeping any row whose private artifacts could not be verified or removed
    /// so its files never lose their visible owner. Returns true when at least
    /// one row was actually removed.
    @discardableResult
    private func dropOldestEntries(_ count: Int, reason: String) -> Bool {
        guard count > 0, !entries.isEmpty else { return false }
        let dropped = Array(entries.suffix(count))
        entries.removeLast(min(count, entries.count))
        // Same treatment expiry gives a row it drops: the hidden managed
        // working files go with it, the user's own documents do not. Skipping
        // this would strand unredacted projects with no owner and no future
        // cleanup pass, since the untracked-file sweep only covers Captures and
        // Recordings.
        let protectedPaths = Self.referencedPaths(in: entries)
        var retainedForRetry: [HistoryEntry] = []
        for entry in dropped {
            do {
                try Self.removeManagedArtifacts(for: entry, excluding: protectedPaths)
                if let thumbnailURL = entry.thumbnailURL {
                    try? FileManager.default.removeItem(at: thumbnailURL)
                }
            } catch {
                // Keep the ownership row if its private artifacts could not be
                // verified or removed; dropping it would strand data with no
                // visible owner and no future retry path.
                retainedForRetry.append(entry)
                Log.history.error(
                    "History \(reason) cleanup was deferred: \(error.localizedDescription)"
                )
            }
        }
        entries.append(contentsOf: retainedForRetry)
        Log.history.notice(
            "History reached its \(reason); removed \(dropped.count - retainedForRetry.count) oldest entries"
        )
        return retainedForRetry.count != dropped.count
    }

    /// Cheap upper bound on what `performWrite` would produce, so the budget can
    /// be applied on the main actor without encoding the store twice per
    /// capture.
    ///
    /// Measured against the real encoder at roughly 400 bytes of pretty-printed
    /// JSON per row including a typical path; the allowance below is larger
    /// than that on purpose, because an estimate that runs high sheds text
    /// slightly early and one that runs low writes a store the next launch has
    /// to repair.
    ///
    /// Deliberately touches only `String.utf8.count`, which is O(1) on native
    /// storage. Reading `fileURL.path` per row would have put a URL-to-String
    /// conversion for the whole store on the capture path — the same cost the
    /// load path was measured and rewritten to avoid.
    private nonisolated static func estimatedStoreBytes(_ entries: [HistoryEntry]) -> Int {
        var total = 64
        for entry in entries {
            // 700 was the pre-recovery heuristic for a pretty-printed row with a
            // typical path. A row with a long filename, sidecar paths, or JSON
            // escaping can exceed that, so budget slightly high: shedding early is
            // cheaper than writing a store the next launch has to repair.
            total += estimatedStoreRowBytes
            total += entry.indexedText?.utf8.count ?? 0
            // JSON escaping (e.g. control chars → \u0000) can expand text beyond
            // utf8.count. A small headroom factor keeps the estimate conservative.
            if let text = entry.indexedText, text.utf8.count > 0 {
                total += text.utf8.count / 10
            }
        }
        return total
    }

    /// Exact encoded size after JSON serialization — used only when the estimate
    /// suggests we may be near the budget, so we don't pay encode cost on every
    /// capture.
    nonisolated static func exactEncodedStoreBytes(_ entries: [HistoryEntry]) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return (try? encoder.encode(entries).count) ?? Int.max
    }

    /// Follows a file that was renamed or moved.
    ///
    /// Deliberately not expressed as `record()` with an updated asset: that path
    /// rebuilds the row from scratch, and with no bitmap to hand it would drop
    /// the thumbnail — deleting the image on disk as a stale duplicate. A row
    /// whose file moved is still the same row.
    ///
    /// A caption is recorded only when the mover supplies both its new
    /// same-stem sibling URL and the identity it verified while moving that
    /// exact file. This method never adopts a same-stem `.srt` that merely
    /// happens to exist at the destination: an unrelated subtitle there must
    /// not become authority to read or delete it later.
    public func updateLocation(
        for id: UUID,
        to url: URL,
        relocatedCaptionURL: URL? = nil,
        relocatedCaptionIdentity: ExternalFileIdentity? = nil
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previous = entries[index].fileURL

        // Validate before mutating any row state, so a failed verification
        // leaves History exactly where it was.
        var captionPath: String?
        var captionIdentity: ExternalFileIdentity?
        if let relocatedCaptionURL {
            guard let relocatedCaptionIdentity,
                  let validated = Self.validatedCaptionURL(
                      path: relocatedCaptionURL.path,
                      for: url
                  ),
                  let current = SafeAssetFile.identity(
                      at: validated,
                      maximumBytes: SafeAssetFile.maximumOwnedBytes
                  ),
                  current == relocatedCaptionIdentity else {
                throw NotchShotError.exportFailed(
                    "The recording's subtitle could not be verified at its new location, so History still points at the previous one."
                )
            }
            captionPath = validated.path
            captionIdentity = current
        }

        entries[index].fileURL = url
        entries[index].captionPath = captionPath
        entries[index].captionFileIdentity = captionIdentity
        // Ownership is a property of where the file lives, not of where it was
        // created: moving a managed capture into a user folder makes it the
        // user's document, and retention must stop treating it as disposable.
        entries[index].ownership = AppPaths.owns(url) ? .managedTemporary : .userDocument
        entries[index].externalFileIdentity = SafeAssetFile.identity(
            at: url,
            maximumBytes: SafeAssetFile.maximumOwnedBytes
        )
        if previous.standardizedFileURL != url.standardizedFileURL {
            Log.history.info("History row followed its file to a new location")
        }
        scheduleSave()
        // Spotlight stores a title and a content URL; without this, a rename
        // leaves search hits pointing at the old name until the next mutation.
        syncSpotlightIfEnabled()
    }

    public func updateProject(for id: UUID, projectURL: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].projectPath = projectURL?.path
        entries[index].projectFileIdentity = projectURL.flatMap {
            SafeAssetFile.fileSystemIdentity(
                at: $0,
                maximumBytes: SafeAssetFile.maximumOwnedBytes,
                allowsDirectory: true
            )
        }
        scheduleSave()
        syncSpotlightIfEnabled()
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
            let captionURL = Self.unsharedURL(entry.captionPath, protectedBy: protectedPaths)
            let projectURL = Self.unsharedURL(entry.projectPath, protectedBy: protectedPaths)
            try Self.trashCaptureAndCaption(
                at: entry.fileURL,
                primaryIdentity: entry.externalFileIdentity,
                captionURL: captionURL,
                captionIdentity: captionURL == nil ? nil : entry.captionFileIdentity,
                projectURL: projectURL,
                projectIdentity: projectURL == nil ? nil : entry.projectFileIdentity,
                toleratingMissingPrimary: true
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
        syncSpotlightIfEnabled()
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
                        primaryIdentity: entry.externalFileIdentity,
                        captionURL: entry.captionPath.map { URL(fileURLWithPath: $0) },
                        captionIdentity: entry.captionFileIdentity,
                        projectURL: entry.projectPath.map { URL(fileURLWithPath: $0) },
                        projectIdentity: entry.projectFileIdentity,
                        toleratingMissingPrimary: true
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
        syncSpotlightIfEnabled()
        return failed
    }

    /// Trashes captions before their MP4, then the primary capture last. A
    /// failure never unlinks either file permanently; Finder Trash remains the
    /// recovery path.
    /// - Parameter toleratingMissingPrimary: when the caller's goal is simply
    ///   that the capture no longer exists — clearing history, retiring a row —
    ///   a primary already deleted in Finder is the desired state, not a
    ///   failure. Sidecars are still retired. Callers that genuinely expect the
    ///   file to be there leave this off and get the strict error.
    public nonisolated static func trashCaptureAndCaption(
        at fileURL: URL,
        primaryIdentity: ExternalFileIdentity? = nil,
        captionURL: URL? = nil,
        captionIdentity: ExternalFileIdentity? = nil,
        projectURL: URL? = nil,
        projectIdentity: ExternalFileIdentity? = nil,
        toleratingMissingPrimary: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let primaryExists = fileManager.fileExists(atPath: fileURL.path)
        guard primaryExists || toleratingMissingPrimary else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        let sidecars = deletableSidecars(
            primaryURL: fileURL,
            captionURL: captionURL,
            projectURL: projectURL
        )

        // Validate every path before moving the first item. That makes the
        // operation all-or-nothing when a stored path has been replaced and
        // prevents an old History row from granting deletion authority over a
        // new file that happens to reuse the same name.
        if primaryExists {
            try SafeAssetFile.requireCurrentItem(
                at: fileURL,
                expectedIdentity: primaryIdentity,
                maximumBytes: SafeAssetFile.maximumOwnedBytes
            )
        }
        for sidecar in sidecars where fileManager.fileExists(atPath: sidecar.path) {
            let isProject = projectURL.map { canonicalPath($0) == canonicalPath(sidecar) } ?? false
            try SafeAssetFile.requireCurrentItem(
                at: sidecar,
                expectedIdentity: isProject ? projectIdentity : captionIdentity,
                maximumBytes: SafeAssetFile.maximumOwnedBytes,
                allowsDirectory: isProject
            )
        }

        for sidecar in sidecars where fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.trashItem(at: sidecar, resultingItemURL: nil)
        }
        guard primaryExists else { return }
        try fileManager.trashItem(at: fileURL, resultingItemURL: nil)
    }

    nonisolated static func deletableSidecars(
        primaryURL: URL,
        captionURL: URL?,
        projectURL: URL?
    ) -> [URL] {
        var urls: [URL] = []
        if let captionURL,
           let validatedCaption = validatedCaptionURL(path: captionURL.path, for: primaryURL) {
            urls.append(validatedCaption)
        }
        // A project contains the untouched source image. Delete it with its
        // capture only when it lives in NotchShot's managed storage; an
        // external project opened from Finder remains the user's document.
        if let projectURL, AppPaths.owns(projectURL) {
            urls.append(projectURL)
        }
        return urls
    }

    nonisolated static func validatedThumbnailURL(filename: String?, id: UUID) -> URL? {
        guard let filename,
              filename == "\(id.uuidString).png" else { return nil }
        // Exact equality with an app-generated UUID filename already excludes
        // separators and traversal spellings. Avoid reparsing every filename as
        // a standalone URL while history loads; physical containment remains
        // enforced by `AppPaths.owns` below.
        let url = AppPaths.thumbnails.appendingPathComponent(filename, isDirectory: false)
        return AppPaths.owns(url) ? url : nil
    }

    /// Captions generated by NotchShot are same-directory, same-stem SRT
    /// siblings of the recording. Persisted metadata cannot authorize any
    /// other path for reading or deletion.
    nonisolated static func validatedCaptionURL(path: String?, for primaryURL: URL) -> URL? {
        guard let path else { return nil }
        let captionURL = URL(fileURLWithPath: path).standardizedFileURL
        let primary = primaryURL.standardizedFileURL
        guard captionURL.pathExtension.lowercased() == "srt",
              captionURL.deletingPathExtension().lastPathComponent
                == primary.deletingPathExtension().lastPathComponent,
              captionURL.deletingLastPathComponent() == primary.deletingLastPathComponent()
        else { return nil }
        return captionURL
    }

    /// Drops every stored OCR string. Called when the user turns text search
    /// off, so the setting is retroactive rather than merely forward-looking.
    public func purgeIndexedText() {
        for index in entries.indices {
            entries[index].indexedText = nil
        }
        scheduleSave()
        // The text also lives in the Spotlight index; clearing only the JSON
        // would leave it searchable until the next mutation or launch.
        syncSpotlightIfEnabled()
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
        guard loadOutcome.permitsManagedCleanup else {
            Log.history.error("Skipped untracked-file cleanup because History did not load safely")
            return 0
        }
        let fileManager = FileManager.default
        let allowedExtensions = Set(["png", "jpg", "jpeg", "heic", "mp4", "srt"])
        var candidates: [URL] = []
        for directory in managedArtifactDirectories {
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
            entries: entries,
            managedRoots: managedArtifactDirectories
        )
        // Finished recordings with History off and “save to disk” off would land
        // in `AppPaths.recordings` as `.managedTemporary` and be deleted here on
        // the next launch — while an *interrupted* recording in the same config
        // is deliberately preserved with an explanation. That asymmetry is the
        // Q1 product question; until it is decided, err on the side of not
        // silently deleting the user's finished take.
        let deletable = untracked.filter { url in
            if url.pathExtension.lowercased() == "mp4",
               !Preferences.shared.historyEnabled {
                return false
            }
            if url.pathExtension.lowercased() == "srt",
               !Preferences.shared.historyEnabled {
                // Captions are siblings of recordings; keep them together.
                return false
            }
            return true
        }
        let preservedRecordings = untracked.count - deletable.count
        if preservedRecordings > 0 {
            Log.history.notice("Preserved \(preservedRecordings) finished recording(s) while History is off; they remain in Recordings until History is cleared or the file is moved")
        }
        for url in deletable {
            try? fileManager.removeItem(at: url)
        }
        if !deletable.isEmpty {
            Log.history.info("Removed \(deletable.count) untracked managed artifacts")
        }
        return untracked.count
    }

    nonisolated static func untrackedManagedArtifacts(
        candidates: [URL],
        entries: [HistoryEntry],
        managedRoots: [URL] = [AppPaths.captures, AppPaths.recordings]
    ) -> [URL] {
        let known = Set(entries.flatMap { entry in
            [entry.fileURL.path, entry.captionPath, entry.projectPath].compactMap { $0 }
        }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let roots = Set(managedRoots.map { $0.standardizedFileURL.path })
        return candidates.filter {
            roots.contains($0.standardizedFileURL.deletingLastPathComponent().path)
                && !known.contains($0.standardizedFileURL.path)
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
        guard loadOutcome.permitsManagedCleanup else {
            Log.history.error("Skipped retention because History did not load safely")
            return 0
        }
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
        let artifacts = managedArtifactRecords(for: entry).filter {
            !protectedPaths.contains(canonicalPath($0.url))
                && fileManager.fileExists(atPath: $0.url.path)
        }
        // As with Trash, verify the complete set before removing any member.
        for artifact in artifacts {
            try SafeAssetFile.requireCurrentItem(
                at: artifact.url,
                expectedIdentity: artifact.identity,
                maximumBytes: SafeAssetFile.maximumOwnedBytes,
                allowsDirectory: artifact.allowsDirectory
            )
        }
        for artifact in artifacts {
            try fileManager.removeItem(at: artifact.url)
        }
    }

    private struct ManagedArtifact: Sendable {
        var url: URL
        var identity: ExternalFileIdentity?
        var allowsDirectory: Bool
    }

    private nonisolated static func managedArtifactRecords(
        for entry: HistoryEntry
    ) -> [ManagedArtifact] {
        var artifacts: [ManagedArtifact] = []
        if let captionURL = validatedCaptionURL(path: entry.captionPath, for: entry.fileURL),
           AppPaths.owns(captionURL) {
            artifacts.append(ManagedArtifact(
                url: captionURL,
                identity: entry.captionFileIdentity,
                allowsDirectory: false
            ))
        }
        if let projectPath = entry.projectPath {
            let projectURL = URL(fileURLWithPath: projectPath)
            if AppPaths.owns(projectURL) {
                artifacts.append(ManagedArtifact(
                    url: projectURL,
                    identity: entry.projectFileIdentity,
                    allowsDirectory: true
                ))
            }
        }
        if AppPaths.owns(entry.fileURL) {
            artifacts.append(ManagedArtifact(
                url: entry.fileURL,
                identity: entry.externalFileIdentity,
                allowsDirectory: false
            ))
        }
        return artifacts
    }

    nonisolated static func managedArtifactsForRetention(
        for entry: HistoryEntry
    ) -> [URL] {
        managedArtifactRecords(for: entry).map(\.url)
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
        // Nothing displaced carries a sidecar, so nothing can be orphaned.
        // Worth checking first: the alternative is canonicalising up to three
        // paths for every row still in the store to build a protected set that
        // is then never consulted, and recording a brand new capture — the
        // common case — displaces nothing at all.
        let candidates = removed.flatMap { entry in
            [entry.captionPath, entry.projectPath].compactMap { $0 }
        }
        guard !candidates.isEmpty else { return }

        let retainedPaths = referencedPaths(in: retainedEntries)
        let fileManager = FileManager.default
        for entry in removed {
            let sidecars = managedArtifactRecords(for: entry).filter {
                canonicalPath($0.url) != canonicalPath(entry.fileURL)
            }
            for sidecar in sidecars {
                let url = sidecar.url
                guard AppPaths.owns(url),
                      !retainedPaths.contains(canonicalPath(url)),
                      fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try SafeAssetFile.requireCurrentItem(
                        at: url,
                        expectedIdentity: sidecar.identity,
                        maximumBytes: SafeAssetFile.maximumOwnedBytes,
                        allowsDirectory: sidecar.allowsDirectory
                    )
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
        result.reserveCapacity(orderedEntries.count)
        var indexByPath: [String: Int] = [:]
        // Rows are only ever appended here, and only ever mutated in place, so a
        // recorded index stays valid. That is what lets this replace the linear
        // `firstIndex(where:)` this loop used to fall back on for every row with
        // an unseen path — which is every row in a healthy store, making the
        // whole coalesce quadratic and dominating the time to load history.
        var indexByID: [UUID: Int] = [:]
        var usedIDs = Set<UUID>()
        var duplicates: [HistoryEntry] = []

        for entry in orderedEntries {
            let path = canonicalPath(entry.fileURL)
            if let index = indexByPath[path] ?? indexByID[entry.id] {
                if result[index].projectPath == nil {
                    result[index].projectPath = entry.projectPath
                    result[index].projectFileIdentity = entry.projectFileIdentity
                }
                if result[index].captionPath == nil {
                    result[index].captionPath = entry.captionPath
                    result[index].captionFileIdentity = entry.captionFileIdentity
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
            indexByID[entry.id] = result.count
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

    /// `thumbnail` is already downsampled by the time it arrives here.
    private func writeThumbnail(_ thumbnail: CGImage, id: UUID) -> String? {
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

    /// Every write to the store goes through here, in order.
    ///
    /// Serialising them is what lets the debounced save encode off the main
    /// actor while `save()` stays synchronous: a blocking save enqueued behind
    /// a background one still lands after it, so the last write to be requested
    /// is the last to reach disk. Termination depends on that — `save()` is
    /// called from `applicationShouldTerminate`, and a store written from a
    /// snapshot taken before the final capture would silently lose it.
    private static let writeQueue = DispatchQueue(
        label: "com.notchshot.history.write",
        qos: .utility
    )

    /// Writes are debounced: a burst of captures shouldn't rewrite the whole
    /// store once per shot.
    ///
    /// Encoding is the expensive half — about 45 ms for a five-thousand row
    /// store, against 4 ms to write the bytes — and it used to run on the main
    /// actor, landing as a hitch shortly after each capture. Only the snapshot
    /// happens here now; the array is copy-on-write, so taking it is cheap.
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
                            let result = try Self.performWrite(request)
                            Task { @MainActor [weak self] in
                                self?.recordWriteSuccess(result)
                            }
                        } catch {
                            let message = error.localizedDescription
                            Log.history.error("History save failed: \(message)")
                            Task { @MainActor [weak self] in
                                self?.recordWriteFailure(message, revision: request.revision)
                            }
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    Log.history.error("History save failed: \(message)")
                    self.recordWriteFailure(message, revision: self.mutationRevision)
                }
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Writes the store and does not return until it is on disk. Failures are
    /// retained as observable dirty state and thrown to the caller; returning
    /// normally is therefore a durability guarantee.
    public func save() throws {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let request: WriteRequest
        do {
            request = try makeWriteRequest()
            // Blocking, and behind anything the debounced path already queued.
            let result = try Self.writeQueue.sync { try Self.performWrite(request) }
            recordWriteSuccess(result)
        } catch {
            let message = error.localizedDescription
            Log.history.error("History save failed: \(message)")
            recordWriteFailure(message, revision: mutationRevision)
            throw error
        }
    }

    /// The main-actor half: check the destination, snapshot the rows.
    private func makeWriteRequest() throws -> WriteRequest {
        guard !usesManagedStore || AppPaths.owns(storeURL) else {
            throw HistoryPersistenceError.unsafeManagedStore
        }
        return WriteRequest(entries: entries, storeURL: storeURL, revision: mutationRevision)
    }

    private func recordWriteSuccess(_ result: WriteResult) {
        guard result.revision >= lastWriteResultRevision else { return }
        lastWriteResultRevision = result.revision
        // `performWrite` can shed indexed text after exact JSON encoding. When
        // no newer mutation exists, mirror that normalized snapshot in memory
        // so a later unrelated save cannot restore data the durable store had
        // to discard to remain loadable.
        if result.revision == mutationRevision, result.entries != entries {
            entries = result.entries
            searchCache = nil
        }
        if !result.droppedEntries.isEmpty {
            // `performWrite` had to drop the oldest rows to keep the store
            // under its read cap. Retire their managed artifacts now, on the
            // main actor, the same way a row-cap drop does.
            let protectedPaths = Self.referencedPaths(in: entries)
            for entry in result.droppedEntries {
                do {
                    try Self.removeManagedArtifacts(for: entry, excluding: protectedPaths)
                    if let thumbnailURL = entry.thumbnailURL {
                        try? FileManager.default.removeItem(at: thumbnailURL)
                    }
                } catch {
                    Log.history.error(
                        "History size-limit cleanup was deferred: \(error.localizedDescription)"
                    )
                }
            }
            Log.history.notice(
                "History exceeded its write limit; removed \(result.droppedEntries.count) oldest entries"
            )
        }
        persistedRevision = max(persistedRevision, result.revision)
        lastPersistenceError = nil
    }

    private func recordWriteFailure(_ message: String, revision: UInt64) {
        guard revision >= lastWriteResultRevision else { return }
        lastWriteResultRevision = revision
        lastPersistenceError = message
    }

    private nonisolated static func performWrite(_ request: WriteRequest) throws -> WriteResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        var entriesToWrite = request.entries
        var droppedEntries: [HistoryEntry] = []
        var data = try encoder.encode(entriesToWrite)
        // If the heuristic budget under-counted (long paths, JSON escaping), the
        // encoded data can still exceed the loader's 16 MB cap. Shed oldest
        // indexedText and re-encode rather than writing a store the next launch
        // must immediately trim and rewrite.
        if data.count > Self.maximumStoreBytes {
            // Drop the stored OCR text in one pass and encode once. Shedding a
            // single row per encode re-encoded the whole store every iteration,
            // which made the launch/quit repair path quadratic on big stores.
            var shed = 0
            for index in entriesToWrite.indices.reversed() where entriesToWrite[index].indexedText != nil {
                entriesToWrite[index].indexedText = nil
                shed += 1
            }
            if shed > 0 {
                data = try encoder.encode(entriesToWrite)
                Log.history.notice("History write exceeded size cap; dropped indexed text from \(shed) entries before writing")
            }
            // The main-actor estimate can under-count unusual rows (a very long
            // path or library tag). Drop the oldest rows here too, then hand
            // them back so their artifacts are retired — a store the app could
            // load must always be one it can write, or every later save fails
            // and the session's captures are lost at quit.
            while data.count > Self.maximumStoreBytes, entriesToWrite.count > 1 {
                let averageRowBytes = max(1, data.count / max(1, entriesToWrite.count))
                let excess = data.count - Self.maximumStoreBytes
                let dropCount = min(
                    entriesToWrite.count - 1,
                    max(1, (excess + averageRowBytes - 1) / averageRowBytes)
                )
                droppedEntries.append(contentsOf: entriesToWrite.suffix(dropCount))
                entriesToWrite.removeLast(dropCount)
                data = try encoder.encode(entriesToWrite)
            }
            guard data.count <= Self.maximumStoreBytes else {
                throw NotchShotError.exportFailed("History data exceeded its safe size limit even after trimming")
            }
        }
        let storeURL = request.storeURL
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: .atomic)
        // Owner-only, for the same reason the clipboard store is: this file
        // holds the recognized text of every capture. Applied after the write,
        // because an atomic write replaces the file and the replacement takes
        // its permissions from the temporary one — which follows the umask.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
        return WriteResult(
            entries: entriesToWrite,
            revision: request.revision,
            droppedEntries: droppedEntries
        )
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                loadOutcome = .missing
                return
            }
            let values = try storeURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            // Over-sized is not the same as corrupt. A store written by an
            // older build — or by any build before the write side enforced a
            // budget — is read and trimmed rather than set aside, because
            // discarding it loses every row the user still has files for.
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize <= Self.maximumRecoverableStoreBytes else {
                throw NotchShotError.exportFailed("History data exceeded its safe size limit")
            }

            let data = try SafeAssetFile.readData(
                at: storeURL,
                maximumBytes: Int64(Self.maximumRecoverableStoreBytes)
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try decoder.decode([HistoryEntry].self, from: data)
            let decoded = raw.map(Self.sanitizedEntry)
                .sorted { $0.createdAt > $1.createdAt }
            let coalesced = Self.coalesceDuplicatePrimaryPaths(decoded)
            entries = coalesced.entries
            loadOutcome = .loaded
            // Newest rows are kept, and their recognised text is shed before
            // any row is dropped, so an over-budget store degrades to a smaller
            // History rather than to none at all.
            let trimmedOverflow = enforceStoreBudget()
            if trimmedOverflow || !coalesced.duplicates.isEmpty {
                for duplicate in coalesced.duplicates {
                    if let thumbnailURL = duplicate.thumbnailURL {
                        try? FileManager.default.removeItem(at: thumbnailURL)
                    }
                }
                Self.removeUnreferencedManagedSidecars(
                    from: coalesced.duplicates,
                    retainedEntries: entries
                )
                mutationRevision += 1
                do {
                    try save()
                } catch {
                    // The decoded rows remain usable in memory and `save()`
                    // retains dirty/error state for a later retry. A failed
                    // cleanup rewrite does not make the source store corrupt.
                    Log.history.error(
                        "Could not persist coalesced History rows: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            // A corrupt store must not stop the app launching; move it aside so
            // it can be inspected rather than silently overwritten.
            Log.history.error("History load failed: \(error.localizedDescription)")
            let backup = storeURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
            var quarantinedURL: URL?
            do {
                try FileManager.default.moveItem(at: storeURL, to: backup)
                quarantinedURL = backup
            } catch {
                Log.history.error("Could not quarantine damaged History: \(error.localizedDescription)")
            }
            entries = []
            loadOutcome = .failed(
                message: error.localizedDescription,
                backupURL: quarantinedURL
            )
        }
    }

    private func syncSpotlightIfEnabled() {
        guard usesManagedStore else { return }
        if Preferences.shared.indexesCapturesInSpotlight {
            CaptureSpotlightIndexer.shared.replaceIndex(with: entries)
        } else {
            CaptureSpotlightIndexer.shared.clear()
        }
    }

    private nonisolated static func sanitizedLibraryLabel(_ value: String) -> String? {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(80))
    }

    private nonisolated static func sanitizedEntry(_ entry: HistoryEntry) -> HistoryEntry {
        var entry = entry
        if validatedThumbnailURL(filename: entry.thumbnailFilename, id: entry.id) == nil {
            entry.thumbnailFilename = nil
        }
        let sanitizedCaption = validatedCaptionURL(path: entry.captionPath, for: entry.fileURL)
        entry.captionPath = sanitizedCaption?.path
        if sanitizedCaption == nil {
            entry.captionFileIdentity = nil
        }
        if let projectPath = entry.projectPath,
           !AppPaths.owns(URL(fileURLWithPath: projectPath)) {
            entry.projectPath = nil
            entry.projectFileIdentity = nil
        }
        entry.pixelWidth = min(max(entry.pixelWidth, 0), 100_000)
        entry.pixelHeight = min(max(entry.pixelHeight, 0), 100_000)
        if !entry.scale.isFinite || entry.scale <= 0 || entry.scale > 16 {
            entry.scale = 1
        }
        if let duration = entry.duration,
           !duration.isFinite || duration < 0 {
            entry.duration = nil
        }
        if entry.ownership == .managedTemporary, !AppPaths.owns(entry.fileURL) {
            entry.ownership = .userDocument
        }
        let tags = Array(Set((entry.tags ?? []).compactMap(sanitizedLibraryLabel))).sorted()
        entry.tags = tags.isEmpty ? nil : tags
        entry.collectionName = entry.collectionName.flatMap(sanitizedLibraryLabel)
        if entry.isFavorite != true { entry.isFavorite = nil }
        return entry
    }
}
