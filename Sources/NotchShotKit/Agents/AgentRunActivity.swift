import Foundation

/// One tool call in an agent's current turn, timed from the hook before it
/// to the hook after it, or to the next call when the agent reports no ends.
/// Kept in memory only, like the session it belongs to.
public struct AgentRunAction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case read, edit, write, search, find, list, command, fetch, webSearch, agent, question, other
    }

    public var id: String
    public var tool: String
    /// The redacted label the hook sent: a path, a pattern, a description.
    public var target: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var failed: Bool

    public init(
        id: String,
        tool: String,
        target: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        failed: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.target = target
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.failed = failed
    }

    public var isOpen: Bool { endedAt == nil }

    public var kind: Kind {
        switch tool {
        case "Read", "NotebookRead": .read
        case "Edit", "MultiEdit", "NotebookEdit": .edit
        case "Write": .write
        case "Grep": .search
        case "Glob": .find
        case "LS": .list
        case "Bash", "BashOutput", "KillShell", "KillBash": .command
        case "WebFetch": .fetch
        case "WebSearch": .webSearch
        case "Task", "Agent": .agent
        case "AskUserQuestion": .question
        default: .other
        }
    }
}

/// Pause and Stop as the island tracks them between the click and the
/// agent acting on it.
public enum AgentRunControlState: Equatable, Sendable {
    /// Asked to pause; the agent has not reached its next step yet.
    case pausing
    /// Held before its next step, which the label names when known.
    case paused(before: String?)
    /// Asked to stop; it ends at its next step.
    case stopping

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

/// What the run card's Pause, Resume and Stop buttons ask for.
public enum AgentRunCommand: String, Equatable, Sendable {
    case pause, resume, stop
}

/// Which run controls a run offers right now, and where a sent one stands.
public struct AgentRunControls: Equatable, Sendable {
    public var canPause: Bool
    public var canStop: Bool
    public var state: AgentRunControlState?

    public init(canPause: Bool = false, canStop: Bool = false, state: AgentRunControlState? = nil) {
        self.canPause = canPause
        self.canStop = canStop
        self.state = state
    }

    public static let none = AgentRunControls()

    /// Pause, Resume or nothing in the first slot.
    public var showsResume: Bool {
        switch state {
        case .pausing, .paused: true
        case .stopping, nil: false
        }
    }
}

/// What the run card's step list and headline say, built from the turn's
/// tool calls.
public struct AgentRunRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: AgentRunAction.Kind
    public var text: String
    public var startedAt: Date
    public var endedAt: Date?
    public var failed: Bool

    public var isCurrent: Bool { endedAt == nil }

    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// Keeps a turn's tool calls and turns them into the card's rows.
public enum AgentRunTimeline {
    public static let maximumActions = 40

    /// Starts a call. Without end events, a new call ends the open ones.
    public static func begin(_ action: AgentRunAction, in actions: inout [AgentRunAction], endsOpenCalls: Bool) {
        if endsOpenCalls { endAll(at: action.startedAt, in: &actions) }
        actions.removeAll { $0.id == action.id }
        actions.append(action)
        if actions.count > maximumActions { actions.removeFirst(actions.count - maximumActions) }
    }

    /// Ends the call with this ID, else the newest open call of this tool,
    /// else the newest open call.
    public static func end(
        toolUseID: String?,
        tool: String?,
        at date: Date,
        failed: Bool,
        in actions: inout [AgentRunAction]
    ) {
        let index = toolUseID.flatMap { id in actions.lastIndex { $0.id == id && $0.isOpen } }
            ?? tool.flatMap { name in actions.lastIndex { $0.tool == name && $0.isOpen } }
            ?? actions.lastIndex(where: \.isOpen)
        guard let index else { return }
        actions[index].endedAt = max(date, actions[index].startedAt)
        actions[index].failed = failed
    }

    public static func endAll(at date: Date, in actions: inout [AgentRunAction]) {
        for index in actions.indices where actions[index].isOpen {
            actions[index].endedAt = max(date, actions[index].startedAt)
        }
    }

