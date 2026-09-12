import Darwin
import Foundation

public enum ClaudeTranscriptRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case tool
}

public struct ClaudeTranscriptMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: ClaudeTranscriptRole
    public var text: String
    public var toolName: String?
    public var timestamp: Date

    public init(
        id: String,
        role: ClaudeTranscriptRole,
        text: String,
        toolName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.timestamp = timestamp
    }
}

/// Reads a Claude JSONL conversation only after the user opens a session's
/// conversation view. The reader never caches or writes transcript content.
public enum ClaudeConversationReader {
    public static let maximumFileBytes = 4 * 1_024 * 1_024
    public static let maximumMessages = 80
    public static let maximumMessageCharacters = 8_000

    public static func messages(
        for session: ClaudeCodeSession,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ClaudeTranscriptMessage] {
        guard let url = sessionFileURL(for: session, homeDirectory: homeDirectory),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? maximumFileBytes + 1) <= maximumFileBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else {
            return []
        }
        return messages(from: data)
    }

    /// Exposed for deterministic tests and for callers that already have a
    /// bounded local JSONL file. It extracts visible user/assistant text and
    /// tool names, deliberately omitting thinking blocks and tool payloads.
    public static func messages(from data: Data) -> [ClaudeTranscriptMessage] {
        guard data.count <= maximumFileBytes,
              let content = String(data: data, encoding: .utf8) else { return [] }

        var parsed: [ClaudeTranscriptMessage] = []
        for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let extracted = extract(message: message, role: type == "user" ? .user : .assistant),
                  !extracted.text.isEmpty else { continue }

            let id = (object["uuid"] as? String).flatMap(nonEmpty)
                ?? "line-\(lineIndex)"
            parsed.append(ClaudeTranscriptMessage(
                id: id,
                role: extracted.role,
                text: extracted.text,
                toolName: extracted.toolName,
                timestamp: date(from: object["timestamp"] as? String)
            ))
            if parsed.count > maximumMessages {
                parsed.removeFirst(parsed.count - maximumMessages)
            }
        }
        return parsed
    }

    public static func sessionFileURL(
        for session: ClaudeCodeSession,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let safeID = AIActivityPolicy.safeIdentifier(session.id)
        guard !safeID.isEmpty, safeID == session.id else { return nil }

        let claudeDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
        let projects = claudeDirectory
            .appendingPathComponent("projects", isDirectory: true)
        guard safeDirectory(claudeDirectory), safeDirectory(projects) else {
            return nil
        }

        // Claude Code's project-folder slug is undocumented and has changed
        // between releases, so it is not reimplemented here. The transcript
        // file is named after the session id inside one project folder; find
        // it, and prefer a candidate whose recorded cwd matches when several
        // folders hold a file with this id.
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var candidates: [URL] = []
        for directory in directories.prefix(500) {
            guard let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                safeDirectory(directory) else { continue }
            let candidate = directory.appendingPathComponent("\(safeID).jsonl", isDirectory: false)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        if !session.cwd.isEmpty,
           let matching = candidates.first(where: { transcriptMatches($0, cwd: session.cwd) }) {
            return matching
        }
        return candidates[0]
    }

    /// Reads only the head of a candidate transcript to see whether it records
    /// this session's working directory. Bounded so a huge file cannot stall
    /// the on-demand conversation read.
    private static func transcriptMatches(_ url: URL, cwd: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536),
              let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let recorded = object["cwd"] as? String else { continue }
            if recorded == cwd { return true }
        }
        return false
    }

    private static func extract(
        message: [String: Any],
        role: ClaudeTranscriptRole
    ) -> (role: ClaudeTranscriptRole, text: String, toolName: String?)? {
        if let content = message["content"] as? String {
            let text = visibleText(content)
            guard !text.isEmpty else { return nil }
            return (role, text, nil)
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        var textParts: [String] = []
        var toolNames: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String {
                    let visible = visibleText(text)
                    if !visible.isEmpty { textParts.append(visible) }
                }
            case "tool_use":
                if let name = block["name"] as? String,
                   let visible = bounded(name, maximum: 120) {
                    toolNames.append(visible)
                }
            default:
                // Tool results and hidden reasoning are intentionally omitted.
                continue
            }
        }

        if !textParts.isEmpty {
            let toolSuffix = toolNames.isEmpty ? nil : "Tool: " + toolNames.joined(separator: ", ")
            let combined = ([textParts.joined(separator: "\n\n"), toolSuffix].compactMap { $0 })
                .joined(separator: "\n\n")
            return (role, bounded(combined, maximum: maximumMessageCharacters) ?? "", nil)
        }
        guard let firstTool = toolNames.first else { return nil }
        return (
            .tool,
            bounded("Used \(toolNames.joined(separator: ", "))", maximum: maximumMessageCharacters) ?? "",
            firstTool
        )
    }

    private static func visibleText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<command-name>"),
              !trimmed.hasPrefix("<local-command"),
              !trimmed.hasPrefix("Caveat:") else { return "" }
        return bounded(trimmed.replacingOccurrences(of: "\0", with: ""), maximum: maximumMessageCharacters) ?? ""
    }

    private static func date(from value: String?) -> Date {
        guard let value else { return Date() }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value) ?? Date()
    }

    private static func bounded(_ value: String, maximum: Int) -> String? {
        let result = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
        return result.isEmpty ? nil : result
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func safeDirectory(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFDIR
    }
}
