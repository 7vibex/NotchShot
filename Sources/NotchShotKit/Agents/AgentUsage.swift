import Foundation
import NotchShotAIReporterSupport
import Observation

/// One ring in the usage strip: how much of a plan window or of the context
/// window is spent.
public struct AgentUsageMeter: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case fiveHour
        case weekly
        case context

        public var shortTitle: String {
            switch self {
            case .fiveHour: "5h"
            case .weekly: "Week"
            case .context: "Context"
            }
        }

        public var title: String {
            switch self {
            case .fiveHour: "5-hour limit"
            case .weekly: "Weekly limit"
            case .context: "Context window"
            }
        }
    }

    public var kind: Kind
    public var usedPercent: Double
    public var resetsAt: Date?

    public var id: String { kind.rawValue }

    public init(kind: Kind, usedPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }
}

/// The rings for one provider.
public struct AgentUsageGroup: Equatable, Identifiable, Sendable {
    public var source: AISource
    public var label: String
    public var meters: [AgentUsageMeter]
    public var isStale: Bool

    public var id: String { source.rawValue + ":" + label }

    /// The fullest window, for the compact bubble's single ring.
    public var tightest: AgentUsageMeter? {
        meters.filter { $0.kind != .context }.max { $0.usedPercent < $1.usedPercent }
    }
}

public enum AgentUsagePolicy {
    /// A plan window older than its own length says nothing about now.
    static let claudeStaleAfter: TimeInterval = 5 * 60 * 60
    /// Context belongs to a live session; an idle one stops mattering.
    static let contextLifetime: TimeInterval = 30 * 60

    public static func claudeGroup(
        from snapshots: [ClaudeStatusSnapshot],
        now: Date = Date()
    ) -> AgentUsageGroup? {
        let newestFirst = snapshots.sorted { $0.updatedAt > $1.updatedAt }
        var meters: [AgentUsageMeter] = []
        let limits = newestFirst.first { $0.fiveHour != nil || $0.sevenDay != nil }
        if let limits {
            if let window = limits.fiveHour, !(window.resetsAt.map { $0 <= now } ?? false) {
                meters.append(AgentUsageMeter(kind: .fiveHour, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
            if let window = limits.sevenDay, !(window.resetsAt.map { $0 <= now } ?? false) {
                meters.append(AgentUsageMeter(kind: .weekly, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
        }
        if let live = newestFirst.first(where: { $0.contextPercent != nil }),
           now.timeIntervalSince(live.updatedAt) < contextLifetime,
           let context = live.contextPercent {
            meters.append(AgentUsageMeter(kind: .context, usedPercent: context))
        }
        guard !meters.isEmpty else { return nil }
        let stale = limits.map { now.timeIntervalSince($0.updatedAt) > claudeStaleAfter } ?? false
        return AgentUsageGroup(source: .claude, label: "Claude", meters: meters, isStale: stale)
    }

    /// Each live Claude session's model, as its status line names it.
    public static func modelBySession(
        from snapshots: [ClaudeStatusSnapshot],
        now: Date = Date()
    ) -> [String: String] {
        var result: [String: String] = [:]
        for snapshot in snapshots where now.timeIntervalSince(snapshot.updatedAt) < contextLifetime {
            if let model = snapshot.model { result[snapshot.sessionID] = model }
        }
        return result
    }

    /// Each live Claude session's context use, for its own row.
    public static func contextBySession(
        from snapshots: [ClaudeStatusSnapshot],
        now: Date = Date()
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for snapshot in snapshots where now.timeIntervalSince(snapshot.updatedAt) < contextLifetime {
            if let context = snapshot.contextPercent { result[snapshot.sessionID] = context }
        }
        return result
    }

    public static func crewlineGroups(from accounts: [CrewlineUsageAccount], now: Date = Date()) -> [AgentUsageGroup] {
        var seen = Set<AISource>()
        return accounts.compactMap { account in
            let provider = account.provider.lowercased()
            let source: AISource = provider.contains("claude") || provider.contains("anthropic") ? .claude : .codex
            // One group per provider: the first account is the active one.
            guard seen.insert(source).inserted else { return nil }
            var meters: [AgentUsageMeter] = []
            if let window = account.fiveHour {
                meters.append(AgentUsageMeter(kind: .fiveHour, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
            if let window = account.weekly {
                meters.append(AgentUsageMeter(kind: .weekly, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
            guard !meters.isEmpty else { return nil }
            return AgentUsageGroup(source: source, label: source.title, meters: meters, isStale: account.isStale)
        }
    }

    /// Claude's own status line wins over Crewline's copy of the same
    /// account; Codex comes from Crewline.
    public static func merged(claude: AgentUsageGroup?, crewline: [AgentUsageGroup]) -> [AgentUsageGroup] {
        var groups: [AgentUsageGroup] = []
        if let claude { groups.append(claude) }
        groups += crewline.filter { group in !(group.source == .claude && claude != nil) }
        return groups
    }

    public static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, date.timeIntervalSince(now))
        let hours = Int(seconds / 3_600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
        if hours >= 48 { return "Resets in \(hours / 24) days" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(max(minutes, 1))m"
    }
}

/// Reads what the bundled `notchshot-ai statusline` command records for each
/// Claude Code session.
@MainActor
@Observable
public final class ClaudeUsageMonitor {
    public static let shared = ClaudeUsageMonitor()

    public private(set) var group: AgentUsageGroup?
    /// Context window used, by Claude session ID.
    public private(set) var contextBySession: [String: Double] = [:]
    /// Model, by Claude session ID, when the status line names one.
    public private(set) var modelBySession: [String: String] = [:]
    private var pollTask: Task<Void, Never>?
    private let folder: URL

    public init(folder: URL = ClaudeStatusLine.directory(base: AppPaths.aiActivity)) {
        self.folder = folder
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        group = nil
        contextBySession = [:]
        modelBySession = [:]
    }

    func refresh(now: Date = Date()) async {
        let folder = folder
        let snapshots = await Task.detached(priority: .utility) {
            Self.readSnapshots(in: folder, now: now)
        }.value
        let updated = AgentUsagePolicy.claudeGroup(from: snapshots, now: now)
        if updated != group { group = updated }
        let context = AgentUsagePolicy.contextBySession(from: snapshots, now: now)
        if context != contextBySession { contextBySession = context }
        let models = AgentUsagePolicy.modelBySession(from: snapshots, now: now)
        if models != modelBySession { modelBySession = models }
    }

    nonisolated static func readSnapshots(in folder: URL, now: Date) -> [ClaudeStatusSnapshot] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshots: [ClaudeStatusSnapshot] = []
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values?.fileSize ?? 0) < 16 * 1_024 else { continue }
            if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > 8 * 24 * 3_600 {
                // A week-old session can't inform a weekly window; tidy it.
                try? manager.removeItem(at: file)
                continue
            }
            if let data = try? Data(contentsOf: file),
               let snapshot = try? decoder.decode(ClaudeStatusSnapshot.self, from: data) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }
}
