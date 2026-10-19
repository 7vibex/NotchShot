import Foundation

public enum AIHookIntegration: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case cursor

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    var relativePath: String {
        switch self {
        case .claude: ".claude/settings.json"
        case .codex: ".codex/hooks.json"
        case .cursor: ".cursor/hooks.json"
        }
    }

    var events: [String] {
        switch self {
        case .claude:
            [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PostToolUseFailure",
                "PermissionDenied",
                "Notification",
                "Stop",
                "StopFailure",
                "PreCompact",
                "PostCompact",
                "SessionEnd",
            ]
        case .codex:
            ["UserPromptSubmit", "SessionStart", "PreToolUse", "PostToolUse", "Stop"]
        case .cursor:
            ["beforeSubmitPrompt", "preToolUse", "postToolUseFailure", "stop", "sessionEnd"]
        }
    }
}

public struct AIHookInstallationResult: Sendable, Equatable {
    public var integration: AIHookIntegration
    public var addedEvents: Int
    public var backupURL: URL?
    public var enabledRuntime: Bool = false

    public var message: String {
        if addedEvents == 0 {
            return enabledRuntime
                ? "\(integration.title) hooks were already present, and the hook runtime is now enabled."
                : "\(integration.title) was already connected."
        }
        let runtime = enabledRuntime ? " The Codex hook runtime was enabled." : ""
        return "Connected \(integration.title) with \(addedEvents) lifecycle hooks.\(runtime)"
    }
}

public enum AIHookInstallerError: LocalizedError {
    case invalidReporter
    case unsafeConfiguration
    case oversizedConfiguration
    case malformedConfiguration
    case unsupportedCodexConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidReporter: "The bundled notchshot-ai reporter could not be found."
        case .unsafeConfiguration: "The hook configuration is a symbolic link or another unsafe file type."
        case .oversizedConfiguration: "The existing hook configuration is unexpectedly large and was left untouched."
        case .malformedConfiguration: "The existing hook configuration is malformed and was left untouched."
        case .unsupportedCodexConfiguration:
            "The existing Codex feature settings cannot be safely edited automatically and were left untouched. Use an explicit [features] table with a codex_hooks boolean, then try again."
        }
    }
}

/// Adds only NotchShot command hooks, preserving every unrelated JSON key and
/// hook. Existing files are backed up before an atomic replacement.
@MainActor
public final class AIHookInstaller {
    public static let shared = AIHookInstaller()
    private static let maximumConfigurationBytes = 1_048_576

    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func configurationURL(for integration: AIHookIntegration) -> URL {
        home.appendingPathComponent(integration.relativePath)
    }

