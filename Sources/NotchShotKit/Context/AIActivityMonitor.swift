import Foundation
import Observation

public enum AISource: String, Sendable, Codable, CaseIterable, Equatable {
    case claude
    case codex
    case cursor
    case terminal
    /// Runs supervised by the Crewline workspace app, reached over its local
    /// RPC socket rather than a hook reporter.
    case crewline

    public var title: String {
        switch self {
        case .crewline: "Crewline"
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .terminal: "Terminal"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: "c.circle.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .terminal: "terminal.fill"
        case .crewline: "point.3.connected.trianglepath.dotted"
        }
    }

    public var accentHex: String {
        switch self {
        case .claude: "#D97757"
        case .codex: "#10A37F"
        case .cursor: "#8B7CFF"
        case .terminal: "#64D2FF"
        // Crewline's dark-theme brand primary.
        case .crewline: "#5B87F5"
        }
    }
}

public enum AIActivityState: String, Sendable, Codable, CaseIterable, Equatable {
    case working
    case waiting
    case finished
    case failed

    public var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Needs attention"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    public var symbolName: String {
        switch self {
        case .working: "arrow.trianglehead.2.clockwise.rotate.90"
        case .waiting: "person.crop.circle.badge.exclamationmark"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    public var isTerminal: Bool { self == .finished || self == .failed }
}

public enum AIActivityStepState: String, Sendable, Codable, CaseIterable, Equatable {
    case pending
    case working
    case completed
    case failed

    public var symbolName: String {
        switch self {
        case .pending: "circle"
        case .working: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

public struct AIActivityStep: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var state: AIActivityStepState

    public init(id: String = UUID().uuidString, label: String, state: AIActivityStepState) {
        self.id = id
        self.label = label
        self.state = state
    }
}

/// A deliberately small interchange format written by the bundled reporter.
/// It contains only labels a hook explicitly provides; NotchShot never reads an
/// AI app's window, transcript, or private process memory.
public struct AIActivitySnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var source: AISource
    public var state: AIActivityState
    public var title: String
    public var detail: String?
    /// Explicit completion supplied by the adapter, in the closed range 0...1.
    public var progress: Double?
    public var workspace: String?
    public var steps: [AIActivityStep]
    public var startedAt: Date?
    public var updatedAt: Date
    /// The agent behind the run when the source hosts several (Crewline
    /// runs Codex, Claude and others side by side).
    public var agentLabel: String?

    public var displayIdentifier: String { source.rawValue + ":" + id }

    public init(
        id: String,
        source: AISource,
        state: AIActivityState,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        workspace: String? = nil,
        steps: [AIActivityStep] = [],
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        agentLabel: String? = nil
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.title = title
        self.detail = detail
        self.progress = progress
        self.workspace = workspace
        self.steps = steps
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.agentLabel = agentLabel
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt ?? updatedAt))
    }
}

public enum AIActivityPolicy {
    public static let maximumFileBytes = 64 * 1_024
    public static let maximumVisibleActivities = 3
    public static let activeLifetime: TimeInterval = 30 * 60
    public static let terminalLifetime: TimeInterval = 45

    public static func sanitized(_ activity: AIActivitySnapshot) -> AIActivitySnapshot? {
        let title = bounded(activity.title, maximum: 160)
        guard !title.isEmpty else { return nil }
        let identifier = safeIdentifier(activity.id)
        guard !identifier.isEmpty else { return nil }

        return AIActivitySnapshot(
            id: identifier,
            source: activity.source,
            state: activity.state,
            title: title,
            detail: boundedOptional(activity.detail, maximum: 240),
            progress: activity.progress.map { min(max($0, 0), 1) },
            workspace: boundedOptional(activity.workspace, maximum: 240),
            steps: activity.steps.prefix(6).compactMap { step in
                let label = bounded(step.label, maximum: 120)
                guard !label.isEmpty else { return nil }
                let safeStepID = safeIdentifier(step.id)
                return AIActivityStep(
                    id: safeStepID.isEmpty ? "step-\(safeIdentifier(label))" : safeStepID,
                    label: label,
                    state: step.state
                )
            },
            startedAt: activity.startedAt,
            updatedAt: activity.updatedAt,
            agentLabel: boundedOptional(activity.agentLabel, maximum: 40)
        )
    }

    public static func deadline(for activity: AIActivitySnapshot) -> Date {
        activity.updatedAt.addingTimeInterval(
            activity.state.isTerminal ? terminalLifetime : activeLifetime
        )
    }

