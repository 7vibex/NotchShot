import Foundation

/// One agent run as Crewline's `workspace.bootstrap` reports it. Only the
/// columns NotchShot draws are kept; prompts and transcripts stay in Crewline.
public struct CrewlineRun: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case queued, starting, running
        case awaitingApproval = "awaiting_approval"
        case awaitingInput = "awaiting_input"
        case paused, interrupted, completed, failed, stopped

        public var isActive: Bool {
            switch self {
            case .queued, .starting, .running, .awaitingApproval, .awaitingInput, .paused: true
            case .interrupted, .completed, .failed, .stopped: false
            }
        }

        var aiState: AIActivityState {
            switch self {
            case .queued, .starting, .running: .working
            case .awaitingApproval, .awaitingInput, .paused: .waiting
            case .completed, .stopped: .finished
            case .interrupted, .failed: .failed
            }
        }
    }

    public var id: String
    public var issueID: String?
    public var agentInstanceID: String?
    public var status: Status
    public var statusDetail: String?
    public var runtimeMode: String?
    public var worktreePath: String?
    public var branch: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var lastText: String?
    public var parentRunID: String?
    public var prompt: String?

    public init(
        id: String,
        issueID: String? = nil,
        agentInstanceID: String? = nil,
        status: Status,
        statusDetail: String? = nil,
        runtimeMode: String? = nil,
        worktreePath: String? = nil,
        branch: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastText: String? = nil,
        parentRunID: String? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.issueID = issueID
        self.agentInstanceID = agentInstanceID
        self.status = status
        self.statusDetail = statusDetail
        self.runtimeMode = runtimeMode
        self.worktreePath = worktreePath
        self.branch = branch
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastText = lastText
        self.parentRunID = parentRunID
        self.prompt = prompt
    }
}

public struct CrewlineApproval: Equatable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    public var tool: String
    public var summary: String?
}

public struct CrewlineAgentInstance: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var adapterKind: String
}

/// The slice of a bootstrap the island needs.
public struct CrewlineWorkspace: Equatable, Sendable {
    public var runs: [CrewlineRun] = []
    public var approvals: [CrewlineApproval] = []
    public var issueTitles: [String: String] = [:]
    public var agents: [String: CrewlineAgentInstance] = [:]

    public init(
        runs: [CrewlineRun] = [],
        approvals: [CrewlineApproval] = [],
        issueTitles: [String: String] = [:],
        agents: [String: CrewlineAgentInstance] = [:]
    ) {
        self.runs = runs
        self.approvals = approvals
        self.issueTitles = issueTitles
        self.agents = agents
    }

    public func run(_ id: String) -> CrewlineRun? { runs.first { $0.id == id } }

    /// Top-level runs that are still going, newest first. Delegated helpers
    /// are left out: their parent run already stands for the work.
    public var activeRuns: [CrewlineRun] {
        runs.filter { $0.status.isActive && $0.parentRunID == nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// The run a screenshot should go to: the most recent active top-level
    /// run, else the most recent finished one.
    public var followUpCandidates: [CrewlineRun] {
        let topLevel = runs.filter { $0.parentRunID == nil }
        return topLevel.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
            return (lhs.endedAt ?? lhs.startedAt ?? .distantPast) > (rhs.endedAt ?? rhs.startedAt ?? .distantPast)
        }
    }

    public func title(for run: CrewlineRun) -> String {
        if let issueID = run.issueID, let title = issueTitles[issueID], !title.isEmpty {
            return title
        }
        if let prompt = run.prompt?.split(whereSeparator: \.isNewline).first {
            let line = prompt.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return String(line.prefix(120)) }
        }
        return "Crewline run"
    }

    public func agentName(for run: CrewlineRun) -> String? {
        run.agentInstanceID.flatMap { agents[$0]?.displayName }
    }
}

public struct CrewlineUsageWindow: Equatable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Double?
    public var resetsAt: Date?
}

public struct CrewlineUsageAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var label: String
    public var plan: String?
    public var isStale: Bool
    public var windows: [CrewlineUsageWindow]

    public var fiveHour: CrewlineUsageWindow? { windows.first { $0.windowMinutes == 300 } }
    public var weekly: CrewlineUsageWindow? { windows.first { $0.windowMinutes == 10_080 } }
}