    /// The newest rows, oldest first. Finished calls of one sort in a row
    /// fold into one line ("Read 12 files"); calls still running fold the
    /// same way among themselves.
    public static func rows(for actions: [AgentRunAction], limit: Int = 3) -> [AgentRunRow] {
        var groups: [[AgentRunAction]] = []
        for action in actions {
            if let last = groups.last?.last,
               last.isOpen == action.isOpen,
               groupKey(last) == groupKey(action) {
                groups[groups.count - 1].append(action)
            } else {
                groups.append([action])
            }
        }
        return groups.suffix(limit).map(row(for:))
    }

    /// What the agent is doing now, in the card's headline.
    public static func currentText(for actions: [AgentRunAction]) -> (text: String, kind: AgentRunAction.Kind)? {
        let open = actions.filter(\.isOpen)
        guard let newest = open.last else { return nil }
        let sameKind = open.filter { groupKey($0) == groupKey(newest) }
        return (AgentRunPhrasing.text(for: sameKind, finished: false), newest.kind)
    }

    static func groupKey(_ action: AgentRunAction) -> String {
        switch action.kind {
        case .read, .list, .fetch, .webSearch: action.kind.rawValue
        case .search, .find: "search"
        case .edit, .write: action.kind.rawValue + ":" + (action.target ?? "")
        case .command, .agent, .question: action.kind.rawValue + ":" + action.id
        case .other: "other:" + action.tool
        }
    }

    private static func row(for group: [AgentRunAction]) -> AgentRunRow {
        let first = group[0]
        let open = group.contains(where: \.isOpen)
        return AgentRunRow(
            id: first.id,
            kind: group.last?.kind ?? first.kind,
            text: AgentRunPhrasing.text(for: group, finished: !open),
            startedAt: group.map(\.startedAt).min() ?? first.startedAt,
            endedAt: open ? nil : group.compactMap(\.endedAt).max(),
            failed: group.contains(where: \.failed)
        )
    }
}

/// The card's words for tool calls: "Editing src/billing/invoice.ts" while
/// it runs, "Read 12 files" once a run of reads is done.
public enum AgentRunPhrasing {
    public static func text(for group: [AgentRunAction], finished: Bool) -> String {
        guard let action = group.last else { return "" }
        let count = group.count
        let target = action.target
        let quoted = target.map { "“\($0)”" }
        switch action.kind {
        case .read:
            if count > 1 { return (finished ? "Read" : "Reading") + " \(count) files" }
            return (finished ? "Read " : "Reading ") + (target ?? "a file")
        case .edit:
            return (finished ? "Edited " : "Editing ") + (target ?? "a file")
        case .write:
            return (finished ? "Wrote " : "Writing ") + (target ?? "a file")
        case .search, .find:
            if count > 1 { return finished ? "Ran \(count) searches" : "Running \(count) searches" }
            if action.kind == .find {
                return (finished ? "Looked for " : "Looking for ") + (quoted ?? "files")
            }
            return (finished ? "Searched for " : "Searching for ") + (quoted ?? "text")
        case .list:
            if count > 1 { return (finished ? "Listed" : "Listing") + " \(count) folders" }
            return (finished ? "Listed " : "Listing ") + (target ?? "a folder")
        case .command:
            // Claude's description already reads as the step ("Run tests").
            return target ?? (finished ? "Ran a command" : "Running a command")
        case .fetch:
            if count > 1 { return (finished ? "Fetched" : "Fetching") + " \(count) pages" }
            return (finished ? "Fetched " : "Fetching ") + (target ?? "a page")
        case .webSearch:
            if count > 1 { return finished ? "Ran \(count) web searches" : "Searching the web" }
            return (finished ? "Searched the web for " : "Searching the web for ") + (quoted ?? "results")
        case .agent:
            return (finished ? "Agent finished: " : "Agent: ") + (target ?? "subtask")
        case .question:
            return finished ? "Asked a question" : "Asking a question"
        case .other:
            let name = toolName(action.tool, target: target)
            if count > 1 { return (finished ? "Used " : "Using ") + name + " ×\(count)" }
            return (finished ? "Used " : "Using ") + name
        }
    }

    /// "mcp__github__create_issue" → "github create issue"; a skill by its
    /// name.
    static func toolName(_ tool: String, target: String?) -> String {
        if tool == "Skill", let target { return "skill " + target }
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " ")
    }

