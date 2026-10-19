import Foundation

/// Lets NotchShot answer Claude Code's `AskUserQuestion` from the notch.
///
/// The bundled hook sees the tool call in `PreToolUse`. It forwards only the
/// questions and option labels (redacted like every other label) and waits
/// for the island. The island answers by option index, so redaction never has
/// to round-trip: the hook maps the indices back onto Claude's original
/// question text and labels, then returns them as the tool's `answers`, which
/// Claude accepts in place of the terminal picker.
///
/// If NotchShot is closed, the user picks "Answer in terminal", or nobody
/// answers before the timeout, the hook returns nothing and Claude shows its
/// own picker as usual.
public enum ClaudeQuestionBridge {
    public static let toolName = "AskUserQuestion"
    /// Socket `status` for a hook that is waiting on an answer.
    public static let waitingStatus = "waiting_for_answer"
    /// How long the hook holds Claude's prompt before handing it back.
    public static let answerTimeoutMilliseconds: Int32 = 120_000

    public static let maximumQuestions = 4
    public static let maximumOptions = 6

    public static func isQuestionTool(_ toolName: String?) -> Bool {
        toolName == Self.toolName
    }

    /// The bounded, redacted copy of the questions sent to NotchShot.
    public static func socketQuestions(fromToolInput toolInput: Any?) -> [[String: Any]]? {
        guard let input = toolInput as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              !questions.isEmpty
        else { return nil }

        let result = questions.prefix(maximumQuestions).compactMap { question -> [String: Any]? in
            guard let text = question["question"] as? String, !text.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).prefix(maximumOptions).compactMap { option -> [String: Any]? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                var entry: [String: Any] = ["label": clip(CommandSecretRedactor.redactText(label), 80)]
                if let description = option["description"] as? String, !description.isEmpty {
                    entry["description"] = clip(CommandSecretRedactor.redactText(description), 160)
                }
                return entry
            }
            guard !options.isEmpty else { return nil }
            var entry: [String: Any] = [
                "question": clip(CommandSecretRedactor.redactText(text), 240),
                "options": options,
                "multiSelect": question["multiSelect"] as? Bool ?? false,
            ]
            if let header = question["header"] as? String, !header.isEmpty {
                entry["header"] = clip(CommandSecretRedactor.redactText(header), 40)
            }
            return entry
        }
        return result.count == questions.prefix(maximumQuestions).count ? result : nil
    }

    /// The hook's stdout for NotchShot's reply, or nil to let Claude ask in
    /// the terminal. The reply is `{"decision": "answer", "answers":
    /// {"0": ["1"], "1": ["0", "2"]}}`, option indices per question index.
    public static func hookOutput(reply: Data, toolInput: Any?) -> String? {
        guard let line = String(data: reply, encoding: .utf8)?
                .split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["decision"] as? String == "answer",
              let indices = object["answers"] as? [String: Any],
              var input = toolInput as? [String: Any],
              let questions = input["questions"] as? [[String: Any]]
        else { return nil }

        var answers: [String: String] = [:]
        for (index, question) in questions.prefix(maximumQuestions).enumerated() {
            guard let text = question["question"] as? String,
                  let chosen = indices[String(index)] as? [String]
            else { return nil }
            let options = question["options"] as? [[String: Any]] ?? []
            let labels = chosen.compactMap(Int.init).compactMap { optionIndex -> String? in
                guard options.indices.contains(optionIndex) else { return nil }
                return options[optionIndex]["label"] as? String
            }
            guard !labels.isEmpty else { return nil }
            answers[text] = labels.joined(separator: ", ")
        }
        guard !answers.isEmpty else { return nil }
        input["answers"] = answers

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Answered in NotchShot",
                "updatedInput": input,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func clip(_ value: String, _ maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }
}
