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
            ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "PostToolUseFailure", "Stop", "SessionEnd"]
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

    public var errorDescription: String? {
        switch self {
        case .invalidReporter: "The bundled notchshot-ai reporter could not be found."
        case .unsafeConfiguration: "The hook configuration is a symbolic link or another unsafe file type."
        case .oversizedConfiguration: "The existing hook configuration is unexpectedly large and was left untouched."
        case .malformedConfiguration: "The existing hook configuration is not a JSON object and was left untouched."
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

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var added = 0
        for event in integration.events {
            let command = "\(Self.shellQuoted(reporterURL.path)) hook --source \(integration.rawValue) --event \(event)"
            var entries = hooks[event] as? [[String: Any]] ?? []
            guard !Self.containsNotchShotCommand(entries) else { continue }
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
        let enabledRuntime = integration == .codex ? try enableCodexHookRuntime() : false
        return AIHookInstallationResult(
            integration: integration,
            addedEvents: added,
            backupURL: backupURL,
            enabledRuntime: enabledRuntime
        )
    }

    private func enableCodexHookRuntime() throws -> Bool {
        let url = home.appendingPathComponent(".codex/config.toml")
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

        var lines = text.components(separatedBy: .newlines)
        var sectionStart: Int?
        var sectionEnd = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[features]" {
                sectionStart = index
                continue
            }
            if sectionStart != nil, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                sectionEnd = index
                break
            }
        }

        var changed = false
        if let sectionStart {
            var found = false
            for index in (sectionStart + 1)..<sectionEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("codex_hooks") else { continue }
                found = true
                if trimmed != "codex_hooks = true" {
                    lines[index] = "codex_hooks = true"
                    changed = true
                }
                break
            }
            if !found {
                lines.insert("codex_hooks = true", at: sectionStart + 1)
                changed = true
            }
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("[features]")
            lines.append("codex_hooks = true")
            changed = true
        }
        guard changed else { return false }

        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("notchshot-backup-\(UUID().uuidString.prefix(8))")
            try manager.copyItem(at: url, to: backup)
        }
        let output = lines.joined(separator: "\n")
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
        return true
    }

    private static func containsNotchShotCommand(_ entries: [[String: Any]]) -> Bool {
        entries.contains { entry in
            if let command = entry["command"] as? String, command.contains("notchshot-ai") { return true }
            let nested = entry["hooks"] as? [[String: Any]] ?? []
            return nested.contains { ($0["command"] as? String)?.contains("notchshot-ai") == true }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
