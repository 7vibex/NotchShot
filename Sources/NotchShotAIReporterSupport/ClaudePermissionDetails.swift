import Foundation

/// Only complete, inspectable actions may be approved away from Claude's own
/// terminal. Unsupported tools or hidden details keep Claude's normal prompt.
public enum ClaudePermissionDetails {
    public static let maximumBytes = 8 * 1_024
    private static let bashKeys: Set<String> = [
        "command", "description", "timeout", "run_in_background", "dangerouslyDisableSandbox",
    ]

    public static func actionDescription(tool: String?, input: Any?, cwd: String?) -> String? {
        guard tool == "Bash", let input = input as? [String: Any],
              Set(input.keys).isSubset(of: bashKeys),
              let command = input["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cwd, (cwd as NSString).isAbsolutePath,
              isInspectable(command), isInspectable(cwd) else { return nil }
        var action: [String: Any] = ["command": command, "cwd": cwd]
        if let timeout = input["timeout"] {
            guard let number = timeout as? NSNumber else { return nil }
            action["timeout"] = number
        }
        for key in ["run_in_background", "dangerouslyDisableSandbox"] {
            if let value = input[key] {
                guard let flag = value as? Bool else { return nil }
                action[key] = flag
            }
        }
        guard JSONSerialization.isValidJSONObject(action),
              let data = try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys, .prettyPrinted]),
              data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Revalidate the wire value rather than trusting a completeness flag from
    /// an older reporter or an unrelated same-user socket client.
    public static func validated(_ text: String?, tool: String?) -> String? {
        guard let text, text.utf8.count <= maximumBytes,
              var action = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let cwd = action.removeValue(forKey: "cwd") as? String else { return nil }
        return actionDescription(tool: tool, input: action, cwd: cwd)
    }

    private static func isInspectable(_ text: String) -> Bool {
        guard text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .format
                      || (CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t")
              }) else { return false }
        let normalized = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        // Never transmit credentials or offer approval for an action whose
        // redacted portion the user cannot inspect. Keep original whitespace
        // when no redaction is needed; it can change shell semantics.
        return CommandSecretRedactor.redactText(text) == normalized
    }
}