    public func install(
        _ integration: AIHookIntegration,
        reporterURL: URL
    ) throws -> AIHookInstallationResult {
        let reporterValues = try? reporterURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
        guard reporterValues?.isRegularFile == true, reporterValues?.isExecutable == true else {
            throw AIHookInstallerError.invalidReporter
        }

        // Validate the TOML edit before installing JSON hooks, so unsupported
        // syntax cannot leave a partially installed integration behind.
        let codexConfiguration = integration == .codex ? try preparedCodexHookConfiguration() : nil

        let destination = configurationURL(for: integration)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        var backupURL: URL?
        if manager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AIHookInstallerError.unsafeConfiguration
            }
            guard (values.fileSize ?? Self.maximumConfigurationBytes + 1) <= Self.maximumConfigurationBytes else {
                throw AIHookInstallerError.oversizedConfiguration
            }
            let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIHookInstallerError.malformedConfiguration
            }
            root = decoded
        }

        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let decodedHooks = existingHooks as? [String: Any] else {
                throw AIHookInstallerError.malformedConfiguration
            }
            hooks = decodedHooks
        } else {
            hooks = [:]
        }
        var added = 0
        for event in integration.events {
            let command = "\(Self.shellQuoted(reporterURL.path)) hook --source \(integration.rawValue) --event \(event)"
            var entries: [[String: Any]]
            if let existingEntries = hooks[event] {
                guard let decodedEntries = existingEntries as? [[String: Any]] else {
                    throw AIHookInstallerError.malformedConfiguration
                }
                entries = decodedEntries
            } else {
                entries = []
            }
            // A hook that already points at this build is left alone; one that
            // points at a previous (moved) install path is replaced so Connect
            // repairs the configuration instead of reporting success.
            if let existing = entries.compactMap(Self.notchShotCommand).first {
                if existing.contains(Self.shellQuoted(reporterURL.path)) { continue }
                entries.removeAll { Self.notchShotCommand($0) != nil }
            }
            if integration == .cursor {
                entries.append(["type": "command", "command": command])
            } else {
                entries.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": command]],
                ])
            }
            hooks[event] = entries
            added += 1
        }
        root["hooks"] = hooks
        if integration == .cursor, root["version"] == nil { root["version"] = 1 }

        // Enable the Codex runtime before the JSON hooks are replaced: if this
        // write fails, the previous hook configuration is untouched. The
        // remaining failure (hooks written, flag not) leaves no live hooks.
        if let codexConfiguration { try writeCodexHookConfiguration(codexConfiguration) }

        if added > 0 || !manager.fileExists(atPath: destination.path) {
            if manager.fileExists(atPath: destination.path) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backup = destination.appendingPathExtension(
                    "notchshot-backup-\(stamp)-\(UUID().uuidString.prefix(8))"
                )
                try manager.copyItem(at: destination, to: backup)
                backupURL = backup
            }
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            let temporary = parent.appendingPathComponent(".notchshot-hooks-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let enabledRuntime = codexConfiguration != nil
        return AIHookInstallationResult(
            integration: integration,
            addedEvents: added,
            backupURL: backupURL,
            enabledRuntime: enabledRuntime
        )
    }

    private func preparedCodexHookConfiguration() throws -> String? {
        let url = home.appendingPathComponent(".codex/config.toml")
        let manager = FileManager.default
        var text = ""
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AIHookInstallerError.unsafeConfiguration
            }
            guard (values.fileSize ?? Self.maximumConfigurationBytes + 1) <= Self.maximumConfigurationBytes else {
                throw AIHookInstallerError.oversizedConfiguration
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw AIHookInstallerError.malformedConfiguration
            }
            text = decoded
        }

        return try CodexHookConfigurationEditor.enablingHooks(in: text)
    }

    private func writeCodexHookConfiguration(_ output: String) throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("notchshot-backup-\(UUID().uuidString.prefix(8))")
            try manager.copyItem(at: url, to: backup)
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".notchshot-config-\(UUID().uuidString).tmp")
        try Data(output.utf8).write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The NotchShot reporter command inside one hook entry, if present at any
    /// nesting depth.
    private static func notchShotCommand(_ entry: [String: Any]) -> String? {
        if let command = entry["command"] as? String, command.contains("notchshot-ai") {
            return command
        }
        for nested in entry["hooks"] as? [[String: Any]] ?? [] {
            if let command = nested["command"] as? String, command.contains("notchshot-ai") {
                return command
            }
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Claude status line

public enum ClaudeStatusLineInstallResult: Equatable, Sendable {
    case alreadyInstalled
    case installed
    /// The user's own status line now runs through NotchShot's, which prints
    /// its output unchanged.
    case wrapped

    public var message: String {
        switch self {
        case .alreadyInstalled: "Claude usage is already reaching the notch."
        case .installed: "Claude usage now reaches the notch. It appears after Claude's next reply."
        case .wrapped: "Claude usage now reaches the notch. Your own status line still shows as before."
        }
    }
}

extension AIHookInstaller {
    /// Points Claude Code's `statusLine` at `notchshot-ai statusline`, which
    /// records plan limits and context for the usage rings. An existing
    /// command status line is kept by passing it to `--then`; any other
    /// unrelated setting is left untouched and the file is backed up first.
    public func installClaudeStatusLine(reporterURL: URL) throws -> ClaudeStatusLineInstallResult {
        let reporterValues = try? reporterURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
        guard reporterValues?.isRegularFile == true, reporterValues?.isExecutable == true else {
            throw AIHookInstallerError.invalidReporter
        }
        let destination = configurationURL(for: .claude)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if manager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AIHookInstallerError.unsafeConfiguration
            }
            guard (values.fileSize ?? Self.statusLineMaximumBytes + 1) <= Self.statusLineMaximumBytes else {
                throw AIHookInstallerError.oversizedConfiguration
            }
            let data = try Data(contentsOf: destination)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIHookInstallerError.malformedConfiguration
            }
            root = decoded
        }

        let ours = Self.shellQuoted(reporterURL.path) + " statusline"
        let result: ClaudeStatusLineInstallResult
        var statusLine: [String: Any] = ["type": "command"]
        if let existing = root["statusLine"] {
            guard let object = existing as? [String: Any] else { throw AIHookInstallerError.malformedConfiguration }
            let command = object["command"] as? String ?? ""
            if command.contains("notchshot-ai") {
                if command.hasPrefix(ours) { return .alreadyInstalled }
                // A moved install: keep whatever it was chaining to.
                let chained = Self.chainedCommand(in: command)
                statusLine = object
                statusLine["command"] = chained.map { ours + " --then " + Self.shellQuoted($0) } ?? ours
                result = chained == nil ? .installed : .wrapped
            } else if object["type"] as? String == "command", !command.isEmpty {
                statusLine = object
                statusLine["command"] = ours + " --then " + Self.shellQuoted(command)
                result = .wrapped
            } else {
                throw AIHookInstallerError.malformedConfiguration
            }
        } else {
            statusLine["command"] = ours
            result = .installed
        }
        root["statusLine"] = statusLine

        if manager.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = destination.appendingPathExtension("notchshot-backup-\(stamp)-\(UUID().uuidString.prefix(8))")
            try manager.copyItem(at: destination, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let temporary = parent.appendingPathComponent(".notchshot-statusline-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return result
    }

    /// Whether Claude's settings already route the status line through
    /// NotchShot.
    public func hasClaudeStatusLine() -> Bool {
        let destination = configurationURL(for: .claude)
        guard let data = try? Data(contentsOf: destination),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return false }
        return command.contains("notchshot-ai") && command.contains("statusline")
    }

    private static let statusLineMaximumBytes = 1_048_576

    /// The single-quoted command after `--then`, unescaped.
    static func chainedCommand(in command: String) -> String? {
        guard let range = command.range(of: " --then '") else { return nil }
        var quoted = String(command[range.upperBound...])
        guard quoted.hasSuffix("'") else { return nil }
        quoted.removeLast()
        return quoted.replacingOccurrences(of: "'\\''", with: "'")
    }
}