    public static func visibleActivities(
        from activities: [AIActivitySnapshot],
        now: Date = Date()
    ) -> [AIActivitySnapshot] {
        activities
            .compactMap(sanitized)
            .filter { $0.updatedAt <= now.addingTimeInterval(60) && deadline(for: $0) > now }
            .sorted { lhs, rhs in
                if lhs.state.isTerminal != rhs.state.isTerminal {
                    return !lhs.state.isTerminal
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(maximumVisibleActivities)
            .map { $0 }
    }

    public static func contextSnapshot(
        from activities: [AIActivitySnapshot],
        now: Date = Date(),
        mayInterruptMedia: Bool
    ) -> ContextSnapshot? {
        let visible = visibleActivities(from: activities, now: now)
        guard let headline = visible.first else { return nil }
        let metric = headline.progress.map { "\(Int(($0 * 100).rounded()))%" }
            ?? headline.state.title
        return ContextSnapshot(
            kind: .ai,
            title: "\(headline.source.title) · \(headline.state.title)",
            subtitle: headline.title,
            metric: metric,
            accentHex: headline.source.accentHex,
            aiActivities: visible,
            createdAt: headline.updatedAt,
            expiresAt: visible.map(deadline).min(),
            mayInterruptMedia: mayInterruptMedia
        )
    }

    public static func safeIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }.prefix(64))
    }

    private static func boundedOptional(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let result = bounded(value, maximum: maximum)
        return result.isEmpty ? nil : result
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximum))
    }
}

/// A bounded, newest-first history. Repeated terminal files must converge on
/// the same result even when the poll reads more rows than history can retain.
enum AIActivityHistoryPolicy {
    static let maximumCount = 20

    static func merging(
        _ activities: [AIActivitySnapshot],
        into history: [AIActivitySnapshot]
    ) -> [AIActivitySnapshot] {
        var latestByID: [String: AIActivitySnapshot] = [:]
        for activity in history + activities.filter({ $0.state.isTerminal }) {
            let id = activity.displayIdentifier
            if let existing = latestByID[id], existing.updatedAt > activity.updatedAt {
                continue
            }
            // An incoming correction at the same timestamp is still an update.
            latestByID[id] = activity
        }
        return Array(latestByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            // Directory enumeration order must not churn equal-time rows.
            return lhs.displayIdentifier < rhs.displayIdentifier
        }.prefix(maximumCount))
    }
}

/// What one `loadActivities()` pass actually touched. Diagnostics and tests use
/// this to prove an unchanged directory is not re-decoded every second.
public struct AIActivityLoadStatistics: Sendable, Equatable {
    public var filesConsidered = 0
    public var filesDecoded = 0
    public var filesReused = 0
    public var cacheEvictions = 0

    public init() {}
}

@MainActor
@Observable
public final class AIActivityMonitor {
    public static let shared = AIActivityMonitor()

    public private(set) var snapshot: ContextSnapshot?
    public private(set) var recentActivities: [AIActivitySnapshot] = []
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let directory: URL
    private let historyURL: URL
    private let ownsURL: (URL) -> Bool
    private var mayInterruptMedia = true
    private var pollTask: Task<Void, Never>?
    private var enabledSources = Set(AISource.allCases)

    /// Validated metadata for a file's last decoded (or last rejected) content.
    /// A fresh poll reuses the decoded value only when the path identity, file
    /// kind, size, and modification identity all still match.
    private struct FileSignature: Equatable {
        var size: Int
        var modified: Date?
        var identity: FileIdentity?
    }

    private struct CachedActivity {
        var signature: FileSignature
        /// `nil` records a file that was read and rejected; it is reused too,
        /// so a malformed file is not re-read on every poll.
        var activity: AIActivitySnapshot?
    }

    @ObservationIgnored private var fileCache: [String: CachedActivity] = [:]

    /// Test/benchmark seam: what the most recent `loadActivities()` pass did.
    @ObservationIgnored public private(set) var lastLoadStatistics = AIActivityLoadStatistics()

    public init(
        directory: URL = AppPaths.aiActivity,
        historyURL: URL = AppPaths.support.appendingPathComponent("AI Activity History.json"),
        ownsURL: @escaping (URL) -> Bool = { AppPaths.owns($0) }
    ) {
        self.directory = directory
        self.historyURL = historyURL
        self.ownsURL = ownsURL
        self.recentActivities = Self.loadHistory(from: historyURL)
    }

