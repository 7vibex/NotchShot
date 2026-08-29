import Foundation
import Observation

public enum AISource: String, Sendable, Codable, CaseIterable, Equatable {
    case claude
    case codex
    case cursor
    case terminal

    public var title: String {
        switch self {
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
        }
    }

    public var accentHex: String {
        switch self {
        case .claude: "#D97757"
        case .codex: "#10A37F"
        case .cursor: "#8B7CFF"
        case .terminal: "#64D2FF"
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
        updatedAt: Date = Date()
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
            updatedAt: activity.updatedAt
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

@MainActor
@Observable
public final class AIActivityMonitor {
    public static let shared = AIActivityMonitor()

    public private(set) var snapshot: ContextSnapshot?
    public private(set) var recentActivities: [AIActivitySnapshot] = []
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let directory: URL
    private let historyURL: URL
    private var mayInterruptMedia = true
    private var pollTask: Task<Void, Never>?
    private var enabledSources = Set(AISource.allCases)

    public init(
        directory: URL = AppPaths.aiActivity,
        historyURL: URL = AppPaths.support.appendingPathComponent("AI Activity History.json")
    ) {
        self.directory = directory
        self.historyURL = historyURL
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
        let newlyTerminal = activities.filter { $0.state.isTerminal }
        var historyChanged = false
        for activity in newlyTerminal.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let existing = recentActivities.first(where: {
                $0.displayIdentifier == activity.displayIdentifier
            }), existing == activity {
                continue
            }
            recentActivities.removeAll { $0.displayIdentifier == activity.displayIdentifier }
            recentActivities.insert(activity, at: 0)
            historyChanged = true
        }
        if recentActivities.count > 20 {
            recentActivities = Array(recentActivities.prefix(20))
            historyChanged = true
        }
        if historyChanged { saveHistory() }
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
        return activityURLs().compactMap(decode)
    }

    func activityURLs() -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // `contentsOfDirectory` returns no meaningful order, so taking the
        // first 32 could fill the budget with stale or invalid files and hide
        // the session the user is actually running. Newest first instead.
        return urls
            .map { url -> (URL, Date) in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return (url, modified ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(32)
            .map(\.0)
    }

    private func decode(_ url: URL) -> AIActivitySnapshot? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard url.pathExtension.lowercased() == "json",
                  AppPaths.owns(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? AIActivityPolicy.maximumFileBytes + 1)
                    <= AIActivityPolicy.maximumFileBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let decoded = try? decoder.decode(AIActivitySnapshot.self, from: data)
        else { return nil }
        return decoded
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
