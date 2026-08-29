import Foundation
import NotchShotKit

/// Pre-optimisation implementations, kept verbatim so every change can be
/// measured head-to-head against what it replaced.
///
/// Comparing two runs of the suite does not work on a developer machine: load
/// average swings of 30× between runs move every number by more than the
/// optimisations do, and a build finishing in the background is enough to make
/// an improvement look like a regression. Running both versions back to back in
/// one process removes that variable — whatever the machine is doing, it is
/// doing it to both sides.
enum Baselines {

    // MARK: AppPaths.owns, before caching the support URL and the lstat rewrite

    static func ownsBefore(_ url: URL) -> Bool {
        ownsBefore(url, within: supportBefore)
    }

    /// Recomputed per access, as the original property was.
    static var supportBefore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NotchShot", isDirectory: true)
    }

    static func ownsBefore(_ url: URL, within supportRoot: URL) -> Bool {
        let lexicalRoot = supportRoot.standardizedFileURL.path
        let resolvedRoot = resolvedPreservingMissingTailBefore(supportRoot).path
        guard resolvedRoot == lexicalRoot else { return false }
        let candidate = resolvedPreservingMissingTailBefore(url).path
        return candidate == resolvedRoot || candidate.hasPrefix(resolvedRoot + "/")
    }

    static func resolvedPreservingMissingTailBefore(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/" {
            let isSymlink = (try? existingAncestor.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink) == true
            if fileManager.fileExists(atPath: existingAncestor.path) || isSymlink {
                break
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// `HistoryEntry.thumbnailURL`'s validation, before the `owns` rewrite.
    static func validatedThumbnailURLBefore(filename: String?, id: UUID) -> URL? {
        guard let filename,
              filename == "\(id.uuidString).png",
              filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        let url = supportBefore
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent(filename)
        return ownsBefore(url) ? url : nil
    }

    // MARK: HistoryEntry.matches, before the prepared-query rewrite

    static func matchesBefore(_ entry: HistoryEntry, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        if entry.fileURL.lastPathComponent.lowercased().contains(needle) { return true }
        if entry.sourceApplicationName?.lowercased().contains(needle) == true { return true }
        if entry.kind.displayName.lowercased().contains(needle) { return true }
        if let indexedText = entry.indexedText, indexedText.lowercased().contains(needle) { return true }
        return false
    }

    static func searchBefore(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        entries.filter { matchesBefore($0, query) }
    }

    // MARK: Candidate rewrites, measured against each other before one is adopted

    /// Hoists the needle's `lowercased()` out of the per-row loop, and nothing else.
    static func searchHoistedNeedle(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.lowercased()
        return entries.filter { entry in
            if entry.fileURL.lastPathComponent.lowercased().contains(needle) { return true }
            if entry.sourceApplicationName?.lowercased().contains(needle) == true { return true }
            if entry.kind.displayName.lowercased().contains(needle) { return true }
            if let text = entry.indexedText, text.lowercased().contains(needle) { return true }
            return false
        }
    }

    /// Drops the per-field `lowercased()` allocations in favour of a
    /// case-insensitive search over the original strings.
    static func searchCaseInsensitiveRange(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        func hit(_ haystack: String?) -> Bool {
            guard let haystack else { return false }
            return haystack.range(of: query, options: [.caseInsensitive]) != nil
        }
        return entries.filter { entry in
            hit(entry.fileURL.lastPathComponent)
                || hit(entry.sourceApplicationName)
                || hit(entry.kind.displayName)
                || hit(entry.indexedText)
        }
    }

    /// An independent spelling of the production matcher's safe two-pass
    /// algorithm. It guards the benchmark's correctness while the repository
    /// cache measures repeated-query behavior separately.
    static func searchSafeReference(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        let lowered = query.lowercased()
        let needleBytes = Array(lowered.utf8)
        let asciiNeedle = needleBytes.allSatisfy(isSimpleASCII) ? needleBytes : nil

        func hit(_ haystack: String?) -> Bool {
            guard let haystack, !haystack.isEmpty else { return false }
            guard let asciiNeedle else {
                return haystack.lowercased().contains(lowered)
            }
            let answer = haystack.utf8.withContiguousStorageIfAvailable { buffer -> Bool? in
                for byte in buffer where !isSimpleASCII(byte) { return nil }
                return asciiCaseInsensitiveContains(buffer, asciiNeedle)
            } ?? nil
            return answer ?? haystack.lowercased().contains(lowered)
        }

        return entries.filter { entry in
            hit(entry.fileURL.lastPathComponent)
                || hit(entry.sourceApplicationName)
                || hit(entry.kind.displayName)
                || hit(entry.indexedText)
        }
    }

    /// Case-insensitive search over UTF-8 bytes without proving that the whole
    /// haystack is ASCII. This is only an unsafe performance lower bound; the
    /// production matcher must preserve Unicode grapheme behavior.
    static func searchByteScan(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        let needle = Array(query.lowercased().utf8)
        func hit(_ haystack: String?) -> Bool {
            guard let haystack else { return false }
            return haystack.utf8.withContiguousStorageIfAvailable { buffer in
                asciiCaseInsensitiveContains(buffer, needle)
            } ?? (haystack.lowercased().contains(query.lowercased()))
        }
        return entries.filter { entry in
            hit(entry.fileURL.lastPathComponent)
                || hit(entry.sourceApplicationName)
                || hit(entry.kind.displayName)
                || hit(entry.indexedText)
        }
    }

    private static func asciiCaseInsensitiveContains(
        _ haystack: UnsafeBufferPointer<UInt8>,
        _ needle: [UInt8]
    ) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if folded(haystack[index]) == first {
                var offset = 1
                while offset < needle.count, folded(haystack[index + offset]) == needle[offset] {
                    offset += 1
                }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }

    private static func folded(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    private static func isSimpleASCII(_ byte: UInt8) -> Bool {
        byte < 0x80 && byte != 0x0D
    }

    // MARK: The load path's per-row validation

    /// What `load()` spends almost all of its time on: deciding, for every
    /// stored row, whether the recorded thumbnail filename still names a file
    /// inside managed storage.
    static func sanitizeThumbnailsBefore(_ entries: [HistoryEntry]) -> Int {
        entries.reduce(into: 0) { count, entry in
            if validatedThumbnailURLBefore(filename: entry.thumbnailFilename, id: entry.id) != nil {
                count += 1
            }
        }
    }

    static func sanitizeThumbnailsAfter(_ entries: [HistoryEntry]) -> Int {
        entries.reduce(into: 0) { count, entry in
            if entry.thumbnailURL != nil { count += 1 }
        }
    }

    /// The exact thumbnail validation immediately before the redundant URL
    /// parse was removed. `AppPaths.owns` is intentionally still the current
    /// implementation on both sides of this comparison.
    static func sanitizeThumbnailsPrevious(_ entries: [HistoryEntry]) -> Int {
        entries.reduce(into: 0) { count, entry in
            guard let filename = entry.thumbnailFilename,
                  filename == "\(entry.id.uuidString).png",
                  filename == URL(fileURLWithPath: filename).lastPathComponent else { return }
            let url = AppPaths.thumbnails.appendingPathComponent(filename)
            if AppPaths.owns(url) { count += 1 }
        }
    }

    // MARK: `record`'s bookkeeping over the existing store

    /// The original four passes: canonicalise every path to find duplicates,
    /// scan that list again per row to build the removal set, canonicalise
    /// everything a second time to remove, then build a protected-path set out
    /// of the whole surviving store whether or not anything was displaced.
    static func recordBookkeepingBefore(
        _ entries: [HistoryEntry],
        _ entry: HistoryEntry
    ) -> ([HistoryEntry], [HistoryEntry]) {
        let canonicalPrimary = canonicalPath(entry.fileURL)
        let duplicates = entries.filter {
            $0.id != entry.id && canonicalPath($0.fileURL) == canonicalPrimary
        }
        let removed = entries.filter { $0.id == entry.id || duplicates.contains($0) }
        var kept = entries
        kept.removeAll { candidate in
            candidate.id == entry.id || canonicalPath(candidate.fileURL) == canonicalPrimary
        }
        kept.insert(entry, at: 0)
        Benchmark.blackHole(referencedPaths(in: kept))
        return (kept, removed)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func referencedPaths(in entries: [HistoryEntry]) -> Set<String> {
        Set(entries.flatMap { entry in
            [entry.fileURL.path, entry.captionPath, entry.projectPath].compactMap { $0 }
        }.map { canonicalPath(URL(fileURLWithPath: $0)) })
    }

    // MARK: Load-time coalescing of rows sharing a path or an id

    /// The original: a dictionary for the path key, but a linear scan of the
    /// rows accumulated so far for the id key — taken for every row whose path
    /// has not been seen, which in a store without duplicates is every row.
    static func coalesceBefore(
        _ orderedEntries: [HistoryEntry]
    ) -> (entries: [HistoryEntry], duplicates: [HistoryEntry]) {
        var result: [HistoryEntry] = []
        var indexByPath: [String: Int] = [:]
        var usedIDs = Set<UUID>()
        var duplicates: [HistoryEntry] = []

        for entry in orderedEntries {
            let path = canonicalPath(entry.fileURL)
            if let index = indexByPath[path] ?? result.firstIndex(where: { $0.id == entry.id }) {
                if result[index].projectPath == nil { result[index].projectPath = entry.projectPath }
                if result[index].captionPath == nil { result[index].captionPath = entry.captionPath }
                if result[index].indexedText == nil { result[index].indexedText = entry.indexedText }
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

    /// The replacement, mirrored here because the shipped one is internal to
    /// the library. `HistoryCoalesceTests` is what pins the shipped version's
    /// behaviour; this copy exists only so the two algorithms can be timed
    /// against each other in one process.
    static func coalesceAfter(
        _ orderedEntries: [HistoryEntry]
    ) -> (entries: [HistoryEntry], duplicates: [HistoryEntry]) {
        var result: [HistoryEntry] = []
        result.reserveCapacity(orderedEntries.count)
        var indexByPath: [String: Int] = [:]
        var indexByID: [UUID: Int] = [:]
        var usedIDs = Set<UUID>()
        var duplicates: [HistoryEntry] = []

        for entry in orderedEntries {
            let path = canonicalPath(entry.fileURL)
            if let index = indexByPath[path] ?? indexByID[entry.id] {
                if result[index].projectPath == nil { result[index].projectPath = entry.projectPath }
                if result[index].captionPath == nil { result[index].captionPath = entry.captionPath }
                if result[index].indexedText == nil { result[index].indexedText = entry.indexedText }
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

    /// The whole load pipeline as it was: read, decode, validate every row,
    /// sort, coalesce. Mirrors `HistoryRepository.load()` closely enough for an
    /// end-to-end comparison against the shipped loader.
    static func loadBefore(from store: URL) -> Int {
        guard let data = try? Data(contentsOf: store) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([HistoryEntry].self, from: data) else { return 0 }
        let decoded = raw.map { entry -> HistoryEntry in
            var entry = entry
            if validatedThumbnailURLBefore(filename: entry.thumbnailFilename, id: entry.id) == nil {
                entry.thumbnailFilename = nil
            }
            return entry
        }.sorted { $0.createdAt > $1.createdAt }
        return coalesceBefore(decoded).entries.count
    }

    // MARK: The difference kernel's write-back, before and after

    /// The shipped kernel computes its sixteen result bytes in one vector and
    /// then writes them out one lane at a time.
    static func differenceScalarStore(
        _ left: [UInt8],
        _ right: [UInt8],
        threshold: UInt8
    ) -> [UInt8] {
        difference(left, right, threshold: threshold) { output, index, delta in
            for lane in 0 ..< 16 { output[index + lane] = delta[lane] }
        }
    }

    /// One sixteen-byte store instead of sixteen one-byte stores.
    static func differenceVectorStore(
        _ left: [UInt8],
        _ right: [UInt8],
        threshold: UInt8
    ) -> [UInt8] {
        difference(left, right, threshold: threshold) { output, index, delta in
            withUnsafeBytes(of: delta) { source in
                (UnsafeMutableRawPointer(output) + index)
                    .copyMemory(from: source.baseAddress!, byteCount: 16)
            }
        }
    }

    private static func difference(
        _ left: [UInt8],
        _ right: [UInt8],
        threshold: UInt8,
        write: (UnsafeMutablePointer<UInt8>, Int, SIMD16<UInt8>) -> Void
    ) -> [UInt8] {
        var output = [UInt8](repeating: 255, count: left.count)
        let alphaLanes = SIMDMask<SIMD16<Int8>>([
            false, false, false, true, false, false, false, true,
            false, false, false, true, false, false, false, true,
        ])
        let thresholdVector = SIMD16<UInt8>(repeating: threshold)
        let opaque = SIMD16<UInt8>(repeating: 255)
        let zero = SIMD16<UInt8>()

        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    guard let leftBase = leftBuffer.baseAddress,
                          let rightBase = rightBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress else { return }
                    let count = min(outputBuffer.count, min(leftBuffer.count, rightBuffer.count))
                    var index = 0
                    while index + 16 <= count {
                        let lhs = SIMD16<UInt8>(UnsafeBufferPointer(start: leftBase + index, count: 16))
                        let rhs = SIMD16<UInt8>(UnsafeBufferPointer(start: rightBase + index, count: 16))
                        var delta = pointwiseMax(lhs, rhs) &- pointwiseMin(lhs, rhs)
                        if threshold > 0 {
                            delta.replace(with: zero, where: delta .< thresholdVector)
                        }
                        delta.replace(with: opaque, where: alphaLanes)
                        write(outputBase, index, delta)
                        index += 16
                    }
                    while index < count {
                        if index % 4 == 3 {
                            outputBase[index] = 255
                        } else {
                            let lhs = leftBase[index]
                            let rhs = rightBase[index]
                            let delta = lhs > rhs ? lhs - rhs : rhs - lhs
                            outputBase[index] = delta >= threshold ? delta : 0
                        }
                        index += 1
                    }
                }
            }
        }
        return output
    }
}
