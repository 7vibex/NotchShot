import Darwin
import Foundation

/// What the Claude hook may say about a tool call beyond its name, for the
/// island's run card: one short, redacted label naming what the tool works
/// on (a path inside the project, a search pattern, Claude's own description
/// of a command), and the agent's task list when the call only updates it.
/// Nothing else from the tool's input leaves the hook, and its output never
/// does.
public enum ClaudeRunReport {
    public static let maximumTargetCharacters = 120
    public static let maximumPlanItems = 12
    public static let maximumPlanLabelCharacters = 80

    /// Tools that only keep the agent's task list. They change the plan, not
    /// the work, so the card does not list them as steps.
    public static let planTools: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]

    public static func isPlanTool(_ tool: String?) -> Bool {
        tool.map(planTools.contains) ?? false
    }

    /// The thing a tool call works on, short enough for one line.
    public static func target(tool: String?, input: Any?, cwd: String?) -> String? {
        guard let tool, let input = input as? [String: Any] else { return nil }
        let raw: String? = switch tool {
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "NotebookRead":
            ((input["file_path"] as? String) ?? (input["notebook_path"] as? String))
                .map { displayPath($0, cwd: cwd) }
        case "LS":
            (input["path"] as? String).map { displayPath($0, cwd: cwd) }
        case "Grep", "Glob":
            input["pattern"] as? String
        case "Bash":
            // Claude's own few words for the command, else the command's
            // first line with anything secret-looking masked.
            (input["description"] as? String) ?? (input["command"] as? String)
        case "WebFetch":
            (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch":
            input["query"] as? String
        case "Task", "Agent":
            (input["description"] as? String) ?? (input["subagent_type"] as? String)
        case "Skill":
            (input["skill"] as? String) ?? (input["command"] as? String)
        default:
            nil
        }
        guard let raw else { return nil }
        // The first line before redacting: redaction joins lines.
        let text = CommandSecretRedactor.redactText(firstLine(raw))
        return clip(text, maximumTargetCharacters)
    }

    /// The socket form of a task-list update: `["plan": [...]]` for a whole
    /// list (`TodoWrite`), `["plan_op": [...]]` for one task (`TaskCreate`,
    /// `TaskUpdate`), or nil.
    public static func planPayload(tool: String?, input: Any?) -> [String: Any]? {
        guard let tool, let input = input as? [String: Any] else { return nil }
        switch tool {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return nil }
            let items = todos.prefix(maximumPlanItems).compactMap { todo -> [String: Any]? in
                guard let label = planLabel(todo["content"] ?? todo["subject"]) else { return nil }
                var item: [String: Any] = ["label": label, "status": (todo["status"] as? String) ?? "pending"]
                if let active = planLabel(todo["activeForm"]) { item["active"] = active }
                return item
            }
            return ["plan": items]
        case "TaskCreate":
            guard let label = planLabel(input["subject"] ?? input["content"]) else { return nil }
            var operation: [String: Any] = ["op": "create", "label": label]
            if let active = planLabel(input["activeForm"]) { operation["active"] = active }
            return ["plan_op": operation]
        case "TaskUpdate":
            guard let identifier = (input["taskId"] as? String) ?? (input["taskId"] as? NSNumber)?.stringValue,
                  let id = safeIdentifier(identifier) else { return nil }
            var operation: [String: Any] = ["op": "update", "id": id]
            if let status = input["status"] as? String { operation["status"] = clip(status, 20) }
            if let label = planLabel(input["subject"]) { operation["label"] = label }
            if let active = planLabel(input["activeForm"]) { operation["active"] = active }
            return ["plan_op": operation]
        default:
            return nil
        }
    }

    /// The model a hook event names, as Claude Code sends it: a bare ID, or
    /// an object with an ID and a display name.
    public static func model(from value: Any?) -> String? {
        let raw: String? = if let text = value as? String {
            text
        } else if let object = value as? [String: Any] {
            (object["display_name"] as? String) ?? (object["id"] as? String)
        } else {
            nil
        }
        guard let raw else { return nil }
        let text = clip(raw, 60)
        return text.isEmpty ? nil : text
    }

    public static func safeIdentifier(_ value: String) -> String? {
        let result = String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }.prefix(64))
        return result.isEmpty ? nil : result
    }

    /// A path relative to the project when it is inside it, from the home
    /// folder when it is not, and only its last three parts when it is long.
    static func displayPath(_ path: String, cwd: String?) -> String {
        var display = path
        if let cwd, !cwd.isEmpty {
            let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
            if path.hasPrefix(root) { display = String(path.dropFirst(root.count)) }
        }
        if display == path {
            let home = NSHomeDirectory()
            if path.hasPrefix(home + "/") { display = "~/" + path.dropFirst(home.count + 1) }
        }
        let parts = display.split(separator: "/", omittingEmptySubsequences: true)
        if display.count > 60, parts.count > 3 {
            display = "…/" + parts.suffix(3).joined(separator: "/")
        }
        return display
    }

    private static func planLabel(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let label = clip(CommandSecretRedactor.redactText(firstLine(text)), maximumPlanLabelCharacters)
        return label.isEmpty ? nil : label
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    }

    private static func clip(_ text: String, _ maximum: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximum else { return trimmed }
        return String(trimmed.prefix(maximum - 1)) + "…"
    }
}