    public func start(mayInterruptMedia: Bool) {
        self.mayInterruptMedia = mayInterruptMedia
        guard pollTask == nil else {
            refresh()
            return
        }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func setEnabledSources(_ sources: Set<AISource>) {
        enabledSources = sources
        refresh()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        publish(nil)
    }

    public func refresh(now: Date = Date()) {
        let activities = loadActivities().filter { enabledSources.contains($0.source) }
        let updatedHistory = AIActivityHistoryPolicy.merging(activities, into: recentActivities)
        if updatedHistory != recentActivities {
            recentActivities = updatedHistory
            saveHistory()
        }
        var context = AIActivityPolicy.contextSnapshot(
            from: activities,
            now: now,
            mayInterruptMedia: mayInterruptMedia
        )
        context?.aiRecentActivities = Array(
            recentActivities.filter { enabledSources.contains($0.source) }.prefix(5)
        )
        publish(context)
    }

    public func dismiss(_ activity: AIActivitySnapshot) {
        recentActivities.removeAll { $0.displayIdentifier == activity.displayIdentifier }
        for url in activityURLs() {
            guard let decoded = decode(url), decoded.displayIdentifier == activity.displayIdentifier else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    public func clearHistory() {
        recentActivities = []
        try? FileManager.default.removeItem(at: historyURL)
        refresh()
    }

    public func loadActivities() -> [AIActivitySnapshot] {
        var statistics = AIActivityLoadStatistics()
        guard let candidates = Self.newestEntries(in: directory, limit: 32) else {
            fileCache.removeAll()
            lastLoadStatistics = statistics
            return []
        }

        var result: [AIActivitySnapshot] = []
        var livePaths = Set<String>()
        livePaths.reserveCapacity(candidates.count)
        for candidate in candidates {
            statistics.filesConsidered += 1
            let url = candidate.url
            let path = url.standardizedFileURL.path
            livePaths.insert(path)
            // File-kind, size, and ownership are re-validated from this poll's
            // fresh metadata even on a cache hit, so a path swap to a symlink
            // or a different kind of file can never serve a cached value.
            guard url.pathExtension.lowercased() == "json",
                  ownsURL(url),
                  candidate.isReadable,
                  candidate.isRegularFile,
                  !candidate.isSymbolicLink,
                  let size = candidate.size,
                  size >= 0,
                  size <= AIActivityPolicy.maximumFileBytes else {
                fileCache[path] = nil
                continue
            }
            let signature = FileSignature(
                size: size,
                modified: candidate.modified,
                identity: candidate.identity
            )
            if let cached = fileCache[path], cached.signature == signature {
                statistics.filesReused += 1
                if let activity = cached.activity { result.append(activity) }
                continue
            }
            statistics.filesDecoded += 1
            let activity = decodeContents(url)
            fileCache[path] = CachedActivity(signature: signature, activity: activity)
            if let activity { result.append(activity) }
        }

        // Deleted or renamed paths must not keep serving their last value.
        if !fileCache.isEmpty {
            let before = fileCache.count
            fileCache = fileCache.filter { livePaths.contains($0.key) }
            statistics.cacheEvictions = before - fileCache.count
        }
        lastLoadStatistics = statistics
        return result
    }

    func activityURLs() -> [URL] {
        Self.newestEntries(in: directory, limit: 32)?.map(\.url) ?? []
    }

    /// One directory entry as the newest-entry scan read it.
    struct DirectoryEntry {
        var url: URL
        /// False when the file system reported an error for this entry; the
        /// other fields are then unreliable.
        var isReadable: Bool
        var isRegularFile: Bool
        var isSymbolicLink: Bool
        var modified: Date?
        /// The data length, for files.
        var size: Int?
        var identity: FileIdentity?
    }

    /// Which file a path named when it was read: an atomic replacement at the
    /// same path is a different file even with the same size and date.
    struct FileIdentity: Equatable {
        var device: Int32
        var file: UInt64
    }

    /// The newest `limit` entries of `directory`, newest first: the same
    /// entries, in the same order, as listing it with `.skipsHiddenFiles` and
    /// stable-sorting by `contentModificationDate`. Dot files and `UF_HIDDEN`
    /// entries are skipped, a symbolic link ranks by its own date, an entry
    /// whose attributes cannot be read ranks last, and equal dates keep
    /// listing order. `nil` when the directory cannot be listed.
    ///
    /// Listing order means nothing, so taking the first 32 could fill the
    /// budget with stale or invalid files and hide the session the user is
    /// actually running. But nothing prunes the hooks' status files, and this
    /// ranks the couple of thousand a heavy user collects every second, on the
    /// main actor. A URL and a bridged resource dictionary per file was most of
    /// that. One `getattrlistbulk` pass reads only what ranking and validation
    /// need, and keeps a running top `limit`, so only the winners get a URL.
    nonisolated static func newestEntries(in directory: URL, limit: Int) -> [DirectoryEntry]? {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(bitPattern: ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        // Newest first; a new entry goes after every entry at least as new, so
        // ties keep listing order exactly as a stable sort would.
        var newest: [(rank: Double, entry: DirectoryEntry)] = []
        newest.reserveCapacity(limit + 1)
        let unreadable = Date.distantPast.timeIntervalSinceReferenceDate
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
            guard count > 0 else {
                if count < 0 { return nil }
                break
            }
            var start = buffer
            for _ in 0 ..< count {
                let entryStart = start
                start += Int(entryStart.loadUnaligned(as: UInt32.self))
                // Attributes follow in the order getattrlistbulk(2) documents:
                // the returned set, the error, then each group's attributes in
                // ascending bit order, common before file.
                var field = entryStart + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                func has(_ attribute: attrgroup_t) -> Bool { returned.commonattr & attribute != 0 }
                func read<Value>(_: Value.Type) -> Value {
                    defer { field += MemoryLayout<Value>.size }
                    return field.loadUnaligned(as: Value.self)
                }

                var isReadable = true
                if has(attrgroup_t(ATTR_CMN_ERROR)) { isReadable = read(UInt32.self) == 0 }
                guard has(attrgroup_t(ATTR_CMN_NAME)) else { continue }
                let nameField = field
                let nameReference = read(attrreference_t.self)
                let device = has(attrgroup_t(ATTR_CMN_DEVID)) ? read(dev_t.self) : nil
                let type = has(attrgroup_t(ATTR_CMN_OBJTYPE)) ? read(fsobj_type_t.self) : nil
                var rank = unreadable
                var modified: Date?
                if has(attrgroup_t(ATTR_CMN_MODTIME)) {
                    let time = read(timespec.self)
                    // Foundation's own conversion, so equal dates tie here too.
                    rank = Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
                        + 1.0e-9 * Double(time.tv_nsec)
                    modified = Date(timeIntervalSinceReferenceDate: rank)
                }
                if has(attrgroup_t(bitPattern: ATTR_CMN_FLAGS)), read(UInt32.self) & UInt32(UF_HIDDEN) != 0 {
                    continue
                }
                let file = has(attrgroup_t(ATTR_CMN_FILEID)) ? read(UInt64.self) : nil
                let size = returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0
                    ? read(off_t.self) : nil
                if !isReadable { rank = unreadable }

                if newest.count == limit, let last = newest.last, rank <= last.rank { continue }
                let name = (nameField + Int(nameReference.attr_dataoffset))
                    .assumingMemoryBound(to: CChar.self)
                guard name.pointee != CChar(UInt8(ascii: ".")) else { continue }
                let entry = DirectoryEntry(
                    url: directory.appendingPathComponent(
                        String(cString: name),
                        isDirectory: type == fsobj_type_t(VDIR.rawValue)
                    ),
                    isReadable: isReadable,
                    isRegularFile: type == fsobj_type_t(VREG.rawValue),
                    isSymbolicLink: type == fsobj_type_t(VLNK.rawValue),
                    modified: modified,
                    size: size.map(Int.init),
                    identity: device.flatMap { device in file.map { FileIdentity(device: device, file: $0) } }
                )
                let index = newest.firstIndex { $0.rank < rank } ?? newest.endIndex
                newest.insert((rank, entry), at: index)
                if newest.count > limit { newest.removeLast() }
            }
        }
        return newest.map(\.entry)
    }

    private func decodeContents(_ url: URL) -> AIActivitySnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let decoded = try? decoder.decode(AIActivitySnapshot.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func decode(_ url: URL) -> AIActivitySnapshot? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard url.pathExtension.lowercased() == "json",
                  ownsURL(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? AIActivityPolicy.maximumFileBytes + 1)
                    <= AIActivityPolicy.maximumFileBytes
        else { return nil }
        return decodeContents(url)
    }

    private func publish(_ newSnapshot: ContextSnapshot?) {
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
        onSnapshotChange?(newSnapshot)
    }

    private func saveHistory() {
        guard AppPaths.owns(historyURL) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(recentActivities) else { return }
        try? data.write(to: historyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    private static func loadHistory(from url: URL) -> [AIActivitySnapshot] {
        guard AppPaths.owns(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? AIActivityPolicy.maximumFileBytes * 4 + 1) <= AIActivityPolicy.maximumFileBytes * 4,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(((try? decoder.decode([AIActivitySnapshot].self, from: data)) ?? []).prefix(20))
    }
}
