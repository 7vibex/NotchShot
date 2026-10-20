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
              let data = newestRows(of: url, maximumBytes: maximumFileBytes)
        else {
            return []
        }
        return messages(from: data)
    }

    /// The newest rows of a transcript, at most `maximumBytes` of them.
    ///
    /// Only the last window of messages is shown, and a session that reads a
    /// few screenshots passes the cap long before its conversation is long, so
    /// a large transcript is read from that far before its end instead of
    /// refused whole. The first row is dropped there, since the window begins
    /// inside it. The file is opened without following a link or waiting on a
    /// FIFO, and must be a regular file.
    static func newestRows(of url: URL, maximumBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              maximumBytes > 0 else { return nil }
        let start = max(0, information.st_size - Int64(maximumBytes))
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.read(upToCount: maximumBytes) ?? Data() else { return nil }
        guard start > 0 else { return data }
        guard let newline = data.firstIndex(of: 10) else { return Data() }
        return Data(data[data.index(after: newline)...])
    }

    /// Exposed for deterministic tests and for callers that already have a
    /// bounded local JSONL file. It extracts visible user/assistant text and
    /// tool names, deliberately omitting thinking blocks and tool payloads.
    public static func messages(from data: Data) -> [ClaudeTranscriptMessage] {
        guard data.count <= maximumFileBytes,
              let content = String(data: data, encoding: .utf8) else { return [] }

        // Each JSONL row is independent and only the last visible window is
        // returned. Walk backward so older discarded messages need no JSON,
        // text or timestamp processing. Enumerate before reversing to retain
        // the original fallback IDs, including ignored nonempty rows.
        var newest: [(id: String, role: ClaudeTranscriptRole, text: String,
            toolName: String?, timestamp: String?)] = []
        newest.reserveCapacity(maximumMessages)
        for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated().reversed() {
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
            newest.append((
                id: id,
                role: extracted.role,
                text: extracted.text,
                toolName: extracted.toolName,
                timestamp: object["timestamp"] as? String
            ))
            if newest.count == maximumMessages { break }
        }
        // Resolve dates in original order so missing/invalid timestamp
        // fallbacks still advance through the visible conversation. Formatter
        // state stays local to this read, including for concurrent callers.
        let dateFormatter = ISO8601DateFormatter()
        return newest.reversed().map { message in
            ClaudeTranscriptMessage(
                id: message.id,
                role: message.role,
                text: message.text,
                toolName: message.toolName,
                timestamp: date(from: message.timestamp, formatter: dateFormatter)
            )
        }
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

    private static func date(from value: String?, formatter: ISO8601DateFormatter) -> Date {
        guard let value else { return Date() }
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