/// Pause and Stop for a Claude Code run, handed to its hook at the next tool
/// boundary. Claude Code has no outside control for a running turn, but its
/// hooks run before every tool: NotchShot leaves a one-word request in a
/// private folder, and the hook acts on it there. Stop ends the turn the way
/// a hook's `continue: false` does. Pause holds the hook, and with it Claude,
/// until NotchShot answers over the socket or the hold times out.
///
/// With no request on file the hook pays one failed `open`. With NotchShot
/// closed a paused hook cannot connect, so it lets Claude carry on.
public enum ClaudeRunControl {
    public enum Command: String, Sendable {
        case pause
        case stop
    }

    /// Socket `status` for a hook holding a paused session before its next
    /// tool. It waits for `{"decision": "resume" | "stop"}`.
    public static let heldStatus = "paused_before_tool"
    /// Socket `status` for a hook that ended the turn on the user's Stop.
    public static let stoppedStatus = "stopped_by_user"
    /// Just under Claude Code's ten-minute hook limit; past it Claude goes on.
    public static let holdTimeoutMilliseconds: Int32 = 590_000
    /// A request no tool call picked up is stale after this.
    public static let requestLifetime: TimeInterval = 30 * 60
    public static let stopReason = "Stopped from NotchShot"

    /// Per-user, beside the hook socket.
    public static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-claude-\(getuid())-control", isDirectory: true)
    }

    /// Leaves a request for the session's hook. Replaces any earlier one.
    @discardableResult
    public static func request(_ command: Command, sessionID: String, in directory: URL = directory) -> Bool {
        guard let name = ClaudeRunReport.safeIdentifier(sessionID), prepare(directory) else { return false }
        let url = directory.appendingPathComponent(name)
        let staging = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: Data(command.rawValue.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        guard rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            return false
        }
        return true
    }

    public static func clear(sessionID: String, in directory: URL = directory) {
        guard let name = ClaudeRunReport.safeIdentifier(sessionID) else { return }
        unlink(directory.appendingPathComponent(name).path)
    }

    /// Drops every request, for when NotchShot starts: nothing it left
    /// before quitting is still wanted.
    public static func clearAll(in directory: URL = directory) {
        guard isPrivateDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names { unlink(directory.appendingPathComponent(name).path) }
    }

    /// The request waiting for this session, if a fresh one is on file. Read
    /// without following links, and only from a small regular file this user
    /// owns.
    public static func pending(sessionID: String, in directory: URL = directory, now: Date = Date()) -> Command? {
        guard let name = ClaudeRunReport.safeIdentifier(sessionID) else { return nil }
        let descriptor = open(directory.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == getuid(),
              information.st_size > 0, information.st_size <= 16 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec))
        guard now.timeIntervalSince(modified) < requestLifetime else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        let word = String(decoding: bytes.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Command(rawValue: word)
    }

    /// The hook's stdout that ends Claude's turn. Before a tool it also
    /// refuses that tool, so nothing runs after Stop.
    public static func stopOutput(beforeTool: Bool) -> String {
        var output: [String: Any] = ["continue": false, "stopReason": stopReason]
        if beforeTool {
            output["hookSpecificOutput"] = [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": stopReason,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            return #"{"continue":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads NotchShot's answer to a held hook. Anything but an explicit stop
    /// lets Claude carry on.
    public static func shouldStop(afterHoldReply data: Data) -> Bool {
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return false }
        return object["decision"] as? String == "stop"
    }

    private static func prepare(_ directory: URL) -> Bool {
        if isPrivateDirectory(directory) { return true }
        guard mkdir(directory.path, 0o700) == 0 else { return false }
        return isPrivateDirectory(directory)
    }

    private static func isPrivateDirectory(_ directory: URL) -> Bool {
        var information = stat()
        guard lstat(directory.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR && information.st_uid == getuid()
    }
}