    /// "1.9s", "12s", "2m 5s", "1h 3m".
    public static func duration(_ seconds: TimeInterval, running: Bool) -> String {
        let value = max(0, seconds)
        if value < 10, !running { return String(format: "%.1fs", (value * 10).rounded(.down) / 10) }
        let whole = Int(value)
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \((whole % 3_600) / 60)m"
    }

    /// The run's clock: "0:03", "12:40", "1:02:09".
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let rest = whole % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}

/// The agent's own task list, as the card's segments.
public enum AgentRunPlan {
    public static let maximumSteps = 12

    /// A whole list, as `TodoWrite` sends it.
    public static func steps(fromList items: [[String: Any]]) -> [AIActivityStep] {
        items.prefix(maximumSteps).enumerated().compactMap { index, item in
            guard let label = item["label"] as? String, !label.isEmpty,
                  let state = state(item["status"] as? String) else { return nil }
            return AIActivityStep(id: String(index + 1), label: label, state: state)
        }
    }

    /// One task created or changed, as `TaskCreate` and `TaskUpdate` send
    /// it. Claude Code numbers a session's tasks from 1 in the order they
    /// are created, which is the ID a later update names.
    public static func applying(_ operation: [String: Any], to plan: [AIActivityStep]) -> [AIActivityStep] {
        var plan = plan
        switch operation["op"] as? String {
        case "create":
            guard let label = operation["label"] as? String, !label.isEmpty, plan.count < maximumSteps else { return plan }
            let next = (plan.compactMap { Int($0.id) }.max() ?? 0) + 1
            plan.append(AIActivityStep(id: String(next), label: label, state: .pending))
        case "update":
            guard let id = operation["id"] as? String,
                  let index = plan.firstIndex(where: { $0.id == id }) else { return plan }
            if let status = operation["status"] as? String {
                guard let state = state(status) else {
                    plan.remove(at: index)
                    return plan
                }
                plan[index].state = state
            }
            if let label = operation["label"] as? String, !label.isEmpty { plan[index].label = label }
        default:
            break
        }
        return plan
    }

    /// Nil for "deleted", which drops the task.
    static func state(_ status: String?) -> AIActivityStepState? {
        switch status?.lowercased() {
        case "in_progress", "in-progress", "inprogress", "active", "working": .working
        case "completed", "complete", "done": .completed
        case "failed", "cancelled", "canceled", "error": .failed
        case "deleted", "removed": nil
        default: .pending
        }
    }

    /// "Step 3 of 6": the task in progress, else the next one to start.
    public static func position(of steps: [AIActivityStep]) -> (current: Int, total: Int)? {
        guard !steps.isEmpty else { return nil }
        if let working = steps.firstIndex(where: { $0.state == .working }) {
            return (working + 1, steps.count)
        }
        if let next = steps.firstIndex(where: { $0.state == .pending }) {
            return (next + 1, steps.count)
        }
        return (steps.count, steps.count)
    }

    public static func isComplete(_ steps: [AIActivityStep]) -> Bool {
        !steps.isEmpty && steps.allSatisfy { $0.state == .completed }
    }
}

/// Model names as people say them: "claude-sonnet-5-5" → "Claude Sonnet 5.5".
public enum AgentModelName {
    public static func display(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "[1m]" and "(1M context)" describe the window, not the model.
        if let bracket = text.firstIndex(where: { $0 == "[" || $0 == "(" }) {
            text = String(text[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        guard lower.hasPrefix("claude-") else {
            if lower.hasPrefix("claude") || text.isEmpty { return text }
            let families = ["opus", "sonnet", "haiku", "fable"]
            return families.contains(where: { lower.hasPrefix($0) }) ? "Claude " + text : text
        }
        var words: [String] = []
        var version: [String] = []
        for part in lower.dropFirst("claude-".count).split(separator: "-") {
            // A trailing release date ("20250805") is not part of the name.
            if part.count == 8, part.allSatisfy(\.isNumber) { continue }
            if part.allSatisfy(\.isNumber) {
                version.append(String(part))
            } else {
                if !version.isEmpty { words.append(version.joined(separator: ".")); version = [] }
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        if !version.isEmpty { words.append(version.joined(separator: ".")) }
        return (["Claude"] + words).joined(separator: " ")
    }
}