/// Pure decoding of Crewline's JSON. Every field is optional on the way in:
/// Crewline is a separate app on its own release train, and a renamed column
/// must cost a missing label, not the whole connection.
public enum CrewlineParser {
    public static func workspace(from payload: Any) -> CrewlineWorkspace {
        guard let object = payload as? [String: Any] else { return CrewlineWorkspace() }

        let runs = (object["runs"] as? [[String: Any]] ?? []).compactMap(run)
        let approvals = (object["approvals"] as? [[String: Any]] ?? []).compactMap { row -> CrewlineApproval? in
            guard let id = string(row["id"]), let runID = string(row["run_id"]) else { return nil }
            if let status = string(row["status"]), status != "pending" { return nil }
            return CrewlineApproval(
                id: id,
                runID: runID,
                tool: string(row["tool"]) ?? "Tool",
                summary: string(row["summary"])
            )
        }
        var titles: [String: String] = [:]
        for issue in object["issues"] as? [[String: Any]] ?? [] {
            guard let id = string(issue["id"]), let title = string(issue["title"]) else { continue }
            titles[id] = title
        }
        var agents: [String: CrewlineAgentInstance] = [:]
        for agent in object["agentInstances"] as? [[String: Any]] ?? [] {
            guard let id = string(agent["id"]) else { continue }
            agents[id] = CrewlineAgentInstance(
                id: id,
                displayName: string(agent["display_name"]) ?? string(agent["displayName"]) ?? "Agent",
                adapterKind: string(agent["adapter_kind"]) ?? string(agent["adapterKind"]) ?? ""
            )
        }
        return CrewlineWorkspace(runs: runs, approvals: approvals, issueTitles: titles, agents: agents)
    }

    public static func run(_ row: [String: Any]) -> CrewlineRun? {
        guard let id = string(row["id"]),
              let rawStatus = string(row["status"]),
              let status = CrewlineRun.Status(rawValue: rawStatus)
        else { return nil }
        return CrewlineRun(
            id: id,
            issueID: string(row["issue_id"]),
            agentInstanceID: string(row["agent_instance_id"]),
            status: status,
            statusDetail: string(row["status_detail"]),
            runtimeMode: string(row["runtime_mode"]),
            worktreePath: string(row["worktree_path"]),
            branch: string(row["branch"]),
            startedAt: date(row["started_at"]),
            endedAt: date(row["ended_at"]),
            lastText: string(row["last_text"]),
            parentRunID: string(row["parent_run_id"]),
            prompt: string(row["prompt"])
        )
    }

    /// The question a run is still waiting on, read from the event window of
    /// `runs.get`: the latest `input.requested` with no `input.resolved` after
    /// it. Each event row carries its payload as a JSON string.
    public static func pendingQuestion(
        inRunEvents payload: Any,
        runID: String
    ) -> AgentInteraction? {
        guard let object = payload as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return nil }

        var pending: (id: String, object: [String: Any], at: Date?)?
        for row in events {
            guard let type = string(row["type"]) else { continue }
            let body: [String: Any]
            if let text = row["payload"] as? String,
               let data = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = decoded
            } else if let decoded = row["payload"] as? [String: Any] {
                body = decoded
            } else {
                continue
            }
            switch type {
            case "input.requested":
                guard let requestID = string(body["requestId"]) else { continue }
                pending = (requestID, body, date(row["ts"]))
            case "input.resolved":
                if string(body["requestId"]) == pending?.id || body["requestId"] == nil {
                    pending = nil
                }
            default:
                continue
            }
        }
        guard let pending else { return nil }
        return AgentInteraction(
            id: pending.id,
            activityKey: activityKey(runID: runID),
            source: .crewline,
            kind: .question(questionForm(from: pending.object)),
            receivedAt: pending.at ?? Date()
        )
    }

    /// Mirrors Crewline's own composer (`InputForm` on iOS, `inputQuestions`
    /// on web): the server's normalized question when it recognised a single
    /// closed question, otherwise the harness's native form answered by index.
    public static func questionForm(from object: [String: Any]) -> AgentQuestionForm {
        let title = string(object["question"]) ?? "The agent asked a question"
        let detail = object["detail"] as? [Any]

        if let normalized = object["normalizedQuestion"] as? [String: Any],
           let kind = string(normalized["kind"]),
           let prompt = string(normalized["prompt"]),
           (detail?.count ?? 1) == 1 {
            let options = (normalized["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestionOption? in
                guard let value = string(option["value"]) else { return nil }
                return AgentQuestionOption(
                    value: value,
                    label: string(option["label"]) ?? value,
                    hint: string(option["hint"])
                )
            }
            let questionKind: AgentQuestion.Kind? = switch kind {
            case "select": .select
            case "multi-select": .multiSelect
            case "confirm": .confirm
            case "text": .text
            default: nil
            }
            if let questionKind {
                let question = AgentQuestion(
                    prompt: prompt,
                    kind: questionKind,
                    options: options,
                    placeholder: string(normalized["placeholder"])
                )
                // A normalized text question keeps the indexed shape, as the
                // web composer does.
                return AgentQuestionForm(
                    title: title,
                    questions: [question],
                    encoding: questionKind == .text ? .crewlineIndexed : .crewlineNormalized
                )
            }
        }

        guard let detail, !detail.isEmpty else {
            return AgentQuestionForm(
                title: title,
                questions: [AgentQuestion(prompt: title, kind: .text)],
                encoding: .crewlineIndexed
            )
        }
        let questions = detail.prefix(6).enumerated().map { index, raw -> AgentQuestion in
            let item = raw as? [String: Any] ?? [:]
            let options = (item["options"] as? [Any] ?? []).prefix(12).map { raw -> AgentQuestionOption in
                let option = raw as? [String: Any] ?? [:]
                let label = string(option["label"]) ?? "Option"
                return AgentQuestionOption(
                    value: string(option["value"]) ?? label,
                    label: label,
                    hint: string(option["description"])
                )
            }
            let multiple = item["multiple"] as? Bool == true
                || item["multiSelect"] as? Bool == true
                || string(item["kind"]) == "multi-select"
                || string(item["type"]) == "multi-select"
            return AgentQuestion(
                header: string(item["header"]) ?? "Question \(index + 1)",
                prompt: string(item["question"]) ?? title,
                kind: multiple ? .multiSelect : options.isEmpty ? .text : .select,
                options: Array(options)
            )
        }
        return AgentQuestionForm(title: title, questions: questions, encoding: .crewlineIndexed)
    }

    public static func usageAccounts(from payload: Any) -> [CrewlineUsageAccount] {
        guard let object = payload as? [String: Any] else { return [] }
        return (object["accounts"] as? [[String: Any]] ?? []).compactMap { account in
            if account["disabled"] as? Bool == true { return nil }
            let provider = string(account["provider"]) ?? ""
            let label = string(account["label"]) ?? provider
            let windows = (account["windows"] as? [[String: Any]] ?? []).compactMap { window -> CrewlineUsageWindow? in
                guard let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
                return CrewlineUsageWindow(
                    label: string(window["label"]) ?? "",
                    usedPercent: min(max(used, 0), 100),
                    windowMinutes: (window["windowDurationMins"] as? NSNumber)?.doubleValue,
                    resetsAt: (window["resetsAt"] as? NSNumber).map {
                        Date(timeIntervalSince1970: $0.doubleValue)
                    }
                )
            }
            guard !windows.isEmpty else { return nil }
            let id = [string(account["sourceId"]), string(account["accountId"])]
                .compactMap { $0 }
                .joined(separator: "/")
            return CrewlineUsageAccount(
                id: id.isEmpty ? label : id,
                provider: provider,
                label: label,
                plan: string(account["plan"]),
                isStale: string(account["status"]) != "ready",
                windows: windows
            )
        }
    }

    public static func activityKey(runID: String) -> String {
        AISource.crewline.rawValue + ":" + AIActivityPolicy.safeIdentifier(runID)
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            // Milliseconds since the epoch are 13 digits; seconds are 10.
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
        }
        guard let text = string(value) else { return nil }
        if let date = fractionalFormatter.date(from: text) { return date }
        if let date = plainFormatter.date(from: text) { return date }
        // SQLite's `datetime('now')` shape: "2026-10-19 12:34:56", UTC.
        return sqliteFormatter.date(from: text)
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let sqliteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Turns a Crewline workspace into the records the island already knows how
/// to draw.
public enum CrewlineActivityMapper {
    public static func activities(
        from workspace: CrewlineWorkspace,
        questions: [String: AgentInteraction],
        now: Date = Date()
    ) -> [AIActivitySnapshot] {
        let pendingApprovalRuns = Set(workspace.approvals.map(\.runID))
        return workspace.runs.compactMap { run -> AIActivitySnapshot? in
            guard run.parentRunID == nil else { return nil }
            if !run.status.isActive {
                // Finished runs linger briefly so the user sees the outcome,
                // then belong to Crewline's own history.
                guard let ended = run.endedAt,
                      now.timeIntervalSince(ended) < AIActivityPolicy.terminalLifetime else { return nil }
            }

            let detail: String? = if pendingApprovalRuns.contains(run.id) {
                workspace.approvals.first { $0.runID == run.id }.map { "\($0.tool) needs approval" }
            } else if run.status == .awaitingInput {
                questions[run.id].map(\.headline) ?? "Asked a question"
            } else {
                lastLine(of: run.lastText) ?? run.statusDetail
            }

            return AIActivitySnapshot(
                id: run.id,
                source: .crewline,
                state: run.status.aiState,
                title: workspace.title(for: run),
                detail: detail,
                workspace: run.worktreePath,
                steps: [],
                startedAt: run.startedAt,
                // Live runs are refreshed by the socket; stamping them now
                // keeps a long run from aging out of the island mid-work.
                updatedAt: run.status.isActive ? now : (run.endedAt ?? now),
                agentLabel: workspace.agentName(for: run)
            )
        }
    }

    public static func approvalInteractions(from workspace: CrewlineWorkspace) -> [AgentInteraction] {
        workspace.approvals.map { approval in
            AgentInteraction(
                id: approval.id,
                activityKey: CrewlineParser.activityKey(runID: approval.runID),
                source: .crewline,
                kind: .approval(AgentApprovalRequest(
                    tool: approval.tool,
                    summary: approval.summary,
                    offersSessionApproval: true
                ))
            )
        }
    }

    static func lastLine(of text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map { String($0.prefix(180)) }
    }
}
